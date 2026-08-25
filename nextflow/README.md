# scRNA-seq Complete Pipeline · Nextflow DSL2 · v3.0.0

> **Parts 1–11:** CellRanger → QC → Integration → Annotation → DE → Exploration → Trajectory → CellChat → NicheNet → CopyKAT

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Input Modes](#input-modes)
3. [Samplesheet Format](#samplesheet-format---input)
4. [Matrix CSV Format](#matrix-csv-format---matrix)
5. [All Parameters](#all-parameters)
6. [Skip & Stop-After Flags](#skip--stop-after-flags)
7. [Profiles](#profiles)
8. [Standalone Entry Points](#standalone-entry-points)
9. [Results Directory](#results-directory)
10. [Performance Optimization](#performance-optimization)
11. [Troubleshooting](#troubleshooting)

---

## Quick Start

```bash
# Clone / navigate to the pipeline
cd /path/to/nextflow/

# Show full help
nextflow run main.nf --help

# Mode 1 – Full pipeline from raw FASTQs
nextflow run main.nf \
    --input samples.csv \
    --ref_human /path/to/refdata-gex-GRCh38-2024-A \
    --outdir my_results \
    -profile server

# Mode 2 – Start from 10X MEX count matrices (skip CellRanger)
nextflow run main.nf \
    --matrix matrix_samples.csv \
    --outdir my_results \
    -profile local

# Mode 3 – Start from a pre-merged Seurat RDS (skip to Annotation)
nextflow run main.nf \
    --seurat_rds results/03_clustering/merged_clustered.rds \
    --outdir my_results

# Resume a failed/interrupted run
nextflow run main.nf --input samples.csv -resume
```

---

## Input Modes

The pipeline supports **three input modes**. Choose exactly one:

| Mode | Flag | Pipeline Entry Point | Use Case |
|---|---|---|---|
| **1 – Full** | `--input samples.csv` | CellRanger → end | Raw FASTQ files |
| **2 – Matrix** | `--matrix matrix.csv` | QC → end | 10X MEX directories (e.g. from CellRanger, STARsolo, Kallisto) |
| **3 – RDS** | `--seurat_rds merged.rds` | Annotation → end | Pre-merged Seurat object |

> **Note:** You cannot combine modes. Providing more than one will cause an error.

---

## Samplesheet Format (`--input`)

Required columns:

| Column | Description | Example |
|---|---|---|
| `sample_id` | Unique sample name (no spaces) | `Healthy_1` |
| `fastq_path` | Path to directory containing FASTQ files | `/data/fastqs/Healthy_1` |
| `sra_id` | SRA accession (leave blank for local FASTQs) | `SRR12345678` or _(blank)_ |
| `condition` | Experimental group | `Healthy`, `Pre`, `Post` |
| `patient_id` | Donor/patient identifier | `Donor_1`, `Patient_1` |

**Example `samples.csv`:**

```csv
sample_id,fastq_path,sra_id,condition,patient_id
Healthy_1,/data/fastqs/Healthy_1,,Healthy,Donor_1
Healthy_2,/data/fastqs/Healthy_2,,Healthy,Donor_2
Pre_Treatment_1,/data/fastqs/Pre_1,,Pre,Patient_1
Post_Treatment_1,/data/fastqs/Post_1,,Post,Patient_1
```

> For SRA-based downloads, provide the `sra_id` and leave `fastq_path` blank.

---

## Matrix CSV Format (`--matrix`)

Use this when you already have 10X MEX count matrices from CellRanger, STARsolo, or similar tools.

Required columns:

| Column | Description | Example |
|---|---|---|
| `sample_id` | Unique sample name | `Healthy_1` |
| `matrix_dir` | Path to the MEX directory (`matrix.mtx.gz`, `barcodes.tsv.gz`, `features.tsv.gz`) | `/data/Healthy_1/filtered_feature_bc_matrix` |
| `condition` | Experimental group | `Healthy` |
| `patient_id` | Donor/patient identifier | `Donor_1` |

**Example `matrix_samples.csv`:**

```csv
sample_id,matrix_dir,condition,patient_id
Healthy_1,/data/cellranger/Healthy_1/outs/filtered_feature_bc_matrix,Healthy,Donor_1
Healthy_2,/data/cellranger/Healthy_2/outs/filtered_feature_bc_matrix,Healthy,Donor_2
Pre_Treatment_1,/data/starsolo/Pre_1/Solo.out/GeneFull/filtered,Pre,Patient_1
Post_Treatment_1,/data/cellranger/Post_1/outs/filtered_feature_bc_matrix,Post,Patient_1
```

---

## All Parameters

### Input / Output

| Parameter | Type | Default | Description |
|---|---|---|---|
| `--input` | PATH | `""` | Mode 1: Samplesheet CSV |
| `--matrix` | PATH | `""` | Mode 2: Matrix CSV (10X MEX dirs) |
| `--seurat_rds` | PATH | `""` | Mode 3: Pre-merged Seurat RDS |
| `--outdir` | STR | `results` | Output directory |

### Reference Genome

| Parameter | Type | Default | Description |
|---|---|---|---|
| `--ref_human` | PATH | `""` | CellRanger-compatible human genome reference |
| `--ref_mouse` | PATH | `""` | Mouse reference (PDX experiments only) |

### CellRanger Options

| Parameter | Type | Default | Description |
|---|---|---|---|
| `--cellranger_dir` | PATH | `""` | Pre-existing CellRanger output root (for `--skip_cellranger`) |
| `--chemistry` | STR | `auto` | Library chemistry (`auto`, `SC3Pv3`, `SC3Pv2`, ...) |
| `--expect_cells` | INT | `5000` | Expected recovered cells per sample |

### Resource Limits

| Parameter | Type | Default | Description |
|---|---|---|---|
| `--max_cpus` | INT | `32` | Max CPUs per process |
| `--max_memory` | STR | `64.GB` | Max RAM per process |
| `--max_time` | STR | `48.h` | Max wall time per process |

### NicheNet Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `--nichenet_receiver` | STR | `CD4+ T cells` | Receiver cell type |
| `--nichenet_sender` | STR | `all` | Sender cell types (`all` or comma-separated) |
| `--nichenet_condition_oi` | STR | `Post` | Condition of interest |
| `--nichenet_condition_ref` | STR | `Healthy` | Reference condition |

### CopyKAT Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `--copykat_genome` | STR | `hg20` | Reference genome (`hg20` or `mm10`) |
| `--copykat_n_cores` | INT | `4` | Cores for CopyKAT |
| `--copykat_ks_cut` | FLOAT | `0.1` | KS test p-value cutoff |

---

## Skip & Stop-After Flags

### Skip flags (bypass a step and reuse existing outputs)

| Flag | What is skipped | Fallback requirement |
|---|---|---|
| `--skip_sra` | SRA download | Local FASTQs in `fastq_path` |
| `--skip_cellranger` | CellRanger count | `--cellranger_dir` or `--matrix` |
| `--skip_pdx` | PDX species demux | Standard human data (most common) |
| `--skip_qc` | QC filtering | Existing `results/02_qc/` outputs |
| `--skip_integration` | Harmony integration | Existing `merged_clustered.rds` |
| `--skip_annotation` | Cell annotation | Existing `integrated_annotated.rds` |
| `--skip_de` | Differential expression | Existing `de_results.rds` |
| `--skip_trajectory` | Slingshot trajectory | _(step skipped entirely)_ |
| `--skip_cellchat` | CellChat analysis | _(step skipped entirely)_ |
| `--skip_nichenet` | NicheNet analysis | _(step skipped entirely)_ |
| `--skip_copykat` | CopyKAT CNV analysis | _(step skipped entirely)_ |

### Stop-after flags (run only up to a checkpoint)

| Flag | Pipeline exits after |
|---|---|
| `--stop_after_qc` | Part 2 – QC |
| `--stop_after_integration` | Part 3 – Integration & Clustering |
| `--stop_after_annotation` | Part 4 – Cell Annotation |
| `--stop_after_de` | Part 5 – Differential Expression |
| `--stop_after_exploration` | Part 6 – Object Exploration |

**Example – run only through QC to inspect results before committing to integration:**

```bash
nextflow run main.nf --input samples.csv --ref_human /path/to/ref --stop_after_qc
```

---

## Profiles

Activate with `-profile <name>`. Combine multiple: `-profile slurm,conda`.

| Profile | Executor | CPUs | RAM | Notes |
|---|---|---|---|---|
| `laptop` | local | 8 | 16 GB | Lightweight for laptops/small VMs |
| `local` | local | 32 | 64 GB | Standard workstation |
| `server` | local | 128 | 250 GB | High-memory server (e.g. tigshp) |
| `hpc_small` | SLURM | 32 | 64 GB | Small compute partition |
| `hpc_large` | SLURM | 128 | 512 GB | High-memory HPC partition |
| `conda` | _(any)_ | — | — | Enable Conda environments |
| `singularity` | _(any)_ | — | — | Enable Singularity containers |
| `docker` | _(any)_ | — | — | Enable Docker containers |
| `test` | local | 8 | 16 GB | Runs bundled test dataset |

**Override resource limits on the fly:**

```bash
nextflow run main.nf --input samples.csv --max_cpus 64 --max_memory 128.GB
```

---

## Standalone Entry Points

Run a single analysis module on an existing Seurat object:

```bash
# NicheNet only (Part 10)
nextflow run main.nf -entry NICHENET_ONLY \
    --nichenet_rds results/04_annotation/integrated_annotated.rds \
    --nichenet_receiver "CD4+ T cells" \
    --nichenet_condition_oi Post \
    --nichenet_condition_ref Healthy

# CopyKAT CNV analysis only (Part 11)
nextflow run main.nf -entry COPYKAT_ONLY \
    --copykat_rds results/04_annotation/integrated_annotated.rds \
    --copykat_genome hg20
```

---

## Results Directory

```
results/
├── pipeline_info/          # Timeline, report, trace, DAG
│   ├── timeline.html
│   ├── report.html
│   └── trace.txt
├── 00_fastq/               # SRA-downloaded FASTQs (if used)
├── 01_cellranger/          # CellRanger count outputs
├── 02_qc/                  # Per-sample QC plots & filtered RDS
│   └── {sample_id}/
│       ├── plots/          # QC metric plots
│       └── qc_summary.csv
├── 03_clustering/          # Integrated & clustered Seurat object
│   ├── merged_clustered.rds
│   └── plots/
├── 04_annotation/          # Cell type annotations
│   ├── integrated_annotated.rds
│   └── plots/
├── 05_de/                  # Differential expression results
│   ├── de_results.rds
│   └── tables/
├── 06_exploration/         # Object exploration plots
├── 07_trajectory/          # Slingshot pseudotime analysis
│   ├── plots/
│   └── results/
├── 08_cellchat/            # CellChat communication analysis
│   ├── 01_overview/
│   ├── 02_pathways/
│   └── ...
├── 09_nichenet/            # NicheNet ligand activity
│   └── plots/
└── 10_copykat/             # CopyKAT CNV analysis
    ├── plots/
    └── results/
```

---

## Performance Optimization

The full 12-sample run takes ~37h and ~4,850 CPU·hours. Key strategies to reduce wall time:

### 1. Always use `-resume`

```bash
nextflow run main.nf --input samples.csv -resume
```

Nextflow caches every completed process. Resuming after failure or partial run skips all already-finished steps at zero cost.

### 2. Match profile to your hardware

```bash
# Laptop (small test run)
nextflow run main.nf --input samples_test.csv -profile laptop --stop_after_qc

# Production server
nextflow run main.nf --input samples.csv -profile server -resume

# HPC with SLURM
nextflow run main.nf --input samples.csv -profile hpc_large -resume
```

### 3. Use stop-after flags for iterative development

Run QC first, inspect the outputs, then continue:

```bash
# Step 1
nextflow run main.nf --input samples.csv --ref_human /path/to/ref --stop_after_qc
# Step 2 (review results/02_qc/)
nextflow run main.nf --input samples.csv --stop_after_integration -resume
# Step 3 (full run)
nextflow run main.nf --input samples.csv -resume
```

### 4. Skip CellRanger if matrices already exist

CellRanger is the single longest step (~1h/sample). If you've already generated count matrices, use `--matrix` or `--skip_cellranger`:

```bash
nextflow run main.nf --matrix matrix_samples.csv -resume
```

### 5. Skip costly downstream analyses during development

```bash
# Develop annotation logic only
nextflow run main.nf --input samples.csv \
    --skip_cellranger --skip_qc --skip_integration \
    --skip_trajectory --skip_cellchat --skip_nichenet --skip_copykat \
    -resume
```

### 6. Run downstream analyses in parallel

CellChat, NicheNet, and CopyKAT all take the annotated RDS as input and run in parallel automatically (Nextflow schedules them concurrently if resources allow).

### 7. SLURM job arrays for CellRanger

On an HPC, the SLURM profile submits each CellRanger job as a separate cluster job, all running in parallel:

```bash
nextflow run main.nf --input samples.csv -profile hpc_large
```

### Summary Table

| Optimization | Time Saved | Effort |
|---|---|---|
| Always use `-resume` | Avoids re-running finished steps | ⭐ Low |
| `--matrix` (skip CellRanger) | ~12h for 12 samples | ⭐ Low |
| `--stop_after_*` flags | Faster iteration | ⭐ Low |
| `-profile server/hpc_large` | Better resource utilization | ⭐ Low |
| Skip unused analyses (`--skip_*`) | 2–8h depending on steps | ⭐ Low |
| SLURM parallel submission | ~12h savings on HPC | ⭐⭐ Medium |

---

## Troubleshooting

### "No input provided" error

```
ERROR: No input provided. Please specify one of: --input / --matrix / --seurat_rds
```

**Fix:** Provide exactly one input mode. Example:
```bash
nextflow run main.nf --input samples.csv
```

### "Cannot find script file: main.nf"

You must run Nextflow **from the directory containing `main.nf`**:
```bash
cd /path/to/nextflow/
nextflow run main.nf --input samples.csv
```

### TRAJECTORY fails with `igraph NA adjacency matrix`

This is a known `igraph`/`slingshot` version compatibility issue. The pipeline handles this gracefully — trajectory will be skipped with a `trajectory_skipped.csv` output and the pipeline will continue.

To skip trajectory intentionally:
```bash
nextflow run main.nf --input samples.csv --skip_trajectory -resume
```

### Pipeline runs out of memory

1. Check which process is failing in `.nextflow.log`
2. Increase limits:
   ```bash
   nextflow run main.nf --input samples.csv --max_memory 256.GB
   ```
3. Or switch to a higher-resource profile:
   ```bash
   nextflow run main.nf --input samples.csv -profile hpc_large -resume
   ```

### CellRanger 'outs' not found when using `--skip_cellranger`

The pipeline searches for outs in this order:
1. `{cellranger_dir}/{sample_id}/outs`
2. `{outdir}/01_cellranger/{sample_id}/outs`
3. `{fastq_path}/{sample_id}/outs`
4. `{fastq_path}/outs`

Ensure one of these paths exists, or provide `--cellranger_dir /path/to/cr_outputs`.

### Resuming after changing the pipeline code

Nextflow only caches by task hash (inputs + script). If you modify a process script, those tasks will re-run even with `-resume`. This is expected behavior.

---

## Citation

If you use this pipeline in your research, please cite the tools used:
- **CellRanger**: 10x Genomics
- **Seurat v5**: Hao et al., *Nature Biotechnology* 2024
- **Harmony**: Korsunsky et al., *Nature Methods* 2019
- **CellChat**: Jin et al., *Nature Communications* 2021
- **NicheNet**: Browaeys et al., *Nature Methods* 2020
- **CopyKAT**: Gao et al., *Nature Biotechnology* 2021
- **Slingshot**: Street et al., *BMC Genomics* 2018
