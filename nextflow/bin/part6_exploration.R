#!/usr/bin/env Rscript

# =============================================================================
# Nextflow-Ready: Part 6: Object Exploration (Conversion)
# Usage: Rscript part6_exploration.R --input annotated.rds --output results/exploration
# =============================================================================

suppressPackageStartupMessages({
  library(Seurat)
  library(SingleCellExperiment)
  library(optparse)
})

option_list <- list(
  make_option(c("-i", "--input"), type="character", default=NULL, help="Input Seurat RDS file"),
  make_option(c("-o", "--output"), type="character", default=NULL, help="Output directory")
)
opt_parser <- OptionParser(option_list=option_list)
opt <- parse_args(opt_parser)

if (is.null(opt$input) || is.null(opt$output)) {
  print_help(opt_parser)
  stop("Missing required arguments", call.=FALSE)
}

dir.create(opt$output, recursive = TRUE, showWarnings = FALSE)

seurat_obj <- readRDS(opt$input)

# Convert to SingleCellExperiment
sce <- as.SingleCellExperiment(seurat_obj)

# Create Pseudobulk SE
pb_counts <- AggregateExpression(seurat_obj, group.by = "cell_type", assays = "RNA", return.seurat = FALSE)$RNA
pb_metadata <- data.frame(
  cell_type = colnames(pb_counts),
  sample_id = unique(seurat_obj$sample_id),
  row.names = colnames(pb_counts)
)
se_pb <- SummarizedExperiment::SummarizedExperiment(
  assays = list(counts = as.matrix(pb_counts)),
  colData = pb_metadata
)

saveRDS(sce,   file.path(opt$output, "sce_object.rds"))
saveRDS(se_pb, file.path(opt$output, "pseudobulk_se.rds"))

cat("Object Exploration/Conversion Complete.\n")
