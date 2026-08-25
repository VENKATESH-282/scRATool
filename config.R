# =============================================================================
# Pipeline Configuration for HPC Cluster
# =============================================================================

# Project Base Directory
# SET THIS to your project's base directory before running any R scripts.
# Example: PROJECT_DIR <- "/path/to/your/scRNA_project"
PROJECT_DIR <- ""

# Global Parallelization Settings
# The cluster has 128 cores; using 64 for conservative high-performance scaling.
N_CORES <- 64

# Future Library Settings (for Seurat v5)
# Increase max size for globals to 128GB to handle large matrices
options(future.globals.maxSize = 128 * 1023^3)
options(future.rng.onMisuse = "ignore") # Silence RNG warnings in parallel loops

# Sub-directory structure (matching Part 1-10 scripts)
DIR_CELLRANGER <- file.path(PROJECT_DIR, "cellranger_output")
DIR_QC         <- file.path(PROJECT_DIR, "QC_analysis")
DIR_INTEGRATION <- file.path(PROJECT_DIR, "integration")
DIR_ANNOTATION  <- file.path(PROJECT_DIR, "annotation")
DIR_DE          <- file.path(PROJECT_DIR, "differential_expression")
DIR_TRAJECTORY  <- file.path(PROJECT_DIR, "trajectory")
DIR_CELLCHAT    <- file.path(PROJECT_DIR, "cellchat")
DIR_NICHENET    <- file.path(PROJECT_DIR, "nichenet")

# Helper function to load and setup parallelization
setup_cluster_parallel <- function() {
  if (requireNamespace("future", quietly = TRUE)) {
    library(future)
    plan("multisession", workers = N_CORES)
    message("Parallel execution enabled using 'future' with ", N_CORES, " workers.")
  } else {
    message("Warning: 'future' package not found. Running sequentially.")
  }
}
