#!/usr/bin/env Rscript

# =============================================================================
# Nextflow-Ready: Part 9: CellChat (with Plots)
# Usage: Rscript part9_cellchat.R --input annotated.rds --output .
# =============================================================================

suppressPackageStartupMessages({
  library(CellChat)
  library(Seurat)
  library(optparse)
  library(patchwork)
})

option_list <- list(
  make_option(c("-i", "--input"), type="character", default=NULL, help="Annotated RDS"),
  make_option(c("-o", "--output"), type="character", default=".", help="Output directory")
)
opt <- parse_args(OptionParser(option_list=option_list))

dir.create(file.path(opt$output, "plots"), recursive = TRUE, showWarnings = FALSE)
setwd(opt$output)

seurat_obj <- readRDS(opt$input)

# Single group or comparative logic
chat <- createCellChat(object = seurat_obj, group.by = "cell_type", assay = "RNA")
chat@DB <- CellChatDB.human
chat <- subsetData(chat) %>% identifyOverExpressedGenes() %>% identifyOverExpressedInteractions()
chat <- computeCommunProb(chat) %>% filterCommunication(min.cells = 10) %>% 
        computeCommunProbPathway() %>% aggregateNet()

# Plots
png("plots/01_interaction_strength.png", width = 800, height = 800, res = 150)
netVisual_circle(chat@net$weight, title.name = "Interaction Strength")
dev.off()

saveRDS(chat, "cellchat_results.rds")
cat("CellChat Complete.\n")
