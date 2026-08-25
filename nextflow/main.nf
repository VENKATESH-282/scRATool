#!/usr/bin/env nextflow
// ============================================================================
//  scRNA-seq Complete Pipeline  –  Nextflow DSL2  v3.0.0
//  Parts 1–11: FASTQ → CellRanger → QC → Integration → Annotation →
//              DE → Exploration → Trajectory → CellChat → NicheNet → CopyKAT
//
//  INPUT MODES:
//    Mode 1 (Full):    --input   samples.csv       Raw FASTQs → full pipeline
//    Mode 2 (Matrix):  --matrix  matrix_samples.csv  10X MEX dirs → QC onward
//    Mode 3 (RDS):     --seurat_rds merged.rds      Seurat object → Annotation onward
// ============================================================================
nextflow.enable.dsl = 2

// ─── Help Message ───────────────────────────────────────────────────────────
if (params.help) {
    log.info """
    ╔═══════════════════════════════════════════════════════════════════════╗
    ║     scRNA-seq Complete Pipeline  v3.0.0  •  Nextflow DSL2            ║
    ║     Parts 1–11: CellRanger → CopyKAT                                 ║
    ╚═══════════════════════════════════════════════════════════════════════╝

    USAGE:
      nextflow run main.nf [INPUT MODE] [OPTIONS] [-profile PROFILE]

    ─── INPUT MODES (choose one) ─────────────────────────────────────────

      Mode 1 – Full pipeline from raw FASTQs:
        nextflow run main.nf --input samples.csv --ref_human /path/to/ref

      Mode 2 – Start from 10X MEX count matrices (skip CellRanger):
        nextflow run main.nf --matrix matrix_samples.csv

      Mode 3 – Start from a pre-merged Seurat RDS (skip to Annotation):
        nextflow run main.nf --seurat_rds merged.rds

    ─── KEY OPTIONS ──────────────────────────────────────────────────────
      --outdir         STR   Output directory                [default: results]
      --ref_human      PATH  CellRanger human genome reference
      --ref_mouse      PATH  CellRanger mouse genome (PDX only)
      --cellranger_dir PATH  Pre-existing CellRanger output dir

    ─── SKIP FLAGS ───────────────────────────────────────────────────────
      --skip_cellranger    Skip CellRanger (use --cellranger_dir or --matrix)
      --skip_pdx           Skip PDX species demultiplexing  [default: true]
      --skip_qc            Skip QC  (use existing 02_qc/ outputs)
      --skip_integration   Skip integration  (use existing merged_clustered.rds)
      --skip_annotation    Skip annotation  (use existing integrated_annotated.rds)
      --skip_de            Skip DE analysis  (use existing de_results.rds)
      --skip_trajectory    Skip Slingshot trajectory analysis
      --skip_cellchat      Skip CellChat cell-cell communication
      --skip_nichenet      Skip NicheNet ligand activity analysis
      --skip_copykat       Skip CopyKAT CNV analysis (Part 11)
      --skip_sra           Skip SRA download (local FASTQs must exist)

    ─── STOP-AFTER FLAGS ─────────────────────────────────────────────────
      --stop_after_qc           Exit after Part 2  (QC)
      --stop_after_integration  Exit after Part 3  (Integration)
      --stop_after_annotation   Exit after Part 4  (Annotation)
      --stop_after_de           Exit after Part 5  (DE Analysis)
      --stop_after_exploration  Exit after Part 6  (Exploration)

    ─── CELLRANGER OPTIONS ───────────────────────────────────────────────
      --chemistry      STR  Library chemistry  [default: auto]
      --expect_cells   INT  Expected cells per sample  [default: 5000]

    ─── QC FILTERING OPTIONS ─────────────────────────────────────────────
      --min_genes      INT  Minimum genes per cell     [default: 500]
      --max_genes      INT  Maximum genes per cell     [default: 5000]
      --min_umi        INT  Minimum UMI per cell       [default: 800]
      --max_umi        INT  Maximum UMI per cell       [default: 20000]
      --max_mt         INT  Max mitochondrial %        [default: 10]

    ─── STANDALONE ENTRY POINTS ──────────────────────────────────────────
      nextflow run main.nf -entry NICHENET_ONLY --nichenet_rds <path.rds>
      nextflow run main.nf -entry COPYKAT_ONLY  --copykat_rds  <path.rds>

    ─── PROFILES ─────────────────────────────────────────────────────────
      -profile laptop      Local, low resources (8 CPU / 16 GB)
      -profile local       Local, standard workstation (32 CPU / 64 GB)
      -profile server      Local, high-memory server (128 CPU / 250 GB)
      -profile hpc_small   SLURM, small partition (32 CPU / 64 GB)
      -profile hpc_large   SLURM, high-mem partition (128 CPU / 512 GB)
      -profile conda       Enable Conda environments
      -profile singularity Enable Singularity containers
      -profile docker      Enable Docker containers
      -profile test        Run test dataset (bundled)

    ─── EXAMPLE COMMANDS ─────────────────────────────────────────────────
      # Full pipeline on a local server:
      nextflow run main.nf \
          --input samples.csv \
          --ref_human /path/to/refdata-gex-GRCh38-2024-A \
          --outdir my_results \
          -profile server

      # Start from count matrices (skip CellRanger):
      nextflow run main.nf \
          --matrix matrix_samples.csv \
          --outdir my_results \
          -profile local

      # Re-run only downstream analysis from an RDS checkpoint:
      nextflow run main.nf \
          --seurat_rds results/03_clustering/merged_clustered.rds \
          --outdir my_results \
          --skip_qc --skip_integration

      # Resume a failed run (uses Nextflow cache):
      nextflow run main.nf --input samples.csv -resume

      # SLURM cluster:
      nextflow run main.nf --input samples.csv -profile hpc_large -resume

    ─── SAMPLESHEET FORMAT (--input) ────────────────────────────────────
      sample_id,fastq_path,sra_id,condition,patient_id
      Healthy_1,/path/to/fastqs,,Healthy,Donor_1
      Post_1,/path/to/fastqs,,Post,Patient_1

    ─── MATRIX CSV FORMAT (--matrix) ────────────────────────────────────
      sample_id,matrix_dir,condition,patient_id
      Healthy_1,/path/to/Healthy_1/filtered_feature_bc_matrix,Healthy,Donor_1
      Post_1,/path/to/Post_1/filtered_feature_bc_matrix,Post,Patient_1

    """.stripIndent()
    exit 0
}

// ─── Validate Required Params & Detect Input Mode ────────────────────────────
def mode_input     = params.input      && params.input      != ""
def mode_matrix    = params.matrix     && params.matrix     != ""
def mode_seurat    = params.seurat_rds && params.seurat_rds != ""
def mode_nichenet  = params.nichenet_rds && params.nichenet_rds != ""
def mode_copykat   = params.copykat_rds  && params.copykat_rds  != ""

// Count how many primary modes are active
def n_modes = [mode_input, mode_matrix, mode_seurat].count { it == true }

if (!mode_input && !mode_matrix && !mode_seurat && !mode_nichenet && !mode_copykat) {
    error """
    ╔══════════════════════════════════════════════════════════════════════╗
    ║  ERROR: No input provided. Please specify one of:                   ║
    ║                                                                      ║
    ║  --input   samples.csv        Full pipeline from raw FASTQs          ║
    ║  --matrix  matrix_samples.csv Start from 10X MEX count matrices     ║
    ║  --seurat_rds merged.rds      Start from a merged Seurat object      ║
    ║                                                                      ║
    ║  Run with --help for full usage information.                         ║
    ╚══════════════════════════════════════════════════════════════════════╝
    """
}

if (n_modes > 1) {
    error "ERROR: Multiple input modes provided. Please use only one of --input, --matrix, or --seurat_rds."
}

if (mode_input && !params.ref_human && !params.skip_cellranger) {
    log.warn "WARNING: --ref_human not set. CellRanger will fail unless you also pass --skip_cellranger."
}

// ─── Log Pipeline Header ─────────────────────────────────────────────────────
def active_input_mode = mode_matrix ? "Matrix CSV (--matrix)" :
                        mode_seurat ? "Seurat RDS (--seurat_rds)" :
                        mode_input  ? "Samplesheet (--input)" :
                        mode_nichenet ? "NicheNet-only" : "CopyKAT-only"

if (workflow.commandLine.contains("NICHENET_ONLY")) {
    log.info """
    ╔══════════════════════════════════════════════════════════════════════╗
    ║   NicheNet Regulatory Analysis (Part 10 – Standalone)               ║
    ╠══════════════════════════════════════════════════════════════════════╣
    ║  Input RDS    : ${params.nichenet_rds}
    ║  Receiver     : ${params.nichenet_receiver}
    ║  Senders      : ${params.nichenet_sender}
    ║  Condition    : ${params.nichenet_condition_oi} vs ${params.nichenet_condition_ref}
    ╚══════════════════════════════════════════════════════════════════════╝
    """.stripIndent()
} else if (workflow.commandLine.contains("COPYKAT_ONLY")) {
    log.info """
    ╔══════════════════════════════════════════════════════════════════════╗
    ║   CopyKAT CNV Analysis (Part 11 – Standalone)                       ║
    ╠══════════════════════════════════════════════════════════════════════╣
    ║  Input RDS    : ${params.copykat_rds}
    ║  Genome       : ${params.copykat_genome}
    ╚══════════════════════════════════════════════════════════════════════╝
    """.stripIndent()
} else {
    log.info """
    ╔══════════════════════════════════════════════════════════════════════╗
    ║   scRNA-seq Complete Pipeline  v3.0.0  •  Nextflow DSL2  •  1–11   ║
    ╠══════════════════════════════════════════════════════════════════════╣
    ║  Input Mode    : ${active_input_mode}
    ║  Input         : ${params.input ?: params.matrix ?: params.seurat_rds}
    ║  Output        : ${params.outdir}
    ║  Ref (human)   : ${params.ref_human ?: '(not set)'}
    ╠══════════════════════════════════════════════════════════════════════╣
    ║  Skip CellRngr : ${params.skip_cellranger}
    ║  Skip PDX      : ${params.skip_pdx}
    ║  Skip QC       : ${params.skip_qc}
    ║  Skip Integrtn : ${params.skip_integration}
    ║  Skip Annot    : ${params.skip_annotation}
    ║  Skip DE       : ${params.skip_de}
    ║  Skip Traj.    : ${params.skip_trajectory}
    ║  Skip CellChat : ${params.skip_cellchat}
    ║  Skip NicheNet : ${params.skip_nichenet}
    ║  Skip CopyKAT  : ${params.skip_copykat}
    ╚══════════════════════════════════════════════════════════════════════╝
    """.stripIndent()
}

// ============================================================================
//  PROCESS 1: DOWNLOAD SRA (optional)
// ============================================================================
process DOWNLOAD_SRA {
    tag "\$sample_id"
    publishDir "${params.outdir}/00_fastq/${sample_id}", mode: 'copy'
    label 'process_medium'
    input:  tuple val(sample_id), val(sra_id)
    output: tuple val(sample_id), path("*.fastq.gz"), emit: fastqs
    script:
    """
    prefetch ${sra_id} --output-directory .
    fasterq-dump ${sra_id}/${sra_id}.sra --split-files --include-technical --threads ${task.cpus} --outdir .
    gzip *.fastq
    mv ${sra_id}_1.fastq.gz ${sample_id}_S1_L001_R1_001.fastq.gz || true
    mv ${sra_id}_2.fastq.gz ${sample_id}_S1_L001_R2_001.fastq.gz || true
    rm -rf ${sra_id}
    """
}

// ============================================================================
//  PROCESS 2: CELLRANGER COUNT (Part 1)
// ============================================================================
process CELLRANGER_COUNT {
    tag "\$sample_id"
    publishDir "${params.outdir}/01_cellranger", mode: 'copy'
    label 'process_high'
    input:  tuple val(sample_id), path(fastq_dir)
    output: tuple val(sample_id), path("${sample_id}/outs"), emit: outs
    script:
    """
    cellranger count --id=${sample_id} --fastqs=${fastq_dir} --sample=${sample_id} \
        --transcriptome=${params.ref_human} --localcores=${task.cpus} --localmem=${task.memory.toGiga()} \
        --expect-cells=${params.expect_cells} --chemistry=${params.chemistry} --create-bam false
    """
}

// ============================================================================
//  PROCESS 3: PDX PROCESSING (Part 8) – optional
//  NOTE: Use --skip_pdx for standard human samples (e.g., GSE174609)
//  Only enable for human-mouse xenograft (PDX) experiments
// ============================================================================
process PDX_PROCESSING {
    tag "\$sample_id"
    publishDir "${params.outdir}/08_pdx/${sample_id}", mode: 'copy'
    label 'process_medium'
    input:  tuple val(sample_id), path(outs)
    output: tuple val(sample_id), path("${sample_id}_human_clean.rds"), emit: human_rds
            tuple val(sample_id), path("${sample_id}_mouse_clean.rds"), optional: true, emit: mouse_rds
            path "plots/*.png", optional: true
    script:
    // Write R script to a file and call it — avoids heredoc-in-heredoc issues
    """
    mkdir -p plots

    cat > pdx_script.R << 'ENDSCRIPT'
    suppressPackageStartupMessages({
        library(Seurat)
        library(data.table)
        library(ggplot2)
        library(dplyr)
        library(patchwork)
    })
    outs_dir    <- commandArgs(trailingOnly=TRUE)[1]
    sample_id   <- commandArgs(trailingOnly=TRUE)[2]
    class_file  <- file.path(outs_dir, "analysis/gem_classification.csv")

    if (!file.exists(class_file)) {
        message("Standard human sample – creating passthrough Seurat object")
        mat <- Read10X(file.path(outs_dir, "filtered_feature_bc_matrix"))
        se  <- CreateSeuratObject(mat, project = sample_id)
        saveRDS(se, paste0(sample_id, "_human_clean.rds"))
    } else {
        message("PDX sample detected – demultiplexing species (Strategy 1)")
        gem    <- fread(class_file)
        counts <- Read10X(file.path(outs_dir, "filtered_feature_bc_matrix"))

        # Calculate metrics for plotting
        gem[, total_reads := GRCh38 + GRCm39]
        gem[, mouse_ratio := GRCm39 / total_reads]
        species_colors <- c("GRCh38" = "#E63946", "GRCm39" = "#457B9D", "Multiplet" = "#A8DADC")

        # Plot 1: Species Composition
        p1 <- ggplot(gem[, .N, by = call][, pct := round(N / sum(N) * 100, 1)], aes(x = call, y = pct, fill = call)) +
              geom_col() + geom_text(aes(label = paste0(pct, "%\n(n=", N, ")")), vjust = -0.5) +
              scale_fill_manual(values = species_colors) + labs(title = "Species Composition", x = "Call", y = "Percent (%)") +
              theme_classic() + theme(legend.position = "none")

        # Plot 2: Scatter
        p2 <- ggplot(gem, aes(x = GRCh38 + 1, y = GRCm39 + 1, color = call)) +
              geom_point(alpha = 0.3, size = 0.4) + scale_color_manual(values = species_colors) +
              scale_x_log10() + scale_y_log10() + labs(title = "Human vs Mouse Reads", x = "Human Reads", y = "Mouse Reads") +
              theme_classic()

        # Plot 3: Distribution
        p3 <- ggplot(gem, aes(x = mouse_ratio, fill = call)) +
              geom_histogram(bins = 100) + scale_fill_manual(values = species_colors) +
              labs(title = "Mouse Read Fraction", x = "Ratio (Mouse/Total)", y = "Cells") +
              theme_classic()

        # Plot 4: UMI Depth
        p4 <- ggplot(gem[call != "Multiplet"], aes(x = call, y = total_reads, fill = call)) +
              geom_violin() + geom_boxplot(width = 0.1, fill = "white") + scale_y_log10() +
              scale_fill_manual(values = species_colors) + labs(title = "UMI Depth", y = "Total Reads") +
              theme_classic() + theme(legend.position = "none")

        if (requireNamespace("patchwork", quietly = TRUE)) {
            combined_plot <- (p1 | p2) / (p3 | p4)
            ggsave("plots/01_pdx_contamination_qc.png", combined_plot, width = 12, height = 9)
        } else {
            ggsave("plots/01_species_composition.png", p1, width = 6, height = 4)
        }

        # Print Summary Report
        total_cells  <- nrow(gem)
        human_cells  <- gem[call == "GRCh38", .N]
        mouse_cells  <- gem[call == "GRCm39",  .N]
        multiplets   <- gem[call == "Multiplet", .N]
        cat("\n=== PDX Contamination Summary (", sample_id, ") ===\n")
        cat("Total cells called:   ", total_cells, "\n")
        cat("Human (GRCh38):       ", human_cells, sprintf("(%.1f%%)\n", human_cells / total_cells * 100))
        cat("Mouse (GRCm39):       ", mouse_cells, sprintf("(%.1f%%)\n", mouse_cells / total_cells * 100))
        cat("Multiplets:           ", multiplets, sprintf("(%.1f%%)\n", multiplets / total_cells * 100))
        cat("==============================================\n\n")

        # Demultiplex and Save
        human_bc   <- gem[call == "GRCh38", barcode]
        human_rows <- grep("^GRCh38_", rownames(counts), value = TRUE)
        human_mat  <- counts[human_rows, human_bc]
        rownames(human_mat) <- sub("^GRCh38_", "", rownames(human_mat))
        saveRDS(CreateSeuratObject(human_mat, project = paste0(sample_id, "_human")),
                paste0(sample_id, "_human_clean.rds"))

        mouse_bc   <- gem[call == "GRCm39", barcode]
        mouse_rows <- grep("^GRCm39_", rownames(counts), value = TRUE)
        if (length(mouse_bc) > 0) {
            mouse_mat <- counts[mouse_rows, mouse_bc]
            rownames(mouse_mat) <- sub("^GRCm39_", "", rownames(mouse_mat))
            saveRDS(CreateSeuratObject(mouse_mat, project = paste0(sample_id, "_mouse")),
                    paste0(sample_id, "_mouse_clean.rds"))
        }
    }
    ENDSCRIPT

    Rscript pdx_script.R "${outs}" "${sample_id}"
    """
}

// ============================================================================
//  PROCESS 4: QC FILTERING (Part 2)
// ============================================================================
process QC_FILTERING {
    tag "\$sample_id"
    publishDir "${params.outdir}/02_qc/${sample_id}", mode: 'copy'
    label 'process_medium'
    errorStrategy 'ignore'
    input:  tuple val(sample_id), path(outs_or_rds), val(condition), val(patient_id)
    output: tuple val(sample_id), path("${sample_id}_qc.rds"), emit: rds
            path "plots/*.png"
            path "qc_summary.csv"
    script:
    def cond = condition ?: "Unknown"
    def patient = patient_id ?: "Unknown"
    """
    mkdir -p plots

    cat > qc_script.R << 'ENDSCRIPT'
# Prevent OpenBLAS/MKL thread contention
Sys.setenv(OPENBLAS_NUM_THREADS=4, OMP_NUM_THREADS=4, R_MAX_NUM_THREADS=4)

# Defensive installations
if (!requireNamespace("BiocManager", quietly = TRUE)) install.packages("BiocManager", repos="http://cran.us.r-project.org")
if (!requireNamespace("BiocParallel", quietly = TRUE)) BiocManager::install("BiocParallel")
if (!requireNamespace("DropletUtils", quietly = TRUE)) BiocManager::install("DropletUtils")
if (!requireNamespace("SoupX", quietly = TRUE)) install.packages("SoupX", repos="http://cran.us.r-project.org")
if (!requireNamespace("scDblFinder", quietly = TRUE)) BiocManager::install("scDblFinder")
if (!requireNamespace("data.table", quietly = TRUE)) install.packages("data.table", repos="http://cran.us.r-project.org")

suppressPackageStartupMessages(library(BiocParallel))
# Disable Bioconductor parallelization entirely to prevent OpenBLAS forking deadlocks!
register(SerialParam())

suppressPackageStartupMessages({
    library(Seurat)
    library(DropletUtils)
    library(SoupX)
    library(scDblFinder)
    library(SingleCellExperiment)
    library(ggplot2)
    library(dplyr)
    library(patchwork)
})

args       <- commandArgs(trailingOnly=TRUE)
sample_id  <- args[1]
cond       <- args[2]
patient    <- args[3]
input_path <- args[4]

# New QC parameters
min_genes  <- as.numeric(args[5])
max_genes  <- as.numeric(args[6])
min_umi    <- as.numeric(args[7])
max_umi    <- as.numeric(args[8])
max_mt     <- as.numeric(args[9])
norm_method <- args[10]
norm_features <- as.numeric(args[11])

message(paste("Processing sample:", sample_id, "Method:", norm_method))

dir.create("plots", showWarnings = FALSE)
set.seed(42)
rho <- NA  # default; set by SoupX branch if used

# ── STEP 1: Load Data ────────────────────────────────────────────────────────
# Detect plain dense text matrix files (.txt.gz, .tsv.gz, .csv.gz, .txt, .tsv)
find_dense_matrix <- function(path) {
    patterns <- c('[.]txt[.]gz\$', '[.]tsv[.]gz\$', '[.]csv[.]gz\$', '[.]txt\$', '[.]tsv\$', '[.]csv\$')
    # Case 1: The path itself is a matching file
    for (pat in patterns) {
        if (grepl(pat, path)) return(path)
    }
    # Case 2: The path is a directory containing a matching file
    if (dir.exists(path)) {
        for (pat in patterns) {
            hits <- list.files(path, pattern = pat, full.names = TRUE)
            if (length(hits) > 0) return(hits[1])
        }
    }
    return(NULL)
}

robust_read10x <- function(path) {
    tryCatch({
        Read10X(path)
    }, error = function(e) {
        message("Read10X failed with default params. Trying gene.column = 1...")
        Read10X(path, gene.column = 1)
    })
}

if (endsWith(input_path, ".rds")) {
    se <- readRDS(input_path)
    se\$sample_id  <- sample_id
    se\$condition  <- cond
    se\$patient_id <- patient
    message("Loaded RDS. Skipping EmptyDrops/SoupX.")
} else {
    raw_dir  <- file.path(input_path, "raw_feature_bc_matrix")
    filt_dir <- file.path(input_path, "filtered_feature_bc_matrix")
    dense_file <- find_dense_matrix(input_path)

    if (dir.exists(raw_dir)) {
        message("10X raw_feature_bc_matrix found. Running Full QC with EmptyDrops + SoupX.")
        raw_counts <- robust_read10x(raw_dir)

        # ── Empty Droplet Detection ──
        sce   <- SingleCellExperiment(list(counts = raw_counts))
        e_out <- emptyDrops(counts(sce), lower = 100)
        is_cell <- e_out\$FDR < 0.01
        is_cell[is.na(is_cell)] <- FALSE

        # Plot 01: EmptyDrops Classification
        empty_df <- data.frame(total_umi = colSums(raw_counts), is_cell = is_cell)
        p1 <- ggplot(empty_df, aes(x = log10(total_umi + 1), fill = is_cell)) +
              geom_histogram(bins = 50, alpha = 0.7, position = "identity") +
              scale_fill_manual(values = c("TRUE" = "#2E86AB", "FALSE" = "#A23B72"),
                                labels = c("Empty", "Cell"), name = "Type") +
              labs(title = "EmptyDrops Detection", x = "log10(UMI + 1)", y = "Count") +
              theme_classic()
        ggsave("plots/01_empty_droplets.png", p1, width = 8, height = 5)

        # ── SoupX Ambient RNA Correction ──
        toc <- raw_counts[, is_cell]
        sc  <- SoupChannel(tod = raw_counts, toc = toc)
        tmp <- CreateSeuratObject(toc) %>% NormalizeData() %>% FindVariableFeatures() %>%
               ScaleData() %>% RunPCA() %>% FindNeighbors(dims = 1:20) %>%
               FindClusters(resolution = 0.5, verbose = FALSE)
        sc  <- setClusters(sc, setNames(as.character(tmp\$seurat_clusters), colnames(tmp)))
        sc  <- tryCatch({ autoEstCont(sc, verbose = FALSE) },
                        error = function(e) { sc\$fit\$rho <- 0.05; sc })
        rho <- if (is.null(sc\$fit\$rho)) 0.05 else as.numeric(sc\$fit\$rho)
        final_counts <- if (rho > 0.02) adjustCounts(sc, verbose = FALSE) else toc

        se <- CreateSeuratObject(final_counts, project = sample_id)
        se\$sample_id  <- sample_id
        se\$condition  <- cond
        se\$patient_id <- patient

    } else if (dir.exists(filt_dir)) {
        message("10X filtered_feature_bc_matrix found. Loading with robust_read10x.")
        se <- CreateSeuratObject(robust_read10x(filt_dir), project = sample_id)
        se\$sample_id  <- sample_id
        se\$condition  <- cond
        se\$patient_id <- patient

    } else if (file.exists(file.path(input_path, "matrix.mtx")) || file.exists(file.path(input_path, "matrix.mtx.gz"))) {
        message("10X matrix found directly in input path. Loading with robust_read10x.")
        se <- CreateSeuratObject(robust_read10x(input_path), project = sample_id)
        se\$sample_id  <- sample_id
        se\$condition  <- cond
        se\$patient_id <- patient

    } else if (!is.null(dense_file)) {
                # ── Dense text matrix branch ─────────
        message(paste("Dense text matrix detected:", dense_file))
        
        # Read first line to detect separator
        first_line <- readLines(dense_file, n = 1)
        sep_char <- if (grepl(",", first_line)) "," else "	"
        message(paste("Detected separator:", if(sep_char==",") "comma" else "tab"))

        message("Using data.table::fread for fast reading...")
        dt <- data.table::fread(dense_file, sep = sep_char, header = TRUE, nThread = 4)
        mat_raw <- as.data.frame(dt)
        rownames(mat_raw) <- mat_raw[[1]]
        mat_raw <- mat_raw[, -1, drop=FALSE]
        
        # Robustness check: Ensure we have more than 1 cell
        if (ncol(mat_raw) < 2) {
            stop(paste("Matrix in", dense_file, "only has", ncol(mat_raw), "cells. This looks like a bulk count file, not a single-cell matrix. Skipping."))
        }
        
        # Convert to matrix
        mat_raw <- as.matrix(mat_raw)
        
        # Handle non-numeric values
        if (!is.numeric(mat_raw)) {
            message("Warning: Matrix contains non-numeric values. Coercing to numeric...")
            mat_raw_dimnames <- dimnames(mat_raw)
            mat_raw <- matrix(as.numeric(mat_raw), nrow = nrow(mat_raw))
            dimnames(mat_raw) <- mat_raw_dimnames
            mat_raw[is.na(mat_raw)] <- 0
        }

        # Auto-detect orientation: if significantly more columns than rows, it's likely cells x genes
        if (ncol(mat_raw) > nrow(mat_raw) * 2) {
            message("Matrix appears to be cells x genes - transposing to genes x cells.")
            mat_raw <- t(mat_raw)
        }

        message(paste("Final matrix dimensions:", nrow(mat_raw), "genes x", ncol(mat_raw), "cells"))

        # Ensure cell names are unique
        colnames(mat_raw) <- make.unique(colnames(mat_raw))

        library(Matrix)
        count_mat <- as(mat_raw, "dgCMatrix")

        # Create Seurat object
        se <- CreateSeuratObject(counts = count_mat, project = sample_id)
        se$sample_id  <- sample_id
        se$condition  <- cond
        se$patient_id <- patient
        message(paste("Successfully created Seurat object for", sample_id))

    } else {
        stop(paste0(
            "ERROR: No recognised input found in directory: ", input_path, "\n",
            "Expected one of:\n",
            "  • raw_feature_bc_matrix/   (10X MEX raw)\n",
            "  • filtered_feature_bc_matrix/  (10X MEX filtered)\n",
            "  • *.txt.gz / *.tsv.gz / *.csv.gz  (dense text matrix)\n",
            "  • *.rds                    (pre-built Seurat object)"
        ))
    }
}

# ── STEP 2: Metrics ──────────────────────────────────────────────────────────
se[["percent.mt"]]   <- PercentageFeatureSet(se, pattern = "^MT-")
se[["percent.ribo"]] <- PercentageFeatureSet(se, pattern = "^RP[SL]")

# ── STEP 3: Doublets ─────────────────────────────────────────────────────────
se <- JoinLayers(se)
sce <- scDblFinder(as.SingleCellExperiment(se))
se\$doublet_class <- sce\$scDblFinder.class
se\$doublet_score <- sce\$scDblFinder.score

# Plot 02: Doublets on UMAP
tmp_umap <- se %>% NormalizeData(verbose=F) %>% FindVariableFeatures(verbose=F) %>% 
            ScaleData(verbose=F) %>% RunPCA(verbose=F) %>% RunUMAP(dims=1:20, verbose=F)
p2 <- DimPlot(tmp_umap, group.by = "doublet_class", cols = c("singlet" = "#90E0EF", "doublet" = "#EF233C")) + 
      labs(title = paste0("Doublet Detection (", round(sum(se\$doublet_class=="doublet")/ncol(se)*100, 1), "%)")) + theme_classic()
ggsave("plots/02_doublets_umap.png", p2, width = 8, height = 7)

# Remove doublets
se <- subset(se, doublet_class == "singlet")

# ── STEP 4: Cell-Level Filtering ─────────────────────────────────────────────
# Plot 03: QC Violins
p3 <- VlnPlot(se, features = c("nCount_RNA", "nFeature_RNA", "percent.mt", "percent.ribo"), ncol = 4, pt.size = 0.1) & theme(plot.title = element_text(size=10))
ggsave("plots/03_qc_violins.png", p3, width = 16, height = 4)

# Plot 04: QC Scatters
p4a <- FeatureScatter(se, feature1 = "nCount_RNA", feature2 = "nFeature_RNA")
p4b <- FeatureScatter(se, feature1 = "nCount_RNA", feature2 = "percent.mt")
p4c <- FeatureScatter(se, feature1 = "percent.mt", feature2 = "percent.ribo")
ggsave("plots/04_qc_scatter.png", (p4a + p4b + p4c), width = 15, height = 5)

# Filtering
# Thresholds: nFeature [500,5000], nCount [800,20000], MT < 10%
qc_df <- se@meta.data
qc_df\$pass_qc <- (qc_df\$nFeature_RNA >= min_genes & qc_df\$nFeature_RNA <= max_genes & 
                  qc_df\$nCount_RNA >= min_umi   & qc_df\$nCount_RNA <= max_umi   &
                  qc_df\$percent.mt < max_mt)

# Plot 05: Filtering Thresholds
p5 <- ggplot(qc_df, aes(x = log10(nCount_RNA + 1), y = log10(nFeature_RNA + 1), color = pass_qc)) +
      geom_point(alpha = 0.5, size = 1) +
      geom_vline(xintercept = log10(c(min_umi, max_umi)), linetype = "dashed", color = "red") +
      geom_hline(yintercept = log10(c(min_genes, max_genes)), linetype = "dashed", color = "red") +
      scale_color_manual(values = c("TRUE" = "#06D6A0", "FALSE" = "#EF476F")) +
      labs(title = "Cell Filtering Thresholds", x = "log10(UMI + 1)", y = "log10(Genes + 1)") + theme_classic()
ggsave("plots/05_filtering_thresholds.png", p5, width = 8, height = 7)

se <- subset(se, nFeature_RNA >= min_genes & nFeature_RNA <= max_genes & 
                 nCount_RNA >= min_umi   & nCount_RNA <= max_umi   &
                 percent.mt < max_mt)

# ── STEP 5: Gene-Level Filtering ─────────────────────────────────────────────
gene_counts <- rowSums(GetAssayData(se, layer = "counts") > 0)
gene_qc <- data.frame(gene = rownames(se), pct_cells = (gene_counts/ncol(se))*100)

# Plot 06: Gene Detection
p6 <- ggplot(gene_qc, aes(x = pct_cells)) +
      geom_histogram(bins = 50, fill = "#118AB2", alpha = 0.7) +
      geom_vline(xintercept = 0.1, linetype = "dashed", color = "red") + scale_x_log10() +
      labs(title = "Gene Detection", subtitle = "0.1% thresholds", x = "% cells expressing gene", y = "Genes") + theme_classic()
ggsave("plots/06_gene_detection.png", p6, width = 8, height = 5)

# Apply Gene Filtering
min_cells <- ceiling(ncol(se) * 0.001)
gene_mask <- gene_counts >= min_cells
hb_genes  <- grep("^HB[AB]", rownames(se), value = TRUE)
gene_mask[hb_genes] <- FALSE
se <- se[names(gene_mask)[gene_mask], ]

# ── STEP 6: Normalization & Variable Features ────────────────────────────────
if (norm_method == "SCTransform") {
    se <- SCTransform(se, variable.features.n = norm_features, verbose=F)
} else if (norm_method == "scran") {
    library(scran)
    library(scater)
    sce <- as.SingleCellExperiment(se)
    clusters <- quickCluster(sce)
    sce <- computeSumFactors(sce, clusters=clusters)
    sce <- logNormCounts(sce)
    se <- as.Seurat(sce)
    se <- FindVariableFeatures(se, nfeatures = norm_features, verbose=F)
} else {
    se <- NormalizeData(se, verbose=F)
    se <- FindVariableFeatures(se, nfeatures = norm_features, verbose=F)
}

# Plot 07: Variable Features
top10 <- head(VariableFeatures(se), 10)
p7 <- VariableFeaturePlot(se)
p7 <- LabelPoints(plot = p7, points = top10, repel = TRUE)
ggsave("plots/07_variable_features.png", p7, width = 10, height = 7)

# Final RDS and Summary
saveRDS(se, paste0(sample_id, "_qc.rds"))
write.csv(se@meta.data, "cell_metadata.csv")
write.csv(data.frame(
    sample_id = sample_id,
    cells_final = ncol(se),
    genes_final = nrow(se),
    median_umi  = median(se\$nCount_RNA),
    median_genes = median(se\$nFeature_RNA),
    contamination_rho = rho
), "qc_summary.csv", row.names = FALSE)


message(paste("Full Workshop QC complete for", sample_id))
ENDSCRIPT

    Rscript qc_script.R "${sample_id}" "${cond}" "${patient}" "${outs_or_rds}" \
        ${params.min_genes} ${params.max_genes} ${params.min_umi} ${params.max_umi} ${params.max_mt} \
        ${params.norm_method} ${params.norm_features}
    """
}

// ============================================================================
//  PROCESS 5: INTEGRATION & CLUSTERING (Part 3)
// ============================================================================
process INTEGRATION_CLUSTERING {
    tag "all_samples"

    publishDir "${params.outdir}/03_clustering", mode: 'copy'
    label 'process_high'
    input:  path rds_files
    output: path "merged_clustered.rds", emit: rds
            path "plots/**/*.png"
            path "metadata/*.csv"
    script:
    """
    mkdir -p plots/integration_comparison plots/clustering metadata

    cat > cluster_script.R << 'ENDSCRIPT'
args <- commandArgs(trailingOnly = TRUE)
pca_dims     <- as.numeric(args[1])
pca_scale    <- as.logical(args[2])
tsne_perp    <- as.numeric(args[3])
umap_neigh   <- as.numeric(args[4])
umap_dist    <- as.numeric(args[5])
target_res   <- as.numeric(args[6])
cluster_alg  <- as.numeric(args[7])
cluster_test <- args[8]

options(future.globals.maxSize = 100 * 1024^3) # 100GB
# Defensive installations
if (!requireNamespace("harmony", quietly = TRUE)) install.packages("harmony", repos="http://cran.us.r-project.org")
if (!requireNamespace("FNN", quietly = TRUE)) install.packages("FNN", repos="http://cran.us.r-project.org")
if (!requireNamespace("cluster", quietly = TRUE)) install.packages("cluster", repos="http://cran.us.r-project.org")
if (!requireNamespace("reshape2", quietly = TRUE)) install.packages("reshape2", repos="http://cran.us.r-project.org")
if (!requireNamespace("ggrepel", quietly = TRUE)) install.packages("ggrepel", repos="http://cran.us.r-project.org")
if (!requireNamespace("BiocManager", quietly = TRUE)) install.packages("BiocManager", repos="http://cran.us.r-project.org")
if (!requireNamespace("batchelor", quietly = TRUE)) BiocManager::install("batchelor", update = FALSE)
if (!requireNamespace("SeuratWrappers", quietly = TRUE)) {
    if (!requireNamespace("remotes", quietly = TRUE)) install.packages("remotes", repos="http://cran.us.r-project.org")
    remotes::install_github('satijalab/seurat-wrappers', upgrade = "never")
}

suppressPackageStartupMessages({
    library(Seurat)
    library(SeuratWrappers)
    library(harmony)
    library(ggplot2)
    library(dplyr)
    library(patchwork)
    library(FNN)
    library(cluster)
    library(reshape2)
    library(ggrepel)
    library(batchelor)
})

# ── STEP 1: Load Data ────────────────────────────────────────────────────────
rds_files <- list.files(pattern = "_qc.rds\$", full.names = TRUE)
if (length(rds_files) == 0) rds_files <- list.files(pattern = ".rds\$", full.names = TRUE)
if (length(rds_files) == 0) stop("No RDS files found for integration!")

seurat_list <- lapply(rds_files, readRDS)
# Standardize features and Join/Split
seurat_list <- lapply(seurat_list, function(x) JoinLayers(x))
common_genes <- Reduce(intersect, lapply(seurat_list, rownames))
seurat_list  <- lapply(seurat_list, function(x) x[common_genes, ])

# ── STEP 2: Pre-Processing ───────────────────────────────────────────────────
merged <- merge(seurat_list[[1]], y = seurat_list[-1], add.cell.ids = sub("_qc.rds\$", "", basename(rds_files)))
merged <- JoinLayers(merged)

      # Robust metadata recovery
      for (col in c("sample_id", "condition", "patient_id")) {
          if (!col %in% colnames(merged@meta.data)) {
              message(paste("Recovering missing metadata column:", col))
              # Fallback to orig.ident or Unknown
              if (col == "sample_id") merged[[col]] <- as.character(merged\$orig.ident)
              else if (col == "condition") merged[[col]] <- "Unknown"
              else if (col == "patient_id") merged[[col]] <- "Unknown"
          }
      }
      # Re-split layers for integration
      merged[["RNA"]] <- split(merged[["RNA"]], f = merged\$sample_id)

merged <- NormalizeData(merged, verbose = FALSE) %>%
          FindVariableFeatures(nfeatures = 2000, verbose = FALSE) %>%
          ScaleData(do.scale = pca_scale, verbose = FALSE) %>%
          RunPCA(npcs = pca_dims, verbose = FALSE)

# Baseline UMAP (Naive)
merged <- RunUMAP(merged, dims = 1:pca_dims, reduction = "pca", reduction.name = "umap.naive", n.neighbors = umap_neigh, min.dist = umap_dist, verbose = FALSE)

# ── STEP 3: Multi-Method Integration ─────────────────────────────────────────
features_to_use <- VariableFeatures(merged)
integrated <- merged

message("Running CCA Integration...")
try({
    integrated <- IntegrateLayers(
        object = integrated, method = CCAIntegration,
        orig.reduction = "pca", new.reduction = "integrated.cca",
        features = features_to_use, dims = 1:30, verbose = FALSE
    )
}, silent = FALSE)

message("Running RPCA Integration...")
try({
    integrated <- IntegrateLayers(
        object = integrated, method = RPCAIntegration,
        orig.reduction = "pca", new.reduction = "integrated.rpca",
        features = features_to_use, dims = 1:30, verbose = FALSE
    )
}, silent = FALSE)

message("Running Harmony Integration...")
try({
    integrated <- IntegrateLayers(
        object = integrated, method = HarmonyIntegration,
        orig.reduction = "pca", new.reduction = "harmony",
        features = features_to_use, dims = 1:30, verbose = FALSE
    )
}, silent = FALSE)

message("Running FastMNN Integration...")
fastmnn_success <- FALSE
tryCatch({
    integrated <- IntegrateLayers(
        object = integrated, method = FastMNNIntegration,
        orig.reduction = "pca", new.reduction = "integrated.mnn",
        features = features_to_use, dims = 1:30, verbose = FALSE
    )
    fastmnn_success <- TRUE
}, error = function(e) {
    message(paste("Integration wrapper failed:", e\$message))
    # Attempting direct RunFastMNN fallback
    tryCatch({
        # Ensure our list of objects has the same genes
        mnf_features <- features_to_use
        mnn_list <- seurat_list
        mnn_embedding <- RunFastMNN(object.list = mnn_list, features = mnf_features, verbose = FALSE)
        
        # Mapping back using a robust approach
        # RunFastMNN prefixing can be tricky, so we'll match by original cell name if possible
        # Or just trust the order if we didn't reorder
        new_embeddings <- Embeddings(mnn_embedding, reduction = "mnn")
        # Ensure we have the right rownames
        if (all(colnames(integrated) %in% rownames(new_embeddings))) {
            integrated[["integrated.mnn"]] <- CreateDimReducObject(
                embeddings = new_embeddings[colnames(integrated), ],
                key = "mnn_", assay = "RNA"
            )
            fastmnn_success <- TRUE
            message("FastMNN fallback successful.")
        } else {
            message("FastMNN fallback failed: Cell names don't match after RunFastMNN.")
        }
    }, error = function(e2) {
        message(paste("FastMNN fully failed:", e2\$message))
    })
})

# ── STEP 4: Metrics & Plotting ───────────────────────────────────────────────
# Define available reductions
available_reds <- Filter(function(r) r %in% Reductions(integrated), 
                         c("integrated.cca", "integrated.rpca", "harmony", "integrated.mnn"))

# Generate UMAPs for all available
for (red in available_reds) {
    umap_name <- gsub("integrated", "umap", red)
    if (red == "harmony") umap_name <- "umap.harmony"
    integrated <- RunUMAP(integrated, reduction = red, dims = 1:pca_dims, 
                          reduction.name = umap_name, n.neighbors = umap_neigh, 
                          min.dist = umap_dist, verbose = FALSE)
}

# Mixing & Separation Functions
calculate_mixing <- function(obj, red, group = "sample_id") {
    if (!(red %in% Reductions(obj))) return(0)
    embedding <- Embeddings(obj, reduction = red)
    nn <- FNN::get.knn(embedding[, 1:min(30, ncol(embedding))], k = 50)
    labels <- obj@meta.data[[group]]
    scores <- sapply(1:nrow(nn\$nn.index), function(i) {
        props <- table(labels[nn\$nn.index[i, ]]) / 50
        1/sum(props^2)
    })
    return(mean(scores))
}

calculate_separation <- function(obj, umap_red) {
    if (!(umap_red %in% Reductions(obj))) return(0)
    coords <- Embeddings(obj, reduction = umap_red)[, 1:2]
    conds <- obj\$condition
    if (length(unique(conds)) < 2) return(0)
    centers <- aggregate(coords, by = list(conds), FUN = mean)
    return(as.numeric(dist(centers[, -1])))
}

# Compile Results
results_df <- data.frame(method = c("Naive", available_reds), mixing = 0, separation = 0)
for (i in 1:nrow(results_df)) {
    m <- results_df\$method[i]
    red <- if(m == "Naive") "pca" else m
    
    # Simpler UMAP name lookup
    umap <- gsub("integrated", "umap", red)
    if (red == "harmony") umap <- "umap.harmony"
    if (m == "Naive") umap <- "umap.naive"
    
    results_df\$mixing[i] <- calculate_mixing(integrated, red)
    results_df\$separation[i] <- calculate_separation(integrated, umap)
}

write.csv(results_df, "metadata/integration_metrics.csv", row.names = FALSE)
best_method <- results_df\$method[which.max(results_df\$mixing)]
message(paste("Best method detected:", best_method))
reduction_final <- if(best_method == "Naive") "pca" else best_method

# Final UMAP name for downstream
umap_final <- gsub("integrated", "umap", reduction_final)
if (reduction_final == "harmony") umap_final <- "umap.harmony"
if (best_method == "Naive") umap_final <- "umap.naive"

# ── PLOTS ────────────────────────────────────────────────────────────────────
make_p <- function(red, title, grp = "sample_id") {
    if(!(red %in% Reductions(integrated))) return(plot_spacer() + ggtitle(paste(title, "(Failed)")))
    DimPlot(integrated, reduction = red, group.by = grp, pt.size = 0.1) + NoLegend() + ggtitle(title)
}

# Comparison UMAPs
p_samp <- (make_p("umap.naive", "Naive") | make_p("umap.cca", "CCA") | make_p("umap.rpca", "RPCA")) /
          (make_p("umap.harmony", "Harmony") | make_p("umap.mnn", "FastMNN") | plot_spacer())
ggsave("plots/integration_comparison/02_by_sample.png", p_samp, width = 15, height = 10)

  if (!"condition" %in% colnames(integrated@meta.data)) integrated\$condition <- "Unknown"
  p_cond <- (make_p("umap.naive", "Naive", "condition") | make_p("umap.cca", "CCA", "condition") | make_p("umap.rpca", "RPCA", "condition")) /
          (make_p("umap.harmony", "Harmony", "condition") | make_p("umap.mnn", "FastMNN", "condition") | plot_spacer())
ggsave("plots/integration_comparison/03_by_condition.png", p_cond, width = 15, height = 10)

p_trade <- ggplot(results_df, aes(x = mixing, y = separation, label = method)) +
           geom_point(aes(color = method), size = 4) + geom_text_repel() + theme_minimal() +
           labs(title = "Integration Benchmarking", x = "Mixing Score", y = "Bio Preservation")
ggsave("plots/integration_comparison/04_metrics_tradeoff.png", p_trade, width = 8, height = 6)

# ── STEP 5: Optimize Clustering ──────────────────────────────────────────────
resolutions <- c(0.4, 0.6, 0.8, 1.0, 1.2)
integrated <- FindNeighbors(integrated, reduction = reduction_final, dims = 1:30, verbose = FALSE)

set.seed(42)
cells_sub <- min(5000, ncol(integrated))
sub_idx <- sample(1:ncol(integrated), cells_sub)
dist_mtx <- dist(Embeddings(integrated, reduction = reduction_final)[sub_idx, 1:min(30, ncol(Embeddings(integrated, reduction = reduction_final)))])

# Optimization Loop around Target Resolution
res_range <- unique(c(target_res, seq(max(0.1, target_res-0.4), min(2.0, target_res+0.4), by=0.1)))
sil_df <- data.frame(res = res_range, score = 0)
for (i in 1:nrow(sil_df)) {
    integrated <- FindClusters(integrated, resolution = sil_df\$res[i], algorithm = cluster_alg, verbose = FALSE)
    res_col <- paste0("RNA_snn_res.", sil_df\$res[i])
    clus <- as.numeric(integrated@meta.data[[res_col]][sub_idx])
    if (length(unique(clus)) > 1) {
        sil <- silhouette(clus, dist_mtx)
        sil_df\$score[i] <- mean(sil[, 3])
    }
}
write.csv(sil_df, "metadata/clustering_optimization.csv", row.names = FALSE)
opt_res <- sil_df\$res[which.max(sil_df\$score)]
integrated\$seurat_clusters <- integrated@meta.data[[paste0("RNA_snn_res.", opt_res)]]
Idents(integrated) <- "seurat_clusters"

# Final Plots
ggsave("plots/clustering/10_final_clusters.png", DimPlot(integrated, reduction = umap_final, label = TRUE), width = 10, height = 8)

sample_table <- as.data.frame(prop.table(table(integrated\$seurat_clusters, integrated\$sample_id), margin = 1) * 100)
colnames(sample_table) <- c("Cluster", "Sample", "Pct")
ggsave("plots/clustering/08_sample_distribution.png", ggplot(sample_table, aes(x=Cluster, y=Pct, fill=Sample)) + geom_bar(stat="identity") + theme_classic(), width = 12, height = 6)

cond_table <- as.data.frame(prop.table(table(integrated\$seurat_clusters, integrated\$condition), margin = 1) * 100)
colnames(cond_table) <- c("Cluster", "Condition", "Pct")
ggsave("plots/clustering/09_condition_distribution.png", ggplot(cond_table, aes(x=Cluster, y=Pct, fill=Condition)) + geom_bar(stat="identity") + theme_classic(), width = 12, height = 6)

# Finalize
integrated <- JoinLayers(integrated)
saveRDS(integrated, "merged_clustered.rds")
message(paste("Integration complete. Opt Res:", opt_res, "Method:", best_method))
ENDSCRIPT

    Rscript cluster_script.R ${params.pca_dims} ${params.pca_scale} ${params.tsne_perp} ${params.umap_neighbors} ${params.umap_mindist} ${params.cluster_res} ${params.cluster_alg} ${params.cluster_test}
    """
}

process CELL_ANNOTATION {
    tag "all_samples"
    label 'process_high'
    publishDir "${params.outdir}/04_annotation", mode: 'copy'

    input:
    path rds
    val sample_list

    output:
    path "integrated_annotated.rds", emit: rds
    path "plots/manual_annotation/*.png", emit: plots_manual
    path "plots/automated_annotation/*.png", emit: plots_auto, optional: true
    path "plots/method_comparison/*.png", emit: plots_comp
    path "annotations/*.csv", emit: csvs

    script:
    """
    mkdir -p plots/manual_annotation plots/automated_annotation plots/method_comparison annotations
    touch plots/automated_annotation/placeholder.png

    printf '%s' "${rds}"         > .rds_path.txt
    printf '%s' "${sample_list}" > .sample_list.txt

    cat > annotate_script.R << 'ENDSCRIPT'
    options(future.globals.maxSize = 100 * 1024^3)
    set.seed(42)
    libs <- c("SingleR","celldex","SingleCellExperiment","scCATCH","HGNChelper","openxlsx","ggalluvial","scales","viridis")
    for (lib in libs) {
        if (!requireNamespace(lib, quietly = TRUE)) {
            if (lib %in% c("SingleR","celldex","SingleCellExperiment")) {
                BiocManager::install(lib, update = FALSE)
            } else { install.packages(lib, repos="http://cran.us.r-project.org") }
        }
    }
    suppressPackageStartupMessages({
        library(Seurat); library(SingleR); library(celldex); library(scCATCH)
        library(SingleCellExperiment); library(HGNChelper); library(openxlsx)
        library(ggplot2); library(ggalluvial); library(dplyr); library(patchwork)
        library(scales); library(viridis)
    })
    theme_set(theme_classic(base_size = 12))
    rds_path      <- trimws(readLines(".rds_path.txt"))
    sample_list_s <- trimws(readLines(".sample_list.txt"))
    obj <- readRDS(rds_path)
    target_samples <- unlist(strsplit(sample_list_s, ","))
    message(paste("Available samples:", paste(unique(obj\$sample_id), collapse=", ")))
    message(paste("Target samples:", paste(target_samples, collapse=", ")))
    obj <- subset(obj, subset = sample_id %in% target_samples)
    if (ncol(obj) == 0) stop("ERROR: No cells remain after subsetting!")
    message(paste("Cells kept:", ncol(obj)))
    DefaultAssay(obj) <- "RNA"
    obj <- JoinLayers(obj)
    obj <- NormalizeData(obj, verbose=FALSE)
    obj <- ScaleData(obj, features=rownames(obj), verbose=FALSE)
    avail_reds <- names(obj@reductions)
    umap_red <- if("umap.harmony" %in% avail_reds) "umap.harmony" else
                if("umap.cca"     %in% avail_reds) "umap.cca"     else
                if("umap.rpca"    %in% avail_reds) "umap.rpca"    else
                if("umap.mnn"     %in% avail_reds) "umap.mnn"     else "umap"
    message(paste("Using UMAP:", umap_red))
    canonical_markers <- list(
        # ── Immune markers (blood datasets) ──────────────────────────
        "T_cells"           = c("CD3D","CD3E","CD3G"),
        "CD4_T"             = c("CD3D","CD4","IL7R"),
        "CD8_T"             = c("CD3D","CD8A","CD8B"),
        "B_cells"           = c("CD79A","MS4A1","CD19"),
        "NK_cells"          = c("NKG7","GNLY","NCAM1"),
        "Monocytes"         = c("CD14","LYZ","S100A8","S100A9"),
        "Classical_Mono"    = c("CD14","S100A8","FCGR3A"),
        "NonClassical_Mono" = c("FCGR3A","MS4A7"),
        "Dendritic_cells"   = c("FCER1A","CST3"),
        "Platelets"         = c("PPBP","PF4"),
        # ── Skeletal muscle markers (FSHD / muscle biopsy datasets) ──
        "Satellite_cells"   = c("PAX7","MYF5","NCAM1"),
        "Myoblasts"         = c("MYOD1","MYF5","DES"),
        "Myocytes"          = c("MYH3","MYH8","ACTA1","DES","TNNT2"),
        "Mature_Muscle"     = c("MYH1","MYH2","MYH4","ACTN2","TTN"),
        "Fibroblasts"       = c("COL1A1","COL1A2","VIM","FN1","PDGFRA"),
        "FAPs"              = c("PDGFRA","SFRP2","LY6E"),
        "Endothelial"       = c("PECAM1","CDH5","VWF","ENG"),
        "Macrophages"       = c("CD68","CD14","MRC1","CSF1R"),
        "Pericytes"         = c("PDGFRB","ACTA2","RGS5"),
        "Schwann_cells"     = c("S100B","MPZ","MBP")
    )
    for (ct in names(canonical_markers)) {
        m <- canonical_markers[[ct]]; present <- m %in% rownames(obj)
        message(sprintf("%-22s: %d/%d present", ct, sum(present), length(m)))
        if (!all(present)) message(sprintf("  Missing: %s", paste(m[!present], collapse=", ")))
    }
    plot_violin_markers <- function(markers, suffix) {
        pm <- markers[markers %in% rownames(obj)]; if (length(pm)==0) return(NULL)
        p <- VlnPlot(obj, features=pm, group.by="seurat_clusters", pt.size=0, ncol=3) &
            theme(legend.position="none", axis.text.x=element_text(angle=0,hjust=0.5,size=8),
                  axis.title.x=element_blank(), plot.title=element_text(size=11,face="bold"))
        ggsave(paste0("plots/manual_annotation/violin_",suffix,".png"),
               p, width=14, height=max(4,ceiling(length(pm)/3)*2.5), dpi=150)
    }
    plot_umap_markers <- function(markers, suffix) {
        pm <- markers[markers %in% rownames(obj)]; if (length(pm)==0) return(NULL)
        p <- FeaturePlot(obj, features=pm, reduction=umap_red, ncol=4, pt.size=0.1) &
            theme(plot.title=element_text(size=10), axis.text=element_blank(), axis.ticks=element_blank())
        ggsave(paste0("plots/manual_annotation/umap_",suffix,".png"),
               p, width=16, height=max(4,ceiling(length(pm)/4)*3), dpi=150)
    }
    for (ct_key in names(canonical_markers)) {
        plot_violin_markers(canonical_markers[[ct_key]], ct_key)
        plot_umap_markers(canonical_markers[[ct_key]], ct_key)
    }
    all_m <- unique(unlist(canonical_markers)); all_m <- all_m[all_m %in% rownames(obj)]
    message(paste("Canonical markers found in dataset:", length(all_m)))
    if (length(all_m) > 0) {
        p_dot <- DotPlot(obj, features=all_m, group.by="seurat_clusters") + coord_flip() +
            theme(axis.text.x=element_text(angle=45,hjust=1,size=9), axis.text.y=element_text(size=8)) +
            labs(title="All Canonical Markers by Cluster")
        ggsave("plots/manual_annotation/dotplot_canonical.png", p_dot,
               width=12, height=max(8, length(all_m)*0.4), dpi=150)
    } else {
        message("WARNING: No canonical markers found in dataset — skipping DotPlot. Data may be non-immune tissue.")
    }
    markers_all <- FindAllMarkers(obj, only.pos=TRUE, min.pct=0.25, logfc.threshold=0.25, verbose=FALSE)
    markers_filt <- markers_all %>% filter(!grepl("^RP[SL]",gene)) %>% filter(!grepl("^MT-",gene))
    write.csv(markers_filt, "annotations/cluster_markers_all.csv", row.names=FALSE)
    top5 <- markers_filt %>% group_by(cluster) %>% top_n(n=5, wt=avg_log2FC) %>% arrange(cluster, desc(avg_log2FC))
    write.csv(top5, "annotations/top5_markers_per_cluster.csv", row.names=FALSE)
    top_genes <- unique(top5\$gene)
    p_heat <- DoHeatmap(obj, features=top_genes, group.by="seurat_clusters", size=3) +
        theme(axis.text.y=element_text(size=6)) + labs(title="Top 5 Markers per Cluster")
    ggsave("plots/manual_annotation/06_heatmap_top_markers.png", p_heat,
           width=12, height=max(10, length(top_genes)*0.18), dpi=150)
    obj\$manual_annotation <- paste0("Cluster_", obj\$seurat_clusters)
    p_cl <- DimPlot(obj, reduction=umap_red, group.by="seurat_clusters", label=TRUE, pt.size=0.1) +
        ggtitle("Clusters (Pre-Annotation)") + theme(plot.title=element_text(face="bold",size=14))
    ggsave("plots/manual_annotation/07_manual_annotation_umap.png", p_cl, width=10, height=8, dpi=150)
    sce <- as.SingleCellExperiment(obj, assay=\"RNA\")
    # ── AUTO TISSUE TYPE DETECTION ──────────────────────────────────────────
    detect_tissue_type <- function(gene_names) {
        muscle_sig <- c(\"MYH3\",\"MYH8\",\"MYH1\",\"MYH2\",\"MYH4\",\"ACTA1\",\"DES\",\"TTN\",\"TNNT2\",
                        \"PAX7\",\"MYOD1\",\"MYF5\",\"COL1A1\",\"COL1A2\",\"ACTN2\")
        immune_sig <- c(\"CD3D\",\"CD3E\",\"CD14\",\"CD79A\",\"NKG7\",\"GNLY\",\"MS4A1\",\"LYZ\",
                        \"S100A8\",\"FCGR3A\",\"CD19\",\"IL7R\",\"CD8A\",\"PPBP\",\"FCER1A\")
        brain_sig  <- c(\"SNAP25\",\"SYP\",\"MAP2\",\"RBFOX3\",\"GFAP\",\"MBP\",\"AIF1\",\"PDGFRA\")
        n_muscle <- sum(muscle_sig %in% gene_names)
        n_immune <- sum(immune_sig %in% gene_names)
        n_brain  <- sum(brain_sig  %in% gene_names)
        scores   <- c(muscle=n_muscle, immune=n_immune, brain=n_brain)
        best     <- names(which.max(scores))
        if (max(scores) < 2) best <- \"general\"
        message(sprintf(\"Tissue detection scores  muscle=%d  immune=%d  brain=%d  -> %s\",
                        n_muscle, n_immune, n_brain, best))
        return(best)
    }
    tissue_type <- detect_tissue_type(rownames(obj))
    # Map tissue type to scType category and scCATCH tissue
    sctype_category  <- switch(tissue_type,
        muscle  = \"Muscle\",
        immune  = \"Immune system\",
        brain   = \"Brain\",
        \"Immune system\"   # default
    )
    sccatch_tissue   <- switch(tissue_type,
        muscle  = \"Muscle\",
        immune  = \"Blood\",
        brain   = \"Brain\",
        \"Blood\"           # default
    )
    message(paste(\"scType category :\", sctype_category))
    message(paste(\"scCATCH tissue  :\", sccatch_tissue))
    # ── SINGLER (always runs; HPCA covers all tissues) ───────────────────────
    obj\$singler_monaco <- tryCatch({
        message(\"Running SingleR with Monaco...\")
        ref_m <- MonacoImmuneData()
        SingleR(test=sce, ref=ref_m, labels=ref_m\$label.main)\$labels
    }, error = function(e) { message(\"SingleR Monaco failed: \", e\$message); rep(\"Unknown\", ncol(obj)) })
    obj\$singler_hpca <- tryCatch({
        message(\"Running SingleR with HPCA (broad reference)...\")
        ref_h <- HumanPrimaryCellAtlasData()
        SingleR(test=sce, ref=ref_h, labels=ref_h\$label.main)\$labels
    }, error = function(e) { message(\"SingleR HPCA failed: \", e\$message); rep(\"Unknown\", ncol(obj)) })
    obj\$singler_dice <- tryCatch({
        message(\"Running SingleR with DICE...\")
        ref_d <- DatabaseImmuneCellExpressionData()
        SingleR(test=sce, ref=ref_d, labels=ref_d\$label.main)\$labels
    }, error = function(e) { message(\"SingleR DICE failed: \", e\$message); rep(\"Unknown\", ncol(obj)) })
    p_hpca   <- DimPlot(obj, reduction=umap_red, group.by=\"singler_hpca\",    pt.size=0.1) + labs(title=\"HPCA\")     + theme(legend.text=element_text(size=7))
    p_monaco <- DimPlot(obj, reduction=umap_red, group.by=\"singler_monaco\",  pt.size=0.1) + labs(title=\"Monaco\")   + theme(legend.text=element_text(size=7))
    p_dice   <- DimPlot(obj, reduction=umap_red, group.by=\"singler_dice\",    pt.size=0.1) + labs(title=\"DICE\")     + theme(legend.text=element_text(size=7))
    p_clust  <- DimPlot(obj, reduction=umap_red, group.by=\"seurat_clusters\", pt.size=0.1) + labs(title=\"Clusters\") + theme(legend.text=element_text(size=7))
    ggsave(\"plots/automated_annotation/10_singler_reference_comparison.png\",
           (p_clust | p_hpca) / (p_monaco | p_dice), width=16, height=12, dpi=150)
    obj\$singler_annotation <- obj\$singler_hpca   # HPCA is best for non-immune tissues
    p_sf <- DimPlot(obj, reduction=umap_red, group.by=\"singler_annotation\",
                    label=TRUE, label.size=3, pt.size=0.1, repel=TRUE) +
        ggtitle(paste0(\"SingleR: HPCA Reference (\", tissue_type, \" tissue)\")) +
        theme(plot.title=element_text(face=\"bold\",size=14))
    ggsave(\"plots/automated_annotation/11_singler_final_annotation.png\", p_sf, width=11, height=8, dpi=150)
    # ── SCTYPE (auto category) ───────────────────────────────────────────────
    tryCatch({
        source(\"https://raw.githubusercontent.com/IanevskiAleksandr/sc-type/master/R/gene_sets_prepare.R\")
        source(\"https://raw.githubusercontent.com/IanevskiAleksandr/sc-type/master/R/sctype_score_.R\")
        db_url <- \"https://raw.githubusercontent.com/IanevskiAleksandr/sc-type/master/ScTypeDB_full.xlsx\"
        t_file <- tempfile(fileext=\".xlsx\"); download.file(db_url, t_file, mode=\"wb\")
        gs_list <- gene_sets_prepare(t_file, sctype_category)
        sc_data <- as.matrix(LayerData(obj, assay=\"RNA\", layer=\"data\"))
        es_max  <- sctype_score(scRNAseqData=sc_data, scaled=FALSE,
                                gs=gs_list\$gs_positive, gs2=gs_list\$gs_negative)
        cL_results <- do.call(\"rbind\", lapply(unique(obj\$seurat_clusters), function(cl) {
            es_cl <- sort(rowSums(es_max[, obj\$seurat_clusters==cl, drop=FALSE]), decreasing=TRUE)
            data.frame(cluster=cl, type=names(es_cl)[1], score=es_cl[1],
                       ncells=sum(obj\$seurat_clusters==cl))
        }))
        score_threshold <- quantile(cL_results\$score, 0.6)
        cL_results\$type[cL_results\$score < score_threshold] <- \"Unknown\"
        obj\$sctype_annotation <- unname(
            setNames(cL_results\$type, cL_results\$cluster)[as.character(obj\$seurat_clusters)])
        write.csv(cL_results, \"annotations/sctype_cluster_scores.csv\", row.names=FALSE)
        p_sctype <- DimPlot(obj, reduction=umap_red, group.by=\"sctype_annotation\",
                            label=TRUE, label.size=4, pt.size=0.1, repel=TRUE) +
            ggtitle(paste0(\"scType: \", sctype_category)) +
            theme(plot.title=element_text(face=\"bold\",size=14))
        ggsave(\"plots/automated_annotation/12_sctype_annotation.png\", p_sctype, width=11, height=8, dpi=150)
    }, error = function(e) {
        message(\"scType failed: \", e\$message)
        obj\$sctype_annotation <<- \"Unknown\"
    })
    # ── SCCATCH (auto tissue) ────────────────────────────────────────────────
    obj\$sccatch_annotation <- \"Unknown\"
    tryCatch({
        obj_catch <- createscCATCH(data=LayerData(obj, assay=\"RNA\", layer=\"data\"),
                                   cluster=as.character(obj\$seurat_clusters))
        obj_catch <- tryCatch(
            findmarkergene(obj_catch, species=\"Human\", marker=cellmatch,
                           tissue=sccatch_tissue, cancer=\"Normal\",
                           cell_min_pct=0.25, logfc=0.25, pvalue=0.05),
            error = function(e2) {
                message(\"scCATCH \", sccatch_tissue, \" failed, trying Blood: \", e2\$message)
                findmarkergene(obj_catch, species=\"Human\", marker=cellmatch,
                               tissue=\"Blood\", cancer=\"Normal\",
                               cell_min_pct=0.25, logfc=0.25, pvalue=0.05)
            }
        )
        obj_catch  <- findcelltype(obj_catch)
        catch_res  <- obj_catch@celltype
        cl_to_ct   <- setNames(catch_res\$cell_type, catch_res\$cluster)
        obj\$sccatch_annotation <- unname(cl_to_ct[as.character(obj\$seurat_clusters)])
        obj\$sccatch_annotation[is.na(obj\$sccatch_annotation)] <- \"Unknown\"
        write.csv(catch_res, \"annotations/sccatch_cluster_assignments.csv\", row.names=FALSE)
        p_sccatch <- DimPlot(obj, reduction=umap_red, group.by=\"sccatch_annotation\",
                             label=TRUE, label.size=4, pt.size=0.1, repel=TRUE) +
            ggtitle(paste0(\"scCATCH: \", sccatch_tissue, \" tissue\")) +
            theme(plot.title=element_text(face=\"bold\",size=14))
        ggsave(\"plots/automated_annotation/13_sccatch_annotation.png\", p_sccatch, width=11, height=8, dpi=150)
    }, error = function(e) { message(\"scCATCH failed: \", e\$message) })
    make_conf <- function(l1, l2, n1, n2) {
        ct <- table(Method1=l1, Method2=l2)
        write.csv(as.data.frame.matrix(ct), paste0("annotations/confusion_matrix_",n1,"_vs_",n2,".csv"))
    }
    make_conf(obj\$manual_annotation, obj\$singler_annotation, "manual", "singler")
    make_conf(obj\$manual_annotation, obj\$sctype_annotation,  "manual", "sctype")
    make_conf(obj\$manual_annotation, obj\$sccatch_annotation, "manual", "sccatch")
    prep_sankey <- function(m1, m2, n1, n2) {
        df <- data.frame(M1=obj@meta.data[[m1]], M2=obj@meta.data[[m2]]) %>%
              group_by(M1, M2) %>% summarise(Count=n(), .groups="drop")
        ggplot(df, aes(axis1=M1, axis2=M2, y=Count)) +
            geom_alluvium(aes(fill=M1), width=1/12, alpha=0.7) +
            geom_stratum(width=1/12, fill="white", color="grey") +
            geom_text(stat="stratum", aes(label=after_stat(stratum)), size=3, fontface="bold") +
            scale_x_discrete(limits=c(n1,n2), expand=c(0.05,0.05)) +
            labs(title=paste(n1,"vs",n2), y="# Cells") + theme_minimal() +
            theme(legend.position="none", axis.text.y=element_blank())
    }
    ggsave("plots/method_comparison/14_sankey_manual_vs_singler.png",
           prep_sankey("manual_annotation","singler_annotation","Manual","SingleR"), width=12, height=10, dpi=150)
    ggsave("plots/method_comparison/15_sankey_manual_vs_sctype.png",
           prep_sankey("manual_annotation","sctype_annotation","Manual","scType"), width=12, height=10, dpi=150)
    ggsave("plots/method_comparison/16_sankey_manual_vs_sccatch.png",
           prep_sankey("manual_annotation","sccatch_annotation","Manual","scCATCH"), width=12, height=10, dpi=150)
    pa <- DimPlot(obj, reduction=umap_red, group.by="manual_annotation",  pt.size=0.1) + labs(title="Manual")          + theme(legend.text=element_text(size=7), plot.title=element_text(face="bold"))
    pb <- DimPlot(obj, reduction=umap_red, group.by="singler_annotation", pt.size=0.1) + labs(title="SingleR (Monaco)") + theme(legend.text=element_text(size=7), plot.title=element_text(face="bold"))
    pc <- DimPlot(obj, reduction=umap_red, group.by="sctype_annotation",  pt.size=0.1) + labs(title="scType")           + theme(legend.text=element_text(size=7), plot.title=element_text(face="bold"))
    pd <- DimPlot(obj, reduction=umap_red, group.by="sccatch_annotation", pt.size=0.1) + labs(title="scCATCH")          + theme(legend.text=element_text(size=7), plot.title=element_text(face="bold"))
    ggsave("plots/method_comparison/17_all_methods_comparison.png", (pa|pb)/(pc|pd), width=18, height=14, dpi=150)
    annotation_comparison <- data.frame(
        cell_barcode=colnames(obj), cluster=obj\$seurat_clusters,
        manual=obj\$manual_annotation, singler=obj\$singler_annotation,
        sctype=obj\$sctype_annotation,  sccatch=obj\$sccatch_annotation,
        sample_id=obj\$sample_id, condition=obj\$condition, stringsAsFactors=FALSE)
    write.csv(annotation_comparison, "annotations/all_methods_comparison.csv", row.names=FALSE)
    get_top_label <- function(x) {
        x <- x[!is.na(x) & x != ""]
        if (length(x)==0) return("Unknown")
        names(sort(table(x), decreasing=TRUE))[1]
    }
    cluster_summary <- obj@meta.data %>% group_by(seurat_clusters) %>%
        summarise(n=n(), Manual=get_top_label(manual_annotation),
                  Monaco=get_top_label(singler_monaco), scType=get_top_label(sctype_annotation),
                  scCATCH=get_top_label(sccatch_annotation), .groups="drop")
    write.csv(cluster_summary, "annotations/cluster_level_comparison.csv", row.names=FALSE)
    obj\$final_annotation <- obj\$singler_monaco
    p_cons <- DimPlot(obj, reduction=umap_red, group.by="final_annotation",
                      label=TRUE, label.size=4, pt.size=0.1, repel=TRUE) +
        ggtitle("Final Consensus Annotation (Monaco)") + theme(plot.title=element_text(face="bold",size=14))
    ggsave("plots/method_comparison/18_final_consensus_annotation.png", p_cons, width=11, height=8, dpi=150)
    if ("condition" %in% colnames(obj@meta.data)) {
        p_split <- DimPlot(obj, reduction=umap_red, group.by="final_annotation",
                           split.by="condition", pt.size=0.1, ncol=2) + ggtitle("Consensus by Condition")
        ggsave("plots/method_comparison/19_consensus_by_condition.png", p_split, width=14, height=6, dpi=150)
    }
    saveRDS(obj, "integrated_annotated.rds")
    message("CELL_ANNOTATION complete.")
ENDSCRIPT

    Rscript annotate_script.R
    """
}

// ============================================================================
//  PROCESS 6: DE ANALYSIS (Part 5)
// ============================================================================
process DE_ANALYSIS {
    tag "de_analysis"
    publishDir "${params.outdir}/05_de", mode: 'copy'
    label 'process_medium'

    input:
    path rds

    output:
    path "de_results.rds",                            emit: rds
    path "plots/proportions/*.png",                   emit: plots_prop,      optional: true
    path "plots/DE_celllevel/*.png",                  emit: plots_cell,      optional: true
    path "plots/DE_pseudobulk/*.png",                 emit: plots_bulk,      optional: true
    path "plots/functional_scoring/*.png",            emit: plots_func,      optional: true
    path "results/*.csv",                             emit: csvs,            optional: true

    script:
    """
    mkdir -p plots/proportions plots/DE_celllevel plots/DE_pseudobulk plots/functional_scoring results

    printf '%s' "${rds}" > .rds_path.txt

    cat > de_script.R << 'ENDSCRIPT'
    options(future.globals.maxSize = 100 * 1024^3)
    set.seed(42)

    # ── Install missing packages ──────────────────────────────────────────────
    pkgs_cran  <- c("msigdbr","ggridges","ggrepel","patchwork","dplyr","tidyr","scales")
    pkgs_bioc  <- c("DESeq2","edgeR","limma","speckle","EnhancedVolcano")
    for (p in pkgs_cran) if (!requireNamespace(p, quietly=TRUE))
        install.packages(p, repos="http://cran.us.r-project.org")
    for (p in pkgs_bioc) if (!requireNamespace(p, quietly=TRUE))
        BiocManager::install(p, update=FALSE)

    suppressPackageStartupMessages({
        library(Seurat); library(SeuratObject)
        library(DESeq2); library(edgeR); library(limma); library(speckle)
        library(msigdbr)
        library(ggplot2); library(ggridges); library(ggrepel); library(EnhancedVolcano)
        library(patchwork); library(dplyr); library(tidyr); library(scales)
    })
    theme_set(theme_classic(base_size = 12))

    rds_path <- trimws(readLines(".rds_path.txt"))
    seurat_obj <- readRDS(rds_path)

    # Ensure required columns exist
    if (!"final_annotation" %in% colnames(seurat_obj@meta.data)) {
        if ("singler_monaco" %in% colnames(seurat_obj@meta.data)) {
            seurat_obj\$final_annotation <- seurat_obj\$singler_monaco
            message("Using singler_monaco as final_annotation")
        } else {
            seurat_obj\$final_annotation <- paste0("Cluster_", seurat_obj\$seurat_clusters)
            message("Warning: no annotation found, using cluster IDs")
        }
    }
    if (!"patient_id" %in% colnames(seurat_obj@meta.data)) {
        seurat_obj\$patient_id <- seurat_obj\$sample_id
    }

    DefaultAssay(seurat_obj) <- "RNA"
    seurat_obj <- JoinLayers(seurat_obj)

    cell_types <- sort(unique(seurat_obj\$final_annotation))
    message(paste("Cell types:", paste(cell_types, collapse=", ")))
    message(paste("Conditions:", paste(unique(seurat_obj\$condition), collapse=", ")))

    dir.create("plots/proportions",       showWarnings=FALSE, recursive=TRUE)
    dir.create("plots/DE_celllevel",      showWarnings=FALSE, recursive=TRUE)
    dir.create("plots/DE_pseudobulk",     showWarnings=FALSE, recursive=TRUE)
    dir.create("plots/functional_scoring",showWarnings=FALSE, recursive=TRUE)
    dir.create("results",                 showWarnings=FALSE, recursive=TRUE)

    # ══════════════════════════════════════════════════════════════════════════
    # PART 1: CELL TYPE PROPORTION ANALYSIS
    # ══════════════════════════════════════════════════════════════════════════
    message("=== PART 1: Proportion Analysis ===")

    proportion_data <- seurat_obj@meta.data %>%
        group_by(sample_id, condition, final_annotation) %>%
        summarise(count = n(), .groups="drop") %>%
        group_by(sample_id) %>%
        mutate(total_cells  = sum(count),
               proportion   = count / total_cells,
               percentage   = proportion * 100) %>%
        ungroup()
    write.csv(proportion_data, "results/cell_type_proportions_per_sample.csv", row.names=FALSE)

    proportion_summary <- proportion_data %>%
        group_by(condition, final_annotation) %>%
        summarise(mean_percentage = mean(percentage),
                  sd_percentage   = sd(percentage),  .groups="drop")

    p_stacked <- ggplot(proportion_data, aes(x=sample_id, y=percentage, fill=final_annotation)) +
        geom_bar(stat="identity") +
        facet_wrap(~condition, scales="free_x") +
        theme_classic(base_size=12) +
        theme(axis.text.x=element_text(angle=45, hjust=1), legend.position="right") +
        labs(title="Cell Type Composition by Sample",
             x="Sample", y="Percentage (%)", fill="Cell Type") +
        scale_fill_brewer(palette="Set3")
    ggsave("plots/proportions/01_stacked_composition.png", p_stacked, width=12, height=6, dpi=150)

    p_grouped <- ggplot(proportion_summary,
                        aes(x=final_annotation, y=mean_percentage, fill=condition)) +
        geom_bar(stat="identity", position=position_dodge(0.9)) +
        geom_errorbar(aes(ymin=mean_percentage-sd_percentage,
                          ymax=mean_percentage+sd_percentage),
                      position=position_dodge(0.9), width=0.2) +
        theme_classic(base_size=12) +
        theme(axis.text.x=element_text(angle=45, hjust=1)) +
        labs(title="Mean Cell Type Proportions by Condition",
             x="Cell Type", y="Mean Percentage (%)") +
        scale_fill_manual(values=c("Healthy"="#2E86AB","Post_Treatment"="#F18F01"))
    ggsave("plots/proportions/02_grouped_proportions.png", p_grouped, width=12, height=6, dpi=150)

    # Propeller test (catches errors gracefully)
    tryCatch({
        cluster_ids <- seurat_obj\$final_annotation
        sample_ids  <- seurat_obj\$sample_id
        sample_to_cond <- unique(seurat_obj@meta.data[, c("sample_id","condition")])
        rownames(sample_to_cond) <- sample_to_cond\$sample_id
        group <- sample_to_cond[sample_ids, "condition"]
        propeller_results <- propeller(clusters=cluster_ids, sample=sample_ids, group=group)
        write.csv(propeller_results, "results/propeller_proportion_test.csv", row.names=FALSE)
        message("Propeller: done")
    }, error=function(e) {
        message(paste("Propeller skipped:", e\$message))
        write.csv(data.frame(note="propeller skipped"), "results/propeller_proportion_test.csv", row.names=FALSE)
    })

    # ══════════════════════════════════════════════════════════════════════════
    # PART 2: CELL-LEVEL DE WITH FindMarkers
    # ══════════════════════════════════════════════════════════════════════════
    message("=== PART 2: FindMarkers Cell-Level DE ===")
    Idents(seurat_obj) <- "condition"

    run_findmarkers <- function(celltype, obj) {
        message(paste("  FindMarkers:", celltype))
        sub_obj <- tryCatch(
            subset(obj, cells=colnames(obj)[obj\$final_annotation == celltype]),
            error=function(e) NULL)
        if (is.null(sub_obj) || ncol(sub_obj) < 10) return(NULL)
        conds <- unique(sub_obj\$condition)
        if (length(conds) < 2) return(NULL)
        markers <- tryCatch(FindMarkers(
            sub_obj, ident.1="Post_Treatment", ident.2="Healthy",
            test.use="wilcox", logfc.threshold=0, min.pct=0.1, verbose=FALSE),
            error=function(e){ message(paste("  FindMarkers error:", e\$message)); NULL })
        if (is.null(markers)) return(NULL)
        markers\$gene <- rownames(markers)
        markers\$cell_type <- celltype
        markers\$significant <- markers\$p_val_adj < 0.05 & abs(markers\$avg_log2FC) > 0.25
        return(markers)
    }

    fm_list  <- lapply(cell_types, run_findmarkers, obj=seurat_obj)
    fm_raw   <- Filter(Negate(is.null), fm_list)
    fm_all   <- if (length(fm_raw) > 0) do.call(rbind, fm_raw) else NULL
    if (!is.null(fm_all)) rownames(fm_all) <- NULL
    write.csv(if (!is.null(fm_all)) fm_all else data.frame(note="no multi-condition cells"),
              "results/findmarkers_celllevel_results.csv", row.names=FALSE)

    if (!is.null(fm_all) && nrow(fm_all) > 0) {
        for (ct in cell_types) {
            ct_data <- fm_all %>% filter(cell_type == ct)
            if (nrow(ct_data) == 0) next
            top_genes <- ct_data %>% filter(!is.na(p_val_adj)) %>%
                arrange(p_val_adj) %>% head(15)
            p_vol <- ggplot(ct_data, aes(x=avg_log2FC, y=-log10(p_val_adj+1e-300))) +
                geom_point(aes(color=significant), alpha=0.5, size=1) +
                scale_color_manual(values=c("FALSE"="grey70","TRUE"="firebrick")) +
                geom_hline(yintercept=-log10(0.05), linetype="dashed", color="steelblue") +
                geom_vline(xintercept=c(-0.25,0.25), linetype="dashed", color="steelblue") +
                labs(title=paste("Volcano:", ct),
                     x="log2 Fold Change (Post-Treatment vs Healthy)",
                     y="-log10(FDR)", color="FDR<0.05 & |FC|>0.25") +
                theme_classic(base_size=12)
            if (nrow(top_genes) > 0)
                p_vol <- p_vol + ggrepel::geom_text_repel(
                    data=top_genes, aes(label=gene), size=3, max.overlaps=10)
            ggsave(paste0("plots/DE_celllevel/volcano_", gsub("[^a-zA-Z0-9]","_",ct), ".png"),
                   p_vol, width=8, height=7, dpi=150)
        }
    } else {
        message("FindMarkers: skipped (fewer than 2 conditions)")
    }
    message("FindMarkers: done")

    # ══════════════════════════════════════════════════════════════════════════
    # PART 3: PSEUDOBULK DE — DESeq2 + limma-voom
    # ══════════════════════════════════════════════════════════════════════════
    message("=== PART 3: Pseudobulk DE ===")

    # metadata keyed by sample
    sample_metadata <- unique(seurat_obj@meta.data[, c("sample_id","condition","patient_id")])
    sample_metadata <- as.data.frame(sample_metadata)
    rownames(sample_metadata) <- sample_metadata\$sample_id

    create_pseudobulk <- function(celltype, obj) {
        sub <- subset(obj, cells=colnames(obj)[obj\$final_annotation == celltype])
        if (ncol(sub) < 5) return(NULL)
        pb <- tryCatch(
            PseudobulkExpression(sub, assays="RNA", group.by="sample_id",
                                 layer="counts", method="aggregate"),
            error=function(e){ message(paste("  PseudobulkExpression error:", e\$message)); NULL })
        if (is.null(pb)) return(NULL)
        mat <- pb\$RNA
        colnames(mat) <- gsub("-","_", colnames(mat))
        as.matrix(mat)
    }

    pb_list <- lapply(cell_types, create_pseudobulk, obj=seurat_obj)
    names(pb_list) <- cell_types
    pb_list <- Filter(Negate(is.null), pb_list)

    run_deseq2 <- function(ct, counts, meta) {
        message(paste("  DESeq2:", ct))
        samps <- colnames(counts)
        samps <- samps[samps %in% rownames(meta)]
        if (length(samps) < 4) { message("  Not enough samples"); return(NULL) }
        counts <- counts[, samps, drop=FALSE]
        meta_ord <- meta[samps, , drop=FALSE]
        meta_ord\$condition <- factor(meta_ord\$condition, levels=c("Healthy","Post_Treatment"))
        tryCatch({
            dds <- DESeqDataSetFromMatrix(countData=counts, colData=meta_ord, design=~condition)
            keep <- rowSums(counts(dds) >= 10) >= 3
            dds <- dds[keep, ]
            if (nrow(dds) < 10) return(NULL)
            dds <- DESeq(dds, quiet=TRUE)
            res <- results(dds, contrast=c("condition","Post_Treatment","Healthy"), alpha=0.05)
            res_df <- as.data.frame(res)
            res_df\$gene <- rownames(res_df)
            res_df\$cell_type <- ct
            res_df\$significant <- !is.na(res_df\$padj) & res_df\$padj<0.05 & abs(res_df\$log2FoldChange)>0.25
            return(res_df)
        }, error=function(e){ message(paste("  DESeq2 error:", e\$message)); NULL })
    }

    deseq2_list <- lapply(names(pb_list), function(ct) run_deseq2(ct, pb_list[[ct]], sample_metadata))
    names(deseq2_list) <- names(pb_list)
    deseq2_raw <- Filter(Negate(is.null), deseq2_list)
    deseq2_all <- if (length(deseq2_raw) > 0) do.call(rbind, deseq2_raw) else NULL
    if (!is.null(deseq2_all)) rownames(deseq2_all) <- NULL
    write.csv(if (!is.null(deseq2_all)) deseq2_all else data.frame(note="no pseudobulk DE results"),
              "results/deseq2_pseudobulk_results.csv", row.names=FALSE)

    # limma-voom
    run_limma <- function(ct, counts, meta) {
        message(paste("  limma:", ct))
        samps <- colnames(counts)[colnames(counts) %in% rownames(meta)]
        if (length(samps) < 4) return(NULL)
        counts <- counts[, samps, drop=FALSE]
        m <- meta[samps, , drop=FALSE]
        m\$condition <- factor(m\$condition, levels=c("Healthy","Post_Treatment"))
        tryCatch({
            keep <- rowSums(counts) >= 10
            counts <- counts[keep, ]
            design <- model.matrix(~0 + condition, data=m)
            colnames(design) <- gsub("condition","", colnames(design))
            v <- voomWithQualityWeights(counts, design, plot=FALSE)
            fit <- lmFit(v, design)
            contr <- makeContrasts(Post_Treatment - Healthy, levels=colnames(design))
            fit2 <- contrasts.fit(fit, contr)
            fit2 <- eBayes(fit2, trend=TRUE, robust=TRUE)
            res <- topTable(fit2, number=Inf, sort.by="none", adjust.method="BH")
            res\$gene <- rownames(res)
            res\$cell_type <- ct
            res\$significant <- res\$adj.P.Val < 0.05 & abs(res\$logFC) > 0.25
            return(res)
        }, error=function(e){ message(paste("  limma error:", e\$message)); NULL })
    }

    limma_list <- lapply(names(pb_list), function(ct) run_limma(ct, pb_list[[ct]], sample_metadata))
    names(limma_list) <- names(pb_list)
    limma_raw <- Filter(Negate(is.null), limma_list)
    limma_all <- if (length(limma_raw) > 0) do.call(rbind, limma_raw) else NULL
    if (!is.null(limma_all)) rownames(limma_all) <- NULL
    write.csv(if (!is.null(limma_all)) limma_all else data.frame(note="no limma results"),
              "results/limma_pseudobulk_results.csv", row.names=FALSE)

    # DESeq2 volcano plots
    if (!is.null(deseq2_all) && nrow(deseq2_all) > 0) {
        for (ct in unique(deseq2_all\$cell_type)) {
            ct_d <- deseq2_all %>% filter(cell_type==ct, !is.na(padj))
            if (nrow(ct_d) == 0) next
            top_g <- ct_d %>% filter(significant) %>% arrange(padj) %>% head(15)
            pv <- ggplot(ct_d, aes(x=log2FoldChange, y=-log10(padj+1e-300))) +
                geom_point(aes(color=significant), alpha=0.5, size=1) +
                scale_color_manual(values=c("FALSE"="grey70","TRUE"="firebrick")) +
                geom_hline(yintercept=-log10(0.05), linetype="dashed", color="steelblue") +
                geom_vline(xintercept=c(-0.25,0.25), linetype="dashed", color="steelblue") +
                labs(title=paste("DESeq2 Pseudobulk:", ct),
                     x="log2FC (Post-Treatment vs Healthy)", y="-log10(FDR)") +
                theme_classic(base_size=12)
            if (nrow(top_g) > 0)
                pv <- pv + ggrepel::geom_text_repel(data=top_g, aes(label=gene), size=3, max.overlaps=10)
            ggsave(paste0("plots/DE_pseudobulk/deseq2_volcano_", gsub("[^a-zA-Z0-9]","_",ct), ".png"),
                   pv, width=8, height=7, dpi=150)
        }
    }
    message("Pseudobulk DE: done")

    # ══════════════════════════════════════════════════════════════════════════
    # PART 4: FUNCTIONAL STATE SCORING
    # ══════════════════════════════════════════════════════════════════════════
    message("=== PART 4: Functional State Scoring ===")

    hallmark_sets <- tryCatch(msigdbr(species="Homo sapiens", category="H"), error=function(e) NULL)

    if (!is.null(hallmark_sets)) {
        pathway_names <- c(
            "HALLMARK_INFLAMMATORY_RESPONSE",
            "HALLMARK_INTERFERON_GAMMA_RESPONSE",
            "HALLMARK_IL6_JAK_STAT3_SIGNALING",
            "HALLMARK_TNFA_SIGNALING_VIA_NFKB",
            "HALLMARK_OXIDATIVE_PHOSPHORYLATION"
        )
        pathway_scores <- list()
        score_cols <- character(0)

        for (pw_name in pathway_names) {
            pw_genes <- hallmark_sets %>%
                filter(gs_name == pw_name) %>% pull(gene_symbol) %>% unique()
            pw_genes <- pw_genes[pw_genes %in% rownames(seurat_obj)]
            if (length(pw_genes) < 5) { message(paste("Skipping (too few genes):", pw_name)); next }
            clean_name <- gsub("HALLMARK_","", pw_name)
            score_col  <- paste0(clean_name, "_Score")
            seurat_obj <- AddModuleScore(seurat_obj, features=list(pw_genes),
                                         name=paste0(clean_name,"_"),
                                         nbin=24, ctrl=100)
            # Seurat appends "1" to name
            rough_col <- paste0(clean_name, "_1")
            if (rough_col %in% colnames(seurat_obj@meta.data)) {
                seurat_obj@meta.data[[score_col]] <- seurat_obj@meta.data[[rough_col]]
                seurat_obj@meta.data[[rough_col]] <- NULL
            }
            score_cols <- c(score_cols, score_col)
            message(paste("Scored:", pw_name))
        }

        if (length(score_cols) > 0) {
            # Ridge plot for first score
            sc <- score_cols[1]
            p_ridge <- ggplot(seurat_obj@meta.data,
                              aes_string(x=sc, y="final_annotation", fill="condition")) +
                geom_density_ridges(alpha=0.7, scale=1.2) +
                theme_classic(base_size=12) +
                labs(title=gsub("_Score","", sc), x="Pathway Score",
                     y="Cell Type", fill="Condition") +
                scale_fill_manual(values=c("Healthy"="#2E86AB","Post_Treatment"="#F18F01"))
            ggsave("plots/functional_scoring/01_ridge_inflammatory.png",
                   p_ridge, width=10, height=max(6, length(cell_types)*0.8), dpi=150)

            # Violin plot all pathways
            for (sc in score_cols) {
                p_vln <- ggplot(seurat_obj@meta.data,
                                aes_string(x="condition", y=sc, fill="condition")) +
                    geom_violin(trim=TRUE, scale="width") +
                    geom_boxplot(width=0.1, outlier.size=0.3) +
                    facet_wrap(~final_annotation, scales="free_y", ncol=4) +
                    theme_classic(base_size=10) +
                    theme(axis.text.x=element_text(angle=30, hjust=1), legend.position="none") +
                    scale_fill_manual(values=c("Healthy"="#2E86AB","Post_Treatment"="#F18F01")) +
                    labs(title=gsub("_Score","", sc), y="Module Score", x="")
                ggsave(paste0("plots/functional_scoring/02_violin_", sc, ".png"),
                       p_vln, width=14, height=max(8, ceiling(length(cell_types)/4)*3), dpi=150)
            }

            # UMAP for first two scores
            score_umap_cols <- score_cols[1:min(2, length(score_cols))]
            avail_reds <- names(seurat_obj@reductions)
            umap_red <- if("umap.harmony" %in% avail_reds) "umap.harmony" else
                        if("umap.cca"     %in% avail_reds) "umap.cca"     else
                        if("umap.rpca"    %in% avail_reds) "umap.rpca"    else
                        if("umap.mnn"     %in% avail_reds) "umap.mnn"     else "umap"
            for (sc in score_umap_cols) {
                p_umap <- FeaturePlot(seurat_obj, features=sc, reduction=umap_red, pt.size=0.1) +
                    scale_color_viridis_c(option="magma") +
                    labs(title=gsub("_Score","", sc))
                ggsave(paste0("plots/functional_scoring/03_umap_", sc, ".png"),
                       p_umap, width=8, height=7, dpi=150)
            }

            # Pseudobulk pathway scoring test
            score_aggregated <- seurat_obj@meta.data %>%
                select(sample_id, condition, final_annotation, all_of(score_cols)) %>%
                group_by(sample_id, condition, final_annotation) %>%
                summarise(across(all_of(score_cols), mean), .groups="drop")

            pw_test_results <- lapply(score_cols, function(sc) {
                lapply(cell_types, function(ct) {
                    ct_d <- score_aggregated %>% filter(final_annotation == ct)
                    h_sc <- ct_d %>% filter(condition=="Healthy") %>% pull(sc)
                    p_sc <- ct_d %>% filter(condition=="Post_Treatment") %>% pull(sc)
                    if (length(h_sc) < 2 || length(p_sc) < 2) return(NULL)
                    tt <- tryCatch(t.test(p_sc, h_sc), error=function(e) NULL)
                    if (is.null(tt)) return(NULL)
                    data.frame(pathway=sc, cell_type=ct,
                               mean_healthy=mean(h_sc), mean_post=mean(p_sc),
                               diff=mean(p_sc)-mean(h_sc), p_value=tt\$p.value)
                }) %>% do.call(rbind, .)
            }) %>% do.call(rbind, .)

            if (!is.null(pw_test_results) && nrow(pw_test_results) > 0) {
                pw_test_results\$FDR <- p.adjust(pw_test_results\$p_value, method="BH")
                write.csv(pw_test_results, "results/pathway_score_tests.csv", row.names=FALSE)
            }
        }
    } else {
        message("msigdbr: failed, skipping pathway scoring")
        write.csv(data.frame(note="msigdbr unavailable"), "results/pathway_score_tests.csv", row.names=FALSE)
    }

    # ── Save final object ──────────────────────────────────────────────────────
    saveRDS(seurat_obj, "de_results.rds")
    message("=== DE_ANALYSIS complete ===")
ENDSCRIPT

    Rscript de_script.R
    """
}

// ============================================================================
//  PROCESS 7: EXPLORATION (Part 6)
// ============================================================================
process EXPLORATION {
    tag "exploration"
    publishDir "${params.outdir}/06_exploration", mode: 'copy'
    label 'process_low'
    input:  path rds
    output: path "sce.rds", emit: sce
            path "object_structure_summary.txt"
    script:
    """
    cat > explore_script.R << 'ENDSCRIPT'
    suppressPackageStartupMessages({ 
        library(Seurat)
        library(SingleCellExperiment) 
        library(dplyr)
    })
    
    se  <- readRDS("${rds}")
    
    # Generate structural summary
    sink("object_structure_summary.txt")
    cat("========================================================\n")
    cat("  scRNA-seq Object Structural Summary (Seurat v5)\n")
    cat("========================================================\n\n")
    
    cat("1. BASIC INFORMATION\n")
    cat("--------------------\n")
    cat("Class: ", class(se), "\n")
    cat("Dimensions: ", nrow(se), " genes x ", ncol(se), " cells\n")
    cat("Project Name: ", se@project.name, "\n")
    cat("Seurat Version: ", as.character(se@version), "\n\n")
    
    cat("2. ASSAYS AND LAYERS\n")
    cat("--------------------\n")
    cat("Available Assays: ", paste(names(se@assays), collapse=", "), "\n")
    cat("Default Assay: ", DefaultAssay(se), "\n\n")
    
    for (assay_name in names(se@assays)) {
        cat("Assay: ", assay_name, "\n")
        assay_obj <- se[[assay_name]]
        if ("layers" %in% slotNames(assay_obj)) {
            cat("  Layers: ", paste(names(assay_obj@layers), collapse=", "), "\n")
        } else {
            cat("  (Seurat v4 format assay detected)\n")
        }
    }
    cat("\n")
    
    cat("3. METADATA COLUMNS\n")
    cat("-------------------\n")
    metadata_cols <- colnames(se@meta.data)
    cat("Total Columns: ", length(metadata_cols), "\n")
    cat("Columns: ", paste(metadata_cols, collapse=", "), "\n\n")
    cat("First few rows of metadata:\n")
    print(head(se@meta.data[, 1:min(5, length(metadata_cols))], 3))
    cat("\n")
    
    cat("4. DIMENSIONALITY REDUCTIONS\n")
    cat("---------------------------\n")
    cat("Reductions: ", paste(names(se@reductions), collapse=", "), "\n\n")
    
    cat("5. MEMORY USAGE\n")
    cat("---------------\n")
    cat("Total Size: ", format(object.size(se), units="auto"), "\n")
    cat("========================================================\n")
    sink()
    
    # Conversion as per Part 6
    message("Converting to SingleCellExperiment...")
    sce <- as.SingleCellExperiment(se, assay = "RNA")
    saveRDS(sce, "sce.rds")
    message("Exploration complete.")
ENDSCRIPT
    Rscript explore_script.R
    """
}

// ============================================================================
//  PROCESS 8: TRAJECTORY (Part 7)
// ============================================================================
process TRAJECTORY {
    tag "trajectory"
    publishDir "${params.outdir}/07_trajectory", mode: 'copy'
    label 'process_medium'
    input:  path rds
    output: path "plots/*.png",    optional: true
            path "results/*.rds", optional: true
            path "results/*.csv", optional: true
    script:
    """
    mkdir -p plots results
    cat > traj_script.R << 'ENDSCRIPT'
    suppressPackageStartupMessages({ 
        library(Seurat); library(slingshot); library(SingleCellExperiment)
        library(dplyr); library(ggplot2); library(viridis); library(patchwork)
        library(AnnotationDbi); library(org.Hs.eg.db)
    })
    
    args <- commandArgs(trailingOnly = TRUE)
    user_start_clus <- if(length(args) >= 1) args[1] else ""
    do_downsample   <- if(length(args) >= 2) as.logical(args[2]) else TRUE
    subset_mode     <- if(length(args) >= 3) args[3] else "all"
    
    # ── Part 7: Slingshot Trajectory Analysis (Tutorial Alignment) ───────────
    message("Loading Seurat object...")
    seurat_full <- readRDS("${rds}")
        # Convert Ensembl IDs -> HGNC symbols
        if (nrow(seurat_full) > 0 && any(grepl("^ENSG", head(rownames(seurat_full), 100)))) {
            message("Detected Ensembl IDs - converting to HGNC symbols...")
            gene_syms <- tryCatch(
                AnnotationDbi::mapIds(org.Hs.eg.db, keys = rownames(seurat_full),
                                      keytype = "ENSEMBL", column = "SYMBOL",
                                      multiVals = "first"),
                error = function(e) { message("org.Hs.eg.db mapIds failed: ", e\$message); NULL }
            )
            if (!is.null(gene_syms)) {
                valid <- !is.na(gene_syms) & nchar(gene_syms) > 0
                se_sym <- seurat_full[valid, ]
                syms    <- gene_syms[valid]
                dup <- duplicated(syms)
                if (any(dup)) {
                    rna_data <- if (inherits(se_sym[["RNA"]], "Assay5")) JoinLayers(se_sym, assay="RNA")[["RNA"]]\$data else GetAssayData(se_sym, assay="RNA", slot="data")
                    rmeans <- Matrix::rowMeans(rna_data)
                    keep <- rep(TRUE, length(syms))
                    for (s in unique(syms[dup])) {
                        ii <- which(syms == s)
                        keep[ii[-which.max(rmeans[ii])]] <- FALSE
                    }
                    se_sym <- se_sym[keep, ]
                    syms   <- syms[keep]
                }
                # Manually update row names in all layers for Seurat v5
                try({
                    rownames(se_sym@assays\$RNA@counts) <- syms
                    rownames(se_sym@assays\$RNA@data)   <- syms
                }, silent=TRUE)
                seurat_full <- se_sym
                message(sprintf("Ensembl->symbol: %d symbols mapped", nrow(seurat_full)))
            }
        }
    
    # STEP 5: Subset to T/NK cell lineage
    message("Subsetting to T/NK lineage...")
    # STEP 5: Subset based on mode
    message(paste("Subsetting mode:", subset_mode))
    
    # Map subset modes to cell types
    subset_map <- list(
      "t_nk"    = c("CD4+ T cells", "CD8+ T cells", "T cells", "NK cells"),
      "myeloid" = c("Monocytes", "Macrophages", "Dendritic cells", "Conventional Monocytes", "Classical Monocytes")
    )
    
    if (subset_mode %in% names(subset_map)) {
      target_types <- subset_map[[subset_mode]]
      message("Available annotations: ", paste(unique(seurat_full\$final_annotation), collapse=", "))
      valid_types <- intersect(target_types, unique(seurat_full\$final_annotation))
      
      if (length(valid_types) > 0) {
          seurat_sub <- subset(seurat_full, subset = final_annotation %in% valid_types)
          message(paste("Subsetted to", subset_mode, ":", ncol(seurat_sub), "cells"))
      } else {
          message(paste(">>> No", subset_mode, "cells found. Falling back to all cells. <<<"))
          seurat_sub <- seurat_full
      }
    } else {
      seurat_sub <- seurat_full
    }
    
    # Validation Check
    if (ncol(seurat_sub) < 30) {
        message(">>> Too few cells for meaningful trajectory analysis (<30). Skipping. <<<")
        dir.create("plots", showWarnings = FALSE)
        dir.create("results", showWarnings = FALSE)
        write.csv(data.frame(status="skipped", reason="low_cell_count", count=ncol(seurat_sub)), "results/trajectory_skipped.csv")
        saveRDS(seurat_sub, "results/se_trajectory_failed.rds")
        png("plots/01_slingshot_lineages.png", width=800, height=600); plot.new(); text(0.5, 0.5, paste("Insufficient cells (", ncol(seurat_sub), ") for trajectory")); dev.off()
        quit(save = "no")
    }

    # STEP 3 (Strategic Downsampling)
    if (do_downsample && ncol(seurat_sub) > 2000) {
      message("Strategic Downsampling (10% per cell type)...")
      set.seed(42)
      # Ensure final_annotation exists for downsampling logic
      if (!"final_annotation" %in% colnames(seurat_sub@meta.data)) {
          seurat_sub\$final_annotation <- paste0("Cluster_", seurat_sub\$seurat_clusters)
      }
      
      all_cell_types <- unique(seurat_sub\$final_annotation)
      downsampled_cells <- c()
      for (cell_type in all_cell_types) {
          cells_of_type <- colnames(seurat_sub)[seurat_sub\$final_annotation == cell_type]
          n_sample <- max(50, round(length(cells_of_type) * 0.2))
          n_sample <- min(n_sample, length(cells_of_type))
          sampled <- sample(cells_of_type, n_sample)
          downsampled_cells <- c(downsampled_cells, sampled)
      }
      se_sub <- subset(seurat_sub, cells = downsampled_cells)
    } else {
      se_sub <- seurat_sub
    }
    
    # STEP 6: Convert to SingleCellExperiment
    message("Converting to SingleCellExperiment...")
    sce <- as.SingleCellExperiment(se_sub)
    
    # Extract UMAP coordinates
    avail_reds <- names(se_sub@reductions)
    umap_red <- if("umap.harmony" %in% avail_reds) "umap.harmony" else
                if("umap.cca"     %in% avail_reds) "umap.cca"     else
                if("umap.rpca"    %in% avail_reds) "umap.rpca"    else
                if("umap.mnn"     %in% avail_reds) "umap.mnn"     else "umap"
    
    reduce_dim <- se_sub@reductions[[umap_red]]@cell.embeddings
    reducedDim(sce, "UMAP") <- reduce_dim
    
    # Robustness Fix: Remove cells with NA coordinates
    valid_coords <- !is.na(reduce_dim[,1]) & !is.na(reduce_dim[,2])
    message(paste("Cells with valid coordinates:", sum(valid_coords), "/", length(valid_coords)))
    if (sum(valid_coords) < 50) {
        message("Insufficient valid coordinates. Skipping.")
        dir.create("plots", showWarnings = FALSE)
        dir.create("results", showWarnings = FALSE)
        write.csv(data.frame(status="skipped", reason="insufficient_valid_coords"), "results/trajectory_skipped.csv", row.names=FALSE)
        saveRDS(sce, "results/slingshot_sce_full.rds")
        png("plots/01_slingshot_lineages.png"); plot.new(); text(0.5, 0.5, "Insufficient valid coordinates"); dev.off()
        quit(save = "no")
    }
    sce <- sce[, valid_coords]

    # Robustness Fix: Ensure clusters are factors and unused levels are dropped AFTER coordinate filtering
    sce\$seurat_clusters <- droplevels(factor(sce\$seurat_clusters))
    message(paste("Active clusters:", paste(levels(sce\$seurat_clusters), collapse=", ")))

    # Determine start cluster: prefer user choice, fallback to detected
    start_clus <- if(user_start_clus %in% levels(sce\$seurat_clusters)) user_start_clus else {
        cluster_celltype_table <- table(sce\$seurat_clusters, sce\$final_annotation)
        cd4_counts <- if ("CD4+ T cells" %in% colnames(cluster_celltype_table)) 
                          cluster_celltype_table[, "CD4+ T cells"] else 
                          rowSums(cluster_celltype_table)
        names(which.max(cd4_counts))
    }
    message(paste("Start Cluster identified:", start_clus))
    
    message("Running Slingshot...")
    # Robustness: Wrap in tryCatch and avoid problematic result-checkers
    sce <- tryCatch({
        slingshot(sce, clusterLabels = "seurat_clusters", 
                  reducedDim = 'UMAP', start.clus = start_clus)
    }, error = function(e) {
        message(paste(">>> Slingshot core failed:", e\$message))
        return(sce)
    })
    
    # Check for success by inspecting the object metadata directly (safer than SlingshotDataSet)
    has_slingshot <- "slingshot" %in% names(sce@int_metadata)
    if (!has_slingshot) {
        message(">>> Slingshot failed to initialize results. Saving object as-is. <<<")
        dir.create("plots", showWarnings = FALSE)
        dir.create("results", showWarnings = FALSE)
        write.csv(data.frame(status="skipped", reason="slingshot_na_error"), "results/trajectory_skipped.csv", row.names=FALSE)
        saveRDS(sce, "results/slingshot_sce_full.rds")
        saveRDS(se_sub, "results/seurat_t_nk_trajectory.rds")
        png("plots/01_slingshot_lineages.png"); plot.new(); text(0.5, 0.5, "Slingshot failed to generate results"); dev.off()
        quit(save = "no")
    }
    
    # STEP 9: Create Consensus Pseudotime
    message("Extracting consensus pseudotime...")
    curves <- slingCurves(sce)
    weights <- slingCurveWeights(sce)
    primary_lineage <- apply(weights, 1, which.max)
    pseudotime_matrix <- slingPseudotime(sce)
    
    slingshot_pt <- sapply(1:ncol(sce), function(i) {
        lineage <- primary_lineage[i]
        pseudotime_matrix[i, lineage]
    })
    sce\$slingshot_pseudotime <- slingshot_pt
    se_sub\$pseudotime <- slingshot_pt
    se_sub\$primary_lineage <- paste0("Lineage_", primary_lineage)
    
    # STEP 10: Visualize T/NK Trajectories
    message("Generating visualizations (Step 10)...")
    
    # 01. Lineages Plot (ggplot2)
    sds <- SlingshotDataSet(sce)
    umap_df <- data.frame(UMAP1=reduce_dim[,1], UMAP2=reduce_dim[,2], 
                          cell_type=se_sub\$final_annotation)
    
    p_lin <- ggplot(umap_df, aes(x=UMAP1, y=UMAP2, color=cell_type)) +
        geom_point(size=0.5, alpha=0.4) +
        theme_classic() + labs(title="Slingshot Trajectory Lineages", color="Cell Type") +
        scale_color_brewer(palette="Set1")
        
    # Overlay curves
    for (i in seq_along(slingCurves(sds))) {
      curve_data <- as.data.frame(slingCurves(sds)[[i]]\$s[slingCurves(sds)[[i]]\$ord, ])
      colnames(curve_data) <- c("UMAP1", "UMAP2")
      p_lin <- p_lin + geom_path(data=curve_data, color="black", linewidth=1.2, arrow=arrow(length=unit(0.2,"cm")))
    }
    ggsave("plots/01_slingshot_lineages.png", p_lin, width=10, height=8, dpi=150)
    
    # 02. Pseudotime Gradient
    umap_df <- data.frame(UMAP1=reduce_dim[,1], UMAP2=reduce_dim[,2], 
                          pseudotime=slingshot_pt, cell_type=se_sub\$final_annotation,
                          condition=se_sub\$condition, lineage=se_sub\$primary_lineage)
    
    p_grad <- ggplot(umap_df, aes(x=UMAP1, y=UMAP2, color=pseudotime)) +
        geom_point(size=0.8, alpha=0.8) +
        scale_color_viridis_c(option="plasma") +
        theme_classic() + labs(title="T/NK Pseudotime Gradient")
    ggsave("plots/02_pseudotime_gradient.png", p_grad, width=8, height=7, dpi=150)
    
    # 03. Violin Plot by Cell Type
    p_vln <- ggplot(umap_df, aes(x=reorder(cell_type, pseudotime, median), y=pseudotime, fill=cell_type)) +
        geom_violin(trim=FALSE) + geom_boxplot(width=0.1, fill="white", outlier.size=0.1) +
        coord_flip() + theme_classic() + labs(title="Pseudotime by Cell Type", x="") +
        scale_fill_brewer(palette="Set3")
    ggsave("plots/03_pseudotime_violin.png", p_vln, width=10, height=6, dpi=150)
    
    # 04. Density by Condition (Treatment Effects)
    p_dens <- ggplot(umap_df, aes(x=pseudotime, fill=condition)) +
        geom_density(alpha=0.5) + theme_classic() + 
        labs(title="Treatment Effect on Trajectory") +
        scale_fill_manual(values=c("Healthy"="#2E86AB","Post_Treatment"="#F18F01"))
    ggsave("plots/04_condition_density.png", p_dens, width=8, height=6, dpi=150)
    
    # STEP 11: Biological Validation (Expanded Marker Suite)
    message("Biological Validation (Step 11)...")
    markers <- c("CCR7", "LEF1", "TCF7", "CD69", "HLA-DRA", "IL2RA", "GZMB", "PRF1", "NKG7")
    markers <- markers[markers %in% rownames(sce)]
    val_results <- data.frame()
    for (m in markers) {
        expr <- logcounts(sce)[m, ]
        if(sd(expr) == 0) next
        ct <- cor.test(slingshot_pt, expr, method="spearman", exact=FALSE)
        val_results <- rbind(val_results, data.frame(gene=m, correlation=ct\$estimate, p_val=ct\$p.value))
    }
    write.csv(val_results, "results/marker_validation.csv", row.names=FALSE)

    
    # STEP 12: Treatment Effects Testing
    message("Treatment Effect Testing (Step 12)...")
    n_cond <- length(unique(umap_df\$condition))
    if (n_cond == 2) {
        wilcox_res <- wilcox.test(pseudotime ~ condition, data=umap_df)
        stat_res <- data.frame(test="Wilcoxon", p_val=wilcox_res\$p.value, 
                               method="pseudotime ~ condition", n_levels=n_cond)
        write.csv(stat_res, "results/treatment_effect_stat.csv", row.names=FALSE)
    } else if (n_cond > 2) {
        k_res <- kruskal.test(pseudotime ~ condition, data=umap_df)
        stat_res <- data.frame(test="Kruskal-Wallis", p_val=k_res\$p.value, 
                               method="pseudotime ~ condition", n_levels=n_cond)
        write.csv(stat_res, "results/treatment_effect_stat.csv", row.names=FALSE)
    } else {
        message("Skipping statistical test: Only one condition level present.")
    }

    
    # STEP 13: Whole-genome Correlation
    message("Identifying Trajectory-associated genes (Step 13)...")
    genes_to_test <- VariableFeatures(se_sub)
    if(length(genes_to_test) < 100) genes_to_test <- head(rownames(se_sub), 1000)
    
    # Use as.matrix carefully with large matrices
    gene_cors <- apply(as.matrix(logcounts(sce)[genes_to_test, ]), 1, function(x) {
        if(sd(x) == 0) return(0)
        cor(x, slingshot_pt, method="spearman")
    })
    sig_genes <- data.frame(gene=names(gene_cors), correlation=gene_cors) %>%
                 arrange(desc(abs(correlation)))
    write.csv(sig_genes, "results/trajectory_all_genes.csv", row.names=FALSE)
    
    # STEP 14: Expanded Visualizations (Tutorial Completeness)
    message("Generating expanded visualization suite...")
    
    # 00. Trajectory Overview Panel (CellType, Pseudotime, Condition, Lineage)
    if (requireNamespace("patchwork", quietly = TRUE)) {
        library(patchwork)
        theme_panel <- theme_void() + theme(plot.title=element_text(size=12, face="bold"), legend.position="bottom", legend.text=element_text(size=8))
        
        p_v1 <- ggplot(umap_df, aes(x=UMAP1, y=UMAP2, color=cell_type)) + geom_point(size=0.3, alpha=0.5) + labs(title="Cell Types") + theme_panel
        p_v2 <- ggplot(umap_df, aes(x=UMAP1, y=UMAP2, color=pseudotime)) + geom_point(size=0.3, alpha=0.5) + 
                scale_color_viridis_c(option="plasma", name="PT") + labs(title="Pseudotime") + theme_panel
        p_v3 <- ggplot(umap_df, aes(x=UMAP1, y=UMAP2, color=condition)) + geom_point(size=0.3, alpha=0.5) + labs(title="Condition") + theme_panel
        p_v4 <- ggplot(umap_df, aes(x=UMAP1, y=UMAP2, color=factor(lineage))) + geom_point(size=0.3, alpha=0.5) + labs(title="Lineage") + theme_panel
        
        p_overview <- (p_v1 + p_v2) / (p_v3 + p_v4) + plot_annotation(title="T/NK Trajectory Analysis Overview")
        ggsave("plots/00_trajectory_overview.png", p_overview, width=14, height=12, dpi=150)
    }

    # 05. Individual Marker Gene Trajectory Plots
    for (m in markers) {
        p_m <- ggplot(umap_df, aes(x=UMAP1, y=UMAP2, color=as.numeric(logcounts(sce)[m, ]))) +
            geom_point(size=0.8, alpha=0.8) +
            scale_color_viridis_c(option="magma", name="LogExpr") +
            theme_classic() + labs(title=paste("Expression of", m, "Along Trajectory"))
        ggsave(paste0("plots/marker_", m, ".png"), p_m, width=6, height=5, dpi=150)
    }
    
    # 06. Top Trajectory Genes Grid (Top 9)
    top_9_genes <- head(sig_genes\$gene, 9)
    plot_list <- list()
    for (g in top_9_genes) {
        plot_list[[g]] <- ggplot(umap_df, aes(x=UMAP1, y=UMAP2, color=as.numeric(logcounts(sce)[g, ]))) +
            geom_point(size=0.4, alpha=0.6) +
            scale_color_viridis_c(option="magma") +
            theme_void() + theme(legend.position="none", plot.title=element_text(size=10)) +
            labs(title=g)
    }
    
    if (requireNamespace("patchwork", quietly = TRUE)) {
        p_grid <- wrap_plots(plot_list, ncol=3) + plot_annotation(title="Top 9 Trajectory-Associated Genes")
        ggsave("plots/05_top_trajectory_genes.png", p_grid, width=12, height=10, dpi=150)
    }
    
    # 07. Custom Pseudotime Density by Lineage (Tutorial Step 12 custom)
    p_dens_lin <- ggplot(umap_df, aes(x=pseudotime, fill=condition)) +
        geom_density(alpha=0.6) +
        facet_wrap(~lineage, scales="free_y") +
        theme_classic() + labs(title="Pseudotime Density per Lineage", x="Pseudotime")
    ggsave("plots/06_pseudotime_density_per_lineage.png", p_dens_lin, width=10, height=8, dpi=150)


    # STEP 15: Integrate back to Seurat
    message("Saving final results...")
    saveRDS(sce, "results/slingshot_sce_full.rds")
    saveRDS(se_sub, "results/seurat_t_nk_trajectory.rds")
    message("Slingshot analysis complete.")
    ENDSCRIPT
    Rscript traj_script.R ${params.traj_start} ${params.traj_downsample} ${params.traj_subset}
    """
}
// ============================================================================
//  PROCESS 9: CELLCHAT (Part 9)
// ============================================================================
process CELLCHAT {
    tag "cellchat"
    publishDir "${params.outdir}/09_cellchat", mode: 'copy'
    label 'process_high'
    input:  path rds
    output:
        path "plots/**/*.png", optional: true
        path "results/*.rds", optional: true
        path "results/*.txt", optional: true
    script:
    """
    cat > cc_script.R << 'ENDSCRIPT'
    suppressPackageStartupMessages({
        library(CellChat)
        library(Seurat)
        library(ggplot2)
        library(patchwork)
        library(NMF)
        library(foreach)
        library(ggalluvial)
        library(reticulate)
        library(AnnotationDbi)
        library(org.Hs.eg.db)
    })

    # ── Python env for netEmbedding (UMAP) ────────────────────────────────────
    message(">>> Setting up Python env for UMAP <<<")
    try({
        virtualenv_create("r-reticulate")
        virtualenv_install("r-reticulate", packages = c("umap-learn"))
        use_virtualenv("r-reticulate", required = TRUE)
    }, silent = TRUE)

    options(stringsAsFactors = FALSE)
    registerDoSEQ()
    dir.create("results", recursive = TRUE, showWarnings = FALSE)

    se <- readRDS("${rds}")

    prepare_cc <- function(obj) {
        obj\$samples <- factor(obj\$sample_id)
        # Auto-detect whether final_annotation is meaningful
        annot_vals  <- obj\$final_annotation
        n_unknown   <- sum(is.na(annot_vals) | annot_vals == "Unknown" | annot_vals == "")
        n_total     <- length(annot_vals)
        n_types     <- length(unique(annot_vals[annot_vals != "Unknown" & !is.na(annot_vals)]))
        pct_unknown <- n_unknown / n_total
        if (n_types < 2 || pct_unknown > 0.7) {
            message(sprintf("WARNING: final_annotation is %.0f%% Unknown (%d types). Falling back to seurat_clusters.",
                            pct_unknown * 100, n_types))
            obj\$cellchat_group <- paste0("Cluster_", obj\$seurat_clusters)
        } else {
            message(sprintf("Using final_annotation (%d types, %.0f%% Unknown).", n_types, pct_unknown * 100))
            obj\$cellchat_group <- as.character(obj\$final_annotation)
            obj\$cellchat_group[is.na(obj\$cellchat_group) | obj\$cellchat_group == "Unknown"] <- paste0("Cluster_", obj\$seurat_clusters[is.na(obj\$cellchat_group) | obj\$cellchat_group == "Unknown"])
        }
        Idents(obj) <- "cellchat_group"
        return(obj)
    }

    message(">>> Starting Complete CellChat Suite <<<")
    conditions <- sort(unique(se\$condition))
    cc_list    <- list()

    # Pathways of Interest — includes FSHD-relevant muscle signaling
    pathways_of_interest <- c("CD99", "CLEC", "MHC-I", "MHC-II", "MIF",
                              "FGF", "PDGF", "VEGF", "TGFb", "WNT",
                              "COLLAGEN", "LAMININ", "FN1", "IGF", "EGF")

    # ══════════════════════════════════════════════════════════════════════════
    # PART 1 — Per-condition Analysis
    # ══════════════════════════════════════════════════════════════════════════
    for (cond in conditions) {
        message(paste("--- Processing Condition:", cond, "---"))
        cond_label <- gsub(" ", "_", tolower(cond))
        out_dir    <- paste0("plots/", cond_label)
        dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

        sub_se <- subset(se, subset = condition == cond)
        if (ncol(sub_se) < 20) {
            message("Too few cells, skipping...")
            next
        }

        # prepare_cc must run FIRST to create the cellchat_group column
        sub_se <- prepare_cc(sub_se)
        ct_counts  <- table(sub_se\$cellchat_group)
        keep_types <- names(which(ct_counts >= 10))
        sub_se     <- subset(sub_se, subset = cellchat_group %in% keep_types)
        if (ncol(sub_se) < 20) next

        # CellChat v2 + Seurat v5 compatibility:
        # Extract data matrix directly to avoid Assay5 slot-access incompatibility
        DefaultAssay(sub_se) <- "RNA"
        if (inherits(sub_se[["RNA"]], "Assay5")) {
            message("Seurat v5 detected: extracting RNA data matrix directly for CellChat...")
            sub_se <- JoinLayers(sub_se, assay = "RNA")
        }
        # Get the counts layer (always exists)
        rna_counts <- tryCatch(
            GetAssayData(sub_se, assay = "RNA", layer = "counts"),
            error = function(e) GetAssayData(sub_se, assay = "RNA", slot = "counts")
        )
        # Try to get pre-normalized data layer
        rna_data <- tryCatch(
            GetAssayData(sub_se, assay = "RNA", layer = "data"),
            error = function(e) GetAssayData(sub_se, assay = "RNA", slot = "data")
        )
        # Check if data layer has real normalized values (max > 0 means it has been log-normalized)
        max_data_val <- if (!is.null(rna_data) && nrow(rna_data) > 0 && ncol(rna_data) > 0) max(rna_data) else 0
        if (max_data_val == 0) {
            message("data layer is all-zero or empty. Log-normalizing counts for CellChat...")
            cs <- Matrix::colSums(rna_counts)
            cs[cs == 0] <- 1  # avoid divide-by-zero
            rna_data <- Matrix::t(Matrix::t(rna_counts) / cs) * 10000
            rna_data <- log1p(rna_data)
        } else {
            message(sprintf("Using pre-normalized data layer (max=%.2f).", max_data_val))
        }
        # Final guard: abort condition if still empty
        if (is.null(rna_data) || nrow(rna_data) == 0 || ncol(rna_data) == 0) {
            message("WARNING: RNA data matrix is empty for condition ", cond, " - skipping")
            next
        }
        # Convert Ensembl IDs -> HGNC symbols (CellChatDB requires gene symbols)
        if (nrow(rna_data) > 0 && any(grepl("^ENSG", head(rownames(rna_data), 100)))) {
            message("Detected Ensembl IDs - converting to HGNC symbols for CellChat...")
            gene_syms <- tryCatch(
                AnnotationDbi::mapIds(org.Hs.eg.db, keys = rownames(rna_data),
                                      keytype = "ENSEMBL", column = "SYMBOL",
                                      multiVals = "first"),
                error = function(e) { message("org.Hs.eg.db mapIds failed: ", e\$message); NULL }
            )
            if (!is.null(gene_syms)) {
                valid <- !is.na(gene_syms) & nchar(gene_syms) > 0
                rna_sym <- rna_data[valid, ]
                syms    <- gene_syms[valid]
                # Deduplicate: keep gene with highest mean expression
                dup <- duplicated(syms)
                if (any(dup)) {
                    rmeans <- Matrix::rowMeans(rna_sym)
                    keep   <- rep(TRUE, length(syms))
                    for (s in unique(syms[dup])) {
                        ii <- which(syms == s)
                        keep[ii[-which.max(rmeans[ii])]] <- FALSE
                    }
                    rna_sym <- rna_sym[keep, ]
                    syms    <- syms[keep]
                }
                rownames(rna_sym) <- syms
                rna_data <- rna_sym
                message(sprintf("Ensembl->symbol: %d symbols mapped for CellChat", nrow(rna_data)))
            } else {
                message("WARNING: Could not map Ensembl IDs to symbols (mapping failed)")
            }
        }

        cc_meta <- data.frame(group = sub_se\$cellchat_group,
                              row.names = colnames(sub_se))
        message(sprintf("Creating CellChat from matrix: %d genes x %d cells, %d groups",
                        nrow(rna_data), ncol(rna_data), length(unique(cc_meta\$group))))
        cc <- createCellChat(object = rna_data, meta = cc_meta, group.by = "group")
        cc@DB <- CellChatDB.human
        cc <- subsetData(cc)

        # Diagnostic: verify CellChat DB gene overlap
        n_sig_genes <- nrow(cc@data.signaling)
        message(sprintf("After subsetData: %d signaling genes in data.signaling", n_sig_genes))
        if (n_sig_genes == 0) {
            message("Gene name diagnostic for condition: ", cond)
            message("First 10 gene names in matrix: ", paste(head(rownames(rna_data), 10), collapse=", "))
            known_cc <- c("MIF", "CD74", "CD44", "EGFR", "CD99", "PDGFRA", "COL1A1", "VEGFA", "TGFB1")
            found_cc <- known_cc[known_cc %in% rownames(rna_data)]
            message(sprintf("Known CellChat genes found: %s (%d/%d)",
                            if (length(found_cc) > 0) paste(found_cc, collapse=",") else "NONE",
                            length(found_cc), length(known_cc)))
            message("SKIPPING condition ", cond, " - no signaling genes found. Gene name mismatch?")
            next
        }

        cc <- identifyOverExpressedGenes(cc)
        cc <- identifyOverExpressedInteractions(cc)
        cc <- computeCommunProb(cc, type = "triMean", nboot = 100)
        cc <- filterCommunication(cc, min.cells = 10)
        cc <- computeCommunProbPathway(cc)
        cc <- aggregateNet(cc)
        cc <- netAnalysis_computeCentrality(cc, slot.name = "netP")

        # ── Global Root Plots (01-19) ─────────────────────────────────────────
        groupSize <- as.numeric(table(cc@idents))
        
        # 01a/01b Circle Plots
        png(paste0(out_dir, "/01a_interaction_count.png"), width = 750, height = 750, res = 150)
        netVisual_circle(cc@net\$count, vertex.weight = groupSize, weight.scale = T, title.name = "Count")
        dev.off()
        png(paste0(out_dir, "/01b_interaction_strength.png"), width = 750, height = 750, res = 150)
        netVisual_circle(cc@net\$weight, vertex.weight = groupSize, weight.scale = T, title.name = "Strength")
        dev.off()

        # 01_interaction_circles (Tutorial style)
        png(paste0(out_dir, "/01_interaction_circles.png"), width = 1200, height = 700, res = 150)
        par(mfrow = c(1,2))
        netVisual_circle(cc@net\$count, vertex.weight = groupSize, title.name = "Count")
        netVisual_circle(cc@net\$weight, vertex.weight = groupSize, title.name = "Weight")
        dev.off()

        # 02_role_heatmap (Outgoing)
        png(paste0(out_dir, "/02_role_heatmap.png"), width = 1000, height = 1200, res = 150)
        print(netAnalysis_signalingRole_heatmap(cc, pattern = "outgoing", color.heatmap = "GnBu"))
        dev.off()

        # 08_bubble_all_interactions
        png(paste0(out_dir, "/08_bubble_all_interactions.png"), width = 1600, height = 1400, res = 150)
        print(netVisual_bubble(cc, remove.isolate = FALSE, angle.x = 45))
        dev.off()

        # 10b_signaling_role_heatmap_incoming
        png(paste0(out_dir, "/10b_signaling_role_heatmap_incoming.png"), width = 1000, height = 1200, res = 150)
        print(netAnalysis_signalingRole_heatmap(cc, pattern = "incoming", color.heatmap = "OrRd"))
        dev.off()

        # 11_signaling_role_scatter
        png(paste0(out_dir, "/11_signaling_role_scatter.png"), width = 800, height = 800, res = 150)
        print(netAnalysis_signalingRole_scatter(cc))
        dev.off()

        # ── Pathway Specific Folders ──────────────────────────────────────────
        for (pw in pathways_of_interest) {
            if (pw %in% cc@netP\$pathways) {
                pw_dir <- paste0(out_dir, "/", pw)
                dir.create(pw_dir, recursive = TRUE, showWarnings = FALSE)
                
                # 02_hierarchy
                png(paste0(pw_dir, "/02_hierarchy.png"), width = 1200, height = 800, res = 150)
                try(netVisual_aggregate(cc, signaling = pw, layout = "hierarchy"))
                dev.off()
                
                # 03_circle
                png(paste0(pw_dir, "/03_circle.png"), width = 800, height = 800, res = 150)
                netVisual_aggregate(cc, signaling = pw, layout = "circle")
                dev.off()
                
                # 04_chord
                png(paste0(pw_dir, "/04_chord.png"), width = 1200, height = 1200, res = 150)
                par(mar = c(0,0,0,0))
                netVisual_aggregate(cc, signaling = pw, layout = "chord")
                dev.off()
                
                # 05_LR_contribution
                png(paste0(pw_dir, "/05_LR_contribution.png"), width = 800, height = 600, res = 150)
                print(netAnalysis_contribution(cc, signaling = pw))
                dev.off()
                
                # 06_top_LR_pair
                pairLR <- extractEnrichedLR(cc, signaling = pw, geneLR.return = FALSE)
                if (!is.null(pairLR) && nrow(pairLR) > 0) {
                    png(paste0(pw_dir, "/06_top_LR_pair.png"), width = 800, height = 800, res = 150)
                    netVisual_individual(cc, signaling = pw, pairLR.use = pairLR[1,], layout = "circle")
                    dev.off()
                }
                
                # 08_gene_expression
                try({
                    lr_df <- subsetCommunication(cc, signaling = pw)
                    genes <- unique(c(lr_df\$ligand, lr_df\$receptor))
                    genes <- genes[genes %in% rownames(sub_se)]
                    if (length(genes) > 0) {
                        png(paste0(pw_dir, "/08_gene_expression.png"), width = 1200, height = 800, res = 150)
                        print(VlnPlot(sub_se, features = genes, group.by = "final_annotation", pt.size = 0) & theme(axis.text.x = element_text(angle = 45, hjust = 1)))
                        dev.off()
                    }
                }, silent = TRUE)
            }
        }

        # ── NMF Patterns (Restoring 12-17) ───────────────────────────────────
        try({
            options(future.rng.onMisuse="ignore")
            # Outgoing
            png(paste0(out_dir, "/12_selectK_outgoing.png"), width = 800, height = 600, res = 150)
            selectK(cc, pattern = "outgoing")
            dev.off()
            
            # Use k=3 as robust fallback
            cc <- identifyCommunicationPatterns(cc, pattern = "outgoing", k = 3)
            png(paste0(out_dir, "/13_pattern_river_outgoing.png"), width = 1200, height = 900, res = 150)
            netAnalysis_river(cc, pattern = "outgoing")
            dev.off()
            png(paste0(out_dir, "/14_pattern_dot_outgoing.png"), width = 1000, height = 1000, res = 150)
            netAnalysis_dot(cc, pattern = "outgoing")
            dev.off()

            # Incoming
            png(paste0(out_dir, "/15_selectK_incoming.png"), width = 800, height = 600, res = 150)
            selectK(cc, pattern = "incoming")
            dev.off()

            cc <- identifyCommunicationPatterns(cc, pattern = "incoming", k = 3)
            png(paste0(out_dir, "/16_pattern_river_incoming.png"), width = 1200, height = 900, res = 150)
            netAnalysis_river(cc, pattern = "incoming")
            dev.off()
            png(paste0(out_dir, "/17_pattern_dot_incoming.png"), width = 1000, height = 1000, res = 150)
            netAnalysis_dot(cc, pattern = "incoming")
            dev.off()
        }, silent = TRUE)

        # ── Manifold Learning (Restoring 18-19) ──────────────────────────────
        try({
            cc <- computeNetSimilarity(cc, type = "functional")
            cc <- netEmbedding(cc, type = "functional")
            cc <- netClustering(cc, type = "functional")
            png(paste0(out_dir, "/18_pathway_functional_embedding.png"), width = 1000, height = 800, res = 150)
            netVisual_embedding(cc, type = "functional", label.size = 3.5)
            dev.off()
            png(paste0(out_dir, "/19_pathway_functional_embedding_zoom.png"), width = 1200, height = 1000, res = 150)
            netVisual_embeddingZoomIn(cc, type = "functional", nCol = 2)
            dev.off()
        }, silent = TRUE)

        saveRDS(cc, file = paste0("results/cellchat_", cond_label, ".rds"))
        cc_list[[cond]] <- cc
    }

    # ══════════════════════════════════════════════════════════════════════════
    # PART 2 — Comparative Analysis (Plots 20-38)
    # ══════════════════════════════════════════════════════════════════════════
    if (length(cc_list) >= 2) {
        message(">>> Starting Comparative Analysis <<<")
        dir.create("plots/comparison", recursive = TRUE, showWarnings = FALSE)

        cell_groups <- unique(unlist(lapply(cc_list, function(x) levels(x@idents))))
        cc_list <- lapply(cc_list, function(x) liftCellChat(x, group.new = cell_groups))
        merged <- mergeCellChat(cc_list, add.names = names(cc_list))

        # 20-21: Count vs Strength
        gg1 <- compareInteractions(merged, show.legend = FALSE, group = 1:length(cc_list))
        gg2 <- compareInteractions(merged, show.legend = FALSE, group = 1:length(cc_list), measure = "weight")
        png("plots/comparison/20_21_interaction_count_vs_strength.png", width = 1200, height = 750, res = 150)
        print(gg1 + gg2)
        dev.off()

        # 22: Circle per condition
        for (i in 1:length(cc_list)) {
            cl <- names(cc_list)[i]
            png(paste0("plots/comparison/22_circle_", cl, ".png"), width = 750, height = 750, res = 150)
            netVisual_circle(cc_list[[i]]@net\$count, weight.scale = T, title.name = cl)
            dev.off()
        }

        # 23-24: Differential Circles
        png("plots/comparison/23_diff_interactions_count.png", width = 800, height = 800, res = 150)
        netVisual_diffInteraction(merged, weight.scale = TRUE)
        dev.off()
        png("plots/comparison/24_diff_interactions_strength.png", width = 800, height = 800, res = 150)
        netVisual_diffInteraction(merged, weight.scale = TRUE, measure = "weight")
        dev.off()

        # 25-26: Differential Heatmaps
        png("plots/comparison/25_26_differential_heatmaps.png", width = 1800, height = 750, res = 150)
        print(netVisual_heatmap(merged) + netVisual_heatmap(merged, measure = "weight"))
        dev.off()

        # 27-28: RankNet
        png("plots/comparison/27_rankNet_stacked.png", width = 1100, height = 1400, res = 150)
        print(rankNet(merged, mode = "comparison", stacked = TRUE, do.stat = TRUE))
        dev.off()
        png("plots/comparison/28_rankNet_sidebyside.png", width = 1100, height = 1400, res = 150)
        print(rankNet(merged, mode = "comparison", stacked = FALSE))
        dev.off()

        # 29-32: Role Heatmaps (Comparison)
        for (i in 1:length(cc_list)) {
            cl <- names(cc_list)[i]
            png(paste0("plots/comparison/", 28+i, "_outgoing_role_heatmap_", cl, ".png"), width = 1200, height = 1200, res = 150)
            print(netAnalysis_signalingRole_heatmap(cc_list[[i]], pattern = "outgoing", color.heatmap = "GnBu"))
            dev.off()
            png(paste0("plots/comparison/", 30+i, "_incoming_role_heatmap_", cl, ".png"), width = 1200, height = 1200, res = 150)
            print(netAnalysis_signalingRole_heatmap(cc_list[[i]], pattern = "incoming", color.heatmap = "OrRd"))
            dev.off()
        }

        # 33-35: Targeted Crosstalk (Monocyte -> T cell)
        try({
            all_types <- levels(merged@idents\$joint)
            src <- intersect(c("Classical Monocytes", "Monocytes"), all_types)
            tgt <- intersect(c("CD4+ T cells", "CD8+ T cells", "T cells"), all_types)
            if (length(src) > 0 && length(tgt) > 0) {
                png("plots/comparison/33_bubble_monocyte_to_Tcells.png", width = 1500, height = 1400, res = 150)
                print(netVisual_bubble(merged, sources.use = src, targets.use = tgt, comparison = c(1,2)))
                dev.off()
                
                png("plots/comparison/34_chord_monocyte_to_Tcell_cond1.png", width = 1200, height = 1200, res = 150)
                netVisual_chord_gene(cc_list[[1]], sources.use = src[1], targets.use = tgt[1])
                dev.off()
                
                png("plots/comparison/35_chord_monocyte_to_Tcell_cond2.png", width = 1200, height = 1200, res = 150)
                netVisual_chord_gene(cc_list[[2]], sources.use = src[1], targets.use = tgt[1])
                dev.off()
            }
        }, silent = TRUE)

        # 36-38: Manifold Learning & RankSimilarity (Comparative)
        try({
            merged <- computeNetSimilarityPairwise(merged, type = "functional")
            merged <- netEmbedding(merged, type = "functional")
            merged <- netClustering(merged, type = "functional")
            png("plots/comparison/36_pairwise_embedding.png", width = 1200, height = 1000, res = 150)
            netVisual_embeddingPairwise(merged, type = "functional", label.size = 3.5)
            dev.off()
            png("plots/comparison/37_pairwise_embedding_zoom.png", width = 1400, height = 1200, res = 150)
            netVisual_embeddingPairwiseZoomIn(merged, type = "functional", nCol = 2)
            dev.off()
            png("plots/comparison/38_rankSimilarity.png", width = 900, height = 1200, res = 150)
            print(rankSimilarity(merged, type = "functional"))
            dev.off()
        }, silent = TRUE)

        saveRDS(merged, "results/cellchat_merged.rds")
    }

    saveRDS(cc_list, "results/cellchat_list.rds")
    if (length(cc_list) == 0) {
        message("WARNING: No conditions produced valid CellChat objects. Writing placeholder.")
        writeLines("No CellChat results - check gene name format in integrated_annotated.rds",
                   "results/cellchat_FAILED.txt")
    }
    message(">>> CellChat Analysis Complete <<<")
    ENDSCRIPT
    Rscript cc_script.R
    """
}

// ============================================================================
//  PROCESS 10: NICHENET (Part 10) – Full 15-Step Suite
//  Inferred upstream ligands, mechanistic signaling paths, and L-R pairs
// ============================================================================
process NICHENET {
    tag "nichenet"
    publishDir "${params.outdir}/10_nichenet", mode: 'copy'
    label 'process_high'
    input:  path rds
    output: 
        path "plots/*.pdf", optional: true
        path "plots/*.png", optional: true
        path "results/*.csv", optional: true
        path "results/*.rds", optional: true
    script:
    """
    mkdir -p plots nichenet_db results
    export NICHENET_MODELS_DIR="${params.nichenet_models}"
    cat > nn_script.R << 'ENDSCRIPT'
    # ── Model Loading Strategy ────────────────────────────────────────────────
    # Priority 1: Local pre-downloaded dir (params.nichenet_models)
    # Priority 2: Cached in work-dir nichenet_db/
    # Priority 3: Download from Zenodo (last resort)
    options(timeout = 1800)

    local_models_dir <- Sys.getenv("NICHENET_MODELS_DIR", "")

    load_model <- function(filename, url, cache_path) {
        local_path <- if (nchar(local_models_dir) > 0) file.path(local_models_dir, filename) else ""
        if (nchar(local_path) > 0 && file.exists(local_path)) {
            message(paste(">>> Using local model:", local_path))
            return(readRDS(local_path))
        }
        if (file.exists(cache_path)) {
            message(paste(">>> Using cached model:", cache_path))
            return(readRDS(cache_path))
        }
        message(paste(">>> Downloading", filename, "from Zenodo ..."))
        tryCatch({
            download.file(url, cache_path, mode = "wb", quiet = FALSE)
        }, error = function(e) {
            stop(paste("Download failed for", filename, "- Set params.nichenet_models to a local dir with pre-downloaded models."))
        })
        return(readRDS(cache_path))
    }

    suppressPackageStartupMessages({ 
        library(nichenetr)
        library(Seurat)
        library(tidyverse)
        library(ComplexHeatmap)
        library(circlize)
        library(igraph)
        library(ggraph)
        library(patchwork)
        library(AnnotationDbi)
        library(org.Hs.eg.db)
    })
    
    # ── Step 1: Load Data & Model ─────────────────────────────────────────────
    message(">>> Step 1: Loading Data and Models <<<")
    seurat_obj <- readRDS("${rds}")
        # Convert Ensembl IDs -> HGNC symbols
        if (nrow(seurat_obj) > 0 && any(grepl("^ENSG", head(rownames(seurat_obj), 100)))) {
            message("Detected Ensembl IDs - converting to HGNC symbols...")
            gene_syms <- tryCatch(
                AnnotationDbi::mapIds(org.Hs.eg.db, keys = rownames(seurat_obj),
                                      keytype = "ENSEMBL", column = "SYMBOL",
                                      multiVals = "first"),
                error = function(e) { message("org.Hs.eg.db mapIds failed: ", e\$message); NULL }
            )
            if (!is.null(gene_syms)) {
                valid <- !is.na(gene_syms) & nchar(gene_syms) > 0
                se_sym <- seurat_obj[valid, ]
                syms    <- gene_syms[valid]
                dup <- duplicated(syms)
                if (any(dup)) {
                    rna_data <- if (inherits(se_sym[["RNA"]], "Assay5")) JoinLayers(se_sym, assay="RNA")[["RNA"]]\$data else GetAssayData(se_sym, assay="RNA", slot="data")
                    rmeans <- Matrix::rowMeans(rna_data)
                    keep <- rep(TRUE, length(syms))
                    for (s in unique(syms[dup])) {
                        ii <- which(syms == s)
                        keep[ii[-which.max(rmeans[ii])]] <- FALSE
                    }
                    se_sym <- se_sym[keep, ]
                    syms   <- syms[keep]
                }
                # Manually update row names in all layers for Seurat v5
                try({
                    rownames(se_sym@assays\$RNA@counts) <- syms
                    rownames(se_sym@assays\$RNA@data)   <- syms
                }, silent=TRUE)
                seurat_obj <- se_sym
                message(sprintf("Ensembl->symbol: %d symbols mapped", nrow(seurat_obj)))
            }
        }
    
    # Download Human Prior Models (Zenodo 7074291)
    lr_network           <- load_model("lr_network_human_21122021.rds",       "https://zenodo.org/record/7074291/files/lr_network_human_21122021.rds",       "nichenet_db/lr_network.rds")
    ligand_target_matrix <- load_model("ligand_target_matrix_nsga2r_final.rds", "https://zenodo.org/record/7074291/files/ligand_target_matrix_nsga2r_final.rds", "nichenet_db/ligand_target_matrix.rds")
    weighted_networks    <- load_model("weighted_networks_nsga2r_final.rds",   "https://zenodo.org/record/7074291/files/weighted_networks_nsga2r_final.rds",   "nichenet_db/weighted_networks.rds")
    ligand_tf_matrix     <- load_model("ligand_tf_matrix_nsga2r_final.rds",    "https://zenodo.org/record/7074291/files/ligand_tf_matrix_nsga2r_final.rds",    "nichenet_db/ligand_tf_matrix.rds")

    lr_network <- lr_network %>% distinct(from, to)
    Idents(seurat_obj) <- seurat_obj\$final_annotation

    # ── Step 2: Define Receiver & Senders ─────────────────────────────────────
    message(">>> Step 2: Defining Receiver and Senders <<<")
    receiver <- "${params.nichenet_receiver}"
    if (!(receiver %in% levels(seurat_obj))) {
        message(paste("Receiver '${params.nichenet_receiver}' not found. Falling back to largest cluster."))
        receiver <- names(sort(table(seurat_obj\$final_annotation), decreasing=TRUE))[1]
    }
    
    sender_param <- "${params.nichenet_sender}"
    all_cell_types <- unique(Idents(seurat_obj))
    
    if (sender_param == "" || sender_param == "all") {
        sender_celltypes <- all_cell_types[all_cell_types != receiver]
    } else {
        sender_celltypes <- unlist(strsplit(sender_param, ","))
        sender_celltypes <- intersect(sender_celltypes, all_cell_types)
        if (length(sender_celltypes) == 0) {
            message("Requested senders not found. Falling back to all other clusters.")
            sender_celltypes <- all_cell_types[all_cell_types != receiver]
        }
    }
    
    condition_oi        <- "${params.nichenet_condition_oi}"
    condition_reference <- "${params.nichenet_condition_ref}"
    
    # Check if conditions exist
      avail_conds <- unique(seurat_obj\$condition)
  if (is.null(avail_conds) || length(avail_conds) < 2) {
      message(">>> Only one condition found. NicheNet requires at least two to compare. Skipping. <<<")
      dir.create("plots", showWarnings = FALSE)
      dir.create("results", showWarnings = FALSE)
      write.csv(data.frame(status="skipped", reason="single_condition"), "results/nichenet_skipped.csv")
      saveRDS(list(), "results/nichenet_final_results.rds")
      quit(save = "no")
  }

  if (condition_oi == condition_reference || !(condition_oi %in% avail_conds) || !(condition_reference %in% avail_conds)) {
      message("Target conditions not found, missing, or identical. Attempting dynamic detection...")
      condition_oi <- if ("Post_Treatment" %in% avail_conds) "Post_Treatment" else if ("Tumor" %in% avail_conds) "Tumor" else avail_conds[1]
      condition_reference <- if ("Healthy" %in% avail_conds) "Healthy" else if ("Control" %in% avail_conds) "Control" else avail_conds[avail_conds != condition_oi][1]
  
      if (is.na(condition_reference) || condition_oi == condition_reference) {
          message(">>> Could not identify two distinct conditions. Skipping. <<<")
          dir.create("plots", showWarnings = FALSE)
          dir.create("results", showWarnings = FALSE)
          write.csv(data.frame(status="skipped", reason="no_comparison_found"), "results/nichenet_skipped.csv")
          saveRDS(list(), "results/nichenet_final_results.rds")
          quit(save = "no")
      }
      message(paste("Now using:", condition_oi, "vs", condition_reference))
  }
    }

    # ── Step 3: Expressed Genes ───────────────────────────────────────────────
    message(">>> Step 3: Identifying Expressed Genes <<<")
    expr_mat    <- GetAssayData(seurat_obj, assay = "RNA", layer = "counts")
    cell_idents <- Idents(seurat_obj)
    
    expressed_genes_receiver <- get_expressed_genes(receiver, expr_mat, cell_idents, pct = 0.10)
    background_expressed_genes <- expressed_genes_receiver %>% .[. %in% rownames(ligand_target_matrix)]
    
    list_expressed_genes_sender  <- sender_celltypes %>% lapply(function(ct) get_expressed_genes(ct, expr_mat, cell_idents, pct = 0.10))
    expressed_genes_sender <- list_expressed_genes_sender %>% unlist() %>% unique()

    # ── Step 4: Gene Set of Interest ──────────────────────────────────────────
    message(">>> Step 4: Defining Gene Set of Interest <<<")
    seurat_receiver <- subset(seurat_obj, idents = receiver)
    Idents(seurat_receiver) <- seurat_receiver\$condition
    
    DE_table_receiver <- FindMarkers(seurat_receiver, ident.1 = condition_oi, ident.2 = condition_reference, min.pct = 0.10)
    
    if (nrow(DE_table_receiver) == 0) {
        stop(paste("No differentially expressed genes found between", condition_oi, "and", condition_reference))
    }
    
    geneset_oi <- DE_table_receiver %>% 
        rownames_to_column("gene") %>%
        filter(p_val_adj <= 0.05 & avg_log2FC >= 0.25) %>% 
        pull(gene) %>%
        intersect(rownames(ligand_target_matrix))
        
    if (length(geneset_oi) < 5) {
        message("Not enough DE genes. Relaxing thresholds...")
        geneset_oi <- DE_table_receiver %>% 
            filter(p_val_adj <= 0.10 & avg_log2FC >= 0.10) %>% 
            rownames() %>% 
            intersect(rownames(ligand_target_matrix))
    }

        # ── Step 5: Define Potential Ligands ──────────────────────────────────────
    message(">>> Step 5: Defining Potential Ligands <<<")
    expressed_receptors <- intersect(lr_network\$to, expressed_genes_receiver)
    all_genes_detected  <- rownames(seurat_obj)
    
    potential_ligands_agnostic <- lr_network %>% filter(to %in% expressed_receptors) %>% pull(from) %>% unique() %>% intersect(all_genes_detected)
    
    expressed_ligands_sender <- intersect(lr_network\$from, expressed_genes_sender)
    potential_ligands_focused <- lr_network %>% filter(from %in% expressed_ligands_sender & to %in% expressed_receptors) %>% pull(from) %>% unique()
    
    message(sprintf("Expressed receptors: %d", length(expressed_receptors)))
    message(sprintf("Potential ligands (agnostic): %d", length(potential_ligands_agnostic)))
    message(sprintf("Potential ligands (focused): %d", length(potential_ligands_focused)))
    
    if (length(potential_ligands_agnostic) == 0) {
        message("No potential ligands found. Using all genes in lr_network as fallback.")
        potential_ligands_agnostic <- intersect(lr_network\$from, all_genes_detected)
    }
    if (length(potential_ligands_focused) == 0) {
        potential_ligands_focused <- potential_ligands_agnostic
    }

    # ── Step 6: Ligand Activity ───────────────────────────────────────────────
    message(">>> Step 6: Running Ligand Activity Analysis <<<")
    message(sprintf("Geneset of interest: %d genes", length(geneset_oi)))
    if (length(geneset_oi) < 2 || length(potential_ligands_agnostic) == 0) {
        message(sprintf(">>> Input too small for NicheNet (geneset=%d, ligands=%d). Skipping. <<<", length(geneset_oi), length(potential_ligands_agnostic)))
        dir.create("plots", showWarnings = FALSE)
        dir.create("results", showWarnings = FALSE)
        write.csv(data.frame(status="skipped", reason="small_input"), "results/nichenet_skipped.csv")
        saveRDS(list(), "results/nichenet_final_results.rds")
        quit(save = "no")
    }
    ligand_activities_agnostic <- predict_ligand_activities(geneset = geneset_oi, background_expressed_genes = background_expressed_genes,
                                                          ligand_target_matrix = ligand_target_matrix, potential_ligands = potential_ligands_agnostic) %>%
                                  arrange(desc(aupr_corrected)) %>% mutate(rank = row_number())
                                  
    ligand_activities_focused  <- predict_ligand_activities(geneset = geneset_oi, background_expressed_genes = background_expressed_genes,
                                                          ligand_target_matrix = ligand_target_matrix, potential_ligands = potential_ligands_focused) %>%
                                  arrange(desc(aupr_corrected)) %>% mutate(rank = row_number())

    # ── Step 7: Select Top Ligands ────────────────────────────────────────────
    top_n <- 20
    best_upstream_ligands_agnostic <- ligand_activities_agnostic %>% top_n(top_n, aupr_corrected) %>% pull(test_ligand) %>% unique()
    best_upstream_ligands_focused  <- ligand_activities_focused %>% top_n(top_n, aupr_corrected) %>% pull(test_ligand) %>% unique()
    best_upstream_ligands <- union(best_upstream_ligands_agnostic, best_upstream_ligands_focused)

    # ── Step 8: Visualize Activity Scores ─────────────────────────────────────
    message(">>> Step 8: Visualizing Activity Scores <<<")
    plot_ligand_activity <- function(df, top, subtitle) {
        df %>% filter(test_ligand %in% top) %>% mutate(test_ligand = factor(test_ligand, levels = rev(top))) %>%
        ggplot(aes(x = test_ligand, y = aupr_corrected)) + geom_bar(stat = "identity", fill = "steelblue") +
        coord_flip() + labs(title = "NicheNet Activity", subtitle = subtitle, x = "Ligand", y = "Corrected AUPR") + theme_classic()
    }
    p_agnostic <- plot_ligand_activity(ligand_activities_agnostic, best_upstream_ligands_agnostic, "Sender-Agnostic")
    p_focused  <- plot_ligand_activity(ligand_activities_focused, best_upstream_ligands_focused, "Sender-Focused")
    ggsave("plots/08_ligand_activity_barplot.pdf", p_agnostic + p_focused, width = 12, height = 7)

    # ── Step 9: Predict Target Genes ──────────────────────────────────────────
    message(">>> Step 9: Predicting Target Genes <<<")
    active_ligand_target_links_df <- best_upstream_ligands %>%
        lapply(get_weighted_ligand_target_links, geneset = geneset_oi, ligand_target_matrix = ligand_target_matrix, n = 250) %>%
        bind_rows() %>% drop_na()
    
    active_ligand_target_links <- prepare_ligand_target_visualization(active_ligand_target_links_df, ligand_target_matrix, cutoff = 1/3)
    order_ligands <- intersect(best_upstream_ligands, colnames(active_ligand_target_links)) %>% rev()
    order_targets <- active_ligand_target_links_df\$target %>% unique() %>% intersect(rownames(active_ligand_target_links))
    
    p_ligand_target <- active_ligand_target_links[order_targets, order_ligands] %>%
        make_heatmap_ggplot(y_name = "Targets", x_name = "Ligands", color = "purple", legend_title = "Reg. Potential") +
        theme(axis.text.x = element_text(face = "italic"))
    ggsave("plots/09_ligand_target_heatmap.pdf", p_ligand_target, width = 10, height = 8)

    # ── Step 10: Infer Receptors ──────────────────────────────────────────────
    message(">>> Step 10: Inferring Receptors <<<")
    ligand_receptor_links_df <- get_weighted_ligand_receptor_links(best_upstream_ligands, expressed_receptors, lr_network, weighted_networks\$lr_sig)
    vis_ligand_receptor <- prepare_ligand_receptor_visualization(ligand_receptor_links_df, best_upstream_ligands, order_hclust = "both")
    
    p_lr_heat <- t(vis_ligand_receptor) %>%
        make_heatmap_ggplot(y_name = "Ligands", x_name = "Receptors", color = "mediumvioletred", legend_title = "Interaction Pot.") +
        theme(axis.text.x = element_text(face = "italic"))
    ggsave("plots/10_ligand_receptor_heatmap.pdf", p_lr_heat, width = 10, height = 7)

    # ── Step 11: Sender Expression Heatmap ────────────────────────────────────
    message(">>> Step 11: Identify Sender Expression <<<")
    seurat_sender <- subset(seurat_obj, idents = sender_celltypes)
    best_upstream_ligands_in_sender <- intersect(best_upstream_ligands, rownames(seurat_sender))
    
    ligand_expression_matrix <- AverageExpression(seurat_sender, features = best_upstream_ligands_in_sender, assay = "RNA", slot = "data")\$RNA
    ligand_expression_scaled <- t(scale(t(ligand_expression_matrix)))
    
    pdf("plots/11_ligand_sender_heatmap.pdf", width = 10, height = 8)
    pheatmap::pheatmap(ligand_expression_scaled, color = colorRampPalette(c("white", "firebrick3"))(50), 
                       main = "Ligand Expression (Senders)", cluster_cols = T, cluster_rows = T)
    dev.off()

    # ── Step 12: Extended Prioritization (Seurat 5 Ready) ─────────────────────
    message(">>> Step 12: Extended Prioritization <<<")
    try({
        # Ensure Default Assay is a single string
        DefaultAssay(seurat_obj) <- "RNA"
        lr_network_filtered <- lr_network %>% filter(from %in% potential_ligands_focused | to %in% expressed_receptors)
        lr_features <- intersect(unique(c(lr_network_filtered\$from, lr_network_filtered\$to)), rownames(seurat_obj))
    
        seurat_oi <- subset(seurat_obj, subset = condition == condition_oi)
        Idents(seurat_oi) <- seurat_oi\$final_annotation
        DE_table <- FindAllMarkers(seurat_oi, features = lr_features, min.pct = 0, logfc.threshold = 0, return.thresh = 1)
    
        # Fix for get_exprs_avg in Seurat 5
        expression_info <- tryCatch({
            get_exprs_avg(seurat_obj, "final_annotation", "condition", condition_oi, lr_features)
        }, error = function(e) {
            message("Falling back to manual average expression calculation...")
            AverageExpression(subset(seurat_obj, subset = condition == condition_oi), 
                              features = lr_features, group.by = "final_annotation")\$RNA %>% 
                as.data.frame() %>% rownames_to_column("gene") %>% pivot_longer(-gene, names_to = "celltype", values_to = "expression")
        })
        
        Idents(seurat_obj) <- seurat_obj\$condition
        condition_markers <- FindMarkers(seurat_obj, ident.1 = condition_oi, ident.2 = condition_reference, features = lr_features, min.pct = 0, logfc.threshold = 0) %>% rownames_to_column("gene")
        
        processed_DE   <- process_table_to_ic(DE_table, "celltype_DE", lr_network_filtered, senders_oi = sender_celltypes, receivers_oi = receiver)
        processed_expr <- process_table_to_ic(expression_info, "expression", lr_network_filtered)
        processed_cond <- process_table_to_ic(condition_markers, "group_DE", lr_network_filtered)
        
        prioritized_tbl <- generate_prioritization_tables(processed_expr, processed_DE, ligand_activities_focused, processed_cond, scenario = "case_control")
        write.csv(prioritized_tbl, "results/prioritized_lr_pairs.csv", row.names = FALSE)
    }, silent = FALSE)

    # ── Step 13: Signaling Paths ──────────────────────────────────────────────
    message(">>> Step 13: Inferring Signaling Paths <<<")
    try({
        top_ligand <- best_upstream_ligands_focused[1]
        top_target <- active_ligand_target_links_df %>% filter(ligand == top_ligand) %>% arrange(desc(weight)) %>% slice(1) %>% pull(target)
        
        sig_path <- get_ligand_signaling_path(ligand_tf_matrix = ligand_tf_matrix, ligands_all = top_ligand, targets_all = top_target, 
                                             top_n_regulators = 4, weighted_networks = weighted_networks, minmax_scaling = TRUE)
        
        sig_graph <- graph_from_data_frame(bind_rows(sig_path\$sig, sig_path\$gr), directed = TRUE)
        p_path <- ggraph(sig_graph, layout = "kk") + 
            geom_edge_link(aes(edge_width = weight, edge_alpha = weight), arrow = arrow(length = unit(3, "mm")), color = "grey50") +
            geom_node_point(size = 5, color = "steelblue") + geom_node_text(aes(label = name), repel = TRUE) + theme_void() +
            labs(title = paste("Path:", top_ligand, "->", top_target))
        ggsave("plots/13_signaling_path.pdf", p_path, width = 8, height = 6)
    }, silent = TRUE)

    # ── Step 14: Ligand-Sender Summary ────────────────────────────────────────
    message(">>> Step 14: Summary Table <<<")
    ligand_sender_assignment <- apply(ligand_expression_matrix, 1, function(x) names(which.max(x))) %>% enframe(name = "ligand", value = "best_sender")
    summary_tbl <- ligand_activities_focused %>% filter(test_ligand %in% names(ligand_sender_assignment\$ligand)) %>% rename(ligand = test_ligand) %>%
        left_join(ligand_sender_assignment, by = "ligand") %>% arrange(desc(aupr_corrected))
    write.csv(summary_tbl, "results/ligand_sender_summary.csv", row.names = FALSE)

    # ── Step 15: Circos Plot ──────────────────────────────────────────────────
    message(">>> Step 15: Circos Plot <<<")
    try({
        circos_data <- active_ligand_target_links_df %>% group_by(ligand) %>% slice_max(weight, n = 5) %>% ungroup() %>%
            left_join(ligand_sender_assignment, by = "ligand") %>% filter(!is.na(best_sender)) %>% group_by(best_sender, target) %>% summarise(n = n(), .groups = "drop")
        
        grid_col <- viridis::viridis(length(unique(circos_data\$best_sender)))
        names(grid_col) <- unique(circos_data\$best_sender)
        
        pdf("plots/15_nichenet_circos.pdf", width = 10, height = 10)
        circos.clear()
        chordDiagram(circos_data, grid.col = c(grid_col, rep("grey80", length(unique(circos_data\$target)))), transparency = 0.4, annotationTrack = "grid", preAllocateTracks = 1)
        circos.trackPlotRegion(track.index = 1, panel.fun = function(x, y) { circos.text(CELL_META\$xcenter, CELL_META\$ylim[1] + 0.1, CELL_META\$sector.index, facing = "clockwise", niceFacing = TRUE, adj = c(0, 0.5), cex = 0.6) }, bg.border = NA)
        title("NicheNet: Sender -> Target Influences")
        dev.off()
        circos.clear()
    }, silent = TRUE)

    saveRDS(list(activities = ligand_activities_focused, summary = summary_tbl), "results/nichenet_final_results.rds")
    message(">>> NicheNet Analysis Complete <<<")
    ENDSCRIPT
    Rscript nn_script.R
    """
}

// ============================================================================
//  PROCESS 11: COPYKAT (Part 11) – CNV & Subclone Analysis
//  Inferring chromosomal copy number changes and tumor subclones
// ============================================================================
process COPYKAT {
    tag "copykat"
    publishDir "${params.outdir}/11_copykat", mode: 'copy'
    label 'process_high'
    input:  path rds
    output: 
        path "plots/*.png", optional: true
        path "plots/*.pdf", optional: true
        path "results/*.csv", optional: true
        path "results/*.rds", optional: true
    script:
    """
    mkdir -p plots results
    cat > ck_script.R << 'ENDSCRIPT'
    suppressPackageStartupMessages({
        library(Seurat)
        library(copykat)
        library(tidyverse)
        library(data.table)
        library(patchwork)
    })

    # ── Step 1: Load Data ─────────────────────────────────────────────────────
    message(">>> Step 1: Loading Seurat Object <<<")
    seurat_obj <- readRDS("${rds}")
    
    # Extract Sample Names
    if (!"Sample" %in% colnames(seurat_obj@meta.data)) {
        if ("orig.ident" %in% colnames(seurat_obj@meta.data)) {
            seurat_obj\$Sample <- seurat_obj\$orig.ident
        } else {
            seurat_obj\$Sample <- "Sample1"
        }
    }
    
    samples <- unique(seurat_obj\$Sample)
    message(paste("Found samples:", paste(samples, collapse=", ")))

    # ── Step 2: Running CopyKAT per Sample ────────────────────────────────────
    # Following the "Run each sample separately" best practice from Part 11
    all_predictions <- list()
    
    for (s in samples) {
        message(paste(">>> Processing Sample:", s, "<<<"))
        seu_sub <- subset(seurat_obj, subset = Sample == s)
        
        # Extract raw counts (Seurat 5 compatible)
        raw_counts <- LayerData(seu_sub, assay = "RNA", layer = "counts")
        
        # Run CopyKAT
        tryCatch({
            ck_res <- copykat(
                rawmat    = as.matrix(raw_counts),
                id.type   = "S",
                genome    = "${params.copykat_genome}",
                n.cores   = ${params.copykat_n_cores},
                sam.name  = s,
                KS.cut    = ${params.copykat_ks_cut},
                distance  = "euclidean",
                cell.line = "no"
            )
            
            # Save raw results
            saveRDS(ck_res, paste0("results/", s, "_copykat_results.rds"))
            
            # Add labels to sub-object for visualization
            pred <- ck_res\$prediction
            colnames(pred)[colnames(pred) == "copykat.pred"] <- "copykat_label"
            
            seu_sub\$copykat_label <- pred\$copykat_label[match(colnames(seu_sub), pred\$cell.names)]
            seu_sub\$copykat_label[is.na(seu_sub\$copykat_label)] <- "not.defined"
            
            # --- Visualization ---
            message(paste(">>> Visualizing Sample:", s, "<<<"))
            seu_sub <- NormalizeData(seu_sub) %>% FindVariableFeatures() %>% ScaleData() %>% RunPCA() %>% RunUMAP(dims = 1:20)
            
            copykat_colors <- c("aneuploid" = "#D62728", "diploid" = "#1F77B4", "not.defined" = "#AAAAAA")
            
            p1 <- DimPlot(seu_sub, group.by = "final_annotation", label = TRUE) + labs(title = paste(s, ": Annotation"))
            p2 <- DimPlot(seu_sub, group.by = "copykat_label", cols = copykat_colors) + labs(title = paste(s, ": CopyKAT"))
            
            ggsave(paste0("plots/", s, "_umap_copykat.png"), p1 | p2, width = 12, height = 6)
            
            # Hierarchical clustering for subclones if aneuploid cells exist
            aneuploid_cells <- pred\$cell.names[pred\$copykat_label == "aneuploid"]
            if (length(aneuploid_cells) > 5) {
                message(paste(">>> Running Subclone Analysis for:", s, "<<<"))
                cna_mat <- t(ck_res\$CNAmat[, 7:ncol(ck_res\$CNAmat)])
                cna_mat <- cna_mat[intersect(rownames(cna_mat), aneuploid_cells), , drop=FALSE]
                
                if (nrow(cna_mat) > 5) {
                    hc <- hclust(dist(cna_mat), method = "ward.D2")
                    subclones <- cutree(hc, k = 2)
                    
                    sub_df <- data.frame(cell = names(subclones), subclone = paste0("Sub_", subclones))
                    seu_sub\$subclone <- sub_df\$subclone[match(colnames(seu_sub), sub_df\$cell)]
                    seu_sub\$subclone[is.na(seu_sub\$subclone)] <- "Non-tumor"
                    
                    p3 <- DimPlot(seu_sub, group.by = "subclone", cols = c("Sub_1"="#E41A1C", "Sub_2"="#FF7F00", "Non-tumor"="#BBBBBB"))
                    ggsave(paste0("plots/", s, "_umap_subclones.png"), p3, width = 7, height = 6)
                }
            }
            
            # Append predictions for summary
            pred\$Sample <- s
            all_predictions[[s]] <- pred
            
        }, error = function(e) {
            message(paste("CopyKAT failed for sample", s, ":", e\$message))
        })
    }

    # ── Step 3: Summary Table ─────────────────────────────────────────────────
    if (length(all_predictions) > 0) {
        final_preds <- bind_rows(all_predictions)
        write.csv(final_preds, "results/all_samples_copykat_predictions.csv", row.names = FALSE)
        
        # Aneuploid fraction summary
        summary_df <- final_preds %>%
            count(Sample, copykat_label) %>%
            group_by(Sample) %>%
            mutate(fraction = n / sum(n))
        write.csv(summary_df, "results/aneuploid_fraction_summary.csv", row.names = FALSE)
    }

    message(">>> CopyKAT Analysis Complete <<<")
    ENDSCRIPT
    Rscript ck_script.R
    """
}




// ============================================================================
//  WORKFLOW
// ============================================================================
workflow {

    // =========================================================================
    // MODE 1: Full pipeline from raw FASTQs (samplesheet --input)
    // =========================================================================
    if (mode_input) {
        ch_input    = Channel.fromPath(params.input).splitCsv(header:true)
                        .map { [ it.sample_id, it.fastq_path ?: "", it.sra_id ?: "", it.condition ?: "", it.patient_id ?: "" ] }
        ch_metadata = ch_input.map { [ it[0], it[3], it[4] ] }

        if (!params.skip_sra) {
            ch_sra    = ch_input.filter { it[2] != "" }.map { [ it[0], it[2] ] }
            DOWNLOAD_SRA(ch_sra)
            ch_fastqs = DOWNLOAD_SRA.out.fastqs.mix(ch_input.filter { it[1] != "" }.map { [ it[0], file(it[1]) ] })
        } else {
            ch_fastqs = ch_input.filter { it[1] != "" }.map { [ it[0], file(it[1]) ] }
        }

        if (!params.skip_cellranger) {
            CELLRANGER_COUNT(ch_fastqs)
            ch_cr_outs = CELLRANGER_COUNT.out.outs
        } else {
            ch_cr_outs = ch_input.map { row ->
                def sample_id = row[0]
                def csv_path  = row[1]
                def d1 = file("${params.cellranger_dir}/${sample_id}/outs")
                def d2 = file("${params.outdir}/01_cellranger/${sample_id}/outs")
                def d3 = file("${csv_path}/${sample_id}/outs")
                def d4 = file("${csv_path}/outs")
                def d5 = file("${csv_path}")
                if (d1.exists())      return [ sample_id, d1 ]
                if (d2.exists())      return [ sample_id, d2 ]
                if (d3.exists())      return [ sample_id, d3 ]
                if (d4.exists())      return [ sample_id, d4 ]
                if (d5.exists() && d5.name == "outs") return [ sample_id, d5 ]
                error "ERROR: CellRanger 'outs' directory NOT found for ${sample_id}. Try --cellranger_dir or --matrix."
            }
        }

        if (!params.skip_pdx) {
            PDX_PROCESSING(ch_cr_outs)
            ch_qc_input = PDX_PROCESSING.out.human_rds.join(ch_metadata)
        } else {
            ch_qc_input = ch_cr_outs.join(ch_metadata)
        }

        ch_input_sample_list = ch_input.map { it[0] }.collect().map { it.join(",") }
        ch_qc_input_full     = ch_qc_input

    }

    // =========================================================================
    // MODE 2: Start from per-sample 10X MEX count matrices (--matrix)
    // Expects a CSV with columns: sample_id, matrix_dir, condition, patient_id
    // =========================================================================
    else if (mode_matrix) {
        log.info ">>> Input Mode: 10X MEX count matrices (--matrix). Skipping CellRanger."
        ch_matrix_csv = Channel.fromPath(params.matrix).splitCsv(header:true)
                          .filter { it.sample_id != null && it.sample_id != "" && !it.sample_id.startsWith("#") }
                          .map { 
                              def mdir = it.matrix_dir ?: it.csv_file ?: it.matrix_path ?: ""
                              if (mdir == "") {
                                  log.warn "WARNING: No matrix_dir or csv_file found for sample ${it.sample_id}. Skipping."
                                  return null
                              }
                              return [ it.sample_id, file(mdir), it.condition ?: "", it.patient_id ?: "" ]
                          }
                          .filter { it != null }

        // Feed directly into QC_FILTERING (matrix_dir acts as the 'outs_or_rds' input)
        ch_qc_input_full     = ch_matrix_csv.map { [ it[0], it[1], it[2], it[3] ] }
        ch_input_sample_list = ch_matrix_csv.map { it[0] }.collect().map { it.join(",") }
    }

    // =========================================================================
    // MODE 3: Start from a pre-merged Seurat RDS (--seurat_rds)
    // Skips CellRanger, QC, and Integration — jumps directly to Annotation.
    // =========================================================================
    else if (mode_seurat) {
        log.info ">>> Input Mode: Pre-merged Seurat RDS (--seurat_rds). Skipping to Annotation."
        ch_integrated_rds    = Channel.fromPath(params.seurat_rds)
        ch_input_sample_list = Channel.value("all_samples")

        if (!params.skip_annotation) {
            CELL_ANNOTATION(ch_integrated_rds, ch_input_sample_list)
            ch_annotated_rds = CELL_ANNOTATION.out.rds
        } else {
            def _ann = file("${params.outdir}/04_annotation/integrated_annotated.rds")
            if (!_ann.exists()) error "ERROR: Annotated RDS not found at ${_ann}"
            ch_annotated_rds = Channel.fromPath(_ann)
        }

        if (!params.stop_after_annotation) {
            if (!params.skip_de) {
                DE_ANALYSIS(ch_annotated_rds)
                ch_de_rds = DE_ANALYSIS.out.rds
            } else {
                def _de = file("${params.outdir}/05_de/de_results.rds")
                if (!_de.exists()) error "ERROR: DE RDS not found at ${_de}"
                ch_de_rds = Channel.fromPath(_de)
            }
            if (!params.stop_after_de) {
                EXPLORATION(ch_de_rds)
                if (!params.stop_after_exploration) {
                    if (!params.skip_trajectory) TRAJECTORY(ch_de_rds)
                    if (!params.skip_cellchat)   CELLCHAT(ch_annotated_rds)
                    if (!params.skip_nichenet)   NICHENET(ch_annotated_rds)
                    if (!params.skip_copykat)    COPYKAT(ch_annotated_rds)
                }
            }
        }
        // RDS mode is fully handled above — exit workflow here
        return
    }

    // =========================================================================
    // SHARED DOWNSTREAM (Mode 1 + Mode 2 converge here at QC step)
    // =========================================================================
    if (!params.skip_qc) {
        QC_FILTERING(ch_qc_input_full)
        ch_final_qc_rds = QC_FILTERING.out.rds
    } else {
        ch_final_qc_rds = ch_qc_input_full.map { row ->
            def sample_id = row[0]
            def rds_p1 = file("${params.outdir}/02_qc/${sample_id}/${sample_id}_qc.rds")
            def rds_p2 = file("${params.outdir}/02_qc/${sample_id}_qc.rds")
            if (rds_p1.exists()) return [ sample_id, rds_p1 ]
            if (rds_p2.exists()) return [ sample_id, rds_p2 ]
            error "ERROR: QC'd RDS file NOT found for ${sample_id} in ${params.outdir}/02_qc/."
        }
    }

    if (!params.stop_after_qc) {
        if (!params.skip_integration) {
            INTEGRATION_CLUSTERING(ch_final_qc_rds.map { it[1] }.collect())
            ch_integrated_rds = INTEGRATION_CLUSTERING.out.rds
        } else {
            def _int = file("${params.outdir}/03_clustering/merged_clustered.rds")
            if (!_int.exists()) error "ERROR: Integrated RDS NOT found at ${_int}."
            ch_integrated_rds = Channel.fromPath(_int)
        }

        if (!params.stop_after_integration) {
            if (!params.skip_annotation) {
                CELL_ANNOTATION(ch_integrated_rds, ch_input_sample_list)
                ch_annotated_rds = CELL_ANNOTATION.out.rds
            } else {
                def _ann = file("${params.outdir}/04_annotation/integrated_annotated.rds")
                if (!_ann.exists()) error "ERROR: Annotated RDS NOT found at ${_ann}."
                ch_annotated_rds = Channel.fromPath(_ann)
            }

            if (!params.stop_after_annotation) {
                if (!params.skip_de) {
                    DE_ANALYSIS(ch_annotated_rds)
                    ch_de_rds = DE_ANALYSIS.out.rds
                } else {
                    def _de = file("${params.outdir}/05_de/de_results.rds")
                    if (!_de.exists()) error "ERROR: DE RDS NOT found at ${_de}."
                    ch_de_rds = Channel.fromPath(_de)
                }

                if (!params.stop_after_de) {
                    EXPLORATION(ch_de_rds)
                    if (!params.stop_after_exploration) {
                        if (!params.skip_trajectory) TRAJECTORY(ch_de_rds)
                        if (!params.skip_cellchat)   CELLCHAT(ch_annotated_rds)
                        if (!params.skip_nichenet)   NICHENET(ch_annotated_rds)
                        if (!params.skip_copykat)    COPYKAT(ch_annotated_rds)
                    }
                }
            }
        }
    }
}

// ─── NICHENET-ONLY WORKFLOW ──────────────────────────────────────────────────
// Use this to run ONLY the NicheNet analysis on an existing Seurat object.
// USAGE: nextflow run main.nf -entry NICHENET_ONLY --nichenet_rds <path_to_rds>
workflow NICHENET_ONLY {
    if (!params.nichenet_rds) {
        error "ERROR: Please provide an RDS file path via --nichenet_rds <path>"
    }
    ch_rds = Channel.fromPath(params.nichenet_rds)
    NICHENET(ch_rds)
}

workflow COPYKAT_ONLY {
    if (!params.copykat_rds) {
        error "ERROR: Please provide an RDS file path via --copykat_rds <path>"
    }
    ch_rds = Channel.fromPath(params.copykat_rds)
    COPYKAT(ch_rds)
}

