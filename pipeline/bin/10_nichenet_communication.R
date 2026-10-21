#!/usr/bin/env Rscript
################################################################################
# Script: 10_nichenet_communication.R (Part 10)
# Description: NicheNet intercellular signaling & mechanistic target gene
#              prediction: active upstream ligands, target expression regulation,
#              and ligand-target regulatory heatmaps / circos plots.
################################################################################

suppressPackageStartupMessages({
    if (!requireNamespace("nichenetr", quietly = TRUE)) {
    warning("nichenetr not installed. Skipping this module.")
        dir.create("results/nichenet", recursive=TRUE, showWarnings=FALSE)
    dir.create("plots/nichenet", recursive=TRUE, showWarnings=FALSE)

    quit(save = "no", status = 0)
  }
  library(nichenetr)
  library(Seurat)
  library(SeuratObject)
  library(tidyverse)
  library(ComplexHeatmap)
  library(circlize)
  library(igraph)
  library(ggraph)
  library(patchwork)
  library(pheatmap)
})

sanitize_filename <- function(x) gsub("[^A-Za-z0-9_.-]", "_", x)

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    seurat_rds            = "results/differential_expression/annotations/integrated_annotated_seurat_final_scored.rds",
    models_dir            = "models",
    outdir                = "results/nichenet",
    reference_condition   = "CTRL",
    seed                  = 42,
    nichenet_receiver     = "auto",
    nichenet_min_expr_pct = 0.05,
    nichenet_top_ligands  = 20,
    nichenet_cutoff       = 0.25,
    organism              = "human",
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
cat(" Step 10 / Part 10: NicheNet Mechanistic Intercellular Signaling\n")
cat(" Input RDS:         ", opt$seurat_rds, "\n")
cat(" Models Dir:        ", opt$models_dir, "\n")
cat(" Output Dir:        ", opt$outdir, "\n")
cat(" Reference Group:   ", opt$reference_condition, "\n")
cat("=================================================================\n\n")

res_dir   <- file.path(opt$outdir, "results/nichenet")
plots_dir <- file.path(opt$outdir, "plots/nichenet")
dir.create(res_dir,   recursive = TRUE, showWarnings = FALSE)
dir.create(plots_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(opt$models_dir, recursive = TRUE, showWarnings = FALSE)

# 1. Download / Load Prior Models
download_if_missing <- function(url, destfile) {
  if (!file.exists(destfile)) {
    options(timeout = 1800)
    cat("Downloading prior model:", basename(destfile), "...\n")
    tryCatch({
      download.file(url = url, destfile = destfile, mode = "wb", quiet = TRUE)
    }, error = function(e) {
      cat("  Warning: could not download", basename(destfile), ":", conditionMessage(e), "\n")
    })
  }
}

org <- tolower(opt$organism)
lr_net_file     <- file.path(opt$models_dir, paste0("lr_network_", org, ".rds"))
lig_target_file <- file.path(opt$models_dir, paste0("ligand_target_matrix_", org, ".rds"))
weighted_file   <- file.path(opt$models_dir, paste0("weighted_networks_", org, ".rds"))

if (org == "mouse") {
  download_if_missing("https://zenodo.org/record/7074291/files/lr_network_mouse_21122021.rds", lr_net_file)
  download_if_missing("https://zenodo.org/record/7074291/files/ligand_target_matrix_mouse.rds", lig_target_file)
  download_if_missing("https://zenodo.org/record/7074291/files/weighted_networks_mouse.rds", weighted_file)
} else {
  download_if_missing("https://zenodo.org/record/7074291/files/lr_network_human_21122021.rds", lr_net_file)
  download_if_missing("https://zenodo.org/record/7074291/files/ligand_target_matrix_nsga2r_final.rds", lig_target_file)
  download_if_missing("https://zenodo.org/record/7074291/files/weighted_networks_nsga2r_final.rds", weighted_file)
}

if (!file.exists(lr_net_file) || !file.exists(lig_target_file) || !file.exists(weighted_file)) {
  cat("\n[NOTE] NicheNet model files not found in", opt$models_dir, "and could not be downloaded.\n")
  cat("Writing status records and completing Stage 10 cleanly.\n")
  writeLines("NicheNet skipped: model files missing or offline.", con = file.path(res_dir, "nichenet_status.txt"))
  p_skip <- ggplot() + 
    annotate("text", x = 0.5, y = 0.5, label = "NicheNet skipped (model files not available).\nPlease download models to models_dir.", size = 5) +
    theme_void()
  ggsave(file.path(plots_dir, "00_nichenet_skipped.png"), p_skip, width = 8, height = 5)
      dir.create("results/nichenet", recursive=TRUE, showWarnings=FALSE)
    dir.create("plots/nichenet", recursive=TRUE, showWarnings=FALSE)

    quit(save = "no", status = 0)
}

cat("Loading NicheNet prior models...\n")
lr_network           <- readRDS(lr_net_file) %>% distinct(from, to)
ligand_target_matrix <- readRDS(lig_target_file)
weighted_networks    <- readRDS(weighted_file)

# 2. Load Seurat Object & Filter
seurat_obj <- readRDS(opt$seurat_rds)
DefaultAssay(seurat_obj) <- "RNA"
if (!is.null(opt$trajectory_exclude_pattern) && opt$trajectory_exclude_pattern != "") {
  all_types <- unique(as.character(seurat_obj$final_annotation))
  exclude_types <- all_types[grepl(opt$trajectory_exclude_pattern, all_types, ignore.case = TRUE)]
  if (length(exclude_types) > 0) {
    seurat_obj <- subset(seurat_obj, subset = final_annotation %in% setdiff(all_types, exclude_types))
  }
}

crosstab <- table(seurat_obj$final_annotation, seurat_obj$condition)
min_per_type <- apply(crosstab, 1, min)
common_cell_types <- names(min_per_type)[min_per_type >= 10]
seurat_obj <- subset(seurat_obj, subset = final_annotation %in% common_cell_types)

# Receiver cell type selection
receiver_target <- if (!is.null(opt$nichenet_receiver) && opt$nichenet_receiver != "auto" && opt$nichenet_receiver != "") {
  opt$nichenet_receiver
} else {
  "Satellite"
}
receiver <- grep(receiver_target, common_cell_types, value = TRUE)[1]
if (is.na(receiver)) receiver <- common_cell_types[1]
senders  <- setdiff(common_cell_types, receiver)

cat(sprintf("Receiver Cell Type (pattern: %s): %s\n", receiver_target, receiver))
cat("Sender Cell Types:\n")
print(senders)

# 3. NicheNet Comparisons for Query Conditions vs Reference
all_conditions <- unique(as.character(seurat_obj$condition))
ref_cond <- opt$reference_condition
query_conds <- setdiff(all_conditions, ref_cond)

for (query in query_conds) {
  cat(sprintf("\n--- Running NicheNet: %s vs %s ---\n", query, ref_cond))
  cmp_label <- paste0(tolower(sanitize_filename(query)), "_vs_", tolower(sanitize_filename(ref_cond)))
  out_sub_dir <- file.path(plots_dir, cmp_label)
  dir.create(out_sub_dir, recursive = TRUE, showWarnings = FALSE)
  
  min_expr_pct <- as.numeric(opt$nichenet_min_expr_pct)
  if (is.na(min_expr_pct) || min_expr_pct <= 0) min_expr_pct <- 0.05
  
  top_n_ligands <- as.integer(opt$nichenet_top_ligands)
  if (is.na(top_n_ligands) || top_n_ligands <= 0) top_n_ligands <- 20
  
  cutoff_val <- as.numeric(opt$nichenet_cutoff)
  if (is.na(cutoff_val) || cutoff_val <= 0) cutoff_val <- 0.25

  # Expressed genes in receiver
  rec_cells <- colnames(seurat_obj)[seurat_obj$final_annotation == receiver & seurat_obj$condition %in% c(query, ref_cond)]
  rec_mat <- LayerData(seurat_obj, assay = "RNA", layer = "counts")[, rec_cells, drop = FALSE]
  expressed_genes_receiver <- rownames(rec_mat)[rowMeans(rec_mat > 0) >= min_expr_pct]
  
  # Expressed genes in senders
  expressed_genes_sender <- list()
  for (s in senders) {
    s_cells <- colnames(seurat_obj)[seurat_obj$final_annotation == s & seurat_obj$condition == query]
    if (length(s_cells) >= 10) {
      s_mat <- LayerData(seurat_obj, assay = "RNA", layer = "counts")[, s_cells, drop = FALSE]
      expressed_genes_sender[[s]] <- rownames(s_mat)[rowMeans(s_mat > 0) >= min_expr_pct]
    }
  }
  expressed_genes_sender_all <- unique(unlist(expressed_genes_sender))
  
  # DE genes in receiver (genes of interest)
  rec_obj <- subset(seurat_obj, subset = final_annotation == receiver & condition %in% c(query, ref_cond))
  Idents(rec_obj) <- "condition"
  
  de_receiver <- FindMarkers(rec_obj, ident.1 = query, ident.2 = ref_cond,
                             test.use = "wilcox", logfc.threshold = 0.25, min.pct = 0.1, verbose = FALSE)
  genes_of_interest <- rownames(de_receiver)[de_receiver$p_val_adj < 0.05 & de_receiver$avg_log2FC > 0.25]
  genes_of_interest <- intersect(genes_of_interest, rownames(ligand_target_matrix))
  
  cat(sprintf("  [%s] Target DE genes in receiver: %d\n", cmp_label, length(genes_of_interest)))
  if (length(genes_of_interest) < 5) {
    cat("  Fewer than 5 DE target genes found — relaxing p_val threshold to unadjusted p < 0.05\n")
    genes_of_interest <- rownames(de_receiver)[de_receiver$p_val < 0.05 & de_receiver$avg_log2FC > 0.25]
    genes_of_interest <- intersect(genes_of_interest, rownames(ligand_target_matrix))
  }
  
  if (length(genes_of_interest) == 0) {
    cat("  No target genes found for NicheNet in this contrast. Skipping.\n")
    next
  }
  
  # Potential ligands
  ligands <- lr_network %>% pull(from) %>% unique()
  receptors <- lr_network %>% pull(to) %>% unique()
  expressed_ligands <- intersect(ligands, expressed_genes_sender_all)
  expressed_receptors <- intersect(receptors, expressed_genes_receiver)
  
  potential_ligands <- lr_network %>%
    filter(from %in% expressed_ligands & to %in% expressed_receptors) %>%
    pull(from) %>% unique()
  
  cat(sprintf("  [%s] Potential expressed ligands: %d\n", cmp_label, length(potential_ligands)))
  if (length(potential_ligands) == 0) next
  
  # Predict Ligand Activities
  background_expressed_genes <- intersect(expressed_genes_receiver, rownames(ligand_target_matrix))
  ligand_activities <- predict_ligand_activities(
    geneset = genes_of_interest,
    background_expressed_genes = background_expressed_genes,
    ligand_target_matrix = ligand_target_matrix,
    potential_ligands = potential_ligands
  ) %>% arrange(desc(pearson))
  
  write.csv(ligand_activities, file.path(res_dir, paste0("ligand_activities_", cmp_label, ".csv")), row.names = FALSE)
  
  # Top ligands barplot
  top_ligands <- head(ligand_activities$test_ligand, top_n_ligands)
  p_bar <- ligand_activities %>%
    filter(test_ligand %in% top_ligands) %>%
    ggplot(aes(x = reorder(test_ligand, pearson), y = pearson)) +
    geom_bar(stat = "identity", fill = "#E76F51") + coord_flip() +
    labs(title = paste("Top Prioritized Ligands (", query, "vs", ref_cond, ")"),
         x = "Ligand", y = "Pearson Correlation Potential")
  ggsave(file.path(out_sub_dir, "01_ligand_activity_barplot.pdf"), p_bar, width = 8, height = 7)
  
  # Target matrix heatmap
  tryCatch({
    active_ligand_target_links_df <- head(top_ligands, min(12, length(top_ligands))) %>%
      lapply(get_weighted_ligand_target_links, geneset = genes_of_interest,
             ligand_target_matrix = ligand_target_matrix, n = 250) %>%
      bind_rows() %>% drop_na()
    
    if (nrow(active_ligand_target_links_df) > 0) {
      active_ligand_target_matrix <- prepare_ligand_target_visualization(
        ligand_target_df     = active_ligand_target_links_df,
        ligand_target_matrix = ligand_target_matrix,
        cutoff               = cutoff_val
      )
      
      if (!is.null(active_ligand_target_matrix) && nrow(active_ligand_target_matrix) > 0) {
        p_heat <- make_heatmap_ggplot(active_ligand_target_matrix, y_name = "Target Gene", x_name = "Prioritized Ligand",
                                      color = "purple", legend_title = "Regulatory Potential")
        ggsave(file.path(out_sub_dir, "02_ligand_target_heatmap.pdf"), p_heat, width = 10, height = 8)
      }
    }
  }, error = function(e) {
    cat("  [NicheNet heatmap note]", conditionMessage(e), "\n")
  })
}

cat("\n=================================================================\n")
cat(" Part 10 (NicheNet) complete!\n")
cat(" Output tables: ", res_dir, "\n")
cat(" Output plots:  ", plots_dir, "\n")
cat("=================================================================\n")
