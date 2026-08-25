# =============================================================================
# Part 8: Processing Human-Mouse Mixed Samples (PDX Models)
# Tutorial: NGS101 – scRNA-seq Complete Beginner's Guide
# Strategy  : Strategy 1 – Align First (Combined Ref), Separate Later
# Input     : Cell Ranger output directory (combined human-mouse reference)
# Output    : Human-only Seurat object, Mouse-only Seurat object, QC plots
# Usage     : Rscript part8_pdx_processing.R
# =============================================================================
# ANALYSIS PIPELINE OVERVIEW
# --------------------------
# Step 1 : Load gem_classification.csv (per-cell species assignments)
# Step 2 : Calculate Species Contamination & QC
# Step 3 : Load Combined Count Matrix
# Step 4 : Subset Matrix into Human and Mouse components
# Step 5 : Remove genome prefixes (GRCh38_ / GRCm39_)
# Step 6 : Save clean Seurat objects
# =============================================================================

library(Seurat)
library(ggplot2)
library(dplyr)
library(patchwork)
library(data.table)

# ------ Configuration -------------------------------------------------------
source("config.R")
setup_cluster_parallel()

SAMPLE_NAME      <- "PDX_sample1"
CELLRANGER_OUT   <- file.path(DIR_CELLRANGER, "combined", SAMPLE_NAME, "outs")
OUTPUT_DIR       <- file.path(PROJECT_DIR, "pdx_processing")
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

setwd(OUTPUT_DIR)

# =============================================================================
# STEP 1: Species Classification & Contamination QC
# =============================================================================
classification_file <- file.path(CELLRANGER_OUT, "analysis/gem_classification.csv")
if (!file.exists(classification_file)) {
  cat("\n[INFO] Classification file not found at:", classification_file, "\n")
  cat("[INFO] Part 8 is specifically for PDX models (Human-Mouse mixtues).\n")
  cat("[INFO] Since this dataset appears to be single-species, skipping Part 8.\n")
  cat("\n=== Part 8 Skipped (Not PDX data) ===\n")
  q(save = "no", status = 0)
}

gem_class <- fread(classification_file)
# Calculate ratios
gem_class[, total := GRCh38 + GRCm39]
gem_class[, mouse_fraction := GRCm39 / total]

# 1a. Species Count Bar Plot
p1 <- ggplot(gem_class, aes(x = call, fill = call)) +
      geom_bar() +
      labs(title = "Species Composition (Called Cells)", x = "Species Call", y = "Count") +
      theme_classic()

# 1b. Scatter Plot (Competitive Alignment Reality Check)
p2 <- ggplot(gem_class, aes(x = GRCh38+1, y = GRCm39+1, color = call)) +
      geom_point(alpha = 0.5, size = 0.5) +
      scale_x_log10() + scale_y_log10() +
      labs(title = "Human vs Mouse Reads", x = "Human reads (log)", y = "Mouse reads (log)") +
      theme_classic()

# 1c. Contamination Histogram
p3 <- ggplot(gem_class, aes(x = mouse_fraction)) +
      geom_histogram(bins = 100, fill = "steelblue") +
      labs(title = "Mouse Read Fraction Distribution", x = "Mouse / (Human + Mouse)", y = "Freq") +
      theme_classic()

ggsave("01_species_contamination_qc.png", p1 + p2 + p3, width = 15, height = 5)

# Report summary
stats <- gem_class %>% group_by(call) %>% summarize(n = n(), .groups="drop")
print(stats)

# =============================================================================
# STEP 2: Load Matrix and Subset
# =============================================================================
cat("Loading combined-reference matrix...\n")
counts <- Read10X(file.path(CELLRANGER_OUT, "filtered_feature_bc_matrix"))

# 2a. Define species-specific barcodes
human_bc <- gem_class[call == "GRCh38", barcode]
mouse_bc <- gem_class[call == "GRCm39",  barcode]

# 2b. Extract Human Matrix
cat("Splitting Human components...\n")
human_rows <- grep("^GRCh38_", rownames(counts), value = TRUE)
human_counts <- counts[human_rows, human_bc]
# Strip prefix
rownames(human_counts) <- sub("^GRCh38_", "", rownames(human_counts))
human_obj <- CreateSeuratObject(counts = human_counts, project = paste0(SAMPLE_NAME, "_human"))
human_obj$species <- "human"

# 2c. Extract Mouse Matrix (Stromal/Immune)
cat("Splitting Mouse components...\n")
mouse_rows <- grep("^GRCm39_", rownames(counts), value = TRUE)
mouse_counts <- counts[mouse_rows, mouse_bc]
# Strip prefix
rownames(mouse_counts) <- sub("^GRCm39_", "", rownames(mouse_counts))
mouse_obj <- CreateSeuratObject(counts = mouse_counts, project = paste0(SAMPLE_NAME, "_mouse"))
mouse_obj$species <- "mouse"

# =============================================================================
# STEP 3: Save Output
# =============================================================================
saveRDS(human_obj, paste0(SAMPLE_NAME, "_human_clean.rds"))
saveRDS(mouse_obj, paste0(SAMPLE_NAME, "_mouse_clean.rds"))

cat("\n=== Part 8 Complete ===\n")
cat("Clean Human object: ", ncol(human_obj), " cells\n")
cat("Clean Mouse object: ", ncol(mouse_obj), " cells\n")
