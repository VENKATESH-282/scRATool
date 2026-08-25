#!/usr/bin/env Rscript

# =============================================================================
# Nextflow-Ready: Part 2: QC & Filtering (with Plots)
# Usage: Rscript part2_qc.R --input path/to/outs --output . --sample_id SampleA
# =============================================================================

suppressPackageStartupMessages({
  library(Seurat)
  library(SoupX)
  library(scDblFinder)
  library(DropletUtils)
  library(optparse)
  library(ggplot2)
  library(patchwork)
  library(dplyr)
})

option_list <- list(
  make_option(c("-i", "--input"), type="character", default=NULL, help="Cell Ranger outs directory"),
  make_option(c("-o", "--output"), type="character", default=".", help="Output directory"),
  make_option(c("-s", "--sample_id"), type="character", default=NULL, help="Sample ID"),
  make_option(c("-c", "--cores"), type="integer", default=4, help="Number of cores")
})
opt <- parse_args(OptionParser(option_list=option_list))

dir.create(file.path(opt$output, "plots"), recursive = TRUE, showWarnings = FALSE)

cat("Processing:", opt$sample_id, "\n")

# --- Step 1: Load Data ---
counts_raw <- Read10X(file.path(opt$input, "raw_feature_bc_matrix"))
counts_filt <- Read10X(file.path(opt$input, "filtered_feature_bc_matrix"))

# --- Step 2: Empty Droppets (Plot 01) ---
sce <- as.SingleCellExperiment(CreateSeuratObject(counts_raw))
set.seed(100)
e_out <- emptyDrops(counts(sce))
is_cell <- e_out$FDR < 0.01; is_cell[is.na(is_cell)] <- FALSE
p1 <- ggplot(data.frame(umi=colSums(counts(sce)), is_cell=is_cell), aes(x=log10(umi+1), fill=is_cell)) +
      geom_histogram(bins=50, alpha=0.7) + labs(title="EmptyDrops Detection") + theme_classic()
ggsave(file.path(opt$output, "plots/01_empty_droplets.png"), p1, width=10, height=6)

# --- Step 3: SoupX ---
sc <- SoupChannel(counts_raw, counts_filt)
so_tmp <- CreateSeuratObject(counts_filt) %>% SCTransform(verbose=F) %>% RunPCA(verbose=F) %>% 
          RunUMAP(dims=1:20, verbose=F) %>% FindNeighbors(dims=1:20, verbose=F) %>% FindClusters(verbose=F)
sc <- setClusters(sc, setNames(so_tmp$seurat_clusters, rownames(so_tmp@meta.data)))
sc <- autoEstCont(sc, verbose=F)
out_counts <- adjustCounts(sc, verbose=F)

# --- Step 4: Doublets (Plot 02) ---
seurat_obj <- CreateSeuratObject(counts = out_counts, project = opt$sample_id)
seurat_obj$sample_id <- opt$sample_id
sce_db <- scDblFinder(as.SingleCellExperiment(seurat_obj), clusters=TRUE, nthreads=opt$cores)
seurat_obj$doublet_class <- sce_db$scDblFinder.class

# Quick UMAP for doublets
tmp <- NormalizeData(seurat_obj, verbose=F) %>% FindVariableFeatures(verbose=F) %>% ScaleData(verbose=F) %>% 
       RunPCA(verbose=F) %>% RunUMAP(dims=1:15, verbose=F)
p2 <- DimPlot(tmp, group.by="doublet_class", cols=c("Singlet"="grey", "Doublet"="red")) + labs(title="Doublets")
ggsave(file.path(opt$output, "plots/02_doublets_umap.png"), p2, width=8, height=6)

seurat_obj <- subset(seurat_obj, subset = doublet_class == "singlet")

# --- Step 5: QC Metrics (Plot 03, 04) ---
seurat_obj[["percent.mt"]] <- PercentageFeatureSet(seurat_obj, pattern = "^MT-")
p3 <- VlnPlot(seurat_obj, features = c("nCount_RNA", "nFeature_RNA", "percent.mt"), ncol = 3, pt.size = 0)
ggsave(file.path(opt$output, "plots/03_qc_violins.png"), p3, width=12, height=5)

p4 <- FeatureScatter(seurat_obj, "nCount_RNA", "nFeature_RNA") + FeatureScatter(seurat_obj, "nCount_RNA", "percent.mt")
ggsave(file.path(opt$output, "plots/04_qc_scatter.png"), p4, width=12, height=6)

# --- Step 6: Normalization ---
seurat_obj <- NormalizeData(seurat_obj) %>% FindVariableFeatures(nfeatures=2000)
top10 <- head(VariableFeatures(seurat_obj), 10)
p7 <- LabelPoints(plot = VariableFeaturePlot(seurat_obj), points = top10, repel = TRUE)
ggsave(file.path(opt$output, "plots/07_variable_features.png"), p7, width=10, height=7)

saveRDS(seurat_obj, file.path(opt$output, paste0(opt$sample_id, "_qc.rds")))
cat("QC Complete.\n")
