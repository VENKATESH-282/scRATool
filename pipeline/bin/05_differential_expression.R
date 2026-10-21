#!/usr/bin/env Rscript
################################################################################
# Script: 05_differential_expression.R (Part 5)
# Description: Final Annotation Resolution, Cell-Type Proportions (propeller),
#              Single-Cell DE (FindMarkers), Pseudobulk DE (DESeq2 & limma-voom),
#              and Functional Pathway Scoring (DUX4 & Myogenesis).
################################################################################

suppressPackageStartupMessages({
  library(Seurat)
  library(SeuratObject)
  library(DESeq2)
  library(edgeR)
  library(limma)
  library(speckle)
  library(fgsea)
  library(msigdbr)
  library(ggplot2)
  library(pheatmap)
  library(ggridges)
  library(ggrepel)
  library(EnhancedVolcano)
  library(patchwork)
  library(dplyr)
  library(tidyr)
})

sanitize_filename <- function(x) gsub("[^A-Za-z0-9_.-]", "_", x)

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    draft_rds           = "results/cell_annotation/annotations/integrated_annotated_seurat_draft.rds",
    annotation_map      = "assets/cluster_annotations.csv",
    outdir              = "results/differential_expression",
    reference_condition = "CTRL",
    de_test             = "wilcox",
    de_min_pct          = 0.1,
    de_logfc_thresh     = 0.25,
    de_fdr_thresh       = 0.05,
    pb_min_counts       = 10,
    pb_min_samples      = 2,
    custom_gene_panel   = "",
    scoring_gene_sets   = "",
    organism            = "human",
    seed                = 42
  )
  i <- 1
  while (i <= length(args)) {
    key <- gsub("^--", "", args[i])
    if (i < length(args) && !grepl("^--", args[i + 1])) {
      val <- args[i + 1]
      if (key %in% c("de_min_pct", "de_logfc_thresh", "de_fdr_thresh")) {
        params[[key]] <- as.numeric(val)
      } else if (key %in% c("pb_min_counts", "pb_min_samples", "seed")) {
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
cat(" Step 5 / Part 5: Differential Expression & Functional Scoring\n")
cat(" Draft RDS:         ", opt$draft_rds, "\n")
cat(" Annotation Map:    ", opt$annotation_map, "\n")
cat(" Output Dir:        ", opt$outdir, "\n")
cat(" Reference Group:   ", opt$reference_condition, "\n")
cat("=================================================================\n\n")

prop_plot_dir   <- file.path(opt$outdir, "plots/proportions")
de_plot_dir     <- file.path(opt$outdir, "plots/DE_celllevel")
func_plot_dir   <- file.path(opt$outdir, "plots/functional_scoring")
res_dir         <- file.path(opt$outdir, "results")
annot_dir       <- file.path(opt$outdir, "annotations")

dir.create(prop_plot_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(de_plot_dir,   recursive = TRUE, showWarnings = FALSE)
dir.create(func_plot_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(res_dir,       recursive = TRUE, showWarnings = FALSE)
dir.create(annot_dir,     recursive = TRUE, showWarnings = FALSE)

# 1. Load Seurat Object & Apply Final Consensus Annotation
integrated_seurat <- readRDS(opt$draft_rds)
cluster_summary   <- read.csv(opt$annotation_map, stringsAsFactors = FALSE)

if (!"consensus_annotation" %in% colnames(cluster_summary)) {
  stop("Annotation map CSV is missing the required 'consensus_annotation' column.")
}

placeholder_pattern <- "fill in|TBD|^<.*>$|^unassigned$"
is_placeholder <- grepl(placeholder_pattern, cluster_summary$consensus_annotation, ignore.case = TRUE)
if (any(is_placeholder)) {
  stop("Placeholder text found in consensus_annotation for cluster(s): ",
       paste(cluster_summary$cluster[is_placeholder], collapse = ", "))
}

cluster_to_final <- setNames(cluster_summary$consensus_annotation, as.character(cluster_summary$cluster))
integrated_seurat$final_annotation <- unname(cluster_to_final[as.character(integrated_seurat$seurat_clusters)])

if (any(is.na(integrated_seurat$final_annotation) | integrated_seurat$final_annotation == "")) {
  warning("NA values detected after final_annotation mapping. Falling back to cluster IDs.")
  na_idx <- is.na(integrated_seurat$final_annotation) | integrated_seurat$final_annotation == ""
  integrated_seurat$final_annotation[na_idx] <- paste0("Cluster_", integrated_seurat$seurat_clusters[na_idx])
}

saveRDS(integrated_seurat, file.path(annot_dir, "integrated_annotated_seurat_final.rds"))

# Conditions & Pairwise contrasts
all_conditions <- unique(as.character(integrated_seurat$condition))
ref_cond <- opt$reference_condition
query_conds <- setdiff(all_conditions, ref_cond)
comparisons <- lapply(query_conds, function(q) c(q, ref_cond))

conditions <- sort(unique(integrated_seurat$condition))
pal <- if (length(conditions) <= 8) RColorBrewer::brewer.pal(max(3, length(conditions)), "Set2")[1:length(conditions)] else rainbow(length(conditions))
condition_colors <- setNames(pal, conditions)

cell_types <- sort(unique(integrated_seurat$final_annotation))

# 2. Cell Type Proportions & Visualizations
cat("\n--- Calculating Cell Type Proportions ---\n")
proportion_data <- integrated_seurat@meta.data %>%
  group_by(sample_id, condition, final_annotation) %>%
  summarise(count = n(), .groups = "drop") %>%
  group_by(sample_id) %>%
  mutate(total_cells = sum(count), proportion = count / total_cells, percentage = proportion * 100) %>%
  ungroup()
write.csv(proportion_data, file.path(res_dir, "cell_type_proportions_per_sample.csv"), row.names = FALSE)

proportion_summary <- proportion_data %>%
  group_by(condition, final_annotation) %>%
  summarise(mean_percentage = mean(percentage), sd_percentage = sd(percentage), .groups = "drop")
write.csv(proportion_summary, file.path(res_dir, "cell_type_proportions_summary.csv"), row.names = FALSE)

p_stacked <- ggplot(proportion_data, aes(x = sample_id, y = percentage, fill = final_annotation)) +
  geom_bar(stat = "identity") + facet_wrap(~ condition, scales = "free_x") +
  theme(axis.text.x = element_text(angle = 45, hjust = 1)) +
  labs(title = "Cell Type Composition by Sample", x = "Sample", y = "Percentage (%)", fill = "Cell Type") +
  scale_fill_brewer(palette = "Set3")
ggsave(file.path(prop_plot_dir, "01_stacked_composition.png"), p_stacked, width = 14, height = 6, dpi = 300)

p_grouped <- ggplot(proportion_summary, aes(x = final_annotation, y = mean_percentage, fill = condition)) +
  geom_bar(stat = "identity", position = position_dodge(0.9)) +
  geom_errorbar(aes(ymin = pmax(0, mean_percentage - sd_percentage), ymax = mean_percentage + sd_percentage),
                position = position_dodge(0.9), width = 0.2) +
  theme(axis.text.x = element_text(angle = 45, hjust = 1)) +
  labs(title = "Mean Cell Type Proportions by Condition", x = "Cell Type", y = "Mean %") +
  scale_fill_manual(values = condition_colors)
ggsave(file.path(prop_plot_dir, "02_grouped_proportions.png"), p_grouped, width = 12, height = 6, dpi = 300)

# 3. Statistical Testing of Proportions (propeller)
cat("\n--- Running Propeller Statistical Testing ---\n")
sample_to_cond <- unique(integrated_seurat@meta.data[, c("sample_id", "condition")])
rownames(sample_to_cond) <- sample_to_cond$sample_id

propeller_overall <- propeller(
  clusters = integrated_seurat$final_annotation,
  sample   = integrated_seurat$sample_id,
  group    = sample_to_cond[integrated_seurat$sample_id, "condition"]
)
write.csv(propeller_overall, file.path(res_dir, "propeller_proportion_test_overall_3group.csv"), row.names = FALSE)

propeller_pairwise <- lapply(comparisons, function(cmp) {
  keep_cells <- integrated_seurat$condition %in% cmp
  sub_meta <- integrated_seurat@meta.data[keep_cells, ]
  res <- propeller(
    clusters = sub_meta$final_annotation,
    sample   = sub_meta$sample_id,
    group    = factor(sub_meta$condition, levels = rev(cmp))
  )
  res$comparison <- paste(cmp[1], "vs", cmp[2])
  res
}) %>% bind_rows()
write.csv(propeller_pairwise, file.path(res_dir, "propeller_proportion_test_pairwise.csv"), row.names = FALSE)

# 4. Cell-Level DE with FindMarkers
cat("\n--- Running Cell-Level FindMarkers ---\n")
DefaultAssay(integrated_seurat) <- "RNA"
Idents(integrated_seurat) <- "condition"

run_findmarkers <- function(celltype, cmp, seurat_obj) {
  seurat_sub <- subset(seurat_obj, subset = final_annotation == celltype & condition %in% cmp)
  if (length(unique(seurat_sub$condition)) < 2) return(NULL)
  markers <- FindMarkers(seurat_sub, ident.1 = cmp[1], ident.2 = cmp[2],
                         test.use = "wilcox", logfc.threshold = 0, min.pct = 0.1, verbose = FALSE)
  markers$gene <- rownames(markers)
  markers$cell_type <- celltype
  markers$comparison <- paste(cmp[1], "vs", cmp[2])
  markers
}

findmarkers_all <- lapply(comparisons, function(cmp) {
  lapply(cell_types, run_findmarkers, cmp = cmp, seurat_obj = integrated_seurat)
}) %>% unlist(recursive = FALSE) %>% bind_rows()

if (nrow(findmarkers_all) > 0 && "avg_log2FC" %in% colnames(findmarkers_all)) {
  findmarkers_all$significant <- findmarkers_all$p_val_adj < 0.05 & abs(findmarkers_all$avg_log2FC) > 0.25
  write.csv(findmarkers_all, file.path(res_dir, "findmarkers_celllevel_results.csv"), row.names = FALSE)

  sig_summary_celllevel <- findmarkers_all %>%
    group_by(cell_type, comparison) %>%
    summarise(
      total_genes = n(), sig_genes = sum(significant),
      sig_up = sum(significant & avg_log2FC > 0.25),
      sig_down = sum(significant & avg_log2FC < -0.25),
      .groups = "drop"
    )
  write.csv(sig_summary_celllevel, file.path(res_dir, "findmarkers_summary.csv"), row.names = FALSE)

  # Volcano plots
  for (cmp in comparisons) {
    cmp_label <- paste(cmp[1], "vs", cmp[2])
    for (ct in cell_types) {
      ct_data <- findmarkers_all %>% filter(cell_type == ct, comparison == cmp_label)
      if (nrow(ct_data) == 0) next
      top_genes <- ct_data %>% filter(significant) %>% arrange(p_val_adj) %>% head(10)
      p_vol <- ggplot(ct_data, aes(x = avg_log2FC, y = -log10(p_val_adj))) +
        geom_point(aes(color = significant), alpha = 0.5, size = 1) +
        scale_color_manual(values = c("FALSE" = "gray", "TRUE" = "red")) +
        labs(title = paste0("Volcano: ", ct, " (", cmp_label, ")"), x = "log2FC", y = "-log10(FDR)") +
        geom_hline(yintercept = -log10(0.05), linetype = "dashed", color = "blue") +
        geom_vline(xintercept = c(-0.25, 0.25), linetype = "dashed", color = "blue")
      if (nrow(top_genes) > 0) {
        p_vol <- p_vol + geom_text_repel(data = top_genes, aes(label = gene), size = 3, max.overlaps = 10)
      }
      fname <- paste0("volcano_", sanitize_filename(ct), "_", sanitize_filename(cmp_label), ".png")
      ggsave(file.path(de_plot_dir, fname), p_vol, width = 8, height = 7, dpi = 300)
    }
  }

} else {
  warning("No significant DE genes found across any cluster/condition combination.")
  write.csv(data.frame(Message="No cells qualified for DE testing between conditions"), file.path(res_dir, "findmarkers_celllevel_results.csv"), row.names = FALSE)
  write.csv(data.frame(Message="No DE cells"), file.path(res_dir, "findmarkers_summary.csv"), row.names = FALSE)
}

# 5. Pseudobulk DE with DESeq2 & limma-voom
cat("\n--- Running Pseudobulk DE (DESeq2 & limma-voom) ---\n")
deseq2_results_all <- list()
limma_results_all  <- list()

for (ct in cell_types) {
  sub_obj <- subset(integrated_seurat, subset = final_annotation == ct)
  pb <- PseudobulkExpression(sub_obj, assays = "RNA", group.by = "sample_id", layer = "counts", method = "aggregate")
  pb_counts <- as.matrix(pb$RNA)
  
  sample_meta <- unique(sub_obj@meta.data[, c("sample_id", "condition")])
  rownames(sample_meta) <- sample_meta$sample_id
  colnames(pb_counts)   <- gsub("-", "_", colnames(pb_counts))
  rownames(sample_meta) <- gsub("-", "_", rownames(sample_meta))
  sample_meta <- sample_meta[colnames(pb_counts), , drop = FALSE]
  
  if (nrow(sample_meta) < 4 || length(unique(sample_meta$condition)) < 2) next
  sample_meta$condition <- factor(sample_meta$condition, levels = c(ref_cond, setdiff(unique(sample_meta$condition), ref_cond)))
  
  # DESeq2
  tryCatch({
    dds <- DESeqDataSetFromMatrix(countData = pb_counts, colData = sample_meta, design = ~ condition)
    keep <- rowSums(counts(dds) >= 10) >= 2
    dds <- dds[keep, ]
    dds <- DESeq(dds, quiet = TRUE)
    
    for (cmp in comparisons) {
      if (all(cmp %in% levels(sample_meta$condition))) {
        res_deseq <- results(dds, contrast = c("condition", cmp[1], cmp[2]))
        df_deseq  <- as.data.frame(res_deseq)
        df_deseq$gene <- rownames(df_deseq)
        df_deseq$cell_type <- ct
        df_deseq$comparison <- paste(cmp[1], "vs", cmp[2])
        deseq2_results_all[[paste(ct, cmp[1], sep = "_")]] <- df_deseq
      }
    }
  }, error = function(e) cat("  [DESeq2 skip]", ct, ":", conditionMessage(e), "\n"))
  
  # limma-voom
  tryCatch({
    dge <- DGEList(counts = pb_counts)
    keep_dge <- filterByExpr(dge, group = sample_meta$condition)
    dge <- dge[keep_dge, , keep.lib.sizes = FALSE]
    dge <- calcNormFactors(dge)
    design <- model.matrix(~ 0 + condition, data = sample_meta)
    colnames(design) <- levels(sample_meta$condition)
    v <- voom(dge, design, plot = FALSE)
    fit <- lmFit(v, design)
    
    for (cmp in comparisons) {
      if (all(cmp %in% colnames(design))) {
        contrast_str <- paste(cmp[1], "-", cmp[2])
        cm <- makeContrasts(contrasts = contrast_str, levels = design)
        fit2 <- contrasts.fit(fit, cm)
        fit2 <- eBayes(fit2)
        tt <- topTable(fit2, number = Inf)
        tt$gene <- rownames(tt)
        tt$cell_type <- ct
        tt$comparison <- paste(cmp[1], "vs", cmp[2])
        limma_results_all[[paste(ct, cmp[1], sep = "_")]] <- tt
      }
    }
  }, error = function(e) cat("  [limma skip]", ct, ":", conditionMessage(e), "\n"))
}

if (length(deseq2_results_all) > 0) {
  deseq2_df <- bind_rows(deseq2_results_all)
  deseq2_df$significant <- deseq2_df$padj < 0.05 & abs(deseq2_df$log2FoldChange) > 0.25
  write.csv(deseq2_df, file.path(res_dir, "deseq2_pseudobulk_results.csv"), row.names = FALSE)
  deseq2_sum <- deseq2_df %>% group_by(cell_type, comparison) %>%
    summarise(total_genes = n(), sig_genes = sum(significant, na.rm = TRUE),
              sig_up = sum(significant & log2FoldChange > 0.25, na.rm = TRUE),
              sig_down = sum(significant & log2FoldChange < -0.25, na.rm = TRUE), .groups = "drop")
  write.csv(deseq2_sum, file.path(res_dir, "deseq2_summary.csv"), row.names = FALSE)
}

if (length(limma_results_all) > 0) {
  limma_df <- bind_rows(limma_results_all)
  limma_df$significant <- limma_df$adj.P.Val < 0.05 & abs(limma_df$logFC) > 0.25
  write.csv(limma_df, file.path(res_dir, "limma_pseudobulk_results.csv"), row.names = FALSE)
  limma_sum <- limma_df %>% group_by(cell_type, comparison) %>%
    summarise(total_genes = n(), sig_genes = sum(significant, na.rm = TRUE),
              sig_up = sum(significant & logFC > 0.25, na.rm = TRUE),
              sig_down = sum(significant & logFC < -0.25, na.rm = TRUE), .groups = "drop")
  write.csv(limma_sum, file.path(res_dir, "limma_summary.csv"), row.names = FALSE)
}

# 6. Functional Scoring
cat("\n--- Running Functional Pathway Scoring ---\n")
score_cols <- c()

if (opt$custom_gene_panel != "") {
  custom_panel <- trimws(unlist(strsplit(opt$custom_gene_panel, ",")))
  custom_present <- custom_panel[custom_panel %in% rownames(integrated_seurat)]
  if (length(custom_present) > 0) {
    integrated_seurat <- AddModuleScore(integrated_seurat, features = list(custom_present), name = "Custom_Panel", nbin = 24, ctrl = 100)
    colnames(integrated_seurat@meta.data)[colnames(integrated_seurat@meta.data) == "Custom_Panel1"] <- "Custom_Panel_Score"
    score_cols <- c(score_cols, "Custom_Panel_Score")
  }
}

if (opt$scoring_gene_sets != "") {
  tryCatch({
    scoring_sets <- read.csv(opt$scoring_gene_sets, stringsAsFactors = FALSE)
    for (i in 1:nrow(scoring_sets)) {
      set_name <- scoring_sets$set_name[i]
      genes <- trimws(unlist(strsplit(scoring_sets$genes[i], ",")))
      present <- genes[genes %in% rownames(integrated_seurat)]
      if (length(present) > 0) {
        integrated_seurat <- AddModuleScore(integrated_seurat, features = list(present), name = set_name, nbin = 24, ctrl = 100)
        score_name <- paste0(set_name, "_Score")
        colnames(integrated_seurat@meta.data)[colnames(integrated_seurat@meta.data) == paste0(set_name, "1")] <- score_name
        score_cols <- c(score_cols, score_name)
      }
    }
  }, error = function(e) cat("Scoring gene sets error:", conditionMessage(e), "\n"))
} else {
  tryCatch({
    hallmark_gene_sets <- msigdbr(species = if (tolower(opt$organism)=="mouse") "Mus musculus" else "Homo sapiens", category = "H")
    myogenesis_genes <- hallmark_gene_sets %>% filter(gs_name == "HALLMARK_MYOGENESIS") %>% pull(gene_symbol)
    myogenesis_present <- myogenesis_genes[myogenesis_genes %in% rownames(integrated_seurat)]
    if (length(myogenesis_present) > 0) {
      integrated_seurat <- AddModuleScore(integrated_seurat, features = list(myogenesis_present), name = "Myogenesis", nbin = 24, ctrl = 100)
      colnames(integrated_seurat@meta.data)[colnames(integrated_seurat@meta.data) == "Myogenesis1"] <- "Myogenesis_Score"
      score_cols <- c(score_cols, "Myogenesis_Score")
    }
  }, error = function(e) {
    cat("Default hallmark scoring skipped:", conditionMessage(e), "\n")
  })
}

for (score_col in score_cols) {
  if (score_col %in% colnames(integrated_seurat@meta.data)) {
    p_ridge <- ggplot(integrated_seurat@meta.data, aes(x = .data[[score_col]], y = final_annotation, fill = condition)) +
      geom_density_ridges(alpha = 0.7) +
      labs(title = paste(gsub("_", " ", score_col), "by Cell Type & Condition"), x = "Score", y = "Cell Type") +
      scale_fill_manual(values = condition_colors)
    ggsave(file.path(func_plot_dir, paste0("ridge_", tolower(sanitize_filename(score_col)), ".png")),
           p_ridge, width = 10, height = 8, dpi = 300)
  }
}

# Pseudobulk statistical test on scores
pathway_results_list <- list()
for (score_col in score_cols) {
  score_agg <- integrated_seurat@meta.data %>%
    group_by(sample_id, condition, final_annotation) %>%
    summarise(mean_score = mean(.data[[score_col]], na.rm = TRUE), .groups = "drop")
  
  res <- lapply(cell_types, function(ct) {
    ct_data <- score_agg %>% filter(final_annotation == ct)
    if (nrow(ct_data) < 4 || length(unique(ct_data$condition)) < 2) return(NULL)
    lapply(comparisons, function(cmp) {
      g1 <- ct_data %>% filter(condition == cmp[1]) %>% pull(mean_score)
      g2 <- ct_data %>% filter(condition == cmp[2]) %>% pull(mean_score)
      if (length(g1) < 2 || length(g2) < 2) return(NULL)
      tt <- t.test(g1, g2)
      data.frame(cell_type = ct, score = score_col, comparison = paste(cmp[1], "vs", cmp[2]),
                 mean_group1 = mean(g1), mean_group2 = mean(g2), diff = mean(g1) - mean(g2), p_value = tt$p.value)
    }) %>% bind_rows()
  }) %>% bind_rows()
  
  if (nrow(res) > 0) pathway_results_list[[score_col]] <- res
}
pathway_results <- bind_rows(pathway_results_list)

if (nrow(pathway_results) > 0) {
  pathway_results$FDR <- p.adjust(pathway_results$p_value, method = "BH")
  write.csv(pathway_results, file.path(res_dir, "pathway_score_tests.csv"), row.names = FALSE)
}

saveRDS(integrated_seurat, file.path(annot_dir, "integrated_annotated_seurat_final_scored.rds"))

cat("\n=================================================================\n")
cat(" Part 5 (DE & Functional Scoring) complete!\n")
cat(" Final Scored RDS: ", file.path(annot_dir, "integrated_annotated_seurat_final_scored.rds"), "\n")
cat(" Results Dir:      ", res_dir, "\n")
cat("=================================================================\n")
