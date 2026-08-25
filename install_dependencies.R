# =============================================================================
# Dependency Installer for scRNA-seq Pipeline (CellChat & NicheNet)
# Tutorial: NGS101 – scRNA-seq Complete Beginner's Guide
# Usage: Rscript install_dependencies.R
# =============================================================================

cat("Checking and installing final-stage dependencies...\n")

if (!requireNamespace("BiocManager", quietly = TRUE))
    install.packages("BiocManager", repos='http://cran.us.r-project.org')

# 1. Install CRAN/Bioconductor Dependencies
deps <- c(
    "ComplexHeatmap", "BiocNeighbors", "NMF", 
    "ggalluvial", "circlize", "reticulate",
    "tidyverse", "ggrepel", "igraph", "ggraph", "patchwork"
)

new_deps <- deps[!(deps %in% installed.packages()[,"Package"])]
if(length(new_deps)) {
    cat("Installing missing dependencies:", paste(new_deps, collapse=", "), "\n")
    BiocManager::install(new_deps, update = FALSE, ask = FALSE)
} else {
    cat("All CRAN/Bioconductor dependencies are already installed.\n")
}

# 2. Install remotes (lighter than devtools) if missing
if (!requireNamespace("remotes", quietly = TRUE)) {
    cat("Installing 'remotes' package...\n")
    install.packages("remotes", repos='https://cloud.r-project.org')
}

# 3. Install CellChat from GitHub (v2)
if (!requireNamespace("CellChat", quietly = TRUE)) {
    cat("Installing CellChat v2 from GitHub...\n")
    remotes::install_github("jinworks/CellChat")
} else {
    cat("CellChat is already installed.\n")
}

# 4. Install NicheNet from GitHub
if (!requireNamespace("nichenetr", quietly = TRUE)) {
    cat("Installing nichenetr from GitHub...\n")
    remotes::install_github("saeyslab/nichenetr")
} else {
    cat("nichenetr is already installed.\n")
}

cat("\n=== Installation Check Complete ===\n")
