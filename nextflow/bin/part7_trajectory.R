#!/usr/bin/env Rscript

# =============================================================================
# Nextflow-Ready: Part 7: Trajectory Analysis (with Plots)
# Usage: Rscript part7_trajectory.R --input sce_object.rds --output .
# =============================================================================

suppressPackageStartupMessages({
  library(Seurat)
  library(slingshot)
  library(optparse)
  library(ggplot2)
  library(SingleCellExperiment)
})

option_list <- list(
  make_option(c("-i", "--input"), type="character", default=NULL, help="SCE object"),
  make_option(c("-o", "--output"), type="character", default=".", help="Output directory")
)
opt <- parse_args(OptionParser(option_list=option_list))

dir.create(file.path(opt$output, "plots"), recursive = TRUE, showWarnings = FALSE)
sce <- readRDS(opt$input)

# Slingshot logic
sce <- slingshot(sce, clusterLabels = 'ident', reducedDim = 'UMAP')

# Plot
png(file.path(opt$output, "plots/01_trajectory_umap.png"), width = 800, height = 600)
plot(reducedDim(sce, "UMAP"), col = as.numeric(as.factor(sce$ident)), pch = 16)
lines(SlingshotDataSet(sce), lwd = 2, col = 'black')
dev.off()

saveRDS(sce, file.path(opt$output, "sce_trajectory.rds"))
cat("Trajectory Complete.\n")
