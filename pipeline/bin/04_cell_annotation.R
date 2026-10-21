#!/usr/bin/env Rscript
################################################################################
# Script: 04_cell_annotation.R (Part 4)
# Description: Feature Symbol Mapping, Canonical & DUX4 Marker Profiling,
#              Marker Discovery, Automated Annotation (SingleR, scType, scCATCH),
#              and Multi-Method Cross-Comparison.
################################################################################

suppressPackageStartupMessages({
  library(Seurat)
  library(SeuratObject)
  has_singler <- requireNamespace("SingleR", quietly=TRUE)
  has_celldex <- requireNamespace("celldex", quietly=TRUE)
  if(has_singler) library(SingleR)
  if(has_celldex) library(celldex)
  library(SingleCellExperiment)
  library(HGNChelper)
  library(ggplot2)
  library(ggalluvial)
  library(dplyr)
  library(patchwork)
  library(scales)
  library(viridis)
  
  library(AnnotationDbi)
  library(openxlsx)
})

select <- dplyr::select

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    integrated_rds      = "results/integration/integrated_data/integrated_clustered_seurat.rds",
    outdir              = "results/cell_annotation",
    tissue              = "auto",
    marker_min_pct      = 0.25,
    marker_logfc_thresh = 0.25,
    top_n_markers       = 5,
    sctype_quantile     = 0.6,
    organism            = "human",
    custom_gene_panel   = "",
    seed                = 42
  )
  i <- 1
  while (i <= length(args)) {
    key <- gsub("^--", "", args[i])
    if (i < length(args) && !grepl("^--", args[i + 1])) {
      val <- args[i + 1]
      if (key %in% c("marker_min_pct", "marker_logfc_thresh", "sctype_quantile")) {
        params[[key]] <- as.numeric(val)
      } else if (key %in% c("top_n_markers", "seed")) {
        params[[key]] <- as.integer(val)
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
theme_set(theme_classic(base_size = 12))

cat("=================================================================\n")
cat(" Step 4 / Part 4: Cell Type Identification & Multi-Method Annotation\n")
cat(" Input RDS:  ", opt$integrated_rds, "\n")
cat(" Output Dir: ", opt$outdir, "\n")
cat(" Tissue DB:  ", opt$tissue, "\n")
cat("=================================================================\n\n")

manual_plot_dir  <- file.path(opt$outdir, "plots/manual_annotation")
auto_plot_dir    <- file.path(opt$outdir, "plots/automated_annotation")
comp_plot_dir    <- file.path(opt$outdir, "plots/method_comparison")
annot_dir        <- file.path(opt$outdir, "annotations")

dir.create(manual_plot_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(auto_plot_dir,   recursive = TRUE, showWarnings = FALSE)
dir.create(comp_plot_dir,   recursive = TRUE, showWarnings = FALSE)
dir.create(annot_dir,       recursive = TRUE, showWarnings = FALSE)

integrated_seurat <- readRDS(opt$integrated_rds)

available_reductions <- names(integrated_seurat@reductions)
umap_reduction <- if ("umap.harmony" %in% available_reductions) {
  "umap.harmony"
} else if ("umap.cca" %in% available_reductions) {
  "umap.cca"
} else if ("umap.rpca" %in% available_reductions) {
  "umap.rpca"
} else {
  grep("umap", available_reductions, value = TRUE)[1]
}

org_db <- if (tolower(opt$organism) == "mouse") {
  requireNamespace("org.Mm.eg.db", quietly = TRUE)
  org.Mm.eg.db::org.Mm.eg.db
} else {
  requireNamespace("org.Hs.eg.db", quietly = TRUE)
  org.Hs.eg.db::org.Hs.eg.db
}

# 1. Map Ensembl IDs -> symbols (Assay5 class-aware)
current_rownames <- rownames(integrated_seurat)
ensembl_pattern <- if (tolower(opt$organism) == "mouse") "^ENSMUSG[0-9]+" else "^ENSG[0-9]+"
looks_like_ensembl <- any(grepl(ensembl_pattern, current_rownames))

if (looks_like_ensembl) {
  cat(sprintf("\nMapping Ensembl IDs to symbols (%s)...\n", opt$organism))
  ensembl_ids <- current_rownames
  symbols <- mapIds(org_db, keys = ensembl_ids, keytype = "ENSEMBL", column = "SYMBOL", multiVals = "first")
  new_names_full <- ifelse(is.na(symbols) | symbols == "", ensembl_ids, symbols)
  new_names_full <- make.unique(new_names_full)
  gene_name_map  <- setNames(new_names_full, ensembl_ids)
  
  a <- integrated_seurat[["RNA"]]
  dimnames(a) <- list(unname(gene_name_map[rownames(a)]), colnames(a))
  integrated_seurat[["RNA"]] <- a
  cat(sprintf("Mapped %d Ensembl IDs to symbols.\n", sum(!is.na(symbols))))
} else {
  cat("\nRownames already appear to be gene symbols. Skipping Ensembl remapping.\n")
}

# Normalize and scale
integrated_seurat <- NormalizeData(integrated_seurat, normalization.method = "LogNormalize", scale.factor = 10000, verbose = FALSE)
integrated_seurat <- ScaleData(integrated_seurat, features = rownames(integrated_seurat), verbose = FALSE)

# 2. Canonical Marker Validation & Dotplots
canonical_markers <- list()
if (opt$custom_gene_panel != "") {
  custom_genes <- trimws(unlist(strsplit(opt$custom_gene_panel, ",")))
  canonical_markers[["Custom_Panel"]] <- custom_genes
}

if (length(canonical_markers) > 0) {
  for (ct_name in names(canonical_markers)) {
    m <- canonical_markers[[ct_name]]
    p_m <- m[m %in% rownames(integrated_seurat)]
    if (length(p_m) > 0) {
      p_vln <- VlnPlot(integrated_seurat, features = p_m, group.by = "seurat_clusters", pt.size = 0, ncol = 3) &
        theme(legend.position = "none", axis.title.x = element_blank())
      ggsave(file.path(manual_plot_dir, paste0("violin_", ct_name, ".png")), p_vln, width = 12, height = 4, dpi = 300)
    }
  }

  all_can_markers <- unique(unlist(canonical_markers))
  present_can <- all_can_markers[all_can_markers %in% rownames(integrated_seurat)]
  if (length(present_can) > 0) {
    p_dot <- DotPlot(integrated_seurat, features = present_can, group.by = "seurat_clusters") +
      coord_flip() + theme(axis.text.x = element_text(angle = 45, hjust = 1)) +
      labs(title = "Custom Panel Markers by Cluster")
    ggsave(file.path(manual_plot_dir, "dotplot_all_canonical_markers.png"), p_dot, width = 12, height = 7, dpi = 300)
  }
}

# 3. Custom Biomarker Scoring
if (opt$custom_gene_panel != "") {
  biomarkers <- trimws(unlist(strsplit(opt$custom_gene_panel, ",")))
  present_biomarkers <- biomarkers[biomarkers %in% rownames(integrated_seurat)]
  if (length(present_biomarkers) > 0) {
    biomarker_expr <- FetchData(integrated_seurat, vars = present_biomarkers, layer = "counts")
    integrated_seurat$custom_biomarker_count <- rowSums(biomarker_expr > 0)
    integrated_seurat$custom_biomarker_affected <- integrated_seurat$custom_biomarker_count >= 1
    p_biomarker <- FeaturePlot(integrated_seurat, features = "custom_biomarker_count", reduction = umap_reduction, pt.size = 0.3) +
      ggtitle("Custom Biomarker Count per Cell")
    ggsave(file.path(manual_plot_dir, "custom_biomarker_score.png"), p_biomarker, width = 8, height = 7, dpi = 300)
  }
}

# 4. Data-Driven Marker Discovery
cat("\n--- Discovering Cluster Markers (FindAllMarkers) ---\n")
cluster_markers <- FindAllMarkers(integrated_seurat, only.pos = TRUE, min.pct = opt$marker_min_pct, logfc.threshold = opt$marker_logfc_thresh, verbose = FALSE)
cluster_markers_filtered <- cluster_markers %>%
  filter(!grepl("^RP[SL]", gene)) %>%
  filter(!grepl("^[Mm][Tt]-", gene))

top_markers <- cluster_markers_filtered %>%
  group_by(cluster) %>%
  top_n(n = opt$top_n_markers, wt = avg_log2FC) %>%
  arrange(cluster, desc(avg_log2FC))

write.csv(cluster_markers_filtered, file.path(annot_dir, "cluster_markers_all.csv"), row.names = FALSE)
write.csv(top_markers, file.path(annot_dir, "top5_markers_per_cluster.csv"), row.names = FALSE)

p_heatmap <- DoHeatmap(integrated_seurat, features = unique(top_markers$gene), group.by = "seurat_clusters", size = 3) +
  theme(axis.text.y = element_text(size = 6)) + labs(title = "Top 5 Markers per Cluster")
ggsave(file.path(manual_plot_dir, "06_heatmap_top_markers.png"), p_heatmap, width = 12, height = 14, dpi = 300)

# 5. SingleR Annotation
cat("\n--- Running SingleR Annotation ---\n")
sce <- as.SingleCellExperiment(integrated_seurat)

tryCatch({
  hpca_ref <- celldex::HumanPrimaryCellAtlasData()
  singler_hpca <- SingleR(test = sce, ref = hpca_ref, labels = hpca_ref$label.main, assay.type.test = "logcounts")
  integrated_seurat$singler_annotation <- singler_hpca$labels
  p_singler <- DimPlot(integrated_seurat, reduction = umap_reduction, group.by = "singler_annotation", label = TRUE, pt.size = 0.3, repel = TRUE) +
    ggtitle("SingleR (HPCA Reference)")
  ggsave(file.path(auto_plot_dir, "11_singler_annotation.png"), p_singler, width = 11, height = 8, dpi = 300)
}, error = function(e) {
  cat("SingleR failed:", conditionMessage(e), "\n")
  integrated_seurat$singler_annotation <<- "NotRun"
})

# 6. scType Annotation
cat("\n--- Running scType Annotation ---\n")
tryCatch({
  source("https://raw.githubusercontent.com/IanevskiAleksandr/sc-type/master/R/gene_sets_prepare.R")
  source("https://raw.githubusercontent.com/IanevskiAleksandr/sc-type/master/R/sctype_score_.R")
  
  db_url <- "https://raw.githubusercontent.com/IanevskiAleksandr/sc-type/master/ScTypeDB_full.xlsx"
  temp_file <- tempfile(fileext = ".xlsx")
  download.file(db_url, destfile = temp_file, mode = "wb", quiet = TRUE)
  
  gs_list <- gene_sets_prepare(temp_file, opt$tissue)
  scaled_data <- as.matrix(LayerData(integrated_seurat, layer = "scale.data"))
  es_max <- sctype_score(scRNAseqData = scaled_data, scaled = TRUE, gs = gs_list$gs_positive, gs2 = gs_list$gs_negative)
  
  clusters <- integrated_seurat$seurat_clusters
  cL_results <- do.call("rbind", lapply(unique(clusters), function(cl) {
    es_max_cl <- sort(rowSums(es_max[, clusters == cl, drop = FALSE]), decreasing = TRUE)
    data.frame(cluster = cl, type = names(es_max_cl)[1], scores = es_max_cl[1], ncells = sum(clusters == cl))
  }))
  score_threshold <- quantile(cL_results$scores, opt$sctype_quantile)
  cL_results$type[cL_results$scores < score_threshold] <- "Unknown"
  
  cluster_to_sctype <- setNames(cL_results$type, cL_results$cluster)
  integrated_seurat$sctype_annotation <- unname(cluster_to_sctype[as.character(integrated_seurat$seurat_clusters)])
  write.csv(cL_results, file.path(annot_dir, "sctype_cluster_scores.csv"), row.names = FALSE)
  
  p_sctype <- DimPlot(integrated_seurat, reduction = umap_reduction, group.by = "sctype_annotation", label = TRUE, pt.size = 0.3, repel = TRUE) +
    ggtitle(paste0("scType (", opt$tissue, " DB)"))
  ggsave(file.path(auto_plot_dir, "12_sctype_annotation.png"), p_sctype, width = 11, height = 8, dpi = 300)
}, error = function(e) {
  cat("scType failed:", conditionMessage(e), "\n")
  integrated_seurat$sctype_annotation <<- "NotRun"
})

# 7. scCATCH Annotation
cat("\n--- Running scCATCH Annotation ---\n")
tryCatch({
  counts_mat <- as.matrix(LayerData(integrated_seurat, layer = "counts"))
  cluster_labels <- as.character(integrated_seurat$seurat_clusters)
  data(cellmatch, package = "scCATCH", envir = environment())
  human_tissues <- sort(unique(cellmatch$tissue[cellmatch$species == "Human"]))
  matched_tissues <- human_tissues[grepl(opt$tissue, human_tissues, ignore.case = TRUE)]
  if (length(matched_tissues) == 0 && length(human_tissues) > 0) matched_tissues <- human_tissues[1]
  
  sccatch_obj <- createscCATCH(data = counts_mat, cluster = cluster_labels)
  sccatch_obj <- findmarkergene(sccatch_obj, species = "Human", marker = cellmatch, tissue = matched_tissues, cancer = NULL)
  sccatch_obj <- findcelltype(sccatch_obj)
  
  cluster_to_sccatch <- setNames(sccatch_obj@celltype$cell_type, sccatch_obj@celltype$cluster)
  integrated_seurat$sccatch_annotation <- unname(cluster_to_sccatch[as.character(integrated_seurat$seurat_clusters)])
  integrated_seurat$sccatch_annotation[is.na(integrated_seurat$sccatch_annotation)] <- "Unassigned"
  
  write.csv(sccatch_obj@celltype, file.path(annot_dir, "sccatch_cluster_scores.csv"), row.names = FALSE)
  p_sccatch <- DimPlot(integrated_seurat, reduction = umap_reduction, group.by = "sccatch_annotation", label = TRUE, pt.size = 0.3, repel = TRUE) +
    ggtitle("scCATCH Annotation")
  ggsave(file.path(auto_plot_dir, "13_sccatch_annotation.png"), p_sccatch, width = 11, height = 8, dpi = 300)
}, error = function(e) {
  cat("scCATCH failed:", conditionMessage(e), "\n")
  integrated_seurat$sccatch_annotation <<- "NotRun"
})

# 8. Cross-Comparison Tables
if (!"manual_annotation" %in% colnames(integrated_seurat@meta.data)) integrated_seurat$manual_annotation <- "Unassigned"
if (!"singler_annotation" %in% colnames(integrated_seurat@meta.data)) integrated_seurat$singler_annotation <- "NotRun"
if (!"sctype_annotation" %in% colnames(integrated_seurat@meta.data)) integrated_seurat$sctype_annotation <- "NotRun"
if (!"sccatch_annotation" %in% colnames(integrated_seurat@meta.data)) integrated_seurat$sccatch_annotation <- "NotRun"

annotation_comparison <- data.frame(
  cell_barcode = colnames(integrated_seurat),
  cluster      = integrated_seurat$seurat_clusters,
  manual       = integrated_seurat$manual_annotation,
  singler      = integrated_seurat$singler_annotation,
  sctype       = integrated_seurat$sctype_annotation,
  sccatch      = integrated_seurat$sccatch_annotation,
  sample_id    = integrated_seurat$sample_id,
  condition    = integrated_seurat$condition,
  stringsAsFactors = FALSE
)
write.csv(annotation_comparison, file.path(annot_dir, "all_methods_comparison.csv"), row.names = FALSE)

cluster_summary <- annotation_comparison %>%
  group_by(cluster) %>%
  summarise(
    n_cells      = n(),
    manual_type  = names(sort(table(manual), decreasing = TRUE))[1],
    singler_type = names(sort(table(singler), decreasing = TRUE))[1],
    sctype_type  = names(sort(table(sctype), decreasing = TRUE))[1],
    sccatch_type = names(sort(table(sccatch), decreasing = TRUE))[1],
    .groups      = "drop"
  )
write.csv(cluster_summary, file.path(annot_dir, "cluster_level_comparison.csv"), row.names = FALSE)

# 4-panel method comparison
p_m  <- DimPlot(integrated_seurat, reduction = umap_reduction, group.by = "manual_annotation", pt.size = 0.3) + labs(title = "Manual")
p_sr <- DimPlot(integrated_seurat, reduction = umap_reduction, group.by = "singler_annotation", pt.size = 0.3) + labs(title = "SingleR (HPCA)")
p_st <- DimPlot(integrated_seurat, reduction = umap_reduction, group.by = "sctype_annotation", pt.size = 0.3) + labs(title = "scType")
p_sc <- DimPlot(integrated_seurat, reduction = umap_reduction, group.by = "sccatch_annotation", pt.size = 0.3) + labs(title = "scCATCH")
ggsave(file.path(comp_plot_dir, "all_methods_comparison.png"),
       (p_m | p_sr) / (p_st | p_sc), width = 16, height = 12, dpi = 300)

saveRDS(integrated_seurat, file.path(annot_dir, "integrated_annotated_seurat_draft.rds"))

cat("\n=================================================================\n")
cat(" Part 4 (Cell Type Identification) complete!\n")
cat(" Draft annotated RDS: ", file.path(annot_dir, "integrated_annotated_seurat_draft.rds"), "\n")
cat(" Cluster comparison:  ", file.path(annot_dir, "cluster_level_comparison.csv"), "\n")
cat("=================================================================\n")
