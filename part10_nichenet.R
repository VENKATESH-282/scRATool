# =============================================================================
# Part 10: NicheNet Analysis (Mechanistic Communication)
# Tutorial: NGS101 – scRNA-seq Complete Beginner's Guide
# Input    : Annotated Seurat object from Part 4
# Output   : Ligand activity rankings, Ligand-Target heatmaps
# Usage    : Rscript part10_nichenet.R
# =============================================================================

library(nichenetr)
library(Seurat)
library(tidyverse)
library(ComplexHeatmap)
library(patchwork)

# ------ Configuration -------------------------------------------------------
source("config.R")
setup_cluster_parallel()

ANNOTATED_RDS <- file.path(DIR_ANNOTATION, "GSE174609_annotated.rds")
OUTPUT_DIR    <- DIR_NICHENET
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "plots"),   recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "models"),  recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "results"), recursive = TRUE, showWarnings = FALSE)

setwd(OUTPUT_DIR)
set.seed(42)

# =============================================================================
# STEP 1: Download/Load NicheNet Prior Models
# =============================================================================
# These files are large and required for NicheNet prediction.
model_dir <- "models"
lr_network_file        <- file.path(model_dir, "lr_network_human.rds")
ligand_target_file     <- file.path(model_dir, "ligand_target_matrix_human.rds")
weighted_networks_file <- file.path(model_dir, "weighted_networks_human.rds")

download_models <- function() {
  cat("Downloading NicheNet models (one-time setup)...\n")
  options(timeout = 600)
  download.file("https://zenodo.org/record/7074291/files/lr_network_human_21122021.rds", lr_network_file)
  download.file("https://zenodo.org/record/7074291/files/ligand_target_matrix_nsga2r_final.rds", ligand_target_file)
  download.file("https://zenodo.org/record/7074291/files/weighted_networks_nsga2r_final.rds", weighted_networks_file)
}

if (!file.exists(lr_network_file) | !file.exists(ligand_target_file)) {
  tryCatch({
    download_models()
  }, error = function(e) {
    stop("Download failed. Please ensure cluster has internet or manually upload models to: ", model_dir)
  })
}

cat("Loading prior models...\n")
lr_network           <- readRDS(lr_network_file)
ligand_target_matrix <- readRDS(ligand_target_file)
weighted_networks    <- readRDS(weighted_networks_file)
lr_network           <- lr_network %>% distinct(from, to)

# =============================================================================
# STEP 2: Prepare Biological Question
# =============================================================================
# Question: Which ligands from all other cells drive changes in CD4+ T cells?
cat("Preparing biological question (Receiver: CD4+ T cells)...\n")
seurat_obj <- readRDS(ANNOTATED_RDS)
Idents(seurat_obj) <- "cell_type"

receiver <- "CD4+ T cells"
if (!receiver %in% levels(seurat_obj)) {
  # Fallback if names differ slightly
  receiver <- grep("CD4", levels(seurat_obj), value = T)[1]
}

sender_celltypes <- setdiff(levels(seurat_obj), receiver)

# =============================================================================
# STEP 3: Define Gene Set of Interest (DE Genes)
# =============================================================================
cat("Calculating DE genes in receiver (Post vs Healthy)...\n")
seurat_receiver <- subset(seurat_obj, idents = receiver)
Idents(seurat_receiver) <- "condition"

# Detect correct condition names
available_conds <- levels(Idents(seurat_receiver))
cat("Found conditions:", paste(available_conds, collapse=", "), "\n")

# Use "Post_Treatment" or "Post_Patient" or "Post" fallback
ident_oi <- intersect(c("Post_Treatment", "Post_Patient", "Post"), available_conds)[1]
ident_ref <- intersect(c("Healthy", "Baseline", "Pre"), available_conds)[1]

if (is.na(ident_oi) | is.na(ident_ref)) {
  stop("Could not find matching condition names for comparison (Post vs Healthy). Available: ", paste(available_conds, collapse="/"))
}
cat("Comparing:", ident_oi, "vs", ident_ref, "\n")

# Find genes upregulated in conditions of interest
DE_table <- FindMarkers(seurat_receiver, ident.1 = ident_oi, ident.2 = ident_ref, min.pct = 0.10)
geneset_oi <- DE_table %>% 
  filter(p_val_adj <= 0.05 & avg_log2FC >= 0.25) %>% 
  rownames() %>% 
  intersect(rownames(ligand_target_matrix))

background_genes <- get_expressed_genes(receiver, seurat_obj, pct = 0.10) %>% 
                    intersect(rownames(ligand_target_matrix))

# =============================================================================
# STEP 4: Run Ligand Activity Prediction
# =============================================================================
cat("Running NicheNet Ligand Activity Analysis...\n")
expressed_ligands <- intersect(lr_network$from, get_expressed_genes(sender_celltypes, seurat_obj, pct = 0.10))
expressed_receptors <- intersect(lr_network$to, get_expressed_genes(receiver, seurat_obj, pct = 0.10))

potential_ligands <- lr_network %>% 
  filter(from %in% expressed_ligands & to %in% expressed_receptors) %>% 
  pull(from) %>% unique()

ligand_activities <- predict_ligand_activities(
  geneset = geneset_oi, 
  background_expressed_genes = background_genes,
  ligand_target_matrix = ligand_target_matrix, 
  potential_ligands = potential_ligands
)

ligand_activities <- ligand_activities %>% arrange(desc(aupr_corrected)) %>% mutate(rank = row_number())
write.csv(ligand_activities, "results/ligand_activities.csv")

# =============================================================================
# STEP 5: Visualization
# =============================================================================
cat("Saving results...\n")
top_ligands <- ligand_activities %>% top_n(20, aupr_corrected) %>% pull(test_ligand)

p_activity <- ligand_activities %>% 
  filter(test_ligand %in% top_ligands) %>% 
  ggplot(aes(x = reorder(test_ligand, aupr_corrected), y = aupr_corrected)) +
  geom_bar(stat = "identity", fill = "purple") + coord_flip() +
  theme_minimal() + labs(title = "Top Predicted Ligands", x = "Ligand", y = "Activity Score")

ggsave("plots/01_ligand_activity.png", p_activity, width = 8, height = 6)

saveRDS(ligand_activities, "results/nichenet_results.rds")
cat("\n=== Part 10 Complete ===\n")
