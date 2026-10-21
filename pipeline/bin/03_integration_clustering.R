#!/usr/bin/env Rscript
################################################################################
# Script: 03_integration_clustering.R (Part 3)
# Description: Multi-sample integration comparison (Harmony, CCA, RPCA),
#              batch effect benchmarking, resolution optimization, and clustering.
################################################################################

suppressPackageStartupMessages({
  library(Seurat)
  library(SeuratObject)
  library(harmony)
  library(batchelor)
  library(ggplot2)
  library(ggrepel)
  library(dplyr)
  library(patchwork)
  library(RColorBrewer)
  library(viridis)
  library(FNN)
  library(cluster)
  library(reshape2)
  library(future)
})

options(future.globals.maxSize = 30 * 1024^3)

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    input_dir          = "results/qc/filtered_data",
    samplesheet        = "assets/samples.csv",
    outdir             = "results/integration",
    preferred_method   = "auto",
    npcs               = 30,
    resolutions        = "0.2,0.4,0.6,0.8,1.0",
    default_resolution = "auto",
    seed               = 42
  )
  i <- 1
  while (i <= length(args)) {
    key <- gsub("^--", "", args[i])
    if (i < length(args) && !grepl("^--", args[i + 1])) {
      val <- args[i + 1]
      if (key %in% c("npcs", "seed")) {
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
theme_set(theme_classic(base_size = 12))

cat("=================================================================\n")
cat(" Step 3 / Part 3: Integration Benchmarking and Clustering\n")
cat(" Input Dir:         ", opt$input_dir, "\n")
cat(" Samplesheet:       ", opt$samplesheet, "\n")
cat(" Output Dir:        ", opt$outdir, "\n")
cat(" Preferred Method:  ", opt$preferred_method, "\n")
cat("=================================================================\n\n")

plots_integ_dir <- file.path(opt$outdir, "plots/integration_comparison")
plots_clust_dir <- file.path(opt$outdir, "plots/clustering")
integ_data_dir  <- file.path(opt$outdir, "integrated_data")
meta_dir        <- file.path(opt$outdir, "metadata")

dir.create(plots_integ_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(plots_clust_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(integ_data_dir,  recursive = TRUE, showWarnings = FALSE)
dir.create(meta_dir,        recursive = TRUE, showWarnings = FALSE)

sample_metadata <- read.csv(opt$samplesheet, stringsAsFactors = FALSE)

# 1. Load QC-filtered objects
seurat_list <- lapply(sample_metadata$sample_id, function(sid) {
  rpath <- file.path(opt$input_dir, paste0(sid, "_qc_filtered.rds"))
  if (!file.exists(rpath)) stop("Missing QC object: ", rpath)
  obj <- readRDS(rpath)
  obj$sample_id  <- sid
  obj$condition  <- sample_metadata$condition[sample_metadata$sample_id == sid]
  if ("patient_id" %in% colnames(sample_metadata)) {
    obj$patient_id <- sample_metadata$patient_id[sample_metadata$sample_id == sid]
  }
  obj
})
names(seurat_list) <- sample_metadata$sample_id

# Common genes across all samples
common_genes <- Reduce(intersect, lapply(seurat_list, rownames))
cat(sprintf("Common genes across all %d samples: %d genes\n", length(seurat_list), length(common_genes)))
seurat_list  <- lapply(seurat_list, function(obj) obj[common_genes, ])

# Palettes
conditions <- unique(sample_metadata$condition)
condition_colors <- setNames(brewer.pal(max(3, length(conditions)), "Set1")[seq_along(conditions)], conditions)
samples <- sample_metadata$sample_id
sample_colors <- setNames(colorRampPalette(brewer.pal(8, "Set2"))(length(samples)), samples)

# 2. Naive Merge (baseline batch check)
cat("\n--- Running Naive Merge Baseline ---\n")
merged_naive <- merge(seurat_list[[1]], seurat_list[-1], add.cell.ids = names(seurat_list), project = "Naive_Merge")
merged_naive <- NormalizeData(merged_naive, verbose = FALSE)
merged_naive <- FindVariableFeatures(merged_naive, nfeatures = 2000, verbose = FALSE)
merged_naive <- ScaleData(merged_naive, verbose = FALSE)
merged_naive <- RunPCA(merged_naive, npcs = 30, verbose = FALSE)
merged_naive <- RunUMAP(merged_naive, dims = 1:30, reduction = "pca", verbose = FALSE)
merged_naive <- FindNeighbors(merged_naive, dims = 1:30, verbose = FALSE)
merged_naive <- FindClusters(merged_naive, resolution = 0.6, verbose = FALSE)

p1_naive <- DimPlot(merged_naive, reduction = "umap", group.by = "sample_id", pt.size = 0.3, cols = sample_colors) + ggtitle("Naive: by Sample")
p2_naive <- DimPlot(merged_naive, reduction = "umap", group.by = "condition", pt.size = 0.3, cols = condition_colors) + ggtitle("Naive: by Condition")
ggsave(file.path(opt$outdir, "plots/01_naive_merge_batch_effects.png"), p1_naive | p2_naive, width = 12, height = 6, dpi = 300)

# 3. Seurat 5 Integration Benchmarking (CCA, RPCA, Harmony)
cat("\n--- Running Integration Methods (CCA, RPCA, Harmony) ---\n")
merged_seurat <- merge(seurat_list[[1]], seurat_list[-1], add.cell.ids = names(seurat_list), project = "Integration")
cell_names <- colnames(merged_seurat)
merged_seurat$sample_id  <- sub("_[ACGTacgt]+-[0-9]*$", "", cell_names)
merged_seurat$condition  <- sample_metadata$condition[match(merged_seurat$sample_id, sample_metadata$sample_id)]

if (length(Layers(merged_seurat[["RNA"]])) <= 1) {
  merged_seurat[["RNA"]] <- split(merged_seurat[["RNA"]], f = merged_seurat$sample_id)
}

merged_seurat <- NormalizeData(merged_seurat, verbose = FALSE)
merged_seurat <- FindVariableFeatures(merged_seurat, nfeatures = 2000, verbose = FALSE)
merged_seurat <- ScaleData(merged_seurat, verbose = FALSE)
merged_seurat <- RunPCA(merged_seurat, npcs = 30, verbose = FALSE)

# CCA
cat("  -> Running CCA Integration...\n")
integrated_cca <- IntegrateLayers(object = merged_seurat, method = CCAIntegration, orig.reduction = "pca",
                                  new.reduction = "integrated.cca", dims = 1:30, verbose = FALSE)
integrated_cca <- FindNeighbors(integrated_cca, reduction = "integrated.cca", dims = 1:30, verbose = FALSE)
integrated_cca <- FindClusters(integrated_cca, resolution = 0.6, verbose = FALSE)
integrated_cca <- RunUMAP(integrated_cca, reduction = "integrated.cca", dims = 1:30, reduction.name = "umap.cca", verbose = FALSE)

# RPCA
cat("  -> Running RPCA Integration...\n")
integrated_rpca <- IntegrateLayers(object = merged_seurat, method = RPCAIntegration, orig.reduction = "pca",
                                   new.reduction = "integrated.rpca", dims = 1:30, verbose = FALSE)
integrated_rpca <- FindNeighbors(integrated_rpca, reduction = "integrated.rpca", dims = 1:30, verbose = FALSE)
integrated_rpca <- FindClusters(integrated_rpca, resolution = 0.6, verbose = FALSE)
integrated_rpca <- RunUMAP(integrated_rpca, reduction = "integrated.rpca", dims = 1:30, reduction.name = "umap.rpca", verbose = FALSE)

# Harmony
cat("  -> Running Harmony Integration...\n")
merged_harmony <- JoinLayers(merged_seurat)
merged_harmony <- RunPCA(merged_harmony, npcs = 30, verbose = FALSE)
integrated_harmony <- RunHarmony(merged_harmony, "sample_id", verbose = FALSE)
integrated_harmony <- FindNeighbors(integrated_harmony, reduction = "harmony", dims = 1:30, verbose = FALSE)
integrated_harmony <- FindClusters(integrated_harmony, resolution = 0.6, verbose = FALSE)
integrated_harmony <- RunUMAP(integrated_harmony, reduction = "harmony", dims = 1:30, reduction.name = "umap.harmony", verbose = FALSE)

# 4. Benchmarking Metrics
calculate_mixing_metric <- function(seurat_obj, group_by = "sample_id", reduction = "umap", k = 30) {
  embedding <- Embeddings(seurat_obj, reduction = reduction)
  k <- min(k, ncol(seurat_obj) - 1)
  nn_result <- FNN::get.knn(embedding[, 1:2], k = k)
  group_labels <- seurat_obj@meta.data[[group_by]]
  mixing_scores <- sapply(seq_len(nrow(nn_result$nn.index)), function(i) {
    neighbor_groups <- group_labels[nn_result$nn.index[i, ]]
    props <- table(neighbor_groups) / length(neighbor_groups)
    1 / sum(props^2)
  })
  mean(mixing_scores)
}

assess_condition_separation <- function(seurat_obj, reduction) {
  umap_coords <- seurat_obj[[reduction]]@cell.embeddings[, 1:2]
  conditions  <- seurat_obj$condition
  centers <- aggregate(umap_coords, by = list(conditions), FUN = mean)
  mean(dist(centers[, -1]))
}

methods_list <- list(
  "Naive"   = list(obj = merged_naive,       reduction = "umap"),
  "CCA"     = list(obj = integrated_cca,     reduction = "umap.cca"),
  "RPCA"    = list(obj = integrated_rpca,    reduction = "umap.rpca"),
  "Harmony" = list(obj = integrated_harmony, reduction = "umap.harmony")
)

mixing_results <- data.frame(
  method               = names(methods_list),
  mixing_score         = sapply(methods_list, function(x) calculate_mixing_metric(x$obj, "sample_id", x$reduction)),
  n_clusters           = sapply(methods_list, function(x) length(unique(x$obj$seurat_clusters))),
  condition_separation = sapply(methods_list, function(x) assess_condition_separation(x$obj, x$reduction))
)
write.csv(mixing_results, file.path(meta_dir, "integration_comparison_metrics.csv"), row.names = FALSE)

p_tradeoff <- ggplot(mixing_results, aes(mixing_score, condition_separation, label = method)) +
  geom_point(size = 4, aes(color = method)) +
  geom_text_repel(size = 4, box.padding = 0.5) +
  labs(title = "Integration Quality: Mixing vs Biological Preservation",
       x = "Sample mixing score", y = "Condition separation") +
  theme(legend.position = "none")
ggsave(file.path(plots_integ_dir, "mixing_vs_preservation.png"), p_tradeoff, width = 9, height = 7, dpi = 300)

# Select best method
mixing_non_naive <- mixing_results[mixing_results$method != "Naive", ]
best_auto <- mixing_non_naive$method[order(-mixing_non_naive$mixing_score)][1]
best_method <- if (opt$preferred_method != "auto" && opt$preferred_method %in% names(methods_list)) {
  opt$preferred_method
} else {
  best_auto
}
cat(sprintf("\n[Selected Integration Method] %s (Auto recommendation: %s)\n", best_method, best_auto))

integrated_final <- switch(best_method,
                           "Harmony" = integrated_harmony,
                           "CCA"     = integrated_cca,
                           "RPCA"    = integrated_rpca,
                           integrated_harmony)

reduction_final <- switch(best_method,
                          "Harmony" = "umap.harmony",
                          "CCA"     = "umap.cca",
                          "RPCA"    = "umap.rpca",
                          "umap.harmony")

integrated_reduction <- switch(reduction_final,
                               "umap.cca"     = "integrated.cca",
                               "umap.rpca"    = "integrated.rpca",
                               "umap.harmony" = "harmony")

# 5. Multi-resolution Clustering & Silhouette Scoring
cat(sprintf("\n--- Testing Clustering Resolutions (%s) ---\n", opt$resolutions))
resolutions <- as.numeric(trimws(unlist(strsplit(as.character(opt$resolutions), ","))))
for (res in resolutions) {
  integrated_final <- FindClusters(integrated_final, resolution = res, verbose = FALSE)
}
colnames(integrated_final@meta.data) <- gsub("RNA_snn_res\\.", "clusters_res_", colnames(integrated_final@meta.data))

n_cells <- ncol(integrated_final)
max_cells_sil <- 5000
subsample_idx <- if (n_cells > max_cells_sil) sample(seq_len(n_cells), max_cells_sil) else seq_len(n_cells)

silhouette_scores <- sapply(resolutions, function(res) {
  cluster_col <- paste0("clusters_res_", res)
  clusters <- as.numeric(integrated_final@meta.data[[cluster_col]][subsample_idx])
  coords <- Embeddings(integrated_final, reduction = integrated_reduction)[subsample_idx, ]
  coords <- coords[, 1:min(30, ncol(coords))]
  if (length(unique(clusters)) > 1) {
    mean(silhouette(clusters, dist(coords))[, 3])
  } else NA
})

resolution_comparison <- data.frame(
  resolution       = resolutions,
  n_clusters       = sapply(resolutions, function(res) length(unique(integrated_final@meta.data[[paste0("clusters_res_", res)]]))),
  silhouette_score = silhouette_scores
)
print(resolution_comparison)

silhouette_best <- resolution_comparison$resolution[which.max(resolution_comparison$silhouette_score)]
optimal_resolution <- if (!is.null(opt$default_resolution) && as.character(opt$default_resolution) != "auto") {
  as.numeric(opt$default_resolution)
} else {
  silhouette_best
}
if (is.na(optimal_resolution)) optimal_resolution <- 0.6
cat(sprintf("Selected clustering resolution: %.1f (Silhouette best: %.1f)\n", optimal_resolution, silhouette_best))

integrated_final$seurat_clusters <- integrated_final@meta.data[[paste0("clusters_res_", optimal_resolution)]]
Idents(integrated_final) <- "seurat_clusters"

# Final clustering plots
p_final_clusters <- DimPlot(integrated_final, reduction = reduction_final, group.by = "seurat_clusters", label = TRUE, pt.size = 0.3) +
  ggtitle(paste0("Final Clustering (", best_method, ", res=", optimal_resolution, ")"))
p_by_sample    <- DimPlot(integrated_final, reduction = reduction_final, group.by = "sample_id", pt.size = 0.3, cols = sample_colors) + ggtitle("Sample Mixing")
p_by_condition <- DimPlot(integrated_final, reduction = reduction_final, group.by = "condition", pt.size = 0.3, cols = condition_colors) + ggtitle("Conditions")

ggsave(file.path(plots_clust_dir, "final_integrated_clustered.png"),
       (p_final_clusters | p_by_condition) / (p_by_sample | plot_spacer()),
       width = 14, height = 10, dpi = 300)

# Save integrated object and metadata
integrated_final <- JoinLayers(integrated_final)
saveRDS(integrated_final, file.path(integ_data_dir, "integrated_clustered_seurat.rds"))
write.csv(integrated_final@meta.data, file.path(meta_dir, "integrated_cell_metadata.csv"), row.names = TRUE)

integration_summary <- data.frame(
  n_samples          = length(unique(integrated_final$sample_id)),
  n_cells_total      = ncol(integrated_final),
  n_genes            = nrow(integrated_final),
  integration_method = best_method,
  optimal_resolution = optimal_resolution,
  n_clusters         = length(unique(integrated_final$seurat_clusters))
)
write.csv(integration_summary, file.path(meta_dir, "integration_summary.csv"), row.names = FALSE)

cat("\n=================================================================\n")
cat(" Part 3 (Integration & Clustering) complete!\n")
cat(" Integrated object: ", file.path(integ_data_dir, "integrated_clustered_seurat.rds"), "\n")
cat("=================================================================\n")
