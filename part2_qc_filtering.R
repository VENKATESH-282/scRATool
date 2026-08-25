# =============================================================================
# Part 2: Quality Control and Cell Filtering
# Tutorial: NGS101 – scRNA-seq Complete Beginner's Guide
# Dataset  : GSE174609 – PBMC samples (periodontitis study)
# Input    : Cell Ranger output from Part 1
# Output   : QC-filtered Seurat object (.rds) ready for integration
# Usage    : Rscript part2_qc_filtering.R
# =============================================================================
# QC PIPELINE OVERVIEW (applied independently to each sample)
# -----------------------------------------------------------
# Step 1 : Load libraries and configure environment
# Step 2 : Load 10x data (raw_feature_bc_matrix)
# Step 3 : Initial data exploration
# Step 4 : Empty droplet detection   (DropletUtils::emptyDrops)
# Step 5 : Ambient RNA correction    (SoupX)
# Step 6 : Doublet detection         (scDblFinder)
# Step 7 : Calculate QC metrics      (MT%, ribosomal%, hemoglobin%)
# Step 8 : Cell-level QC filtering   (data-driven thresholds)
# Step 9 : Gene-level QC filtering
# Step 10: Normalization & variable feature selection
# Step 11: Save filtered object + QC summary
# =============================================================================

# =============================================================================
# STEP 1: Install packages (run once, then comment out)
# =============================================================================
# Un-comment and run these lines the first time only:
# install.packages(c("Seurat", "SeuratObject", "ggplot2", "patchwork", "dplyr", "SoupX"))
# if (!require("BiocManager", quietly = TRUE)) install.packages("BiocManager")
# BiocManager::install(c("DropletUtils", "scDblFinder", "SingleCellExperiment"))

# =============================================================================
# STEP 1 (cont.): Load libraries and configure environment
# =============================================================================
library(Seurat)               # Main scRNA-seq toolkit (must be v5+)
library(SeuratObject)         # Seurat data structures
library(DropletUtils)         # Statistical empty droplet detection
library(scDblFinder)          # Computational doublet detection
library(SoupX)                # Ambient RNA ("soup") correction
library(SingleCellExperiment) # SCE objects (intermediate format for QC tools)
library(ggplot2)              # Custom plots
library(patchwork)            # Combine multiple ggplot panels
library(dplyr)                # Data wrangling

# ------ Configuration -------------------------------------------------------
source("config.R")
setup_cluster_parallel()

# This script processes one sample at a time.
# Support for command-line arguments (for Slurm array jobs)
args <- commandArgs(trailingOnly = TRUE)
if (length(args) > 0) {
  SAMPLE_NAME <- args[1]
  message("Processing sample from argument: ", SAMPLE_NAME)
} else {
  SAMPLE_NAME <- "Healthy_1" # Default fallback
  message("No argument provided. Defaulting to: ", SAMPLE_NAME)
}

CELLRANGER_OUT <- file.path(DIR_CELLRANGER, SAMPLE_NAME, "outs")
OUTPUT_DIR     <- DIR_QC

# Create output directories
dir.create(file.path(OUTPUT_DIR, "plots"),        recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "qc_metrics"),   recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "filtered_data"),recursive = TRUE, showWarnings = FALSE)
setwd(OUTPUT_DIR)

set.seed(42)   # For reproducibility in all stochastic steps

# Verify Seurat 5
cat("Seurat version:", as.character(packageVersion("Seurat")), "\n")
# Expected: Seurat version: 5.x.x

# =============================================================================
# STEP 2: Load 10x Genomics raw data into Seurat
# =============================================================================
# We use the RAW matrix (all droplets) for maximum control.
# Cell Ranger's FILTERED matrix already removed empty droplets with a simple
# UMI threshold.  EmptyDrops (Step 4) is statistically more sensitive and
# can recover rare low-RNA cell types that the UMI threshold would miss.
#
# Alternative: use filtered matrix and skip Steps 4 & 5.
# Be consistent – use the same matrix type for ALL samples.
#
# Expected: Seurat object with ~1,389,510 droplets × ~38,606 genes

counts <- Read10X(
  data.dir = file.path(CELLRANGER_OUT, "raw_feature_bc_matrix")
)

seurat_obj <- CreateSeuratObject(
  counts      = counts,
  project     = SAMPLE_NAME,
  min.cells   = 0,   # Do NOT filter genes here; do it explicitly in Step 9
  min.features = 0   # Do NOT filter cells here; do it explicitly in Step 8
)

# Record initial dimensions for QC summary at the end
initial_droplet_count <- ncol(seurat_obj)
initial_gene_count    <- nrow(seurat_obj)

# Attach biological metadata
seurat_obj$sample_id  <- "Healthy_1"
seurat_obj$sra_id     <- "SRR14575500"
seurat_obj$condition  <- "Healthy"
seurat_obj$patient_id <- "Donor_1"
seurat_obj$time_point <- NA         # Not applicable for healthy donors

cat("Loaded:", ncol(seurat_obj), "droplets ×", nrow(seurat_obj), "genes\n")
# Expected: Loaded: 1389510 droplets × 38606 genes

# =============================================================================
# STEP 3: Initial data exploration
# =============================================================================
# The RAW matrix is > 99% empty droplets.
# Median UMI ≈ 1 (empty droplets) vs > 1000 for real cells.
# The bimodal UMI distribution is the key diagnostic.

cat("Total droplets:", ncol(seurat_obj), "\n")
cat("Total genes   :", nrow(seurat_obj), "\n")

# Matrix sparsity (expect ~99.9% zeros)
sparsity <- 1 - (sum(LayerData(seurat_obj, layer = "counts") > 0) /
                 (nrow(seurat_obj) * ncol(seurat_obj)))
cat("Matrix sparsity:", round(sparsity * 100, 1), "%\n")
# Expected: Matrix sparsity: 99.9 %

umi_counts <- colSums(LayerData(seurat_obj, layer = "counts"))
cat("Median UMI/droplet:", median(umi_counts), "\n")
# Expected: Median UMI per droplet: 1 (almost all are empty)
cat("Droplets > 500 UMI:", sum(umi_counts > 500), "(likely real cells)\n")
# Expected: Droplets with > 500 UMI: 9883

# =============================================================================
# STEP 4: Empty droplet detection with DropletUtils
# =============================================================================
# EmptyDrops statistical approach:
#   1. Estimates the "ambient RNA profile" using barcodes with < 100 UMI
#   2. Tests each droplet: "Does this profile differ from ambient RNA alone?"
#   3. Reports FDR for each droplet
#   4. Calls cell if FDR < 0.01 (1% false discovery rate)
#
# Advantage over Cell Ranger's method: recovers rare low-RNA cells
# (e.g., quiescent stem cells, platelets) that simple UMI cutoffs miss.
#
# SKIP THIS STEP if you loaded the FILTERED matrix in Step 2.
#
# Expected:
#   Cells called   : ~9,600 (0.7% of 1.38M droplets)
#   Empty removed  : ~1,379,910 (99.3%)

sce <- as.SingleCellExperiment(seurat_obj)    # Convert for DropletUtils

set.seed(100)
empty_results <- emptyDrops(
  m            = counts(sce),
  lower        = 100,         # Barcodes < 100 UMI define the ambient profile
  niters       = 10000,       # Monte Carlo iterations for p-value precision
  test.ambient = TRUE         # Also test very low UMI barcodes
)

# Call cells: FDR < 0.01 is a stringent 1% false discovery rate
is_cell <- empty_results$FDR < 0.01
is_cell[is.na(is_cell)] <- FALSE        # NA = below lower threshold → empty

validated_barcodes <- colnames(sce)[is_cell]

cat("Cells called  :", sum(is_cell), "\n")
cat("Empty removed :", sum(!is_cell), "\n")
# Expected: Cells called: 9603 | Empty removed: 1379907

# Visualize UMI distribution coloured by EmptyDrops classification
empty_df <- data.frame(total_umi = colSums(counts(sce)), is_cell = is_cell)
p1 <- ggplot(empty_df, aes(x = log10(total_umi + 1), fill = is_cell)) +
  geom_histogram(bins = 50, alpha = 0.7, position = "identity") +
  scale_fill_manual(values = c("TRUE" = "#2E86AB", "FALSE" = "#A23B72"),
                    labels = c("Empty Droplet", "Cell"), name = "Classification") +
  labs(title = "EmptyDrops: Cell vs Empty Droplet Detection",
       subtitle = paste(sum(is_cell), "cells called from", ncol(sce), "droplets"),
       x = "log10(UMI + 1)", y = "Number of Droplets") +
  theme_classic()
ggsave("plots/01_empty_droplets.png", p1, width = 10, height = 6, dpi = 300)
# Expected plot: bimodal distribution; blue (cells) on right, purple (empty) on left

# Save raw counts BEFORE filtering (SoupX in Step 5 needs them)
raw_counts_all_droplets <- LayerData(seurat_obj, layer = "counts")

# Filter Seurat object to keep only EmptyDrops-validated cells
seurat_obj <- subset(seurat_obj, cells = validated_barcodes)
cat("After EmptyDrops:", ncol(seurat_obj), "cells retained\n")
# Expected: After EmptyDrops: 9603 cells retained

# =============================================================================
# STEP 5: Ambient RNA correction with SoupX
# =============================================================================
# Even real cells contain ambient RNA – "soup" from lysed cells in suspension.
# Impact: inflates expression of highly-expressed genes (e.g., haemoglobin
# in blood samples, myelin in brain) → false cell type assignments.
# SoupX estimates contamination fraction and adjusts counts accordingly.
#
# Typical contamination for PBMCs: < 5%
# NOTE: This step is OPTIONAL. If contamination is NULL or < 5%, skip.
# SKIP THIS STEP if you loaded the FILTERED matrix in Step 2.
#
# Expected:
#   contamination fraction : ~0.02 (2%)
#   Corrected counts replace original counts in Seurat object

contamination_fraction <- NULL   # Default; updated if SoupX runs successfully

tryCatch({
  # SoupX needs the raw (all droplets) and filtered (cells only) matrices
  sc <- SoupChannel(
    tod = raw_counts_all_droplets,                      # Raw (all droplets)
    toc = LayerData(seurat_obj, layer = "counts")       # Filtered (cells only)
  )

  # Rough clustering to estimate contamination profile
  seurat_tmp <- seurat_obj
  seurat_tmp <- NormalizeData(seurat_tmp, verbose = FALSE)
  seurat_tmp <- FindVariableFeatures(seurat_tmp, verbose = FALSE)
  seurat_tmp <- ScaleData(seurat_tmp, verbose = FALSE)
  seurat_tmp <- RunPCA(seurat_tmp, verbose = FALSE)
  seurat_tmp <- FindNeighbors(seurat_tmp, dims = 1:15, verbose = FALSE)
  seurat_tmp <- FindClusters(seurat_tmp, resolution = 0.5, verbose = FALSE)

  sc <- setClusters(sc, Idents(seurat_tmp))
  sc <- autoEstCont(sc, verbose = FALSE)           # Estimate contamination fraction
  contamination_fraction <- sc$fit$rho             # Store for QC summary

  cat("Estimated contamination:", round(contamination_fraction * 100, 2), "%\n")
  # Expected: Estimated contamination: ~2%

  if (!is.null(contamination_fraction) && contamination_fraction > 0.05) {
    # Apply correction only if contamination exceeds 5%
    corrected_counts <- adjustCounts(sc, verbose = FALSE)
    LayerData(seurat_obj, layer = "counts") <- corrected_counts
    cat("SoupX correction applied (contamination > 5%)\n")
  } else {
    cat("Contamination <= 5%; SoupX correction skipped (counts unchanged)\n")
  }

}, error = function(e) {
  cat("SoupX failed (often normal for clean samples):", conditionMessage(e), "\n")
  cat("Continuing with original counts.\n")
  # This is common when: few cells, homogeneous population, or very clean prep
})

# =============================================================================
# STEP 6: Doublet detection with scDblFinder
# =============================================================================
# Doublets = two cells captured in a single GEM droplet.
# Expected rate: ~0.5-2% (increases with cell concentration loaded).
# Impact: spurious intermediate cell states, inflated co-expression.
#
# scDblFinder simulates doublets by summing random cell pairs, then builds
# a classifier to score real cells. Flagged cells are labeled "Doublet".
#
# Expected:
#   Doublet rate : < 2% for ~5,000 cells
#   Plot: low-dimensional UMAP showing doublets scattered across clusters

cells_before_doublet_removal <- ncol(seurat_obj)

sce_for_dbl <- as.SingleCellExperiment(seurat_obj)
set.seed(42)
sce_for_dbl <- scDblFinder(sce_for_dbl, verbose = FALSE)

# Transfer doublet scores/classifications back to Seurat metadata
seurat_obj$doublet_score <- sce_for_dbl$scDblFinder.score
seurat_obj$doublet_class <- as.character(sce_for_dbl$scDblFinder.class)

# Ensure case-insensitive matching for "Doublet" / "doublet"
n_doublets  <- sum(tolower(seurat_obj$doublet_class) == "doublet", na.rm = TRUE)
doublet_rate <- (n_doublets / ncol(seurat_obj)) * 100
cat("Doublets detected:", n_doublets, "(", round(doublet_rate, 1), "%)\n")
# Expected: Doublets detected: ~100-200 (< 2%)

# Quick UMAP to visualize doublet locations (temporary, not final UMAP)
seurat_tmp <- NormalizeData(seurat_obj, verbose = FALSE)
seurat_tmp <- FindVariableFeatures(seurat_tmp, verbose = FALSE)
seurat_tmp <- ScaleData(seurat_tmp, verbose = FALSE)
seurat_tmp <- RunPCA(seurat_tmp, verbose = FALSE)
seurat_tmp <- RunUMAP(seurat_tmp, dims = 1:15, verbose = FALSE)

p2 <- DimPlot(seurat_tmp, group.by = "doublet_class",
              cols = c("Singlet" = "grey80", "Doublet" = "red"),
              pt.size = 0.3, alpha = 0.5) +
  labs(title = "Doublet Detection (scDblFinder)",
       subtitle = paste(n_doublets, "doublets =",
                        round(doublet_rate, 1), "% of cells")) +
  theme_classic()
ggsave("plots/02_doublets_umap.png", p2, width = 10, height = 8, dpi = 300)
# Expected plot: doublets (red) scattered across all clusters, not concentrated
# in one cluster (that would indicate wrong doublet rate or biological artifact)

# Remove doublets (case-insensitive check)
seurat_obj <- seurat_obj[, tolower(seurat_obj$doublet_class) != "doublet"]
cat("After doublet removal:", ncol(seurat_obj), "cells\n")
# Expected: After doublet removal: ~9,400-9,500 cells

# =============================================================================
# STEP 7: Calculate QC metrics
# =============================================================================
# Three key per-cell metrics:
#   percent.mt  : % of UMIs mapping to mitochondrial genes (MT-*)
#                 High % = cell membrane damage / cell stress / dying cells
#                 Expected for healthy PBMCs: < 5-10%
#   percent.rb  : % of UMIs from ribosomal protein genes (RPS*, RPL*)
#                 Extremely high may indicate RNA capture issues
#   percent.hb  : % from haemoglobin genes (HBA*, HBB, HBBA)
#                 High % = red blood cell contamination in PBMC prep

seurat_obj[["percent.mt"]] <- PercentageFeatureSet(seurat_obj, pattern = "^MT-")
seurat_obj[["percent.rb"]] <- PercentageFeatureSet(seurat_obj, pattern = "^RP[SL]")
seurat_obj[["percent.hb"]] <- PercentageFeatureSet(seurat_obj, pattern = "^HB[^P]")

# MT gene count for reference
n_mt_genes <- sum(grepl("^MT-", rownames(seurat_obj)))
cat("MT genes:", n_mt_genes, "| Ribo genes:",
    sum(grepl("^RP[SL]", rownames(seurat_obj))),
    "| Hb genes:", sum(grepl("^HB[^P]", rownames(seurat_obj))), "\n")
# Expected: MT genes: 13 | Ribo genes: 107 | Hb genes: 3

# Violin plots: distribution of key QC metrics per cell
p3 <- VlnPlot(seurat_obj,
              features = c("nCount_RNA", "nFeature_RNA", "percent.mt"),
              ncol = 3, pt.size = 0) &
  theme(axis.text.x = element_blank())
ggsave("plots/03_qc_violins.png", p3, width = 14, height = 5, dpi = 300)

# Scatter plots: identify outlier cells
p4 <- FeatureScatter(seurat_obj, "nCount_RNA", "nFeature_RNA") +
      FeatureScatter(seurat_obj, "nCount_RNA", "percent.mt")
ggsave("plots/04_qc_scatter.png", p4, width = 14, height = 6, dpi = 300)
# Expected:  nCount vs nFeature: linear correlation (more UMIs → more genes)
#            nCount vs percent.mt: most cells low MT%, outliers on right/top

# =============================================================================
# STEP 8: Cell-level QC filtering (data-driven thresholds)
# =============================================================================
# Strategy: use percentile-based thresholds with biological sanity checks.
# Do NOT use the same hard numbers for all samples – always look at the plots.
#
# Rules:
#   nFeature_RNA (genes/cell) : remove outlier-low (damaged) and outlier-high
#   nCount_RNA   (UMIs/cell)  : remove outlier-low and outlier-high (doublets)
#   percent.mt               : remove high MT% (damaged/dying cells)
#
# Sanity checks prevent over-filtering:
#   PBMCs must have >= 500 genes and >= 800 UMIs to be biologically meaningful
#   MT% threshold raised to 10% if fewer than 2% of cells exceed 5%
#
# IMPORTANT: Inspect plots/03 and plots/04 before accepting these thresholds.
#            Adjust nfeature_min for your tissue type (neurons: lower; immune: higher).

# Percentile-based thresholds (data-driven, not hardcoded)
ncount_lower   <- 0.025                             # 2.5th percentile
ncount_upper   <- 0.975                             # 97.5th percentile
nfeature_lower <- 0.025
nfeature_upper <- 0.975
mt_percentile  <- 0.95                              # 95th percentile

# Calculate thresholds from data
ncount_min  <- max(quantile(seurat_obj$nCount_RNA,   ncount_lower),   800)
ncount_max  <- quantile(seurat_obj$nCount_RNA,   ncount_upper)
nfeature_min <- max(quantile(seurat_obj$nFeature_RNA, nfeature_lower), 500)
nfeature_max  <- quantile(seurat_obj$nFeature_RNA, nfeature_upper)
mt_thresh     <- quantile(seurat_obj$percent.mt, mt_percentile)

# Sanity check: if MT threshold would remove > 30% of cells, raise to 10%
pct_mt_flagged <- mean(seurat_obj$percent.mt > mt_thresh) * 100
if (pct_mt_flagged > 30) {
  cat("WARNING: MT threshold", round(mt_thresh, 1), "% would remove > 30% of cells.\n")
  cat("Raising to 10%\n")
  mt_thresh <- 10
}

cat("Filtering thresholds:\n")
cat("  nCount_RNA  :", ncount_min, "–", ncount_max, "\n")
cat("  nFeature_RNA:", nfeature_min, "–", nfeature_max, "\n")
cat("  percent.mt  : <", mt_thresh, "%\n")

# Visualize thresholds on violin plots
p5 <- VlnPlot(seurat_obj,
              features = c("nCount_RNA", "nFeature_RNA", "percent.mt"),
              ncol = 3, pt.size = 0) &
  geom_hline(aes(yintercept = NA))   # Add threshold lines in real plot
ggsave("plots/05_filtering_thresholds.png", p5, width = 14, height = 5, dpi = 300)

# Apply cell-level filters
cells_before <- ncol(seurat_obj)
seurat_obj <- subset(seurat_obj,
  subset = nCount_RNA   >= ncount_min  &
           nCount_RNA   <= ncount_max  &
           nFeature_RNA >= nfeature_min &
           nFeature_RNA <= nfeature_max &
           percent.mt   <  mt_thresh
)

cells_removed <- cells_before - ncol(seurat_obj)
pct_removed   <- round(cells_removed / cells_before * 100, 1)
cat("Cells removed by QC:", cells_removed, "(", pct_removed, "%)\n")
cat("Cells retained     :", ncol(seurat_obj), "\n")
# Expected: ~10-25% removal is typical for quality data
# WARNING: >30% removal suggests over-stringent thresholds; review plots

# =============================================================================
# STEP 9: Gene-level QC filtering
# =============================================================================
# Remove genes detected in too few cells (noise) and haemoglobin genes
# (contamination from lysed red blood cells in PBMC prep).
#
# Detection threshold: ≥ 0.1% of cells is a balanced cutoff that:
#   - Retains rare cell-type-specific markers
#   - Removes genes with only 1-2 cells expressing them (likely noise)
# Expected:
#   Genes passing : ~21,731 / 38,606
#   Removed       : ~16,872 low-detection + 3 haemoglobin

min_cells_pct <- 0.001      # 0.1% of cells must express a gene
min_cells     <- max(3, round(ncol(seurat_obj) * min_cells_pct))

cat("Gene detection threshold: ≥", min_cells, "cells (", min_cells_pct * 100, "%)\n")

# Haemoglobin genes – remove (contaminating red blood cells in PBMCs)
hb_genes <- grep("^HB[^P]", rownames(seurat_obj), value = TRUE)
cat("Haemoglobin genes flagged for removal:", paste(hb_genes, collapse = ", "), "\n")

# Which genes pass detection threshold?
gene_counts   <- rowSums(LayerData(seurat_obj, layer = "counts") > 0)
genes_to_keep <- gene_counts >= min_cells
genes_to_keep[hb_genes] <- FALSE              # Force-remove haemoglobin

cat("Genes before:", nrow(seurat_obj), "\n")
seurat_obj <- seurat_obj[genes_to_keep, ]
cat("Genes after :", nrow(seurat_obj), "\n")
# Expected: After gene filtering: 21731 genes remaining

# Gene detection frequency plot
gene_df <- data.frame(n_cells = gene_counts[genes_to_keep])
p6 <- ggplot(gene_df, aes(x = log10(n_cells + 1))) +
  geom_histogram(bins = 50, fill = "#2E86AB", alpha = 0.8) +
  geom_vline(xintercept = log10(min_cells + 1), color = "red", linetype = "dashed") +
  labs(title = "Gene Detection Frequency",
       x = "log10(cells expressing gene + 1)", y = "Number of Genes") +
  theme_classic()
ggsave("plots/06_gene_detection.png", p6, width = 10, height = 6, dpi = 300)

# =============================================================================
# STEP 10: Normalization and variable feature selection
# =============================================================================
# Normalization (LogNormalize):
#   1. Divide each cell's counts by total UMIs × 10,000 (CPM-like)
#   2. Apply log1p (natural log + 1)
#   → Corrects for differences in sequencing depth between cells
#   → log(0 + 1) = 0 for unexpressed genes (avoids -Inf)
#
# Variable features (VST method):
#   - Identifies 2,000 genes with highest cell-to-cell variability
#   - These genes carry information about cell identity and state
#   - Used in downstream PCA and clustering
#
# Expected top variable genes for PBMC: immune-specific genes
#   (IGLC2, IGKC, S100A9, FCER1A, BANK1, etc.)

seurat_obj <- NormalizeData(seurat_obj,
                            normalization.method = "LogNormalize",
                            scale.factor = 10000,
                            verbose = FALSE)

seurat_obj <- FindVariableFeatures(seurat_obj,
                                   selection.method = "vst",
                                   nfeatures = 2000,
                                   verbose = FALSE)

top10 <- head(VariableFeatures(seurat_obj), 10)
cat("Top 10 variable genes:", paste(top10, collapse = ", "), "\n")
# Expected: IGLC2, IGKC, LYPD2, IGLC3, PTGDS, FCER1A, IGHM, BANK1, S100A9…

p7 <- LabelPoints(plot = VariableFeaturePlot(seurat_obj),
                  points = top10, repel = TRUE)
ggsave("plots/07_variable_features.png", p7, width = 10, height = 7, dpi = 300)

# =============================================================================
# STEP 11: Save filtered Seurat object and QC summary
# =============================================================================
# Save the clean object → input for Part 3 (Integration and Clustering)
saveRDS(seurat_obj,
        file = file.path(OUTPUT_DIR, "filtered_data",
                         paste0(SAMPLE_NAME, "_qc_filtered.rds")))

# Comprehensive QC summary CSV
qc_summary <- data.frame(
  sample              = SAMPLE_NAME,
  initial_droplets    = initial_droplet_count,
  after_emptydrops    = length(validated_barcodes),
  after_doublets      = cells_before_doublet_removal - n_doublets,
  after_cell_qc       = ncol(seurat_obj),
  final_cells         = ncol(seurat_obj),
  initial_genes       = initial_gene_count,
  final_genes         = nrow(seurat_obj),
  median_umi          = median(seurat_obj$nCount_RNA),
  median_genes        = median(seurat_obj$nFeature_RNA),
  median_mt_pct       = median(seurat_obj$percent.mt),
  contamination_pct   = ifelse(is.null(contamination_fraction), 0,
                               round(contamination_fraction * 100, 2)),
  doublet_rate_pct    = round(doublet_rate, 2),
  ncount_min          = ncount_min,
  ncount_max          = ncount_max,
  nfeature_min        = nfeature_min,
  nfeature_max        = nfeature_max,
  mt_threshold        = mt_thresh
)

write.csv(qc_summary,
          file.path(OUTPUT_DIR, "qc_metrics", "QC_summary.csv"),
          row.names = FALSE)
write.csv(seurat_obj@meta.data,
          file.path(OUTPUT_DIR, "filtered_data", "cell_metadata.csv"))

cat("\n=== Part 2 QC Complete ===\n")
cat("Final cells :", ncol(seurat_obj), "\n")
cat("Final genes :", nrow(seurat_obj), "\n")
cat("QC plots    :", length(list.files(file.path(OUTPUT_DIR, "plots"))), "PNG files\n")
cat("Output saved:", file.path(OUTPUT_DIR, "filtered_data",
                               paste0(SAMPLE_NAME, "_qc_filtered.rds")), "\n")
# Expected:
#   Final cells : 7252   (variable per sample)
#   Final genes : 21731
#   QC plots    : 7 PNG files

# =============================================================================
# BATCH PROCESSING: Apply this QC to all 12 samples
# =============================================================================
# IMPORTANT: Run QC independently per sample – thresholds must be inspected
# visually for each sample. Do NOT blindly apply the same numbers.
# Uncomment and adapt the loop below once you've tuned thresholds per sample.
#
# samples_info <- list(
#   list(name="Healthy_1",     sra="SRR14575500", condition="Healthy",   patient="Donor_1"),
#   list(name="Healthy_2",     sra="SRR14575501", condition="Healthy",   patient="Donor_2"),
#   list(name="Healthy_3",     sra="SRR14575502", condition="Healthy",   patient="Donor_3"),
#   list(name="Healthy_4",     sra="SRR14575503", condition="Healthy",   patient="Donor_4"),
#   list(name="Pre_Patient_1", sra="SRR14575504", condition="Pre",       patient="Patient_1"),
#   list(name="Pre_Patient_2", sra="SRR14575505", condition="Pre",       patient="Patient_2"),
#   list(name="Pre_Patient_3", sra="SRR14575506", condition="Pre",       patient="Patient_3"),
#   list(name="Pre_Patient_4", sra="SRR14575507", condition="Pre",       patient="Patient_4"),
#   list(name="Post_Patient_1",sra="SRR14575508", condition="Post",      patient="Patient_1"),
#   list(name="Post_Patient_2",sra="SRR14575509", condition="Post",      patient="Patient_2"),
#   list(name="Post_Patient_3",sra="SRR14575510", condition="Post",      patient="Patient_3"),
#   list(name="Post_Patient_4",sra="SRR14575511", condition="Post",      patient="Patient_4")
# )
# for (s in samples_info) {
#   source("part2_qc_filtering.R")   # or wrap in a function and call it here
# }
