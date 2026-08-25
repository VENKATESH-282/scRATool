# =============================================================================
# Part 7: Trajectory and Pseudotime Analysis (Monocle 3 / Slingshot)
# Tutorial: NGS101 – scRNA-seq Complete Beginner's Guide
# Input    : Annotated Seurat (Part 4) or SCE (Part 6)
# Output   : Trajectory plots and Pseudotime-linked metadata
# Usage    : Rscript part7_trajectory_analysis.R
# =============================================================================

library(Seurat)
library(ggplot2)
library(dplyr)
library(viridis)
library(patchwork)

# Optional libraries
has_monocle     <- requireNamespace("monocle3", quietly = TRUE)
has_slingshot   <- requireNamespace("slingshot", quietly = TRUE)
has_wrappers    <- requireNamespace("SeuratWrappers", quietly = TRUE)

if (has_monocle)   library(monocle3)
if (has_slingshot) library(slingshot)

# ------ Configuration -------------------------------------------------------
source("config.R")
setup_cluster_parallel()

ANNOTATED_RDS <- file.path(DIR_ANNOTATION, "GSE174609_annotated.rds")
SCE_RDS       <- file.path(PROJECT_DIR, "object_conversions/GSE174609_SCE.rds")
OUTPUT_DIR    <- DIR_TRAJECTORY

dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "plots"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "results"), recursive = TRUE, showWarnings = FALSE)

setwd(OUTPUT_DIR)
set.seed(42)

# =============================================================================
# STEP 1: Load Data
# =============================================================================
if (file.exists(SCE_RDS)) {
  cat("Loading SCE object from Part 6...\n")
  obj <- readRDS(SCE_RDS)
} else if (file.exists(ANNOTATED_RDS)) {
  cat("Loading Seurat object from Part 4...\n")
  obj <- readRDS(ANNOTATED_RDS)
} else {
  stop("Input data not found. Run Part 4 or Part 6 first.")
}

# =============================================================================
# STEP 2: Trajectory Analysis
# =============================================================================

if (has_monocle) {
  # --- MONOCLE 3 IMPLEMENTATION ---
  cat("\nRunning Trajectory Analysis with Monocle 3...\n")
  
  if (inherits(obj, "Seurat")) {
    library(SeuratWrappers)
    cds <- as.cell_data_set(obj)
  } else {
    cds <- obj # Already SCE/CDS compatible
  }
  
  rowData(cds)$gene_short_name <- rownames(cds)
  cds <- cluster_cells(cds, reduction_method = "UMAP")
  cds <- learn_graph(cds, use_partition = TRUE)
  
  # Pick root cells (Naive T cells)
  root_labels <- c("CD4+ Naive T", "CD4+ T cells")
  root_cells <- colnames(cds)[colData(cds)$cell_type %in% root_labels]
  
  if (length(root_cells) > 0) {
    cds <- order_cells(cds, root_cells = root_cells)
  } else {
    cds <- order_cells(cds)
  }
  
  # Plot
  p_traj <- plot_cells(cds, color_cells_by = "pseudotime", label_cell_groups = FALSE)
  ggsave("plots/01_monocle3_trajectory.png", p_traj, width = 10, height = 8)
  
} else if (has_slingshot) {
  # --- SLINGSHOT IMPLEMENTATION ---
  cat("\nRunning Trajectory Analysis with Slingshot (Bioconductor)...\n")
  
  # Slingshot works best on SingleCellExperiment
  if (inherits(obj, "Seurat")) {
    sce <- as.SingleCellExperiment(obj)
  } else {
    sce <- obj
  }
  
  # Run Slingshot using UMAP coordinates
  # We specify 'CD4+ Naive T' as the starting cluster (start.clus)
  # Adjust start.clus based on your cluster names from Part 4
  sce <- slingshot(sce, clusterLabels = 'cell_type', reducedDim = 'UMAP',
                   start.clus = 'CD4+ Naive T', approx_points = 150)
  
  # Visualization
  colors <- viridis(100)[cut(sce$slingPseudotime_1, breaks = 100)]
  png("plots/01_slingshot_trajectory.png", width = 800, height = 600)
  plot(reducedDim(sce, "UMAP"), col = colors, pch = 16, cex = 0.5,
       main = "Slingshot Trajectory (Pseudotime)")
  lines(SlingshotDataSet(sce), lwd = 2, col = 'black')
  dev.off()
  
} else {
  cat("\nError: Neither 'monocle3' nor 'slingshot' is installed.\n")
  cat("Please install one using:\n")
  cat("  Rscript -e 'BiocManager::install(\"slingshot\")' # Recommended for simplicity\n")
  cat("  OR use conda: conda install -c bioconda r-monocle3\n")
}

cat("\n=== Part 7 Complete ===\n")
