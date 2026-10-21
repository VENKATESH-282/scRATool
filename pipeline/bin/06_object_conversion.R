#!/usr/bin/env Rscript
################################################################################
# Script: 06_object_conversion.R (Part 6)
# Description: Converts Seurat Object to SingleCellExperiment (SCE) and
#              SummarizedExperiment (SE) Pseudobulk structures for cross-framework
#              interoperability and validation.
################################################################################

suppressPackageStartupMessages({
  library(Seurat)
  library(SeuratObject)
  library(SingleCellExperiment)
  library(SummarizedExperiment)
  library(S4Vectors)
  library(DESeq2)
  library(dplyr)
  library(ggplot2)
  library(patchwork)
})

sanitize_filename <- function(x) gsub("[^A-Za-z0-9_.-]", "_", x)

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    seurat_rds = "results/differential_expression/annotations/integrated_annotated_seurat_final_scored.rds",
    outdir     = "results/object_structures",
    seed       = 42
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
cat(" Step 6 / Part 6: Cross-Platform Object Conversions (SCE & SE)\n")
cat(" Input RDS:  ", opt$seurat_rds, "\n")
cat(" Output Dir: ", opt$outdir, "\n")
cat("=================================================================\n\n")

plots_dir   <- file.path(opt$outdir, "plots")
example_dir <- file.path(opt$outdir, "examples")
dir.create(plots_dir,   recursive = TRUE, showWarnings = FALSE)
dir.create(example_dir, recursive = TRUE, showWarnings = FALSE)

seurat_obj <- readRDS(opt$seurat_rds)

available_reductions <- names(seurat_obj@reductions)
umap_name <- if ("umap.harmony" %in% available_reductions) {
  "umap.harmony"
} else if ("umap.cca" %in% available_reductions) {
  "umap.cca"
} else if ("umap.rpca" %in% available_reductions) {
  "umap.rpca"
} else {
  grep("umap", available_reductions, value = TRUE)[1]
}

# 1. UMAP by Cell Type split by Condition
umap_coords <- seurat_obj@reductions[[umap_name]]@cell.embeddings
umap_df <- data.frame(
  UMAP1     = umap_coords[, 1],
  UMAP2     = umap_coords[, 2],
  cell_type = seurat_obj$final_annotation,
  condition = seurat_obj$condition
)

p_umap <- ggplot(umap_df, aes(x = UMAP1, y = UMAP2, color = cell_type)) +
  geom_point(size = 0.3, alpha = 0.5) +
  facet_wrap(~ condition) +
  labs(title = "UMAP by Cell Type, split by Condition", color = "Cell Type") +
  scale_color_brewer(palette = "Set3")
ggsave(file.path(plots_dir, "01_umap_by_celltype_condition.png"), p_umap, width = 16, height = 6, dpi = 300)

# Export UMAP coordinates and metadata for Interactive GUI
cat("\nExporting real_umap_data.csv for Interactive UI...\n")
gui_umap_df <- data.frame(
  cell_id   = colnames(seurat_obj),
  UMAP_1    = umap_coords[, 1],
  UMAP_2    = umap_coords[, 2],
  cell_type = seurat_obj$final_annotation,
  condition = seurat_obj$condition,
  sample_id = seurat_obj$sample_id,
  cluster   = if("seurat_clusters" %in% colnames(seurat_obj@meta.data)) as.character(seurat_obj$seurat_clusters) else "0",
  stringsAsFactors = FALSE
)

# Dynamically add any scoring or flag columns
score_cols <- grep("_score$|_affected$|_flag$", colnames(seurat_obj@meta.data), value = TRUE, ignore.case = TRUE)
for (col in score_cols) {
  gui_umap_df[[col]] <- seurat_obj@meta.data[[col]]
}
write.csv(gui_umap_df, file.path(opt$outdir, "real_umap_data.csv"), row.names = FALSE)
cat("  Saved:", file.path(opt$outdir, "real_umap_data.csv"), "\n")


# 2. Convert to SingleCellExperiment
cat("\nConverting to SingleCellExperiment...\n")
sce_from_seurat <- as.SingleCellExperiment(seurat_obj)
saveRDS(sce_from_seurat, file.path(example_dir, "sce_full_object.rds"))
cat("  Saved:", file.path(example_dir, "sce_full_object.rds"), "\n")

# 3. Build SummarizedExperiment per cell type
build_pseudobulk_se <- function(celltype, seurat_obj) {
  sub_obj <- subset(seurat_obj, subset = final_annotation == celltype)
  pb <- PseudobulkExpression(sub_obj, assays = "RNA", group.by = "sample_id", layer = "counts", method = "aggregate")
  pb_mat <- as.matrix(pb$RNA)
  colnames(pb_mat) <- gsub("-", "_", colnames(pb_mat))
  
  sample_meta <- unique(sub_obj@meta.data[, c("sample_id", "condition")])
  rownames(sample_meta) <- sample_meta$sample_id
  rownames(sample_meta) <- gsub("-", "_", rownames(sample_meta))
  sample_meta <- sample_meta[colnames(pb_mat), , drop = FALSE]
  
  SummarizedExperiment(assays = list(counts = pb_mat), colData = sample_meta)
}

cell_types <- sort(unique(seurat_obj$final_annotation))
pseudobulk_se_list <- lapply(cell_types, function(ct) build_pseudobulk_se(ct, seurat_obj))
names(pseudobulk_se_list) <- sanitize_filename(cell_types)
saveRDS(pseudobulk_se_list, file.path(example_dir, "pseudobulk_SE_by_celltype.rds"))
cat("  Saved:", file.path(example_dir, "pseudobulk_SE_by_celltype.rds"), "\n")

# 4. Validation Checks
cat("\n--- Validation Check ---\n")
cat("Metadata rows match cells: ", nrow(seurat_obj@meta.data) == ncol(seurat_obj), "\n")
cat("No NA in final_annotation: ", !any(is.na(seurat_obj$final_annotation)), "\n")
cat("Assays available:          ", paste(names(seurat_obj@assays), collapse = ", "), "\n")
cat("=================================================================\n")
cat(" Part 6 complete!\n")
cat("=================================================================\n")
