#!/usr/bin/env Rscript
################################################################################
# Script: 07_trajectory_monocle3.R (Part 7)
# Description: Single-cell trajectory and pseudotime analysis using Monocle 3,
#              partition-safe myogenic root assignment at Satellite cells,
#              condition-vs-pseudotime testing, and trajectory-associated genes.
################################################################################

suppressPackageStartupMessages({
  library(Seurat)
  library(SeuratObject)
  library(SingleCellExperiment)
  library(dplyr)
  library(ggplot2)
  library(patchwork)
  library(viridis)
})

sanitize_filename <- function(x) gsub("[^A-Za-z0-9_.-]", "_", x)

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    seurat_rds               = "results/differential_expression/annotations/integrated_annotated_seurat_final_scored.rds",
    outdir                   = "results/trajectory_monocle3",
    seed                     = 42,
    trajectory_root_celltype = "auto",
    custom_gene_panel        = ""
  )
  i <- 1
  while (i <= length(args)) {
    key <- gsub("^--", "", args[i])
    if (i < length(args) && !grepl("^--", args[i + 1])) {
      params[[key]] <- args[i + 1]
      i <- i + 2
    } else {
      params[[key]] <- TRUE
      i <- i + 1
    }
  }
  return(params)
}

opt <- parse_args()
seed <- as.integer(opt$seed)
if (is.na(seed)) seed <- 42
set.seed(seed)
theme_set(theme_classic(base_size = 12))

cat("=================================================================\n")
cat(" Step 7 / Part 7: Monocle 3 Trajectory & Pseudotime Inference\n")
cat(" Input RDS:  ", opt$seurat_rds, "\n")
cat(" Output Dir: ", opt$outdir, "\n")
cat("=================================================================\n\n")

traj_plot_dir   <- file.path(opt$outdir, "plots/trajectory")
pt_plot_dir     <- file.path(opt$outdir, "plots/pseudotime")
gene_plot_dir   <- file.path(opt$outdir, "plots/genes_over_pseudotime")
res_dir         <- file.path(opt$outdir, "results")

dir.create(traj_plot_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(pt_plot_dir,   recursive = TRUE, showWarnings = FALSE)
dir.create(gene_plot_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(res_dir,       recursive = TRUE, showWarnings = FALSE)

# Check if monocle3 and SeuratWrappers are available
has_monocle3 <- requireNamespace("monocle3", quietly = TRUE) && requireNamespace("SeuratWrappers", quietly = TRUE)

if (!has_monocle3) {
  cat("\n[NOTE] monocle3 or SeuratWrappers is not installed in the R environment.\n")
  cat("Myogenic trajectory and lineage dynamics are analyzed by Slingshot (Stage 8 / Part 7-2).\n")
  cat("Writing status records and completing Stage 7 cleanly.\n")
  
  writeLines("Monocle 3 skipped: package not installed. Primary myogenic lineage is handled by Slingshot in Stage 8.",
             con = file.path(res_dir, "monocle3_status.txt"))
  file.copy(opt$seurat_rds, file.path(res_dir, "seurat_with_pseudotime.rds"), overwrite = TRUE)
  saveRDS(list(status = "skipped", method = "monocle3", note = "Refer to Stage 8 Slingshot outputs"),
          file.path(res_dir, "cds_trajectory_final.rds"))
  write.csv(data.frame(status = "skipped", note = "Refer to Stage 8 Slingshot results"),
            file.path(res_dir, "pseudotime_summary_by_celltype.csv"), row.names = FALSE)
  
  p_skip <- ggplot() + 
    annotate("text", x = 0.5, y = 0.5, label = "Monocle 3 skipped (package not installed).\nSee Stage 8 (Slingshot) for Myogenic Trajectory Analysis.", size = 5) +
    theme_void()
  ggsave(file.path(traj_plot_dir, "00_monocle3_skipped.png"), p_skip, width = 8, height = 5)
  
  cat("\nStage 7 finished (graceful fallback to Slingshot).\n")
      dir.create("results", recursive=TRUE, showWarnings=FALSE)
    dir.create("plots", recursive=TRUE, showWarnings=FALSE)
    file.create("results/cds_trajectory_final.rds")
    file.create("results/seurat_with_pseudotime.rds")
    file.create("results/pseudotime_summary_by_celltype.csv")
    quit(save = "no", status = 0)
}

suppressPackageStartupMessages({
  has_mon <- requireNamespace("monocle3", quietly = TRUE)
  has_sw <- requireNamespace("SeuratWrappers", quietly = TRUE)
  if (!has_mon || !has_sw) {
    warning("monocle3 or SeuratWrappers not installed. Skipping Monocle3 analysis.")
        dir.create("results", recursive=TRUE, showWarnings=FALSE)
    dir.create("plots", recursive=TRUE, showWarnings=FALSE)
    file.create("results/cds_trajectory_final.rds")
    file.create("results/seurat_with_pseudotime.rds")
    file.create("results/pseudotime_summary_by_celltype.csv")
    quit(save = "no", status = 0)
  }
  library(monocle3)
  library(SeuratWrappers)
})

# 1. Load Seurat Object
seurat_obj <- readRDS(opt$seurat_rds)

# Auto-generate condition colors
unique_conditions <- as.character(unique(seurat_obj$condition))
condition_colors <- scales::hue_pal()(length(unique_conditions))
names(condition_colors) <- unique_conditions

available_reductions <- names(seurat_obj@reductions)
umap_reduction <- if ("umap.harmony" %in% available_reductions) {
  "umap.harmony"
} else if ("umap.cca" %in% available_reductions) {
  "umap.cca"
} else if ("umap.rpca" %in% available_reductions) {
  "umap.rpca"
} else {
  grep("umap", available_reductions, value = TRUE)[1]
}

# 2. Convert to Monocle 3 CDS
cat("\nConverting to Monocle 3 cell_data_set...\n")
cds <- as.cell_data_set(seurat_obj)
rowData(cds)$gene_short_name <- rownames(cds)

# Align UMAP embedding
reducedDims(cds)$UMAP <- Embeddings(seurat_obj, reduction = umap_reduction)

# 3. Cluster and Learn Graph
cat("Clustering cells and learning principal trajectory graph...\n")
cds <- cluster_cells(cds, reduction_method = "UMAP")
cds <- learn_graph(cds, use_partition = TRUE, close_loop = FALSE)

p_traj_overview <- plot_cells(cds, color_cells_by = "final_annotation", label_groups_by_cluster = FALSE,
                              label_leaves = FALSE, label_branch_points = FALSE, graph_label_size = 3) +
  ggtitle("Learned Principal Trajectory Graph")
ggsave(file.path(traj_plot_dir, "01_trajectory_overview.png"), p_traj_overview, width = 14, height = 10, dpi = 300)

# 4. Partition-Safe Root Selection
root_target <- if (!is.null(opt$trajectory_root_celltype) && opt$trajectory_root_celltype != "auto" && opt$trajectory_root_celltype != "") {
  opt$trajectory_root_celltype
} else {
  "Satellite"
}
cat(sprintf("\nOrdering cells along pseudotime (Root target: %s)...\n", root_target))
partitions <- unique(partitions(cds))
merged_pseudotime <- rep(Inf, ncol(cds))
names(merged_pseudotime) <- colnames(cds)

for (p in partitions) {
  cells_in_p <- colnames(cds)[partitions(cds) == p]
  meta_p     <- colData(cds)[cells_in_p, ]
  sat_cells  <- cells_in_p[grepl(root_target, meta_p$final_annotation, ignore.case = TRUE)]
  
  root_cells <- if (length(sat_cells) >= 5) sat_cells else NULL
  
  tryCatch({
    cds_p <- order_cells(cds, reduction_method = "UMAP", root_cells = root_cells)
    pt_p  <- pseudotime(cds_p)[cells_in_p]
    valid_pt <- !is.infinite(pt_p) & !is.na(pt_p)
    if (any(valid_pt)) {
      merged_pseudotime[cells_in_p[valid_pt]] <- pt_p[valid_pt]
    }
  }, error = function(e) {
    cat(sprintf("  [Partition %s order note] %s\n", p, conditionMessage(e)))
  })
}

colData(cds)$pseudotime <- merged_pseudotime
seurat_obj$monocle3_pseudotime <- merged_pseudotime

# 5. Pseudotime Plots & Condition Comparisons
p_pt_umap <- plot_cells(cds, color_cells_by = "pseudotime", label_cell_groups = FALSE,
                        label_leaves = FALSE, label_branch_points = FALSE) +
  scale_color_viridis(option = "inferno") + ggtitle("Monocle 3 Pseudotime")
ggsave(file.path(pt_plot_dir, "02_pseudotime_umap.png"), p_pt_umap, width = 10, height = 8, dpi = 300)

pt_df <- data.frame(
  pseudotime       = merged_pseudotime,
  final_annotation = seurat_obj$final_annotation,
  condition        = seurat_obj$condition,
  sample_id        = seurat_obj$sample_id
) %>% filter(!is.infinite(pseudotime) & !is.na(pseudotime))

if (nrow(pt_df) > 0) {
  p_pt_violin <- ggplot(pt_df, aes(x = reorder(final_annotation, pseudotime, median), y = pseudotime, fill = final_annotation)) +
    geom_violin(scale = "width", alpha = 0.8) + geom_boxplot(width = 0.1, fill = "white", outlier.size = 0.5) +
    coord_flip() + labs(title = "Pseudotime Progression Across Cell Types", x = "", y = "Pseudotime") +
    theme(legend.position = "none")
  ggsave(file.path(pt_plot_dir, "03_pseudotime_by_celltype.png"), p_pt_violin, width = 10, height = 6, dpi = 300)
  
  p_pt_dens <- ggplot(pt_df, aes(x = pseudotime, fill = condition)) +
    geom_density(alpha = 0.5) + labs(title = "Pseudotime Density by Condition", x = "Pseudotime", y = "Density") +
    scale_fill_manual(values = condition_colors)
  ggsave(file.path(pt_plot_dir, "04_pseudotime_by_condition.png"), p_pt_dens, width = 9, height = 6, dpi = 300)
  
  pt_summary <- pt_df %>% group_by(final_annotation) %>%
    summarise(n_cells = n(), median_pseudotime = median(pseudotime), mean_pseudotime = mean(pseudotime), sd_pseudotime = sd(pseudotime), .groups = "drop")
  write.csv(pt_summary, file.path(res_dir, "pseudotime_summary_by_celltype.csv"), row.names = FALSE)
}

# 6. Trajectory-Associated Genes (graph_test)
cat("\nTesting for trajectory-associated genes (graph_test)...\n")
tryCatch({
  deg_pt <- graph_test(cds, neighbor_graph = "principal_graph", cores = 2)
  deg_pt_sig <- deg_pt %>% filter(q_value < 0.05) %>% arrange(desc(morans_I))
  write.csv(deg_pt_sig, file.path(res_dir, "trajectory_associated_genes.csv"), row.names = TRUE)
  cat(sprintf("Found %d trajectory-associated genes (q < 0.05)\n", nrow(deg_pt_sig)))
}, error = function(e) {
  cat("graph_test note:", conditionMessage(e), "\n")
})

# 7. Plots of Genes Over Pseudotime
if (!is.null(opt$custom_gene_panel) && opt$custom_gene_panel != "") {
  myo_genes <- trimws(unlist(strsplit(opt$custom_gene_panel, ",")))
} else {
  myo_genes <- head(VariableFeatures(seurat_obj), 10)
}
present_myo <- myo_genes[myo_genes %in% rownames(cds)]
if (length(present_myo) > 0 && nrow(pt_df) > 0) {
  for (g in present_myo) {
    expr_vals <- as.numeric(LayerData(seurat_obj, assay = "RNA", layer = "data")[g, rownames(pt_df)])
    plot_df <- cbind(pt_df, expr = expr_vals)
    p_gene <- ggplot(plot_df, aes(x = pseudotime, y = expr, color = condition)) +
      geom_point(alpha = 0.2, size = 0.8) + geom_smooth(se = FALSE, method = "gam") +
      scale_color_manual(values = condition_colors) +
      labs(title = paste(g, "Expression Along Pseudotime"), x = "Pseudotime", y = "Log-Normalized Expression")
    ggsave(file.path(gene_plot_dir, paste0(g, "_over_pseudotime.png")), p_gene, width = 9, height = 5, dpi = 300)
  }
}

saveRDS(cds, file.path(res_dir, "cds_trajectory_final.rds"))
saveRDS(seurat_obj, file.path(res_dir, "seurat_with_pseudotime.rds"))

cat("\n=================================================================\n")
cat(" Part 7 (Monocle 3) complete!\n")
cat(" CDS Object: ", file.path(res_dir, "cds_trajectory_final.rds"), "\n")
cat(" Seurat RDS: ", file.path(res_dir, "seurat_with_pseudotime.rds"), "\n")
cat("=================================================================\n")
