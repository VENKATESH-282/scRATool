#!/usr/bin/env Rscript

# =============================================================================
# Nextflow-Ready: Part 5: Differential Expression (with Plots)
# Usage: Rscript part5_de.R --input annotated.rds --output .
# =============================================================================

suppressPackageStartupMessages({
  library(Seurat)
  library(optparse)
  library(ggplot2)
  library(dplyr)
})

option_list <- list(
  make_option(c("-i", "--input"), type="character", default=NULL, help="Input RDS file"),
  make_option(c("-o", "--output"), type="character", default=".", help="Output directory")
)
opt <- parse_args(OptionParser(option_list=option_list))

dir.create(file.path(opt$output, "plots"), recursive = TRUE, showWarnings = FALSE)

seurat_obj <- readRDS(opt$input)

# Proportions (Plot 01)
p1 <- ggplot(seurat_obj@meta.data, aes(x = sample_id, fill = cell_type)) + geom_bar(position = "fill") + theme_classic()
ggsave(file.path(opt$output, "plots/01_proportion_barplot.png"), p1, width = 10, height = 6)

# Markers
all_markers <- FindAllMarkers(seurat_obj, only.pos = TRUE, min.pct = 0.25, logfc.threshold = 0.25, verbose = FALSE)
write.csv(all_markers, file.path(opt$output, "all_markers.csv"))

# Heatmap
top10 <- all_markers %>% group_by(cluster) %>% top_n(n = 10, wt = avg_log2FC)
p2 <- DoHeatmap(seurat_obj, features = top10$gene) + NoLegend()
ggsave(file.path(opt$output, "plots/02_top_markers_heatmap.png"), p2, width = 12, height = 10)

cat("DE Analysis Complete.\n")
