# =============================================================================
# Part 3: Integration and Clustering
# Tutorial: NGS101 – scRNA-seq Complete Beginner's Guide
# Input    : QC-filtered Seurat objects from Part 2
# Output   : Integrated + clustered Seurat object
# Usage    : Rscript part3_integration_clustering.R
# =============================================================================

library(Seurat)
library(ggplot2)
library(patchwork)
library(dplyr)
library(harmony)      # Harmony integration

# =============================================================================
# STEP 1: Load all QC-filtered samples and merge
# =============================================================================
source("config.R")
setup_cluster_parallel()

QC_DIR     <- file.path(DIR_QC, "filtered_data")
OUTPUT_DIR <- DIR_INTEGRATION

dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "plots"), recursive = TRUE, showWarnings = FALSE)

# Sample metadata table – defines all 12 samples
sample_info <- data.frame(
  sample    = c("Healthy_1","Healthy_2","Healthy_3","Healthy_4",
                "Pre_Patient_1","Pre_Patient_2","Pre_Patient_3","Pre_Patient_4",
                "Post_Patient_1","Post_Patient_2","Post_Patient_3","Post_Patient_4"),
  condition = c(rep("Healthy",4), rep("Pre",4), rep("Post",4)),
  patient   = c(paste0("Donor_",1:4),
                paste0("Patient_",1:4),
                paste0("Patient_",1:4)),
  stringsAsFactors = FALSE
)

# Load available QC-filtered samples
seurat_list <- list()
for (i in seq_len(nrow(sample_info))) {
  s      <- sample_info$sample[i]
  rds    <- file.path(QC_DIR, paste0(s, "_qc_filtered.rds"))
  if (!file.exists(rds)) next
  
  obj <- readRDS(rds)
  obj$condition   <- sample_info$condition[i]
  obj$patient_id  <- sample_info$patient[i]
  obj$sample_id   <- s
  seurat_list[[s]] <- obj
  cat("Loaded:", s, "–", ncol(obj), "cells\n")
}

if (length(seurat_list) == 0) stop("No QC-filtered RDS files found in: ", QC_DIR)

# Merge samples
merged <- merge(seurat_list[[1]], y = seurat_list[-1], 
                add.cell.ids = names(seurat_list), project = "GSE174609")

# Standard Pre-processing
merged <- NormalizeData(merged, verbose = FALSE)
merged <- FindVariableFeatures(merged, nfeatures = 2000, verbose = FALSE)
merged <- ScaleData(merged, verbose = FALSE)
merged <- RunPCA(merged, npcs = 30, verbose = FALSE)
merged <- RunUMAP(merged, dims = 1:30, verbose = FALSE)

# =============================================================================
# STEP 2: Handle Integration vs. Single-Sample clustering
# =============================================================================
if (length(seurat_list) < 2) {
  cat("\n[SINGLE SAMPLE MODE] Skipping integration, proceeding to clustering.\n")
  selected_obj     <- merged
  reduction_to_use <- "pca"
  umap_to_use      <- "umap"
} else {
  cat("\n[INTEGRATION MODE] Aligning ", length(seurat_list), " samples.\n")
  
  # Split layers for Seurat v5 integration
  merged[["RNA"]] <- split(merged[["RNA"]], f = merged$sample_id)
  
  # Method: CCA (Standard for this tutorial)
  cat("Running CCA integration...\n")
  selected_obj <- IntegrateLayers(
    object = merged, method = CCAIntegration,
    orig.reduction = "pca", new.reduction = "integrated.cca",
    verbose = FALSE
  )
  reduction_to_use <- "integrated.cca"
  umap_to_use      <- "umap.cca"
  
  selected_obj <- RunUMAP(selected_obj, dims = 1:30, 
                          reduction = reduction_to_use, 
                          reduction.name = umap_to_use, verbose = FALSE)
}

# =============================================================================
# STEP 3: Multi-resolution Clustering
# =============================================================================
selected_obj <- FindNeighbors(selected_obj, reduction = reduction_to_use, dims = 1:30, verbose = FALSE)

resolutions <- c(0.1, 0.3, 0.5, 0.8, 1.0)
for (res in resolutions) {
  selected_obj <- FindClusters(selected_obj, resolution = res, verbose = FALSE)
}

# Set default resolution
Idents(selected_obj) <- "RNA_snn_res.0.5"

# =============================================================================
# STEP 4: Visualizations
# =============================================================================
p1 <- DimPlot(selected_obj, reduction = umap_to_use, group.by = "sample_id", split.by = "sample_id", ncol = 4, label = FALSE, raster = FALSE) + 
      labs(title = "Sample Distribution")
p2 <- DimPlot(selected_obj, reduction = umap_to_use, label = TRUE, raster = FALSE) + 
      labs(title = "Clusters (res=0.5)")

ggsave(file.path(OUTPUT_DIR, "plots/01_final_clustering_umap.png"), p1 / p2, width = 16, height = 12)

# =============================================================================
# STEP 5: Save Results
# =============================================================================
selected_obj <- JoinLayers(selected_obj)
saveRDS(selected_obj, file = file.path(OUTPUT_DIR, "GSE174609_integrated_clustered.rds"))

cat("\n=== Part 3 Complete ===\n")
cat("Total cells:", ncol(selected_obj), "\n")
cat("Output saved:", file.path(OUTPUT_DIR, "GSE174609_integrated_clustered.rds"), "\n")
