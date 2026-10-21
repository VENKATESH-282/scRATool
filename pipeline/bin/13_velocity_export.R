#!/usr/bin/env Rscript
################################################################################
# Script: 13_velocity_export.R (Part 13)
# Description: Exports Seurat cell metadata, batch-corrected Harmony embeddings,
#              UMAP coordinates, lineage flags, and pseudotime reference vectors
#              formatted for downstream RNA velocity (scVelo / CellRank) analysis.
################################################################################

suppressPackageStartupMessages({
  library(Seurat)
  library(SeuratObject)
  library(dplyr)
})

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    seurat_rds = "results/differential_expression/annotations/integrated_annotated_seurat_final_scored.rds",
    outdir     = "results/velocity_inputs",
    seed       = 42,
    trajectory_exclude_pattern = ""
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
cat("=================================================================\n")
cat(" Step 13 / Part 13: Export Seurat Data for RNA Velocity (scVelo)\n")
cat(" Input RDS:  ", opt$seurat_rds, "\n")
cat(" Output Dir: ", opt$outdir, "\n")
cat("=================================================================\n\n")

dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

seurat_obj <- readRDS(opt$seurat_rds)

# 1. Format-independent barcode key
cells <- colnames(seurat_obj)
raw_barcodes <- gsub(".*_([ACGTacgt]{16,}).*", "\\1", cells)
if (!any(grepl("^[ACGTacgt]{16}", raw_barcodes))) {
  raw_barcodes <- cells
}
cell_keys <- paste0(seurat_obj$sample_id, "|", raw_barcodes)

# 2. Lineage flag (trajectory analysis targets)
all_types <- as.character(seurat_obj$final_annotation)
if (!is.null(opt$trajectory_exclude_pattern) && opt$trajectory_exclude_pattern != "") {
  lineage_flag <- !grepl(opt$trajectory_exclude_pattern, all_types, ignore.case = TRUE)
} else {
  lineage_flag <- rep(TRUE, length(all_types))
}

# 3. Metadata Export
out_meta <- data.frame(
  cell_key         = cell_keys,
  seurat_barcode   = cells,
  sample_id        = seurat_obj$sample_id,
  condition        = seurat_obj$condition,
  final_annotation = seurat_obj$final_annotation,
  seurat_clusters  = seurat_obj$seurat_clusters,
  lineage_flag     = lineage_flag,
  nCount_RNA       = seurat_obj$nCount_RNA,
  nFeature_RNA     = seurat_obj$nFeature_RNA,
  percent.mt       = seurat_obj$percent.mt,
  stringsAsFactors = FALSE
)
write.csv(out_meta, file.path(opt$outdir, "seurat_metadata.csv"), row.names = FALSE)

# 4. Embeddings Export
available_reductions <- names(seurat_obj@reductions)
umap_reduction <- if ("umap.harmony" %in% available_reductions) {
  "umap.harmony"
} else if ("umap.cca" %in% available_reductions) {
  "umap.cca"
} else {
  grep("umap", available_reductions, value = TRUE)[1]
}

umap_emb <- Embeddings(seurat_obj, reduction = umap_reduction)
umap_df <- data.frame(cell_key = cell_keys, UMAP_1 = umap_emb[, 1], UMAP_2 = umap_emb[, 2])
write.csv(umap_df, file.path(opt$outdir, "seurat_umap.csv"), row.names = FALSE)

if ("harmony" %in% available_reductions) {
  h_emb <- Embeddings(seurat_obj, reduction = "harmony")
  h_df <- cbind(data.frame(cell_key = cell_keys), as.data.frame(h_emb[, 1:min(30, ncol(h_emb))]))
  write.csv(h_df, file.path(opt$outdir, "seurat_harmony.csv"), row.names = FALSE)
}

# 5. Pseudotime Reference Export
pt_ref <- data.frame(cell_key = cell_keys)
if ("monocle3_pseudotime" %in% colnames(seurat_obj@meta.data)) {
  pt_ref$monocle3_pseudotime <- seurat_obj$monocle3_pseudotime
}
if ("slingshot_pseudotime" %in% colnames(seurat_obj@meta.data)) {
  pt_ref$slingshot_pseudotime <- seurat_obj$slingshot_pseudotime
}
write.csv(pt_ref, file.path(opt$outdir, "seurat_pseudotime_reference.csv"), row.names = FALSE)

cat("=================================================================\n")
cat(" Part 13 (Velocity Export) complete!\n")
cat(" Files saved to: ", opt$outdir, "\n")
cat("=================================================================\n")
