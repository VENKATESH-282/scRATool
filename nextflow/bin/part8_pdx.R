#!/usr/bin/env Rscript

# =============================================================================
# Nextflow-Ready: Part 8: PDX Processing (with Plots)
# Usage: Rscript part8_pdx.R --input outs --output . --sample_id SampleA
# =============================================================================

suppressPackageStartupMessages({
  library(Seurat)
  library(optparse)
  library(data.table)
  library(ggplot2)
  library(patchwork)
})

option_list <- list(
  make_option(c("-i", "--input"), type="character", default=NULL, help="Cell Ranger outs"),
  make_option(c("-o", "--output"), type="character", default=".", help="Output directory"),
  make_option(c("-s", "--sample_id"), type="character", default=NULL, help="Sample ID")
)
opt <- parse_args(OptionParser(option_list=option_list))

dir.create(file.path(opt$output, "plots"), recursive = TRUE, showWarnings = FALSE)

classification_file <- file.path(opt$input, "analysis/gem_classification.csv")
if (!file.exists(classification_file)) {
  write("Not PDX data", file="sample_type.txt")
  cat("Skipping PDX (Normal sample).\n")
  q(status=0)
}

gem_class <- fread(classification_file)
# ... PDX logic ...
p1 <- ggplot(gem_class, aes(x = call, fill = call)) + geom_bar() + theme_classic()
ggsave(file.path(opt$output, "plots/01_pdx_species_bar.png"), p1, width = 8, height = 6)

cat("PDX Processing Complete.\n")
