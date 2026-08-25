#!/usr/bin/env Rscript

# =============================================================================
# Nextflow-Ready: Part 3: Integration & Clustering (with Plots)
# Usage: Rscript part3_clustering.R --input path/to/rds_list --output .
# =============================================================================

suppressPackageStartupMessages({
  library(Seurat)
  library(optparse)
  library(future)
  library(ggplot2)
})

option_list <- list(
  make_option(c("-i", "--input"), type="character", default=NULL, help="Comma-separated RDS files"),
  make_option(c("-o", "--output"), type="character", default=".", help="Output directory"),
  make_option(c("-c", "--cores"), type="integer", default=32, help="Number of cores")
)
opt <- parse_args(OptionParser(option_list=option_list))

plan("multisession", workers = opt$cores)
dir.create(file.path(opt$output, "plots"), recursive = TRUE, showWarnings = FALSE)

files <- strsplit(opt$input, ",")[[1]]
obj_list <- lapply(files, readRDS)

if (length(obj_list) > 1) {
  seurat_obj <- merge(obj_list[[1]], y = obj_list[-1], add.cell.ids = names(obj_list))
  seurat_obj[["RNA"]] <- split(seurat_obj[["RNA"]], f = seurat_obj$sample_id)
  seurat_obj <- SCTransform(seurat_obj, verbose = FALSE) %>% RunPCA(verbose = FALSE)
  seurat_obj <- IntegrateLayers(object = seurat_obj, method = CCAIntegration, orig.reduction = "pca", 
                                new.reduction = "integrated.cca", verbose = FALSE)
  red <- "integrated.cca"; umap_n <- "umap.cca"
} else {
  seurat_obj <- obj_list[[1]] %>% SCTransform(verbose = FALSE) %>% RunPCA(verbose = FALSE)
  red <- "pca"; umap_n <- "umap"
}

seurat_obj <- RunUMAP(seurat_obj, dims = 1:30, reduction = red, reduction.name = umap_n, verbose = FALSE) %>% 
              FindNeighbors(dims = 1:30, reduction = red, verbose = FALSE) %>% 
              FindClusters(resolution = 0.5, verbose = FALSE)

p1 <- DimPlot(seurat_obj, reduction = umap_n, group.by = "sample_id") + labs(title = "Sample Distribution")
p2 <- DimPlot(seurat_obj, reduction = umap_n, label = TRUE) + labs(title = "Clusters (res=0.5)")
ggsave(file.path(opt$output, "plots/01_final_clustering_umap.png"), p1 + p2, width = 14, height = 6)

saveRDS(JoinLayers(seurat_obj), file.path(opt$output, "merged_clustered.rds"))
cat("Clustering Complete.\n")
