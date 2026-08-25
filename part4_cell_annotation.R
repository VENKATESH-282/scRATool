# =============================================================================
# Part 4: Cell Type Identification (Annotation)
# Tutorial: NGS101 – scRNA-seq Complete Beginner's Guide
# Input    : Integrated + clustered Seurat object from Part 3
# Output   : Annotated Seurat object with consensus labels
# Usage    : Rscript part4_cell_annotation.R
# =============================================================================
# ANNOTATION PIPELINE OVERVIEW
# ----------------------------
# Step 1 : Load integrated data and libraries
# Step 2 : Manual Annotation (The Gold Standard)
#          - Canonical marker visualization (Violins, UMAPs, DotPlots)
#          - Data-driven marker discovery (FindAllMarkers)
#          - Manual cluster assignment
# Step 3 : Automated Annotation 1 – SingleR (Reference-based)
#          - Compare HPCA, Monaco, and DICE references
# Step 4 : Automated Annotation 2 – scType (Marker-based scoring)
# Step 5 : Automated Annotation 3 – scCATCH (Tissue-specific DB)
# Step 6 : Method Comparison & Consensus Building
#          - Confusion matrices & Sankey diagrams
#          - Consensus label assignment
# Step 7 : Save annotated object
# =============================================================================

# Install packages (first time only):
# BiocManager::install(c("SingleR", "celldex", "SingleCellExperiment"))
# install.packages(c("scCATCH", "HGNChelper", "openxlsx", "ggalluvial"))

library(Seurat)
library(ggplot2)
library(dplyr)
library(patchwork)
library(SingleR)
library(celldex)
library(SingleCellExperiment)
library(HGNChelper)
library(ggalluvial)

# Optional libraries
has_scCATCH <- requireNamespace("scCATCH", quietly = TRUE)
if (has_scCATCH) library(scCATCH)

# ------ Configuration -------------------------------------------------------
source("config.R")
setup_cluster_parallel()

INTEGRATED_RDS <- file.path(DIR_INTEGRATION, "GSE174609_integrated_clustered.rds")
OUTPUT_DIR     <- DIR_ANNOTATION
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "plots/manual"),    recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "plots/automated"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "plots/comparison"),recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUTPUT_DIR, "tables"),          recursive = TRUE, showWarnings = FALSE)

setwd(OUTPUT_DIR)
set.seed(42)

# =============================================================================
# STEP 1: Load data and check clusters
# =============================================================================
if (!file.exists(INTEGRATED_RDS)) stop("Integrated RDS not found: ", INTEGRATED_RDS)
seurat_obj <- readRDS(INTEGRATED_RDS)

# Detect best UMAP reduction
available_reductions <- names(seurat_obj@reductions)
umap_red <- "umap" # default
if ("umap.harmony" %in% available_reductions) umap_red <- "umap.harmony" else
if ("umap.cca" %in% available_reductions)     umap_red <- "umap.cca"     else
if ("umap.rpca" %in% available_reductions)    umap_red <- "umap.rpca"

cat("Using reduction:", umap_red, "\n")

# Default resolution from Part 3 (0.5)
Idents(seurat_obj) <- "RNA_snn_res.0.5"

# =============================================================================
# STEP 2: Manual Annotation – Visualize Canonical Markers
# =============================================================================
# Definitive PBMC marker panel
canonical_markers <- list(
  "T cells"          = c("CD3D", "CD3E", "CD3G"),
  "CD4+ T cells"     = c("CD4", "IL7R"),
  "CD8+ T cells"     = c("CD8A", "CD8B"),
  "B cells"          = c("CD79A", "MS4A1", "CD19"),
  "NK cells"         = c("NKG7", "GNLY", "NCAM1"),
  "Monocytes"        = c("CD14", "LYZ", "S100A8"),
  "CD16+ Monocytes"  = c("FCGR3A", "MS4A7"),
  "Dendritic cells"  = c("FCER1A", "CST3"),
  "pDCs"             = c("IL3RA", "GZMB", "SERPINF1"),
  "Platelets"        = c("PPBP", "PF4")
)

# 2a. DotPlot for all markers (best overview)
p_dot <- DotPlot(seurat_obj, features = canonical_markers) +
         coord_flip() + labs(title = "Canonical Markers by Cluster")
ggsave("plots/manual/01_canonical_dotplot.png", p_dot, width = 12, height = 8, dpi = 300)

# 2b. Discovery: Find cluster-specific markers
# This identifies genes that are uniquely high in each cluster
cat("Finding all markers...\n")
all_markers <- FindAllMarkers(seurat_obj, only.pos = TRUE, min.pct = 0.25,
                              logfc.threshold = 0.25, verbose = FALSE)

# Filter out ribosomal/mitochondrial clutter
top5 <- all_markers %>%
  filter(!grepl("^RP[SL]|^MT-", gene)) %>%
  group_by(cluster) %>%
  top_n(n = 5, wt = avg_log2FC)

write.csv(all_markers, "tables/cluster_markers_all.csv", row.names = FALSE)

# 2c. Manual Assignment (Example mapping - EDIT based on plots!)
# Note: Use your visual inspection of p_dot and top5 to refine this.
cluster_labels <- c(
  "0"  = "CD4+ Naive T",
  "1"  = "CD4+ Memory T",
  "2"  = "CD14+ Monocytes",
  "3"  = "B cells",
  "4"  = "CD8+ T cells",
  "5"  = "NK cells",
  "6"  = "CD16+ Monocytes",
  "7"  = "B cells",
  "8"  = "DC",
  "9"  = "pDC",
  "10" = "Platelets"
)
# Ensure all clusters are in mapping
missing_clusters <- setdiff(levels(Idents(seurat_obj)), names(cluster_labels))
if(length(missing_clusters) > 0) {
  for(c in missing_clusters) cluster_labels[c] <- paste0("Cluster_", c)
}

# Use unname() to prevent Seurat from trying to match cluster IDs ("0", "1") to cell barcodes
seurat_obj$manual_annotation <- unname(cluster_labels[as.character(Idents(seurat_obj))])

# =============================================================================
# STEP 3: Automated Annotation 1 – SingleR
# =============================================================================
cat("Running SingleR (Monaco Reference)...\n")
sce <- as.SingleCellExperiment(seurat_obj)
monaco_ref <- celldex::MonacoImmuneData()

# SingleR works on SCE objects, correlates query cells with reference profiles
singler_results <- SingleR(test = sce, ref = monaco_ref,
                           labels = monaco_ref$label.main)

seurat_obj$singler_annotation <- unname(singler_results$labels)

p_singler <- DimPlot(seurat_obj, group.by = "singler_annotation", reduction = umap_red,
                     label = TRUE, repel = TRUE) + labs(title = "SingleR (Monaco)")
ggsave("plots/automated/02_singler_umap.png", p_singler, width = 10, height = 8, dpi = 300)

# =============================================================================
# STEP 4: Automated Annotation 2 – scType
# =============================================================================
# scType scores each cluster based on a marker database (no reference data needed)
cat("Running scType...\n")
source("https://raw.githubusercontent.com/IanevskiAleksandr/sc-type/master/R/gene_sets_prepare.R")
source("https://raw.githubusercontent.com/IanevskiAleksandr/sc-type/master/R/sctype_score_.R")

# Prepare gene sets for "Immune system"
db_url <- "https://raw.githubusercontent.com/IanevskiAleksandr/sc-type/master/ScTypeDB_full.xlsx"
gs_list <- gene_sets_prepare(db_url, "Immune system")

# Score clusters
scaled_data <- as.matrix(LayerData(seurat_obj, layer = "scale.data"))
es_max <- sctype_score(scRNAseqData = scaled_data, scaled = TRUE,
                       gs = gs_list$gs_positive, gs2 = gs_list$gs_negative)

# Assign top scoring cell type per cluster
cL_results <- do.call("rbind", lapply(unique(Idents(seurat_obj)), function(cl) {
  total_score <- rowSums(es_max[, Idents(seurat_obj) == cl])
  top_type <- names(sort(total_score, decreasing = TRUE))[1]
  data.frame(cluster = cl, type = top_type)
}))

seurat_obj$sctype_annotation <- unname(cL_results$type[match(Idents(seurat_obj), cL_results$cluster)])

# =============================================================================
# STEP 5: Automated Annotation 3 – scCATCH
# =============================================================================
# scCATCH matches cluster markers to a tissue-specific database (Blood)
cat("Running scCATCH...\n")
tryCatch({
  obj_sccatch <- createscCATCH(data = LayerData(seurat_obj, layer = "data"),
                               cluster = as.character(Idents(seurat_obj)))
  obj_sccatch <- findmarkergene(obj_sccatch, species = "Human", marker = cellmatch,
                                tissue = "Blood")
  obj_sccatch <- findcelltype(obj_sccatch)
  
  seurat_obj$sccatch_annotation <- obj_sccatch@celltype$cell_type[match(Idents(seurat_obj), obj_sccatch@celltype$cluster)]
}, error = function(e) {
  cat("scCATCH failed:", conditionMessage(e), "\n")
  seurat_obj$sccatch_annotation <- "Unknown"
})

# =============================================================================
# STEP 6: Comparison & Consensus
# =============================================================================
# Visualize all methods together
p_manual  <- DimPlot(seurat_obj, group.by = "manual_annotation", reduction = umap_red, label = TRUE, repel = TRUE, raster = FALSE) + labs(title = "Manual")
p_singler <- DimPlot(seurat_obj, group.by = "singler_annotation", reduction = umap_red, label = TRUE, repel = TRUE, raster = FALSE) + labs(title = "SingleR")
p_sctype  <- DimPlot(seurat_obj, group.by = "sctype_annotation", reduction = umap_red, label = TRUE, repel = TRUE, raster = FALSE) + labs(title = "scType")
p_sccatch <- DimPlot(seurat_obj, group.by = "sccatch_annotation", reduction = umap_red, label = TRUE, repel = TRUE, raster = FALSE) + labs(title = "scCATCH")

ggsave("plots/comparison/03_annotation_comparison.png", 
       p_manual + p_singler + p_sctype + p_sccatch, 
       width = 24, height = 18, dpi = 300)

# Sankey Diagram: visualize flow from clusters to SingleR labels
# (Helps identify which clusters were merged/split by automated tools)
sankey_data <- seurat_obj@meta.data %>%
  group_by(seurat_clusters, singler_annotation) %>%
  summarise(value = n(), .groups = "drop")

p_sankey <- ggplot(sankey_data, aes(axis1 = seurat_clusters, axis2 = singler_annotation, y = value)) +
  geom_alluvium(aes(fill = singler_annotation)) +
  geom_stratum() + geom_text(stat = "stratum", aes(label = after_stat(stratum))) +
  theme_void() + labs(title = "Cluster to SingleR Mapping")
ggsave("plots/comparison/04_sankey_mapping.png", p_sankey, width = 10, height = 8)

# Define FINAL consensus labels (edit based on Step 6 comparison)
# Usually, prioritize Manual > SingleR > others IF manual markers are clear.
seurat_obj$cell_type <- seurat_obj$manual_annotation
Idents(seurat_obj) <- "cell_type"

# =============================================================================
# STEP 7: Save
# =============================================================================
saveRDS(seurat_obj, "GSE174609_annotated.rds")
write.csv(seurat_obj@meta.data, "tables/final_metadata.csv")

cat("\n=== Part 4 Complete ===\n")
cat("Final cell types:", paste(unique(seurat_obj$cell_type), collapse = ", "), "\n")
cat("Output saved: GSE174609_annotated.rds\n")
# Next step: Part 5 – Differential Expression and Pathway Analysis
