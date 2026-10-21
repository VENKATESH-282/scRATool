#!/usr/bin/env Rscript
################################################################################
# Script: 08_trajectory_slingshot.R (Part 7-2)
# Description: Cross-method trajectory validation using Slingshot,
#              myogenic lineage subsetting, principal curve fitting with
#              Satellite cell root, marker validation, and condition comparison.
################################################################################

suppressPackageStartupMessages({
  library(slingshot)
  library(SingleCellExperiment)
  library(princurve)
  library(TrajectoryUtils)
  library(Seurat)
  library(SeuratObject)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(patchwork)
  library(RColorBrewer)
  library(viridis)
  library(scales)
})

sanitize_filename <- function(x) gsub("[^A-Za-z0-9_.-]", "_", x)

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    seurat_rds               = "results/differential_expression/annotations/integrated_annotated_seurat_final_scored.rds",
    outdir                   = "results/trajectory_slingshot",
    seed                     = 42,
    trajectory_root_celltype = "auto",
    slingshot_approx_points  = 150,
    trajectory_exclude_pattern = "",
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
cat(" Step 8 / Part 7-2: Slingshot Trajectory Inference\n")
cat(" Input RDS:  ", opt$seurat_rds, "\n")
cat(" Output Dir: ", opt$outdir, "\n")
cat("=================================================================\n\n")

traj_plot_dir <- file.path(opt$outdir, "plots/slingshot_trajectory")
pt_plot_dir   <- file.path(opt$outdir, "plots/slingshot_pseudotime")
res_dir       <- file.path(opt$outdir, "results")

dir.create(traj_plot_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(pt_plot_dir,   recursive = TRUE, showWarnings = FALSE)
dir.create(res_dir,       recursive = TRUE, showWarnings = FALSE)

# 1. Load Seurat Object & Subset to Target Lineage
seurat_full <- readRDS(opt$seurat_rds)

# Auto-generate condition colors
unique_conditions <- as.character(unique(seurat_full$condition))
condition_colors <- scales::hue_pal()(length(unique_conditions))
names(condition_colors) <- unique_conditions

available_reductions <- names(seurat_full@reductions)
umap_reduction <- if ("umap.harmony" %in% available_reductions) {
  "umap.harmony"
} else if ("umap.cca" %in% available_reductions) {
  "umap.cca"
} else if ("umap.rpca" %in% available_reductions) {
  "umap.rpca"
} else {
  grep("umap", available_reductions, value = TRUE)[1]
}

# Subsetting: keep target lineage, exclude non-target / rare groups
all_types <- unique(as.character(seurat_full$final_annotation))
if (!is.null(opt$trajectory_exclude_pattern) && opt$trajectory_exclude_pattern != "") {
  excluded_types <- all_types[grepl(opt$trajectory_exclude_pattern, all_types, ignore.case = TRUE)]
} else {
  excluded_types <- character(0)
}
myogenic_types <- setdiff(all_types, excluded_types)

cat("Target Lineage Types Kept:\n")
print(myogenic_types)

seurat_sub <- subset(seurat_full, subset = final_annotation %in% myogenic_types)

p_lineage <- DimPlot(seurat_sub, reduction = umap_reduction, group.by = "final_annotation", label = TRUE, pt.size = 0.3) +
  ggtitle("Myogenic Lineage Subset for Slingshot")
ggsave(file.path(traj_plot_dir, "00_lineage_subset.png"), p_lineage, width = 11, height = 8, dpi = 300)

# 2. Build SingleCellExperiment for Slingshot
sce <- as.SingleCellExperiment(seurat_sub)
reducedDims(sce)$UMAP <- Embeddings(seurat_sub, reduction = umap_reduction)

# 3. Determine Root Cluster
root_target <- if (!is.null(opt$trajectory_root_celltype) && opt$trajectory_root_celltype != "auto" && opt$trajectory_root_celltype != "") {
  opt$trajectory_root_celltype
} else {
  "Satellite"
}
sat_type <- myogenic_types[grepl(root_target, myogenic_types, ignore.case = TRUE)][1]
if (is.na(sat_type)) sat_type <- myogenic_types[1]
cat(sprintf("Selected Slingshot root cluster (pattern: %s): %s\n", root_target, sat_type))

# 4. Run Slingshot
cat("\nFitting Slingshot principal curves...\n")
approx_pts <- as.integer(opt$slingshot_approx_points)
if (is.na(approx_pts) || approx_pts <= 0) approx_pts <- 150

sce <- slingshot(
  sce,
  clusterLabels = "final_annotation",
  reducedDim    = "UMAP",
  start.clus    = sat_type,
  approx_points = approx_pts
)

# Extract pseudotime
pt_matrix <- slingPseudotime(sce)
curve_obj <- SlingshotDataSet(sce)

seurat_sub$slingshot_pseudotime <- pt_matrix[, 1]
colData(sce)$slingshot_pseudotime <- pt_matrix[, 1]

# 5. Pseudotime Plots
pt_df <- data.frame(
  pseudotime       = pt_matrix[, 1],
  final_annotation = seurat_sub$final_annotation,
  condition        = seurat_sub$condition,
  sample_id        = seurat_sub$sample_id
) %>% filter(!is.na(pseudotime))

p_pt_umap <- FeaturePlot(seurat_sub, features = "slingshot_pseudotime", reduction = umap_reduction, pt.size = 0.4) +
  scale_color_viridis(option = "magma", na.value = "lightgrey") + ggtitle("Slingshot Pseudotime")
ggsave(file.path(traj_plot_dir, "02_slingshot_overview.png"), p_pt_umap, width = 10, height = 8, dpi = 300)

p_vln <- ggplot(pt_df, aes(x = reorder(final_annotation, pseudotime, median), y = pseudotime, fill = final_annotation)) +
  geom_violin(scale = "width", alpha = 0.8) + geom_boxplot(width = 0.1, fill = "white", outlier.size = 0.5) +
  coord_flip() + labs(title = "Slingshot Pseudotime by Cell Type", x = "", y = "Pseudotime") +
  theme(legend.position = "none")
ggsave(file.path(pt_plot_dir, "03_pseudotime_by_celltype.png"), p_vln, width = 10, height = 6, dpi = 300)

p_dens <- ggplot(pt_df, aes(x = pseudotime, fill = condition)) +
  geom_density(alpha = 0.5) + labs(title = "Slingshot Pseudotime Density by Condition", x = "Pseudotime", y = "Density") +
  scale_fill_manual(values = condition_colors)
ggsave(file.path(pt_plot_dir, "04_pseudotime_by_condition.png"), p_dens, width = 9, height = 6, dpi = 300)

# 6. Summary Statistics & Marker Validation
summary_stats <- pt_df %>% group_by(final_annotation) %>%
  summarise(n_cells = n(), median_pseudotime = median(pseudotime), mean_pseudotime = mean(pseudotime), sd_pseudotime = sd(pseudotime), .groups = "drop")
write.csv(summary_stats, file.path(res_dir, "slingshot_pseudotime_by_celltype.csv"), row.names = FALSE)

# Marker correlation with pseudotime
if (!is.null(opt$custom_gene_panel) && opt$custom_gene_panel != "") {
  marker_genes <- trimws(unlist(strsplit(opt$custom_gene_panel, ",")))
} else {
  marker_genes <- head(VariableFeatures(seurat_sub), 10)
}
present_markers <- marker_genes[marker_genes %in% rownames(seurat_sub)]
cor_res <- lapply(present_markers, function(g) {
  expr <- as.numeric(LayerData(seurat_sub, assay = "RNA", layer = "data")[g, rownames(pt_df)])
  ct <- cor.test(expr, pt_df$pseudotime, method = "spearman")
  data.frame(gene = g, spearman_rho = ct$estimate, p_value = ct$p.value)
}) %>% bind_rows()
write.csv(cor_res, file.path(res_dir, "slingshot_marker_validation.csv"), row.names = FALSE)

# Condition comparison (Kruskal-Wallis)
kw_test <- kruskal.test(pseudotime ~ condition, data = pt_df)
cond_res <- data.frame(test = "Kruskal-Wallis (pseudotime ~ condition)", chi_squared = kw_test$statistic, p_value = kw_test$p.value)
write.csv(cond_res, file.path(res_dir, "slingshot_pseudotime_by_condition.csv"), row.names = FALSE)

saveRDS(sce, file.path(res_dir, "sce_lineage_slingshot.rds"))
saveRDS(sce, file.path(res_dir, "sce_myogenic_slingshot.rds"))
saveRDS(seurat_sub, file.path(res_dir, "seurat_lineage_with_slingshot.rds"))
saveRDS(seurat_sub, file.path(res_dir, "seurat_myogenic_lineage_with_slingshot.rds"))

cat("\n=================================================================\n")
cat(" Part 7-2 (Slingshot) complete!\n")
cat(" Slingshot SCE:    ", file.path(res_dir, "sce_lineage_slingshot.rds"), "\n")
cat(" Lineage Seurat:   ", file.path(res_dir, "seurat_lineage_with_slingshot.rds"), "\n")
cat("=================================================================\n")
