#!/usr/bin/env Rscript

# =============================================================================
# Nextflow-Ready: Part 4: Cell Annotation (with Plots)
# Usage: Rscript part4_annotation.R --input merged_clustered.rds --output .
# =============================================================================

suppressPackageStartupMessages({
  library(Seurat)
  library(optparse)
  library(SingleR)
  library(celldex)
  library(ggplot2)
})

option_list <- list(
  make_option(c("-i", "--input"), type="character", default=NULL, help="Input RDS file"),
  make_option(c("-o", "--output"), type="character", default=".", help="Output directory")
)
opt <- parse_args(OptionParser(option_list=option_list))

dir.create(file.path(opt$output, "plots"), recursive = TRUE, showWarnings = FALSE)

seurat_obj <- readRDS(opt$input)
ref <- celldex::MonacoImmuneData()

# SingleR
pred <- SingleR(test = as.SingleCellExperiment(seurat_obj), ref = ref, labels = ref$label.main)
seurat_obj$cell_type <- pred$labels

# Plots
p1 <- DimPlot(seurat_obj, group.by = "cell_type", label = TRUE, repel = TRUE) + labs(title = "SingleR Annotation")
ggsave(file.path(opt$output, "plots/01_annotation_umap.png"), p1, width = 10, height = 8)

canonical_markers <- c("CD3D", "CD3E", "CD4", "CD8A", "MS4A1", "CD14", "FCGR3A", "NKG7", "PPBP")
p2 <- DotPlot(seurat_obj, features = canonical_markers, group.by = "cell_type") + coord_flip()
ggsave(file.path(opt$output, "plots/02_marker_dotplot.png"), p2, width = 10, height = 8)

saveRDS(seurat_obj, file.path(opt$output, "annotated.rds"))
cat("Annotation Complete.\n")
