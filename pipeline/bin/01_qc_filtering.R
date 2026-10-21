#!/usr/bin/env Rscript
################################################################################
# Script: 01_qc_filtering.R (Part 2)
# Description: Quality Control, Cell Filtering, Doublet Detection (scDblFinder),
#              Gene-Level Filtering (with DUX4 biomarker allowlist), and
#              Normalization / Variable Feature Selection.
################################################################################

suppressPackageStartupMessages({
  library(Seurat)
  library(SeuratObject)
  library(dplyr)
  library(ggplot2)
  library(patchwork)
  library(scDblFinder)
  library(SingleCellExperiment)
  library(org.Hs.eg.db)
  library(AnnotationDbi)
})

# Argument parsing helper
parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    samplesheet   = "assets/samples.csv",
    outdir        = "results/qc",
    nfeature_min  = 500,
    nfeature_max  = 6000,
    ncount_min    = 800,
    ncount_max    = 50000,
    mt_thresh     = 15,
    min_pct_cells         = 0.1,
    n_hvg                 = 2000,
    custom_gene_allowlist = "",
    organism              = "human",
    seed                  = 42
  )
  i <- 1
  while (i <= length(args)) {
    key <- gsub("^--", "", args[i])
    if (i < length(args) && !grepl("^--", args[i + 1])) {
      val <- args[i + 1]
      if (key %in% c("nfeature_min", "nfeature_max", "ncount_min", "ncount_max", "mt_thresh", "min_pct_cells", "n_hvg", "seed")) {
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

cat("=================================================================\n")
cat(" Step 1 / Part 2: scRNA-seq Quality Control & Filtering\n")
cat(" Samplesheet:   ", opt$samplesheet, "\n")
cat(" Output Dir:    ", opt$outdir, "\n")
cat(" nFeature Range:", opt$nfeature_min, "-", opt$nfeature_max, "\n")
cat(" nCount Range:  ", opt$ncount_min, "-", opt$ncount_max, "\n")
cat(" Max MT %:      ", opt$mt_thresh, "\n")
cat(" Min Cell %:    ", opt$min_pct_cells, "\n")
cat("=================================================================\n\n")

plots_dir    <- file.path(opt$outdir, "plots")
qc_meta_dir  <- file.path(opt$outdir, "qc_metrics")
filt_dir     <- file.path(opt$outdir, "filtered_data")

dir.create(plots_dir,   recursive = TRUE, showWarnings = FALSE)
dir.create(qc_meta_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(filt_dir,    recursive = TRUE, showWarnings = FALSE)

sample_info <- read.csv(opt$samplesheet, stringsAsFactors = FALSE)
stopifnot(all(c("sample_id", "condition", "file_path") %in% colnames(sample_info)))

seurat_list <- list()

# 1. Load Samples
for (i in seq_len(nrow(sample_info))) {
  sid   <- sample_info$sample_id[i]
  fpath <- sample_info$file_path[i]
  cond  <- sample_info$condition[i]
  
  cat(sprintf("[Loading %d/%d] %s (%s)\n", i, nrow(sample_info), sid, cond))
  
  # Handle remote URLs (GEO, S3 HTTP, FTP)
  if (grepl("^http://|^https://|^ftp://", fpath)) {
    cat(sprintf("  Downloading remote file: %s\n", fpath))
    download_dir <- file.path(opt$outdir, "raw_downloads")
    if (!dir.exists(download_dir)) {
      dir.create(download_dir, recursive = TRUE, showWarnings = FALSE)
    }
    dest <- file.path(download_dir, basename(fpath))
    if (!file.exists(dest)) {
      download.file(fpath, dest, mode = "wb", quiet = FALSE)
    }
    fpath <- dest
  }

  if (!file.exists(fpath)) {
    stop("Input matrix not found: ", fpath)
  }
  
  is_obj <- FALSE
  if (dir.exists(fpath)) {
    mat <- Read10X(data.dir = fpath)
  } else if (grepl("\\.h5$", fpath, ignore.case=TRUE)) {
    mat <- Read10X_h5(fpath)
  } else if (grepl("\\.h5ad$", fpath, ignore.case=TRUE)) {
    if (!requireNamespace("SeuratDisk", quietly = TRUE)) {
      stop("The 'SeuratDisk' package is required to read .h5ad files. Install it with remotes::install_github('mojaveazure/seurat-disk').")
    }
    h5seurat_path <- gsub("\\.h5ad$", ".h5seurat", fpath, ignore.case=TRUE)
    if (!file.exists(h5seurat_path)) {
      cat("  Converting .h5ad to .h5seurat...\n")
      SeuratDisk::Convert(fpath, dest = "h5seurat", overwrite = TRUE)
    }
    obj <- SeuratDisk::LoadH5Seurat(h5seurat_path, assays = "RNA", meta.data = FALSE, misc = FALSE)
    is_obj <- TRUE
  } else if (grepl("\\.rds$", fpath, ignore.case=TRUE)) {
    obj <- readRDS(fpath)
    is_obj <- TRUE
  } else if (grepl("\\.csv(\\.gz)?$", fpath, ignore.case=TRUE)) {
    con <- if (grepl("\\.gz$", fpath, ignore.case=TRUE)) gzfile(fpath) else file(fpath)
    df  <- read.csv(con, header = TRUE, row.names = 1, check.names = FALSE)
    mat <- Matrix::Matrix(as.matrix(df), sparse = TRUE)
  } else if (grepl("\\.mtx(\\.gz)?$", fpath, ignore.case=TRUE)) {
    mat <- Matrix::readMM(fpath)
  } else {
    con <- if (grepl("\\.gz$", fpath, ignore.case=TRUE)) gzfile(fpath) else file(fpath)
    df  <- read.delim(con, header = TRUE, row.names = 1, check.names = FALSE)
    mat <- Matrix::Matrix(as.matrix(df), sparse = TRUE)
  }
  
  if (!is_obj) {
    obj <- CreateSeuratObject(counts = mat, project = sid, min.cells = 0, min.features = 0)
  }
  obj$sample_id <- sid
  obj$condition <- cond
  if ("patient_id" %in% colnames(sample_info)) {
    obj$patient_id <- sample_info$patient_id[i]
  }
  seurat_list[[sid]] <- obj
}

# 2. MT & Ribo calculation
mt_genes_ensembl <- c(
  "ENSG00000198888", "ENSG00000198763", "ENSG00000198804", "ENSG00000198712",
  "ENSG00000228253", "ENSG00000198899", "ENSG00000198938", "ENSG00000198840",
  "ENSG00000212907", "ENSG00000198886", "ENSG00000198786", "ENSG00000198695",
  "ENSG00000198727"
)

for (sid in names(seurat_list)) {
  obj <- seurat_list[[sid]]
  mt_present <- intersect(mt_genes_ensembl, rownames(obj))
  
  if (length(mt_present) == 0) {
    symbol_hits <- grep("^[Mm][Tt]-", rownames(obj), value = TRUE)
    if (length(symbol_hits) > 0) {
      obj[["percent.mt"]] <- PercentageFeatureSet(obj, pattern = "^[Mm][Tt]-")
    } else {
      warning(sprintf("%s: No MT genes matched by Ensembl or MT- symbol prefix. percent.mt set to 0.", sid))
      obj$percent.mt <- 0
    }
  } else {
    obj[["percent.mt"]] <- PercentageFeatureSet(obj, features = mt_present)
  }
  
  obj[["percent.ribo"]] <- PercentageFeatureSet(obj, pattern = "^RP[SL]")
  
  p_vln <- VlnPlot(obj, features = c("nCount_RNA", "nFeature_RNA", "percent.mt"), ncol = 3, pt.size = 0.3)
  ggsave(file.path(plots_dir, paste0(sid, "_qc_violins.png")), p_vln, width = 12, height = 4, dpi = 300)
  
  p1 <- FeatureScatter(obj, feature1 = "nCount_RNA", feature2 = "nFeature_RNA") + labs(title = paste(sid, "- UMI vs Genes"))
  p2 <- FeatureScatter(obj, feature1 = "nCount_RNA", feature2 = "percent.mt") + labs(title = paste(sid, "- UMI vs MT%"))
  ggsave(file.path(plots_dir, paste0(sid, "_qc_scatter.png")), p1 + p2, width = 12, height = 5, dpi = 300)
  
  seurat_list[[sid]] <- obj
}

# 3. Cell-level QC Filtering
cell_qc_summary <- list()
for (sid in names(seurat_list)) {
  obj <- seurat_list[[sid]]
  before <- ncol(obj)
  
  qc_df <- data.frame(
    nCount_RNA   = obj$nCount_RNA,
    nFeature_RNA = obj$nFeature_RNA,
    percent.mt   = obj$percent.mt
  )
  qc_df$pass_qc <- (
    qc_df$nCount_RNA   >= opt$ncount_min   &
    qc_df$nCount_RNA   <= opt$ncount_max   &
    qc_df$nFeature_RNA >= opt$nfeature_min &
    qc_df$nFeature_RNA <= opt$nfeature_max &
    qc_df$percent.mt   <  opt$mt_thresh
  )
  
  p_thresh <- ggplot(qc_df, aes(x = log10(nCount_RNA + 1), y = log10(nFeature_RNA + 1), color = pass_qc)) +
    geom_point(alpha = 0.5, size = 1) +
    geom_vline(xintercept = log10(c(opt$ncount_min, opt$ncount_max)), linetype = "dashed", color = "red") +
    geom_hline(yintercept = log10(c(opt$nfeature_min, opt$nfeature_max)), linetype = "dashed", color = "red") +
    scale_color_manual(values = c("TRUE" = "#06D6A0", "FALSE" = "#EF476F")) +
    labs(
      title = paste0(sid, ": Cell Filtering Thresholds"),
      subtitle = sprintf("%d cells pass QC (%.1f%%)", sum(qc_df$pass_qc), 100 * sum(qc_df$pass_qc)/nrow(qc_df)),
      x = "log10(UMI + 1)", y = "log10(Genes + 1)", color = "Pass QC"
    ) +
    theme_classic()
  ggsave(file.path(plots_dir, paste0(sid, "_filtering_thresholds.png")), p_thresh, width = 8, height = 7, dpi = 300)
  
  obj <- subset(obj, subset = nCount_RNA >= opt$ncount_min & nCount_RNA <= opt$ncount_max &
                              nFeature_RNA >= opt$nfeature_min & nFeature_RNA <= opt$nfeature_max &
                              percent.mt < opt$mt_thresh)
  after <- ncol(obj)
  removal_pct <- round((before - after) / before * 100, 1)
  cat(sprintf("  [%s] Cell QC: %d -> %d cells (%.1f%% removed)\n", sid, before, after, removal_pct))
  
  cell_qc_summary[[sid]] <- data.frame(
    sample = sid, cells_before_cell_qc = before, cells_after_cell_qc = after, removal_pct = removal_pct
  )
  seurat_list[[sid]] <- obj
}

# 4. Doublet Detection with scDblFinder
doublet_rate_summary <- list()
for (sid in names(seurat_list)) {
  obj <- seurat_list[[sid]]
  sce <- as.SingleCellExperiment(obj)
  set.seed(42)
  suppressWarnings({
    sce <- scDblFinder(sce, dbr = NULL, verbose = FALSE)
  })
  
  obj$doublet_class <- ifelse(sce$scDblFinder.class == "doublet", "Doublet", "Singlet")
  obj$doublet_score <- sce$scDblFinder.score
  n_doublets <- sum(obj$doublet_class == "Doublet")
  doublet_rate <- round(n_doublets / ncol(obj) * 100, 1)
  
  cat(sprintf("  [%s] scDblFinder: %d doublets (%.1f%%)\n", sid, n_doublets, doublet_rate))
  obj <- subset(obj, subset = doublet_class == "Singlet")
  doublet_rate_summary[[sid]] <- doublet_rate
  seurat_list[[sid]] <- obj
}

# 5. Gene-level QC with Custom Allowlist
allowlist_symbols <- if (opt$custom_gene_allowlist != "") {
  trimws(unlist(strsplit(opt$custom_gene_allowlist, ",")))
} else {
  character(0)
}

org_db <- if (tolower(opt$organism) == "mouse") {
  requireNamespace("org.Mm.eg.db", quietly = TRUE)
  org.Mm.eg.db::org.Mm.eg.db
} else {
  org.Hs.eg.db
}

allowlist_ensembl_lookup <- tryCatch({
  if (length(allowlist_symbols) > 0) {
    mapIds(org_db, keys = allowlist_symbols, keytype = "SYMBOL", column = "ENSEMBL", multiVals = "list")
  } else {
    list()
  }
}, error = function(e) list())
allowlist_ensembl <- unique(unlist(allowlist_ensembl_lookup))
allowlist_all <- unique(c(allowlist_symbols, allowlist_ensembl))

gene_qc_summary <- list()
for (sid in names(seurat_list)) {
  obj <- seurat_list[[sid]]
  counts_matrix <- LayerData(obj, layer = "counts")
  gene_detection <- rowSums(counts_matrix > 0)
  
  gene_qc <- data.frame(
    gene = rownames(obj),
    n_cells_detected = gene_detection,
    pct_cells_detected = (gene_detection / ncol(obj)) * 100,
    is_hb = grepl("^HB[AB]", rownames(obj)) | rownames(obj) %in% c("ENSG00000206172", "ENSG00000244734"),
    is_allowlisted = rownames(obj) %in% allowlist_all
  )
  
  genes_before <- nrow(obj)
  genes_to_keep <- (gene_qc$pct_cells_detected >= opt$min_pct_cells | gene_qc$is_allowlisted) & !gene_qc$is_hb
  rescued <- sum(gene_qc$is_allowlisted & gene_qc$pct_cells_detected < opt$min_pct_cells)
  
  obj <- obj[gene_qc$gene[genes_to_keep], ]
  cat(sprintf("  [%s] Gene QC: %d -> %d genes (Custom allowlist genes rescued: %d)\n",
              sid, genes_before, nrow(obj), rescued))
  
  gene_qc_summary[[sid]] <- data.frame(sample = sid, genes_before = genes_before, genes_after = nrow(obj))
  seurat_list[[sid]] <- obj
}

# 6. Normalization and Variable Feature Selection
for (sid in names(seurat_list)) {
  obj <- seurat_list[[sid]]
  obj <- NormalizeData(obj, normalization.method = "LogNormalize", scale.factor = 10000, verbose = FALSE)
  obj <- FindVariableFeatures(obj, selection.method = "vst", nfeatures = opt$n_hvg, verbose = FALSE)
  top10 <- head(VariableFeatures(obj), 10)
  
  p_var <- VariableFeaturePlot(obj)
  p_var <- LabelPoints(plot = p_var, points = top10, repel = TRUE)
  ggsave(file.path(plots_dir, paste0(sid, "_variable_features.png")), p_var, width = 10, height = 7, dpi = 300)
  
  seurat_list[[sid]] <- obj
}

# 7. Save Summaries and Filtered RDS objects
qc_summary_list <- lapply(names(seurat_list), function(sid) {
  obj <- seurat_list[[sid]]
  cell_info <- cell_qc_summary[[sid]]
  gene_info <- gene_qc_summary[[sid]]
  data.frame(
    sample = sid,
    cells_before_cell_qc = cell_info$cells_before_cell_qc,
    cells_after_cell_qc  = cell_info$cells_after_cell_qc,
    cell_qc_removal_pct  = cell_info$removal_pct,
    final_cells          = ncol(obj),
    genes_before_gene_qc = gene_info$genes_before,
    final_genes          = nrow(obj),
    median_umi           = median(obj$nCount_RNA),
    median_genes         = median(obj$nFeature_RNA),
    median_mt_pct        = round(median(obj$percent.mt), 2),
    median_doublet_score = round(median(obj$doublet_score), 3),
    doublet_rate_pct     = doublet_rate_summary[[sid]],
    ncount_min           = opt$ncount_min,
    ncount_max           = opt$ncount_max,
    nfeature_min         = opt$nfeature_min,
    nfeature_max         = opt$nfeature_max,
    mt_threshold         = opt$mt_thresh
  )
})
qc_summary <- do.call(rbind, qc_summary_list)
write.csv(qc_summary, file.path(qc_meta_dir, "QC_summary_all_samples.csv"), row.names = FALSE)

for (sid in names(seurat_list)) {
  rds_path <- file.path(filt_dir, paste0(sid, "_qc_filtered.rds"))
  csv_path <- file.path(filt_dir, paste0(sid, "_cell_metadata.csv"))
  saveRDS(seurat_list[[sid]], file = rds_path)
  write.csv(seurat_list[[sid]]@meta.data, file = csv_path)
}

cat("\n=================================================================\n")
cat(" Part 2 (QC & Filtering) completed successfully!\n")
cat(" Summary:  ", file.path(qc_meta_dir, "QC_summary_all_samples.csv"), "\n")
cat(" Objects:  ", filt_dir, "\n")
cat(" Plots:    ", plots_dir, "\n")
cat("=================================================================\n")
