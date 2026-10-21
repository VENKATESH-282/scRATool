#!/usr/bin/env Rscript
################################################################################
# Script: 12_hdwgcna_networks.R (Part 12)
# Description: High-dimensional Weighted Gene Co-expression Network Analysis
#              (hdWGCNA): Metacell construction, soft power selection,
#              module detection, hub gene extraction, and DME analysis.
################################################################################

suppressPackageStartupMessages({
    if (!requireNamespace("hdWGCNA", quietly = TRUE)) {
    warning("hdWGCNA not installed. Skipping this module.")
        dir.create("results/hdwgcna", recursive=TRUE, showWarnings=FALSE)
    dir.create("plots/hdwgcna", recursive=TRUE, showWarnings=FALSE)

    quit(save = "no", status = 0)
  }
  library(hdWGCNA)
  library(WGCNA)
  library(Seurat)
  library(SeuratObject)
  library(Matrix)
  library(tidyverse)
  library(cowplot)
  library(patchwork)
  library(igraph)
  library(enrichR)
})

sanitize_filename <- function(x) gsub("[^A-Za-z0-9_.-]", "_", x)
shorten_label <- function(x) {
  x <- sub("\\s*\\(.*\\)\\s*$", "", x)
  gsub("[^A-Za-z0-9-]+", "_", trimws(x))
}

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    seurat_rds               = "results/differential_expression/annotations/integrated_annotated_seurat_final_scored.rds",
    outdir                   = "results/hdwgcna",
    target_celltypes         = "auto",
    n_threads                = 4,
    reference_condition      = "CTRL",
    seed                     = 42,
    hdwgcna_k_metacell       = 20,
    hdwgcna_min_cells        = 40,
    hdwgcna_target_metacells = 1000,
    hdwgcna_min_module_size  = 30,
    hdwgcna_merge_cut_height = 0.25
  )
  i <- 1
  while (i <= length(args)) {
    key <- gsub("^--", "", args[i])
    if (i < length(args) && !grepl("^--", args[i + 1])) {
      val <- args[i + 1]
      if (key %in% c("n_threads", "seed", "hdwgcna_k_metacell", "hdwgcna_min_cells", "hdwgcna_target_metacells", "hdwgcna_min_module_size", "hdwgcna_merge_cut_height")) {
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
seed <- as.integer(opt$seed)
if (is.na(seed)) seed <- 42
set.seed(seed)

cat("=================================================================\n")
cat(" Step 12 / Part 12: hdWGCNA Gene Co-Expression Network Analysis\n")
cat(" Input RDS:         ", opt$seurat_rds, "\n")
cat(" Output Dir:        ", opt$outdir, "\n")
cat(" Target Cell Types: ", opt$target_celltypes, "\n")
cat(" Reference Group:   ", opt$reference_condition, "\n")
cat("=================================================================\n\n")

res_root_dir   <- file.path(opt$outdir, "results/hdwgcna")
plots_root_dir <- file.path(opt$outdir, "plots/hdwgcna")
annot_dir      <- file.path(opt$outdir, "annotations")

dir.create(res_root_dir,   recursive = TRUE, showWarnings = FALSE)
dir.create(plots_root_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(annot_dir,      recursive = TRUE, showWarnings = FALSE)

tryCatch(enableWGCNAThreads(nThreads = opt$n_threads), error = function(e) NULL)

# 1. Load Seurat Object
seurat_obj <- readRDS(opt$seurat_rds)
DefaultAssay(seurat_obj) <- "RNA"
seurat_obj <- tryCatch(JoinLayers(seurat_obj, assay = "RNA"), error = function(e) seurat_obj)

if (!"data" %in% Layers(seurat_obj, assay = "RNA")) {
  seurat_obj <- NormalizeData(seurat_obj, verbose = FALSE)
}
if (length(VariableFeatures(seurat_obj)) == 0) {
  seurat_obj <- FindVariableFeatures(seurat_obj, verbose = FALSE)
}

seurat_obj$celltype_short <- shorten_label(as.character(seurat_obj$final_annotation))

available_reductions <- names(seurat_obj@reductions)
umap_reduction <- if ("umap.harmony" %in% available_reductions) {
  "umap.harmony"
} else if ("umap.cca" %in% available_reductions) {
  "umap.cca"
} else {
  grep("umap", available_reductions, value = TRUE)[1]
}

embed_reduction <- if ("harmony" %in% available_reductions) {
  "harmony"
} else if ("integrated.cca" %in% available_reductions) {
  "integrated.cca"
} else {
  "pca"
}

if (!is.null(opt$target_celltypes) && opt$target_celltypes == "auto") {
  celltype_counts <- table(seurat_obj$final_annotation)
  target_types <- names(sort(celltype_counts, decreasing = TRUE))[1:min(2, length(celltype_counts))]
} else {
  target_types <- trimws(unlist(strsplit(opt$target_celltypes, ",")))
}
valid_targets <- intersect(target_types, unique(as.character(seurat_obj$final_annotation)))
cat("Valid Target Cell Types for hdWGCNA:\n")
print(valid_targets)

all_conditions <- unique(as.character(seurat_obj$condition))
ref_cond <- opt$reference_condition
query_conds <- setdiff(all_conditions, ref_cond)
comparisons <- lapply(query_conds, function(q) c(q, ref_cond))

hdwgcna_summary_list <- list()

for (ct in valid_targets) {
  short <- shorten_label(ct)
  wgcna_name <- paste0(short, "_WGCNA")
  plot_dir   <- file.path(plots_root_dir, short)
  res_dir    <- file.path(res_root_dir, short)
  dir.create(plot_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(res_dir,  recursive = TRUE, showWarnings = FALSE)
  
  cat(sprintf("\n=== Processing hdWGCNA for: %s ===\n", ct))
  cells_ct <- colnames(seurat_obj)[as.character(seurat_obj$final_annotation) == ct]
  
  # Network gene selection (genes detected in >= 5% of target cells)
  data_mat <- LayerData(seurat_obj, assay = "RNA", layer = "data")
  frac <- Matrix::rowMeans(data_mat[, cells_ct, drop = FALSE] > 0)
  net_genes <- names(frac)[frac >= 0.05]
  
  seurat_obj <- tryCatch({
    SetupForWGCNA(seurat_obj, gene_select = "custom", features = net_genes, wgcna_name = wgcna_name)
  }, error = function(e) {
    SetupForWGCNA(seurat_obj, gene_select = "fraction", fraction = 0.05, wgcna_name = wgcna_name)
  })
  
  seurat_obj <- SetActiveWGCNA(seurat_obj, wgcna_name)
  
  # Construct Metacells
  cat("  Constructing metacells...\n")
  seurat_obj <- MetacellsByGroups(
    seurat_obj   = seurat_obj,
    group.by     = c("celltype_short", "sample_id"),
    ident.group  = "celltype_short",
    reduction    = embed_reduction,
    k            = as.integer(opt$hdwgcna_k_metacell),
    max_shared   = 10,
    min_cells    = as.integer(opt$hdwgcna_min_cells),
    target_metacells = as.integer(opt$hdwgcna_target_metacells),
    wgcna_name   = wgcna_name
  )
  seurat_obj <- NormalizeMetacells(seurat_obj, wgcna_name = wgcna_name)
  
  # Set Expression & Test Soft Power
  cat("  Testing soft powers...\n")
  seurat_obj <- SetDatExpr(seurat_obj, group_name = short, group.by = "celltype_short", assay = "RNA", slot = "data", wgcna_name = wgcna_name)
  seurat_obj <- TestSoftPowers(seurat_obj, powers = c(seq(1, 10, by = 1), seq(12, 20, by = 2)), networkType = "signed", wgcna_name = wgcna_name)
  
  pt <- GetPowerTable(seurat_obj, wgcna_name = wgcna_name)
  write.csv(pt, file.path(res_dir, "soft_power_table.csv"), row.names = FALSE)
  
  # Determine selected power (SFT.R.sq >= 0.8 or fallback)
  rsq_hits <- which(pt$SFT.R.sq >= 0.8)
  selected_power <- if (length(rsq_hits) > 0) pt$Power[rsq_hits[1]] else pt$Power[which.max(pt$SFT.R.sq)]
  if (is.na(selected_power) || selected_power < 3) selected_power <- 6
  cat(sprintf("  Selected soft power: %d\n", selected_power))
  
  # Construct Co-expression Network
  cat("  Constructing co-expression network...\n")
  seurat_obj <- ConstructNetwork(
    seurat_obj,
    soft_power       = selected_power,
    tom_name         = short,
    minModuleSize    = as.integer(opt$hdwgcna_min_module_size),
    mergeCutHeight   = as.numeric(opt$hdwgcna_merge_cut_height),
    wgcna_name       = wgcna_name,
    overwrite_tom    = TRUE
  )
  
  # Module Eigengenes
  cat("  Computing module eigengenes...\n")
  seurat_obj <- ScaleData(seurat_obj, features = VariableFeatures(seurat_obj), verbose = FALSE)
  seurat_obj <- ModuleEigengenes(seurat_obj, group.by.vars = "sample_id", wgcna_name = wgcna_name)
  seurat_obj <- ModuleConnectivity(seurat_obj, group.by = "celltype_short", group_name = short, wgcna_name = wgcna_name)
  
  modules_tbl <- GetModules(seurat_obj, wgcna_name = wgcna_name)
  write.csv(modules_tbl, file.path(res_dir, "modules.csv"), row.names = FALSE)
  
  hub_df <- GetHubGenes(seurat_obj, n_hubs = 10, wgcna_name = wgcna_name)
  write.csv(hub_df, file.path(res_dir, "hub_genes.csv"), row.names = FALSE)
  
  # Differential Module Eigengene (DME) testing
  cat("  Running DME contrasts...\n")
  for (cmp in comparisons) {
    cells_g1 <- colnames(seurat_obj)[as.character(seurat_obj$final_annotation) == ct & seurat_obj$condition == cmp[1]]
    cells_g2 <- colnames(seurat_obj)[as.character(seurat_obj$final_annotation) == ct & seurat_obj$condition == cmp[2]]
    
    if (length(cells_g1) >= 10 && length(cells_g2) >= 10) {
      tryCatch({
        dmes <- FindDMEs(seurat_obj, barcodes1 = cells_g1, barcodes2 = cells_g2, test.use = "wilcox", wgcna_name = wgcna_name)
        dmes$module <- rownames(dmes)
        dmes$comparison <- paste(cmp[1], "vs", cmp[2])
        write.csv(dmes, file.path(res_dir, paste0("DME_", sanitize_filename(cmp[1]), "_vs_", sanitize_filename(cmp[2]), ".csv")), row.names = FALSE)
      }, error = function(e) cat("  [DME contrast note]", conditionMessage(e), "\n"))
    }
  }
  
  hdwgcna_summary_list[[short]] <- data.frame(
    cell_type   = ct,
    soft_power  = selected_power,
    n_genes     = nrow(modules_tbl),
    n_modules   = length(unique(modules_tbl$module))
  )
}

if (length(hdwgcna_summary_list) > 0) {
  hdwgcna_sum <- do.call(rbind, hdwgcna_summary_list)
  write.csv(hdwgcna_sum, file.path(res_root_dir, "hdwgcna_summary.csv"), row.names = FALSE)
}

saveRDS(seurat_obj, file.path(annot_dir, "integrated_annotated_seurat_hdwgcna.rds"))

cat("\n=================================================================\n")
cat(" Part 12 (hdWGCNA) complete!\n")
cat(" Object RDS: ", file.path(annot_dir, "integrated_annotated_seurat_hdwgcna.rds"), "\n")
cat(" Results:    ", res_root_dir, "\n")
cat("=================================================================\n")
