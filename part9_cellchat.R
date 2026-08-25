# =============================================================================
# Part 9: Cell-Cell Communication Analysis (CellChat)
# Tutorial: NGS101 – scRNA-seq Complete Beginner's Guide
# Input    : Annotated Seurat object from Part 4
# Output   : CellChat objects, Interaction networks, Comparative plots
# Usage    : Rscript part9_cellchat.R
# =============================================================================

library(CellChat)
library(Seurat)
library(patchwork)
library(ggplot2)
library(NMF)
library(ggalluvial)

# ------ Configuration -------------------------------------------------------
source("config.R")
setup_cluster_parallel()

ANNOTATED_RDS <- file.path(DIR_ANNOTATION, "GSE174609_annotated.rds")
OUTPUT_DIR    <- DIR_CELLCHAT
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "plots/healthy"),    recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "plots/post_treat"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "plots/comparison"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "results"),         recursive = TRUE, showWarnings = FALSE)

setwd(OUTPUT_DIR)
set.seed(42)

# =============================================================================
# STEP 1: Load Data & Pre-process for CellChat
# =============================================================================
if (!file.exists(ANNOTATED_RDS)) stop("Annotated RDS not found: ", ANNOTATED_RDS)
seurat_obj <- readRDS(ANNOTATED_RDS)

# CellChat v2 expects 'samples' column for replicates
seurat_obj$samples <- factor(seurat_obj$sample_id)
Idents(seurat_obj) <- "cell_type"

# =============================================================================
# FUNCTION: Run CellChat Pipeline for a Condition
# =============================================================================
run_cellchat_pipeline <- function(seurat_sub, label) {
  cat("\n--- Running CellChat for:", label, "---\n")
  
  cellchat <- createCellChat(object = seurat_sub, group.by = "cell_type", assay = "RNA")
  cellchat@DB <- CellChatDB.human # Use full database
  
  # Preprocessing
  cellchat <- subsetData(cellchat)
  cellchat <- identifyOverExpressedGenes(cellchat, do.fast = FALSE)
  cellchat <- identifyOverExpressedInteractions(cellchat)
  
  # Inference (Computational Core)
  # nboot = 100 is standard for exploration; increase for publication
  cellchat <- computeCommunProb(cellchat, type = "triMean", nboot = 100)
  cellchat <- filterCommunication(cellchat, min.cells = 10)
  cellchat <- computeCommunProbPathway(cellchat)
  cellchat <- aggregateNet(cellchat)
  
  return(cellchat)
}

# =============================================================================
# STEP 2: Process Groups
# =============================================================================
conditions <- unique(seurat_obj$condition)

if (length(conditions) > 1) {
  # Comparative Analysis
  cat("Multiple conditions detected. Running comparative CellChat...\n")
  
  # 1. Healthy
  seurat_h <- subset(seurat_obj, subset = condition == "Healthy")
  chat_h   <- run_cellchat_pipeline(seurat_h, "Healthy")
  
  # 2. Post_Treatment
  seurat_p <- subset(seurat_obj, subset = condition == "Post_Treatment")
  # Fallback if condition name differs (check "Post_Patient" cases)
  if (ncol(seurat_p) == 0) {
    # Some datasets use "Post_Treatment", others might use something else
    cat("Warning: No cells found for 'Post_Treatment'. Checking 'Post_Patient'...\n")
    seurat_p <- subset(seurat_obj, subset = condition == "Post_Patient")
  }
  
  if (ncol(seurat_p) > 0) {
    chat_p <- run_cellchat_pipeline(seurat_p, "Post_Treatment")
    
    # 3. Merge & Compare
    cat("\n--- Merging Objects for Comparison ---\n")
    object_list <- list(Healthy = chat_h, Post_Treatment = chat_p)
    cellchat_merged <- mergeCellChat(object_list, add.names = names(object_list))
    
    # Visualizations
    cat("Saving comparative plots...\n")
    
    # Compare interaction numbers
    p1 <- compareInteractions(cellchat_merged, show.legend = F, group = c(1,2))
    p2 <- compareInteractions(cellchat_merged, show.legend = F, group = c(1,2), measure = "weight")
    ggsave("plots/comparison/01_interaction_comparison.png", p1 + p2, width = 12, height = 6)
    
    # Differential Heatmap
    png("plots/comparison/02_differential_heatmap.png", width = 1200, height = 1000, res = 150)
    netVisual_heatmap(cellchat_merged)
    dev.off()
    
    saveRDS(cellchat_merged, "results/cellchat_merged_analysis.rds")
  }
  
} else {
  # Single Group Analysis
  cat("Single condition detected. Running baseline CellChat...\n")
  chat_single <- run_cellchat_pipeline(seurat_obj, conditions[1])
  
  # Basic Circle Plots
  png("plots/healthy/01_interaction_strength.png", width = 800, height = 800, res = 150)
  netVisual_circle(chat_single@net$weight, title.name = "Interaction Strength")
  dev.off()
  
  saveRDS(chat_single, "results/cellchat_single_group.rds")
}

cat("\n=== Part 9 Complete ===\n")
