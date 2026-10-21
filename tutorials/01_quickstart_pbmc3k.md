# Tutorial 1: Quickstart with 10x Genomics PBMC Data

This tutorial provides a hands-on, step-by-step walkthrough for analyzing a real single-cell RNA-seq dataset using **scRATool**. We use the canonical **10x Genomics Peripheral Blood Mononuclear Cell (PBMC)** dataset to demonstrate the complete workflow from raw matrix ingestion to publication-grade figures.

---

## 📋 Overview & Prerequisites

By the end of this tutorial, you will:
1. Download a standard single-cell count matrix.
2. Structure a valid `samples.csv` experimental design file.
3. Execute the full 14-stage Nextflow pipeline (either via CLI or Web GUI).
4. Inspect the generated outputs across QC, batch integration, cell annotation, and differential expression.
5. Load the processed objects in R (`readRDS`) or Python (`scanpy.read_h5ad`).

### Prerequisites
* Linux or macOS with **Bash**, **curl**, and **git**.
* Python 3.10+ installed (`python3 --version`).
* Nextflow 23.04+ installed (`nextflow -v`).
* [Pixi](https://pixi.sh/) package manager (handles all R 4.4 and Bioconductor dependencies automatically).

---

## 📥 Step 1: Download Benchmark Test Data

We will download the 10x Genomics 3k PBMC filtered feature-barcode matrix. In your scRATool workspace directory:

```bash
# Create a data directory for test inputs
mkdir -p data/pbmc_demo

# Download the 10x Genomics PBMC 3k feature matrix (.h5)
curl -o data/pbmc_demo/pbmc3k_filtered_matrix.h5 \
  https://cf.10xgenomics.com/samples/cell-exp/3.0.0/pbmc_1k_v3/pbmc_1k_v3_filtered_feature_bc_matrix.h5
```

> **Note:** scRATool accepts both `.h5` files, 10x outs directories (`matrix.mtx.gz`, `barcodes.tsv.gz`, `features.tsv.gz`), compressed text matrices (`.csv.gz`, `.txt.gz`), and pre-built Seurat `.rds` objects.

---

## 📝 Step 2: Create the Samplesheet (`samples.csv`)

Create a `samples_pbmc.csv` file in your project directory:

```csv
sample_id,condition,patient_id,file_path
PBMC_Donor1,Healthy,Donor_1,data/pbmc_demo/pbmc3k_filtered_matrix.h5
```

If you have multiple replicates or disease conditions (e.g. Healthy vs. Patient), add one row per sample:

```csv
sample_id,condition,patient_id,file_path
PBMC_Healthy_1,Healthy,Donor_1,data/pbmc_demo/pbmc_healthy_1.h5
PBMC_Healthy_2,Healthy,Donor_2,data/pbmc_demo/pbmc_healthy_2.h5
PBMC_Treated_1,Treated,Donor_3,data/pbmc_demo/pbmc_treated_1.h5
PBMC_Treated_2,Treated,Donor_4,data/pbmc_demo/pbmc_treated_2.h5
```

---

## ⚡ Step 3: Run the Pipeline via CLI

Run the pipeline using Nextflow with the `local` and `pixi` profiles:

```bash
nextflow run pipeline/main.nf \
    --samples samples_pbmc.csv \
    --outdir results_pbmc/ \
    --organism human \
    --reference_condition Healthy \
    -profile local,pixi \
    -resume
```

### Expected Terminal Output:
Nextflow will display the execution banner and monitor each stage in real time:

```text
================================================================================
  scRATool: Universal Single-Cell RNA-seq Analysis Platform (v1.0.0)
================================================================================
  Samplesheet      : samples_pbmc.csv
  Output Dir       : results_pbmc/
  Organism         : human
  Ref Condition    : Healthy
  Profiles Active  : local,pixi
================================================================================

[01/14] STAGE_01_QC_FILTERING             [100%] 1 of 1 ✔
[02/14] STAGE_02_QC_TOOL_COMPARE          [100%] 1 of 1 ✔
[03/14] STAGE_03_INTEGRATION_CLUSTERING   [100%] 1 of 1 ✔
[04/14] STAGE_04_CELL_TYPE_ANNOTATION     [100%] 1 of 1 ✔
[05/14] STAGE_05_DIFFERENTIAL_EXPRESSION  [100%] 1 of 1 ✔
[06/14] STAGE_06_OBJECT_CONVERSION        [100%] 1 of 1 ✔
[07/14] STAGE_07_MONOCLE3_TRAJECTORY      [100%] 1 of 1 ✔
[08/14] STAGE_08_SLINGSHOT_LINEAGES       [100%] 1 of 1 ✔
[09/14] STAGE_09_CELLCHAT_COMMUNICATION   [100%] 1 of 1 ✔
[10/14] STAGE_10_NICHENET_SIGNALING       [100%] 1 of 1 ✔
[11/14] STAGE_11_COPYKAT_CNV              [100%] 1 of 1 ✔
[12/14] STAGE_12_HDWGCNA_NETWORKS         [100%] 1 of 1 ✔
[13/14] STAGE_13_VELOCITY_EXPORT          [100%] 1 of 1 ✔
[14/14] STAGE_14_PUBLICATION_FIGURES      [100%] 1 of 1 ✔

Pipeline completed successfully! Elapsed time: 4m 12s.
```

---

## 📂 Step 4: Inspect the Output Directory Structure

All results are neatly organized into numbered stage subdirectories under `results_pbmc/`:

```text
results_pbmc/
├── 01_qc/
│   ├── qc_violins_pre_filtering.png       # Raw nUMI, nGene, % mitochondrial reads
│   ├── qc_violins_post_filtering.png      # Post-MAD & doublet filtering distributions
│   ├── soupx_ambient_contamination.png    # SoupX estimated contamination fraction
│   ├── scdblfinder_doublets.csv           # Barcodes flagged as heterotypic doublets
│   └── seurat_filtered.rds                # Cleaned Seurat object
├── 02_qc_benchmark/
│   ├── decontx_vs_soupx_scatter.png       # Ambient RNA caller comparison
│   └── doublet_callers_concordance.png    # scDblFinder vs DoubletFinder Venn diagram
├── 03_integration/
│   ├── umap_uncorrected.png               # Pre-integration PCA/UMAP
│   ├── umap_integrated_harmony.png        # Integrated UMAP embedding
│   ├── integration_benchmarking.csv       # Quantitative kBET and LISI scores
│   └── seurat_integrated.rds              # Integrated Seurat v5 object
├── 04_annotation/
│   ├── umap_consensus_celltypes.png       # SingleR + scType + scCATCH consensus UMAP
│   ├── annotation_confidence_scores.png   # Bootstrap confidence distributions
│   └── cluster_annotations.csv            # Per-cluster consensus assignments
├── 05_differential_expression/
│   ├── pseudobulk_deseq2_results.csv      # Multi-donor DESeq2 condition DE
│   ├── volcano_plot_de_genes.png          # High-resolution volcano plot
│   └── clusterprofiler_gsea_dotplot.png   # GO / KEGG pathway enrichment
├── 06_interoperability/
│   ├── adata_processed.h5ad               # Scanpy / AnnData format
│   ├── sce_processed.rds                  # Bioconductor SingleCellExperiment
│   └── loom_processed.loom                # Loom format
├── 07_monocle3/
│   ├── monocle3_principal_graph.png       # Learned manifold trajectory
│   └── monocle3_pseudotime.png            # Cells ordered along root pseudotime
├── 09_cellchat/
│   ├── cellchat_communication_network.png # Intercellular signaling interaction chord
│   └── signaling_pathways_summary.csv     # Significant ligand-receptor pairs
└── 14_figures/
    ├── Figure_1_Composite_Overview.png    # Multi-panel publication composite (300 DPI)
    └── Figure_1_Composite_Overview.pdf    # Vector graphics publication PDF
```

---

## 🔬 Step 5: Biological Interpretation of Results

### 1. QC & Decontamination (Stage 01 & 02)
* Check `results_pbmc/01_qc/soupx_ambient_contamination.png`. For peripheral blood, ambient RNA contamination typically ranges between **2% and 5%**. If higher, SoupX automatically subtracts the ambient background profile before downstream clustering.
* Check `results_pbmc/01_qc/qc_violins_post_filtering.png`. Low-quality droplets with `< 200` unique genes or `> 15%` mitochondrial reads are filtered out.

### 2. Cell-Type Annotation (Stage 04)
Open `results_pbmc/04_annotation/umap_consensus_celltypes.png`. For PBMC datasets, scRATool automatically resolves:
* **CD4+ T Cells:** Marked by *IL7R*, *CD4*.
* **CD8+ T Cells:** Marked by *CD8A*, *CD8B*.
* **B Cells:** High *MS4A1* (CD20) and *CD79A*.
* **CD14+ Monocytes:** Expressing *CD14*, *LYZ*.
* **FCGR3A+ Monocytes (Non-classical):** Expressing *FCGR3A* (CD16), *MS4A7*.
* **NK Cells:** High *GNLY*, *NKG7*.
* **Dendritic Cells:** *FCER1A*, *CST3*.
* **Platelets / Megakaryocytes:** *PPBP*.

Because scRATool uses **triangulated consensus voting** (combining SingleR reference mapping, scType marker enrichment, and scCATCH evidence), conflicting annotations are reconciled with high statistical confidence.

### 3. Differential Expression (Stage 05)
Open `results_pbmc/05_differential_expression/volcano_plot_de_genes.png`.
* Unlike traditional tools that run single-cell Wilcoxon tests (which inflate false-positive rates due to pseudoreplication), scRATool aggregates single-cell counts into **donor-level pseudo-bulks** and evaluates significance with **DESeq2** using a negative binomial generalized linear model.
* Significant upregulated and downregulated genes are cross-referenced with **clusterProfiler** for Gene Ontology (GO) and KEGG enrichment.

---

## 🐍 Step 6: Load Results into Python or R

Once the pipeline completes, you can immediately continue your exploratory analysis in Python or R:

### Loading in Python (Scanpy / AnnData)
```python
import scanpy as sc

# Read the AnnData object generated in Stage 06
adata = sc.read_h5ad("results_pbmc/06_interoperability/adata_processed.h5ad")
print(adata)
# AnnData object with n_obs × n_vars = 2638 × 18342
#   obs: 'sample_id', 'condition', 'consensus_celltype', 'pseudotime'
#   obsm: 'X_umap', 'X_pca'

# Plot UMAP colored by cell types
sc.pl.umap(adata, color=["consensus_celltype", "condition"])
```

### Loading in R (Seurat)
```r
library(Seurat)

# Read the integrated Seurat object generated in Stage 03/04
seurat_obj <- readRDS("results_pbmc/03_integration/seurat_integrated.rds")

# Inspect cell types and clusters
DimPlot(seurat_obj, group.by = "consensus_celltype", label = TRUE)
```

---

## 🎯 Next Steps

* To run this workflow interactively in your browser with real-time progress bars and interactive Plotly lasso selection, see [Tutorial 2: Web GUI Walkthrough](02_gui_walkthrough.md).
* To learn how to structure your experimental design with multi-donor replicates, see [Tutorial 3: Samplesheet & Biological Metadata Guide](03_samplesheet_guide.md).
* To run massive cohorts on an institutional SLURM cluster, see [Tutorial 4: HPC & SLURM Deployment](04_hpc_slurm_guide.md).
* To learn how to customize gene allowlists and rescue rare biomarker-positive cells, see [Tutorial 8: Custom Biology & Allowlists](08_custom_biology_and_allowlists.md).
