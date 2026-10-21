#!/usr/bin/env Rscript
################################################################################
# Script: 14_publication_figures.R (Part 15)
# Description: Synthesis and generation of publication-ready high-resolution
#              figures using scplotter and ComplexHeatmap/ggplot2: QC distributions,
#              UMAPs, composition bars, canonical dotplots, DE volcanoes, and
#              cell-cell communication networks.
################################################################################

suppressPackageStartupMessages({
  library(Seurat)
  library(SeuratObject)
  library(ggplot2)
  library(ComplexHeatmap)
  library(patchwork)
  library(dplyr)
})

has_scplotter <- suppressWarnings(requireNamespace("scplotter", quietly = TRUE))
has_cellchat  <- suppressWarnings(requireNamespace("CellChat", quietly = TRUE))

sanitize_filename <- function(x) gsub("[^A-Za-z0-9_.-]", "_", x)

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    seurat_rds   = "results/differential_expression/annotations/integrated_annotated_seurat_final_scored.rds",
    de_csv       = "results/differential_expression/results/findmarkers_celllevel_results.csv",
    cellchat_dir = "results/cellchat/results/cellchat",
    outdir       = "results/publication_figures",
    seed         = 42,
    custom_gene_panel = ""
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
cat(" Step 14 / Part 15: Publication-Grade Multi-Panel Figures\n")
cat(" Input RDS:     ", opt$seurat_rds, "\n")
cat(" DE CSV:        ", opt$de_csv, "\n")
cat(" CellChat Dir:  ", opt$cellchat_dir, "\n")
cat(" Output Dir:    ", opt$outdir, "\n")
cat(" scplotter:     ", ifelse(has_scplotter, "Available", "Using ggplot2 Fallback"), "\n")
cat("=================================================================\n\n")

plots_dir <- file.path(opt$outdir, "plots")
dir.create(plots_dir, recursive = TRUE, showWarnings = FALSE)

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
} else {
  grep("umap", available_reductions, value = TRUE)[1]
}

# 2. QC Violins
p_qc <- VlnPlot(seurat_obj, features = c("nCount_RNA", "nFeature_RNA", "percent.mt"),
                group.by = "sample_id", ncol = 3, pt.size = 0) &
  theme(axis.text.x = element_text(angle = 45, hjust = 1))
ggsave(file.path(plots_dir, "01_qc_violins.png"), p_qc, width = 14, height = 5, dpi = 300)

# 3. UMAPs
p_clust <- DimPlot(seurat_obj, reduction = umap_reduction, group.by = "seurat_clusters", label = TRUE, pt.size = 0.3) +
  ggtitle("UMAP: Seurat Clusters")
ggsave(file.path(plots_dir, "02_umap_clusters.png"), p_clust, width = 8, height = 7, dpi = 300)

p_ct <- DimPlot(seurat_obj, reduction = umap_reduction, group.by = "final_annotation", label = TRUE, pt.size = 0.3, repel = TRUE) +
  ggtitle("UMAP: Cell Type Annotations")
ggsave(file.path(plots_dir, "03_umap_celltypes.png"), p_ct, width = 11, height = 8, dpi = 300)

p_samp <- DimPlot(seurat_obj, reduction = umap_reduction, group.by = "sample_id", pt.size = 0.3) +
  ggtitle("UMAP: Samples")
ggsave(file.path(plots_dir, "04_umap_by_sample.png"), p_samp, width = 9, height = 7, dpi = 300)

p_cond <- DimPlot(seurat_obj, reduction = umap_reduction, group.by = "condition", pt.size = 0.3, cols = condition_colors) +
  ggtitle("UMAP: Conditions")
ggsave(file.path(plots_dir, "05_umap_by_condition.png"), p_cond, width = 8, height = 7, dpi = 300)

# 4. Composition Stacked Bar Plot
prop_df <- seurat_obj@meta.data %>%
  group_by(condition, final_annotation) %>%
  summarise(n = n(), .groups = "drop") %>%
  group_by(condition) %>%
  mutate(pct = n / sum(n) * 100)

p_prop <- ggplot(prop_df, aes(x = condition, y = pct, fill = final_annotation)) +
  geom_bar(stat = "identity", width = 0.6) +
  labs(title = "Cell Type Proportions Across Conditions", x = "", y = "Proportion (%)", fill = "Cell Type") +
  scale_fill_brewer(palette = "Set3")
ggsave(file.path(plots_dir, "06_condition_proportions_stacked.png"), p_prop, width = 8, height = 6, dpi = 300)

# 5. Canonical Marker Dotplot
if (!is.null(opt$custom_gene_panel) && opt$custom_gene_panel != "") {
  myo_markers <- trimws(unlist(strsplit(opt$custom_gene_panel, ",")))
  present_myo <- myo_markers[myo_markers %in% rownames(seurat_obj)]
  if (length(present_myo) > 0) {
    p_dot <- DotPlot(seurat_obj, features = present_myo, group.by = "final_annotation") +
      coord_flip() + theme(axis.text.x = element_text(angle = 45, hjust = 1)) +
      labs(title = "Expression of Key Markers by Cell Type", x = "", y = "")
    ggsave(file.path(plots_dir, "07_marker_dotplot.png"), p_dot, width = 10, height = 6, dpi = 300)
  }
}

# 6. DE Volcano Plots
if (file.exists(opt$de_csv)) {
  de_data <- read.csv(opt$de_csv, stringsAsFactors = FALSE)
  for (cmp in unique(de_data$comparison)) {
    sub_de <- de_data %>% filter(comparison == cmp)
    top_genes <- sub_de %>% filter(significant) %>% arrange(p_val_adj) %>% head(15)
    
    p_vol <- ggplot(sub_de, aes(x = avg_log2FC, y = -log10(p_val_adj))) +
      geom_point(aes(color = significant), alpha = 0.4, size = 1) +
      scale_color_manual(values = c("FALSE" = "#B0BEC5", "TRUE" = "#E63946")) +
      geom_hline(yintercept = -log10(0.05), linetype = "dashed", color = "blue") +
      geom_vline(xintercept = c(-0.25, 0.25), linetype = "dashed", color = "blue") +
      labs(title = paste("Volcano Plot:", cmp), x = "Average log2 Fold Change", y = "-log10 Adjusted P-value")
    if (nrow(top_genes) > 0) {
      p_vol <- p_vol + ggrepel::geom_text_repel(data = top_genes, aes(label = gene), size = 3.5, max.overlaps = 12)
    }
    ggsave(file.path(plots_dir, paste0("08_volcano_", sanitize_filename(cmp), ".png")), p_vol, width = 9, height = 7, dpi = 300)
  }
}

# 7. CellChat Multi-Panel Communication Networks
if (dir.exists(opt$cellchat_dir) && has_cellchat) {
  suppressPackageStartupMessages(library(CellChat))
  cc_files <- list.files(opt$cellchat_dir, pattern = "^cellchat_.*\\.rds$", full.names = TRUE)
  cc_files <- cc_files[!grepl("merged", cc_files)]
  
  if (length(cc_files) > 0) {
    pdf(file.path(plots_dir, "09_cellchat_networks.pdf"), width = 12, height = 4 * length(cc_files))
    par(mfrow = c(length(cc_files), 1))
    for (cc_f in cc_files) {
      c_name <- gsub("cellchat_|\\.rds", "", basename(cc_f))
      cc_obj <- readRDS(cc_f)
      groupSize <- as.numeric(table(cc_obj@idents))
      netVisual_circle(cc_obj@net$count, vertex.weight = groupSize, weight.scale = TRUE,
                       label.edge = FALSE, title.name = paste("Number of Interactions -", c_name))
    }
    dev.off()
  }
}

cat("\n=================================================================\n")
cat(" Part 15 (Publication Figures) complete!\n")
cat(" Figures saved in: ", plots_dir, "\n")
cat("=================================================================\n")
