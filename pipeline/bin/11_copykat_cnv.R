#!/usr/bin/env Rscript
################################################################################
# Script: 11_copykat_cnv.R (Part 11)
# Description: Copy Number Variation (CNV) & Large-Scale Aneuploidy Inference
#              using CopyKAT across samples, conditions, and cell types.
################################################################################

suppressPackageStartupMessages({
    if (!requireNamespace("copykat", quietly = TRUE)) {
    warning("copykat not installed. Skipping this module.")
        dir.create("results/copykat", recursive=TRUE, showWarnings=FALSE)
    dir.create("plots/copykat", recursive=TRUE, showWarnings=FALSE)

    quit(save = "no", status = 0)
  }
  library(copykat)
  library(Seurat)
  library(SeuratObject)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(patchwork)
})

sanitize_filename <- function(x) gsub("[^A-Za-z0-9_.-]", "_", x)

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    seurat_rds     = "results/differential_expression/annotations/integrated_annotated_seurat_final_scored.rds",
    outdir         = "results/copykat",
    min_cells      = 200,
    n_cores        = 4,
    force_rerun    = FALSE,
    seed           = 1234,
    copykat_genome = "hg20",
    copykat_ks_cut = 0.1
  )
  i <- 1
  while (i <= length(args)) {
    key <- gsub("^--", "", args[i])
    if (i < length(args) && !grepl("^--", args[i + 1])) {
      val <- args[i + 1]
      if (key %in% c("min_cells", "n_cores", "seed", "copykat_ks_cut")) {
        params[[key]] <- as.numeric(val)
      } else if (key == "force_rerun") {
        params[[key]] <- as.logical(val)
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
seed <- as.integer(opt$seed)
if (is.na(seed)) seed <- 1234
set.seed(seed)

cat("=================================================================\n")
cat(" Step 11 / Part 11: CopyKAT Large-Scale Aneuploidy / CNV Inference\n")
cat(" Input RDS:    ", opt$seurat_rds, "\n")
cat(" Output Dir:   ", opt$outdir, "\n")
cat(" Min Cells:    ", opt$min_cells, "\n")
cat(" Cores:        ", opt$n_cores, "\n")
cat("=================================================================\n\n")

res_dir   <- file.path(opt$outdir, "results/copykat")
plots_dir <- file.path(opt$outdir, "plots/copykat")
annot_dir <- file.path(opt$outdir, "annotations")

dir.create(res_dir,   recursive = TRUE, showWarnings = FALSE)
dir.create(plots_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(annot_dir, recursive = TRUE, showWarnings = FALSE)

# 1. Load Seurat Object
seurat_obj <- readRDS(opt$seurat_rds)
DefaultAssay(seurat_obj) <- "RNA"

sample_ids <- sort(unique(as.character(seurat_obj$sample_id)))

run_copykat_sample <- function(sid) {
  cells <- colnames(seurat_obj)[as.character(seurat_obj$sample_id) == sid]
  cat(sprintf("\n=== CopyKAT: %s (%d cells) ===\n", sid, length(cells)))
  
  if (length(cells) < opt$min_cells) {
    cat(sprintf("  [skip] Sample %s has fewer than %d cells.\n", sid, opt$min_cells))
    return(NULL)
  }
  
  rds_path <- file.path(res_dir, paste0("ck_", sanitize_filename(sid), ".rds"))
  if (file.exists(rds_path) && !opt$force_rerun) {
    cat("  [cache] Using cached result:", rds_path, "\n")
    return(readRDS(rds_path))
  }
  
  seu_sub <- subset(seurat_obj, cells = cells)
  raw_mat <- as.matrix(LayerData(seu_sub, assay = "RNA", layer = "counts"))
  
  ck <- tryCatch({
    copykat(
      rawmat    = raw_mat,
      id.type   = "S",
      genome    = as.character(opt$copykat_genome),
      ngene.chr = 5,
      win.size  = 25,
      KS.cut    = as.numeric(opt$copykat_ks_cut),
      LOW.DR    = 0.05,
      UP.DR     = 0.1,
      distance  = "euclidean",
      cell.line = "no",
      n.cores   = opt$n_cores,
      sam.name  = file.path(res_dir, sanitize_filename(sid))
    )
  }, error = function(e) {
    cat(sprintf("  [error] CopyKAT failed for %s: %s\n", sid, conditionMessage(e)))
    NULL
  })
  
  if (!is.null(ck)) saveRDS(ck, rds_path)
  return(ck)
}

ck_list <- setNames(lapply(sample_ids, run_copykat_sample), sample_ids)

sample_cond <- unique(seurat_obj@meta.data[, c("sample_id", "condition")])
run_status <- data.frame(
  sample_id = sample_ids,
  condition = sample_cond$condition[match(sample_ids, sample_cond$sample_id)],
  n_cells   = as.integer(table(factor(as.character(seurat_obj$sample_id), levels = sample_ids))),
  stringsAsFactors = FALSE
)
run_status$status <- ifelse(!vapply(ck_list, is.null, logical(1)), "ok",
                            ifelse(run_status$n_cells < opt$min_cells, "skipped_too_few_cells", "failed"))
write.csv(run_status, file.path(res_dir, "copykat_run_status.csv"), row.names = FALSE)

# 2. Attach CopyKAT Predictions to Seurat Object
labels <- setNames(rep("not.run", ncol(seurat_obj)), colnames(seurat_obj))

for (sid in names(ck_list)) {
  ck <- ck_list[[sid]]
  if (is.null(ck)) next
  cell_ids <- colnames(seurat_obj)[as.character(seurat_obj$sample_id) == sid]
  pred <- ck$prediction
  if (!is.null(pred) && nrow(pred) > 0) {
    norm_barcodes <- gsub("-", ".", cell_ids, fixed = TRUE)
    m <- match(norm_barcodes, gsub("-", ".", pred$cell.names, fixed = TRUE))
    found <- !is.na(m)
    labels[cell_ids[found]] <- pred$copykat.pred[m[found]]
  }
}

seurat_obj$copykat_prediction <- labels

# 3. Calculate Aneuploid Fractions & Summaries
aneuploid_data <- seurat_obj@meta.data %>%
  filter(copykat_prediction %in% c("diploid", "aneuploid")) %>%
  group_by(sample_id, condition, final_annotation) %>%
  summarise(
    n_called    = n(),
    n_aneuploid = sum(copykat_prediction == "aneuploid"),
    fraction    = n_aneuploid / n_called,
    .groups     = "drop"
  )
write.csv(aneuploid_data, file.path(res_dir, "aneuploid_fraction_summary.csv"), row.names = FALSE)

# 4. Visualization
available_reductions <- names(seurat_obj@reductions)
umap_reduction <- if ("umap.harmony" %in% available_reductions) {
  "umap.harmony"
} else if ("umap.cca" %in% available_reductions) {
  "umap.cca"
} else {
  grep("umap", available_reductions, value = TRUE)[1]
}

copykat_colors <- c("aneuploid" = "#D62728", "diploid" = "#1F77B4", "not.defined" = "#AAAAAA", "not.run" = "#E0E0E0")
p_ck_umap <- DimPlot(seurat_obj, reduction = umap_reduction, group.by = "copykat_prediction", cols = copykat_colors, pt.size = 0.3) +
  ggtitle("CopyKAT Predicted Karyotype")
ggsave(file.path(plots_dir, "01_copykat_prediction_umap.png"), p_ck_umap, width = 9, height = 7, dpi = 300)

saveRDS(seurat_obj, file.path(annot_dir, "integrated_annotated_seurat_final_scored_copykat.rds"))

cat("\n=================================================================\n")
cat(" Part 11 (CopyKAT) complete!\n")
cat(" Status:     ", file.path(res_dir, "copykat_run_status.csv"), "\n")
cat(" Object RDS: ", file.path(annot_dir, "integrated_annotated_seurat_final_scored_copykat.rds"), "\n")
cat("=================================================================\n")
