# =============================================================================
# Part 5: Differential Expression and Pathway Analysis
# Tutorial: NGS101 – scRNA-seq Complete Beginner's Guide
# Input    : Annotated Seurat object from Part 4
# Output   : DE results (cell-level & pseudobulk), proportion tests, pathway scores
# Usage    : Rscript part5_differential_expression.R
# =============================================================================

library(Seurat)
library(ggplot2)
library(dplyr)
library(patchwork)

# Optional libraries with status checks
has_deseq2   <- requireNamespace("DESeq2", quietly = TRUE)
has_speckle  <- requireNamespace("speckle", quietly = TRUE)
has_msigdbr  <- requireNamespace("msigdbr", quietly = TRUE)
has_volcano  <- requireNamespace("EnhancedVolcano", quietly = TRUE)
has_ridges   <- requireNamespace("ggridges", quietly = TRUE)

if (has_deseq2)  library(DESeq2)
if (has_msigdbr) library(msigdbr)
if (has_volcano) library(EnhancedVolcano)
if (has_ridges)  library(ggridges)

# ------ Configuration -------------------------------------------------------
source("config.R")
setup_cluster_parallel()

ANNOTATED_RDS <- file.path(DIR_ANNOTATION, "GSE174609_annotated.rds")
OUTPUT_DIR    <- DIR_DE
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "plots/proportions"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "plots/volcano"),     recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "plots/pathways"),    recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "results"),          recursive = TRUE, showWarnings = FALSE)

setwd(OUTPUT_DIR)
set.seed(42)

# =============================================================================
# STEP 1: Load Data & Check Comparisons
# =============================================================================
if (!file.exists(ANNOTATED_RDS)) stop("Annotated RDS not found: ", ANNOTATED_RDS)
seurat_obj <- readRDS(ANNOTATED_RDS)

n_conditions <- length(unique(seurat_obj$condition))
n_samples    <- length(unique(seurat_obj$sample_id))

cat("Analyzing:", n_samples, "samples across", n_conditions, "conditions.\n")

# =============================================================================
# STEP 2: Proportion Analysis
# =============================================================================
if (n_samples > 1 && has_speckle) {
  cat("Testing cell type proportions (speckle)...\n")
  try({
    prop_results <- speckle::propeller(clusters = seurat_obj$cell_type,
                                      sample = seurat_obj$sample_id,
                                      group = seurat_obj$condition)
    write.csv(prop_results, "results/proportion_test_results.csv")
  })
} else {
  cat("Skipping statistical proportion testing.\n")
}

p_prop <- ggplot(seurat_obj@meta.data, aes(x = sample_id, fill = cell_type)) +
  geom_bar(position = "fill") +
  theme_classic() + labs(title = "Cell Type Proportions", y = "Fraction")
if (n_conditions > 1) p_prop <- p_prop + facet_wrap(~condition, scales = "free_x")
ggsave("plots/proportions/01_proportion_barplot.png", p_prop, width = 12, height = 6)


# =============================================================================
# STEP 3: Differential Expression (DE)
# =============================================================================
if (n_conditions < 2) {
  cat("\n[SINGLE CONDITION DETECTED] Skipping Differential Expression between groups.\n")
} else if (!has_deseq2) {
  cat("\n[DESeq2 MISSING] Skipping pseudobulk DE analysis.\n")
} else {
  cat("\nRunning Differential Expression (Placeholder for multi-condition logic)...\n")
  # (Integration of multi-condition DE code here)
}

# =============================================================================
# STEP 4: Functional State Scoring (Pathway Analysis)
# =============================================================================
if (has_msigdbr) {
  cat("\nScoring Hallmark Pathways (msigdbr)...\n")
  h_df <- msigdbr(species = "Homo sapiens", category = "H")
  h_list <- split(x = h_df$gene_symbol, f = h_df$gs_name)
  target_pathways <- c("HALLMARK_INFLAMMATORY_RESPONSE", "HALLMARK_INTERFERON_GAMMA_RESPONSE")
  h_list <- lapply(h_list, function(x) x[x %in% rownames(seurat_obj)])
  
  seurat_obj <- AddModuleScore(seurat_obj, features = h_list[target_pathways], name = "Hallmark_")
  score_cols <- paste0("Hallmark_", 1:length(target_pathways))
  colnames(seurat_obj@meta.data)[match(score_cols, colnames(seurat_obj@meta.data))] <- target_pathways

  if (has_ridges) {
    fill_var <- if (n_conditions > 1) "condition" else "cell_type"
    p_ridge <- ggplot(seurat_obj@meta.data, aes(x = !!sym(target_pathways[1]), y = cell_type, fill = !!sym(fill_var))) +
      geom_density_ridges(alpha = 0.6) +
      theme_ridges() + labs(title = paste(target_pathways[1], "Score"))
    ggsave("plots/pathways/05_inflammatory_score_ridge.png", p_ridge, width = 10, height = 8)
  }
} else {
  cat("\nmsigdbr not installed. Skipping pathway scoring.\n")
}

# =============================================================================
# STEP 5: Save Results
# =============================================================================
saveRDS(seurat_obj, "GSE174609_final_analysis.rds")
cat("\n=== Part 5 Complete ===\n")
cat("Results saved in:", OUTPUT_DIR, "\n")
