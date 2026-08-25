# =============================================================================
# Part 6: Understanding and Converting scRNA-seq Objects
# Tutorial: NGS101 – scRNA-seq Complete Beginner's Guide
# Input    : Final processed Seurat object from Part 5
# Output   : SingleCellExperiment conversion and diagnostic reports
# Usage    : Rscript part6_object_exploration.R
# =============================================================================
# This part is educational but crucial for interoperability with Bioconductor
# tools (like Monocle etc.) used in later parts.
# =============================================================================

library(Seurat)
library(SingleCellExperiment)
library(SummarizedExperiment)
library(dplyr)
library(ggplot2)

source("config.R")

# Load data from previous part
INPUT_RDS <- file.path(DIR_DE, "GSE174609_final_analysis.rds")
if (!file.exists(INPUT_RDS)) {
  # Fallback to Part 4 output if Part 5 wasn't run fully
  INPUT_RDS <- file.path(DIR_ANNOTATION, "GSE174609_annotated.rds")
}

if (!file.exists(INPUT_RDS)) stop("No input RDS found from Part 4 or 5.")

seurat_obj <- readRDS(INPUT_RDS)

# =============================================================================
# STEP 1: Seurat v5 Architecture Inspection
# =============================================================================
cat("\n--- Seurat Object Inspection ---\n")
print(seurat_obj)

cat("\nAvailable slots:\n")
print(slotNames(seurat_obj))

cat("\nRNA Assay layers (Seurat 5 structure):\n")
print(names(seurat_obj@assays$RNA@layers))

# =). Metadata Exploration
cat("\nMetadata columns:\n")
print(colnames(seurat_obj@meta.data))

# =============================================================================
# STEP 2: Conversion to SingleCellExperiment (SCE)
# =============================================================================
cat("\n--- Converting to SingleCellExperiment (Bioconductor Standard) ---\n")

# Use Seurat's built-in converter
# Note: In Seurat v5, this correctly transfers counts, data, and reductions.
sce <- as.SingleCellExperiment(seurat_obj)

cat("SCE Object summary:\n")
print(sce)

cat("\nAssays in SCE:\n")
print(assayNames(sce))

cat("\nDimensionality reductions in SCE:\n")
print(reducedDimNames(sce))

# =============================================================================
# STEP 3: SummarizedExperiment for Pseudobulk
# =============================================================================
cat("\n--- Creating SummarizedExperiment for Pseudobulk ---\n")

# Aggregate cells to cell_type level (since sample_id is constant/ignored in single-sample)
pb_counts <- AggregateExpression(seurat_obj, group.by = "cell_type",
                                 assays = "RNA", return.seurat = FALSE)$RNA

# Create metadata reflecting cell types
pb_metadata <- data.frame(
  cell_type = colnames(pb_counts),
  sample_id = unique(seurat_obj$sample_id),
  condition = unique(seurat_obj$condition),
  row.names = colnames(pb_counts)
)

se_pb <- SummarizedExperiment(
  assays = list(counts = as.matrix(pb_counts)),
  colData = pb_metadata
)

cat("SummarizedExperiment (Pseudobulk) created:\n")
print(se_pb)

# =============================================================================
# STEP 4: Save converted objects for Part 7 (Trajectory Analysis)
# =============================================================================
OUTPUT_DIR <- file.path(PROJECT_DIR, "object_conversions")
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

saveRDS(sce,   file = file.path(OUTPUT_DIR, "GSE174609_SCE.rds"))
saveRDS(se_pb, file = file.path(OUTPUT_DIR, "GSE174609_pseudobulk_SE.rds"))

cat("\n=== Part 6 Complete ===\n")
cat("Converted objects saved in:", OUTPUT_DIR, "\n")
cat("These objects are ready for use in Bioconductor-based tools (Part 7).\n")
