#!/usr/bin/env Rscript
################################################################################
# Script: 02_qc_tool_compare.R (Part 2-2)
# Description: QC Tool Comparison — DecontX (ambient RNA decontamination) and
#              DoubletFinder vs scDblFinder doublet caller cross-evaluation.
################################################################################

suppressPackageStartupMessages({
  library(Seurat)
  library(SeuratObject)
  library(dplyr)
  library(ggplot2)
  library(patchwork)
  library(decontX)
  library(scDblFinder)
  has_df <- requireNamespace("DoubletFinder", quietly=TRUE)
if(has_df) library(DoubletFinder)
  library(SingleCellExperiment)
})

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    input_dir  = "results/qc/filtered_data",
    outdir     = "results/qc_compare",
    npcs       = 30,
    resolution = 0.8,
    seed       = 12345
  )
  i <- 1
  while (i <= length(args)) {
    key <- gsub("^--", "", args[i])
    if (i < length(args) && !grepl("^--", args[i + 1])) {
      val <- args[i + 1]
      if (key %in% c("npcs", "resolution", "seed")) {
        params[[key]] <- as.numeric(val)
      } else {
        params[[key]] <- val
      }
      i <- i + 2
    } else {
      params[[key]] <- TRUE
      i <- i + 1
    }
  }
  return(params)
}

opt <- parse_args()
set.seed(opt$seed)
theme_set(theme_classic())

cat("=================================================================\n")
cat(" Step 2 / Part 2-2: QC Tool Comparison (DecontX & Doublet Callers)\n")
cat(" Input Dir:  ", opt$input_dir, "\n")
cat(" Output Dir: ", opt$outdir, "\n")
cat("=================================================================\n\n")

plots_dir   <- file.path(opt$outdir, "plots")
rds_out_dir <- file.path(opt$outdir, "filtered_data")
dir.create(plots_dir,   recursive = TRUE, showWarnings = FALSE)
dir.create(rds_out_dir, recursive = TRUE, showWarnings = FALSE)

rds_files <- list.files(opt$input_dir, pattern = "_qc_filtered\\.rds$", full.names = TRUE)
if (length(rds_files) == 0) {
  stop("No '*_qc_filtered.rds' files found in: ", opt$input_dir)
}

qc_compare_results <- list()

for (rpath in rds_files) {
  sid <- gsub("_qc_filtered\\.rds$", "", basename(rpath))
  cat(sprintf("\n=== Processing QC Comparison: %s ===\n", sid))
  
  seurat_obj <- readRDS(rpath)
  filt_counts <- LayerData(seurat_obj, layer = "counts")
  
  # Shared clustering for doublet and decontx evaluation
  seurat_obj <- NormalizeData(seurat_obj, verbose = FALSE)
  seurat_obj <- FindVariableFeatures(seurat_obj, verbose = FALSE)
  seurat_obj <- ScaleData(seurat_obj, verbose = FALSE)
  seurat_obj <- RunPCA(seurat_obj, npcs = opt$npcs, verbose = FALSE)
  seurat_obj <- RunUMAP(seurat_obj, dims = 1:opt$npcs, verbose = FALSE)
  seurat_obj <- FindNeighbors(seurat_obj, dims = 1:opt$npcs, verbose = FALSE)
  seurat_obj <- FindClusters(seurat_obj, resolution = opt$resolution, verbose = FALSE)
  
  shared_clusters <- setNames(as.character(seurat_obj$seurat_clusters), colnames(seurat_obj))
  
  # 1. DecontX ambient RNA correction
  sce_ambient <- SingleCellExperiment(assays = list(counts = filt_counts))
  sce_ambient <- decontX(sce_ambient, z = shared_clusters[colnames(filt_counts)])
  
  decontx_contam <- sce_ambient$decontX_contamination
  names(decontx_contam) <- colnames(sce_ambient)
  seurat_obj$decontx_contamination <- decontx_contam
  
  p_contam_dist <- ggplot(data.frame(DecontX = decontx_contam), aes(x = DecontX)) +
    geom_histogram(bins = 60, fill = "#2A9D8F", alpha = 0.85) +
    labs(
      title    = paste0(sid, ": DecontX per-cell contamination"),
      subtitle = sprintf("Median: %.3f | 95th pct: %.3f", median(decontx_contam), quantile(decontx_contam, 0.95)),
      x = "DecontX per-cell contamination fraction", y = "Number of cells"
    )
  ggsave(file.path(plots_dir, paste0(sid, "_01_decontx_distribution.png")),
         p_contam_dist, width = 8, height = 6, dpi = 300)
  
  # 2. DoubletFinder
  if(has_df) {
    sweep_list  <- paramSweep(seurat_obj, PCs = 1:opt$npcs, sct = FALSE)
    sweep_stats <- summarizeSweep(sweep_list, GT = FALSE)
    bcmvn       <- find.pK(sweep_stats)
    optimal_pk  <- as.numeric(as.character(bcmvn$pK[which.max(bcmvn$BCmetric)]))
    
    n_cells        <- ncol(seurat_obj)
    homotypic_prop <- modelHomotypic(seurat_obj$seurat_clusters)
    nExp           <- round((0.008 * n_cells / 1000) * n_cells)
    nExp_adj       <- round(nExp * (1 - homotypic_prop))
    
    seurat_obj <- doubletFinder(
      seurat_obj, PCs = 1:30, pN = 0.25, pK = optimal_pk,
      nExp = nExp_adj, reuse.pANN = NULL, sct = FALSE
    )
    df_class_col <- grep("^DF.classifications", colnames(seurat_obj@meta.data), value = TRUE)
    seurat_obj$DoubletFinder <- seurat_obj[[df_class_col]][, 1]
  } else {
    seurat_obj$DoubletFinder <- "Singlet"
  }
  
  # 3. scDblFinder
  sce_doublet <- as.SingleCellExperiment(seurat_obj)
  sce_doublet <- scDblFinder(sce_doublet, clusters = "seurat_clusters")
  seurat_obj$scDblFinder       <- sce_doublet$scDblFinder.class
  seurat_obj$scDblFinder_score <- sce_doublet$scDblFinder.score
  
  # 4. Consensus
  seurat_obj$doublet_consensus <- dplyr::case_when(
    seurat_obj$DoubletFinder == "Doublet" & seurat_obj$scDblFinder == "doublet" ~ "Both",
    seurat_obj$DoubletFinder == "Doublet" | seurat_obj$scDblFinder == "doublet" ~ "One only",
    TRUE ~ "Neither"
  )
  
  n_both <- sum(seurat_obj$doublet_consensus == "Both")
  cat(sprintf("  [%s] Consensus doublets (Both tools agree): %d (%.1f%%)\n",
              sid, n_both, round(n_both / ncol(seurat_obj) * 100, 1)))
  
  # 5. Shared UMAP Visualization
  p_df    <- DimPlot(seurat_obj, group.by = "DoubletFinder", cols = c("Singlet" = "#90E0EF", "Doublet" = "#EF233C")) + ggtitle(paste0(sid, ": DoubletFinder"))
  p_scdbl <- DimPlot(seurat_obj, group.by = "scDblFinder", cols = c("singlet" = "#90E0EF", "doublet" = "#EF233C")) + ggtitle(paste0(sid, ": scDblFinder"))
  p_cons  <- DimPlot(seurat_obj, group.by = "doublet_consensus", cols = c("Neither" = "#D3D3D3", "One only" = "#F4A261", "Both" = "#E76F51")) + ggtitle(paste0(sid, ": Consensus"))
  
  ggsave(file.path(plots_dir, paste0(sid, "_02_doublet_caller_comparison.png")),
         (p_df | p_scdbl | p_cons), width = 16, height = 5, dpi = 300)
  
  saveRDS(seurat_obj, file = file.path(rds_out_dir, paste0(sid, "_qc_toolcompare.rds")))
  
  qc_compare_results[[sid]] <- data.frame(
    sample_id            = sid,
    n_cells              = ncol(seurat_obj),
    median_contamination = median(decontx_contam),
    pct95_contamination  = quantile(decontx_contam, 0.95),
    doubletfinder_calls  = sum(seurat_obj$DoubletFinder == "Doublet"),
    scdblfinder_calls    = sum(seurat_obj$scDblFinder == "doublet"),
    consensus_doublets   = n_both,
    consensus_rate_pct   = round(n_both / ncol(seurat_obj) * 100, 2)
  )
}

qc_compare_summary <- do.call(rbind, qc_compare_results)
write.csv(qc_compare_summary, file.path(opt$outdir, "QC_tool_comparison_summary.csv"), row.names = FALSE)

cat("\n=================================================================\n")
cat(" Part 2-2 (QC Tool Compare) completed successfully!\n")
cat(" Summary: ", file.path(opt$outdir, "QC_tool_comparison_summary.csv"), "\n")
cat("=================================================================\n")
