#!/usr/bin/env Rscript
################################################################################
# Script: 09_cellchat_communication.R (Part 9)
# Description: Intercellular communication analysis with CellChat,
#              per-condition communication networks, merged comparative analyses,
#              information flow, and target signaling axis exploration.
################################################################################

suppressPackageStartupMessages({
    if (!requireNamespace("CellChat", quietly = TRUE)) {
    warning("CellChat not installed. Skipping this module.")
        dir.create("results/cellchat", recursive=TRUE, showWarnings=FALSE)
    dir.create("plots/cellchat", recursive=TRUE, showWarnings=FALSE)

    quit(save = "no", status = 0)
  }
  library(CellChat)
  library(Seurat)
  library(SeuratObject)
  library(patchwork)
  library(NMF)
  library(foreach)
  library(ggalluvial)
  library(dplyr)
  library(circlize)
  library(ComplexHeatmap)
})

options(stringsAsFactors = FALSE)
registerDoSEQ()

sanitize_filename <- function(x) gsub("[^A-Za-z0-9_.-]", "_", x)

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    seurat_rds          = "results/differential_expression/annotations/integrated_annotated_seurat_final_scored.rds",
    outdir              = "results/cellchat",
    reference_condition = "CTRL",
    seed                = 42,
    cellchat_prob_type  = "triMean",
    organism            = "human",
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
cat(" Step 9 / Part 9: CellChat Cell-Cell Communication Analysis\n")
cat(" Input RDS:         ", opt$seurat_rds, "\n")
cat(" Output Dir:        ", opt$outdir, "\n")
cat(" Reference Group:   ", opt$reference_condition, "\n")
cat("=================================================================\n\n")

res_dir   <- file.path(opt$outdir, "results/cellchat")
plots_dir <- file.path(opt$outdir, "plots/cellchat")
dir.create(res_dir,   recursive = TRUE, showWarnings = FALSE)
dir.create(plots_dir, recursive = TRUE, showWarnings = FALSE)

# 1. Load Seurat Object & Filter Cell Types
seurat_obj <- readRDS(opt$seurat_rds)
DefaultAssay(seurat_obj) <- "RNA"

# Exclude specific cells if requested
if (!is.null(opt$trajectory_exclude_pattern) && opt$trajectory_exclude_pattern != "") {
  all_types <- unique(as.character(seurat_obj$final_annotation))
  exclude_types <- all_types[grepl(opt$trajectory_exclude_pattern, all_types, ignore.case = TRUE)]
  if (length(exclude_types) > 0) {
    seurat_obj <- subset(seurat_obj, subset = final_annotation %in% setdiff(all_types, exclude_types))
  }
}

min_cells_thresh <- as.integer(opt$cellchat_min_cells)
if (is.na(min_cells_thresh) || min_cells_thresh < 1) min_cells_thresh <- 10

prob_type <- as.character(opt$cellchat_prob_type)
if (is.na(prob_type) || prob_type == "") prob_type <- "triMean"

# Ensure >= min_cells_thresh in EVERY condition
crosstab <- table(seurat_obj$final_annotation, seurat_obj$condition)
min_per_type <- apply(crosstab, 1, min)
common_cell_types <- names(min_per_type)[min_per_type >= min_cells_thresh]

cat(sprintf("Cell types with >=%d cells in every condition:\n", min_cells_thresh))
print(common_cell_types)

seurat_obj <- subset(seurat_obj, subset = final_annotation %in% common_cell_types)
seurat_obj$final_annotation <- factor(as.character(seurat_obj$final_annotation), levels = common_cell_types)
Idents(seurat_obj) <- "final_annotation"

if (tolower(opt$organism) == "mouse") {
  CellChatDB <- CellChatDB.mouse
} else {
  CellChatDB <- CellChatDB.human
}
CellChatDB.use <- CellChatDB

# 2. Build CellChat Object per Condition
conditions <- sort(unique(as.character(seurat_obj$condition)))
cellchat_list <- list()

for (cond in conditions) {
  cat(sprintf("\n--- Building CellChat for Condition: %s ---\n", cond))
  cond_plot_dir <- file.path(plots_dir, tolower(sanitize_filename(cond)))
  dir.create(cond_plot_dir, recursive = TRUE, showWarnings = FALSE)
  
  sub_obj <- subset(seurat_obj, subset = condition == cond)
  data.input <- GetAssayData(sub_obj, assay = "RNA", layer = "data")
  meta <- data.frame(labels = sub_obj$final_annotation, samples = sub_obj$sample_id, row.names = colnames(sub_obj))
  
  cc <- createCellChat(object = data.input, meta = meta, group.by = "labels")
  cc@DB <- CellChatDB.use
  
  cc <- subsetData(cc)
  cc <- identifyOverExpressedGenes(cc)
  cc <- identifyOverExpressedInteractions(cc)
  
  cc <- computeCommunProb(cc, type = prob_type)
  cc <- filterCommunication(cc, min.cells = min_cells_thresh)
  cc <- computeCommunProbPathway(cc)
  cc <- aggregateNet(cc)
  cc <- netAnalysis_computeCentrality(cc, slot.name = "netP")
  
  saveRDS(cc, file.path(res_dir, paste0("cellchat_", sanitize_filename(cond), ".rds")))
  cellchat_list[[cond]] <- cc
}

# 3. Comparative Pairwise Analyses (vs Reference)
ref_cond <- opt$reference_condition
query_conds <- setdiff(conditions, ref_cond)

for (query in query_conds) {
  cat(sprintf("\n--- Comparing: %s vs %s ---\n", query, ref_cond))
  cmp_label <- paste0("comparison_", tolower(sanitize_filename(query)), "_vs_", tolower(sanitize_filename(ref_cond)))
  cmp_dir   <- file.path(plots_dir, cmp_label)
  dir.create(cmp_dir, recursive = TRUE, showWarnings = FALSE)
  
  cc_query <- cellchat_list[[query]]
  cc_ref   <- cellchat_list[[ref_cond]]
  
  object.list <- list(REF = cc_ref, QUERY = cc_query)
  names(object.list) <- c(ref_cond, query)
  cellchat_merged <- mergeCellChat(object.list, add.names = names(object.list))
  
  # Total Interactions & Strength Comparison
  p_num <- compareInteractions(cellchat_merged, show.legend = FALSE, group = c(1, 2), measure = "count")
  p_str <- compareInteractions(cellchat_merged, show.legend = FALSE, group = c(1, 2), measure = "weight")
  ggsave(file.path(cmp_dir, "01_interaction_number_strength_bars.png"), p_num + p_str, width = 8, height = 5, dpi = 300)
  
  # Differential Interaction Network
  tryCatch({
    png(file.path(cmp_dir, "02_diff_interaction_network.png"), width = 9, height = 7, units = "in", res = 300)
    netVisual_diffInteraction(cellchat_merged, weight.scale = TRUE, measure = "count")
    dev.off()
  }, error = function(e) {
    if (dev.cur() > 1) dev.off()
    cat("  [diffInteraction plot note]", conditionMessage(e), "\n")
  })
  
  # Information Flow RankNet
  p_rank <- rankNet(cellchat_merged, mode = "comparison", stacked = TRUE, do.stat = TRUE)
  ggsave(file.path(cmp_dir, "03_pathway_information_flow.png"), p_rank, width = 10, height = 8, dpi = 300)
  
  # Signaling Role Scatter
  p_role1 <- netAnalysis_signalingRole_scatter(object.list[[1]], title = ref_cond)
  p_role2 <- netAnalysis_signalingRole_scatter(object.list[[2]], title = query)
  ggsave(file.path(cmp_dir, "04_signaling_roles_scatter.png"), p_role1 + p_role2, width = 14, height = 6, dpi = 300)
  
  # Targeted Axis Bubble Plot: FAP -> Satellite
  src <- grep("FAP", common_cell_types, value = TRUE)[1]
  tgt <- grep("Satellite", common_cell_types, value = TRUE)[1]
  
  if (!is.na(src) && !is.na(tgt)) {
    tryCatch({
      p_bubble <- netVisual_bubble(cellchat_merged, sources.use = src, targets.use = tgt,
                                   comparison = c(1, 2), angle.x = 45)
      ggsave(file.path(cmp_dir, "05_bubble_fap_to_satellite.png"), p_bubble, width = 10, height = 7, dpi = 300)
    }, error = function(e) cat("  [Bubble plot note]", conditionMessage(e), "\n"))
  }
  
  saveRDS(cellchat_merged, file.path(res_dir, paste0("cellchat_merged_", sanitize_filename(query), "_vs_", sanitize_filename(ref_cond), ".rds")))
}

cat("\n=================================================================\n")
cat(" Part 9 (CellChat) complete!\n")
cat(" Objects saved in: ", res_dir, "\n")
cat(" Plots saved in:   ", plots_dir, "\n")
cat("=================================================================\n")
