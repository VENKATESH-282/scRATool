# scRATool: Universal Single-Cell RNA-seq Analysis Platform

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Nextflow](https://img.shields.io/badge/Nextflow-DSL2-brightgreen.svg)](https://www.nextflow.io/)
[![Framework: Seurat 5](https://img.shields.io/badge/Framework-Seurat%205-blue.svg)](https://satijalab.org/seurat/)
[![FastAPI](https://img.shields.io/badge/GUI-FastAPI-009688.svg)](https://fastapi.tiangolo.com/)

**scRATool** is an end-to-end, reproducible, and universally applicable single-cell RNA sequencing (scRNA-seq) downstream analysis platform. Orchestrated by **Nextflow DSL2** and powered by **Seurat v5 & Bioconductor**, scRATool couples a high-performance **FastAPI web GUI** with automated multi-method benchmarking across 14 modular analytical stages.

---

## 🌟 Key Features

* **Universal Count Matrix Ingestion:** Directly ingests 10x Genomics Cell Ranger directories, HDF5 (`.h5`, `.h5ad`), compressed tabular matrices (`.txt.gz`, `.csv.gz`, `.tsv.gz`), serialized Seurat RDS (`.rds`), or remote NCBI GEO accessions (GSE/GSM) via automated HTTPS retrieval.
* **14 Modular Analysis Stages:**
  1. **QC & Decontamination:** SoupX ambient RNA correction, DropletUtils cell calling, scDblFinder doublet removal, and adaptive MAD metric filtering.
  2. **QC Tool Comparison:** Empirical comparative benchmarking between DecontX vs. SoupX and DoubletFinder vs. scDblFinder.
  3. **Multi-Method Batch Integration:** Parallel benchmarking of SCTransform v2 with CCA, RPCA, Harmony, and FastMNN, evaluated via kBET and LISI mixing scores.
  4. **Triangulated Cell-Type Annotation:** Consensus majority voting combining SingleR, scType, and scCATCH.
  5. **Differential Expression & GSEA:** Multi-donor pseudo-bulk DESeq2 condition testing, cluster markers, and functional pathway enrichment (clusterProfiler, Enrichr).
  6. **Cross-Platform Interoperability:** Automated export to Bioconductor `SingleCellExperiment`, Python `AnnData (.h5ad)`, and `Loom`.
  7. **Monocle 3 Trajectory:** Manifold graph learning, root-to-terminal pseudotime, and kinetic branch genes.
  8. **Slingshot Lineages:** Simultaneous principal curve inference and smooth GAM modeling via `tradeSeq`.
  9. **CellChat v2 Signaling:** Mass-action cell-cell communication networks, pathway topology, and interaction chord diagrams.
  10. **NicheNet v2 Signaling:** Prior-model mechanistic ligand prioritization and downstream target gene regulation.
  11. **CopyKAT CNV Profiling:** Read-depth chromosomal copy-number alteration inference and aneuploid vs. diploid classification.
  12. **hdWGCNA Networks:** High-dimensional co-expression network analysis, metacell aggregation, and hub gene identification.
  13. **RNA Velocity Input Export:** Spliced/unspliced count matrix layer export compatible with `scVelo` and `CellRank`.
  14. **Publication Multi-Panel Figures:** Automated composite figure assembly (300 DPI PNG & vector PDF).
* **Interactive Results Explorer & Lasso Sub-Clustering:** Plotly-powered UMAP with interactive Lasso and Box selection tools enabling researchers to dynamically isolate cell subpopulations and export custom metadata CSV cohorts for targeted downstream analysis.
* **HPC Cluster Integration (SLURM / SGE / PBS):** Built-in remote profile manager supporting SSH filesystem verification, remote directory browsing, samplesheet synchronization, and remote pipeline dispatch without requiring terminal interaction.
* **Multi-User Isolation:** 16-character workspace session tokens enabling instant project switching and run isolation.

---

## 🚀 Quick Start

### 1. Prerequisites

* **Linux** or **macOS**
* **Python 3.10+**
* **Nextflow (>= 23.04.0)**:
  ```bash
  curl -s https://get.nextflow.io | bash
  sudo mv nextflow /usr/local/bin/
  ```
* **Pixi** or **Conda** for R/Python bioinformatics dependencies:
  ```bash
  curl -fsSL https://pixi.sh/install.sh | bash
  ```

### 2. Installation

Clone this repository and install Python web dependencies:

```bash
git clone https://github.com/<your-username>/scRATool.git
cd scRATool

pip install -r requirements.txt
```

Initialize the Pixi environment for the 14-stage bioinformatics pipeline:
```bash
cd pipeline
pixi install
cd ..
```

### 3. Launch the Web Interface

Start the local server with one command:

```bash
./start.sh
```

Then open your browser at **`http://localhost:8051`**.

---

## 🖥️ Running on an HPC Cluster

scRATool enables direct execution on remote SLURM/HPC clusters from the web interface:

1. Open the **Run Monitor** tab in the web GUI.
2. Select **Run Location: Remote HPC Cluster**.
3. Click **+ Add Profile** to enter your cluster credentials:
   * **Host:** `cluster.institution.edu`
   * **User:** `your_username`
   * **Port:** `22`
   * **Auth:** Password or Private Key Path
4. Click **Test & Connect**. Once connected, scRATool automatically verifies remote Nextflow and Pixi environments, synchronizes your samplesheet, and dispatches jobs to SLURM nodes.

---

## 📁 Samplesheet Format (`samples.csv`)

Create a comma-separated CSV file with your single-cell samples:

```csv
sample_id,condition,patient_id,file_path
Sample_CTRL_1,CTRL,Donor_A,/path/to/data/CTRL_1/filtered_feature_bc_matrix.h5
Sample_CTRL_2,CTRL,Donor_B,/path/to/data/CTRL_2.csv.gz
Sample_TREATED_1,TREATED,Donor_C,/path/to/data/TREATED_1/
Sample_TREATED_2,TREATED,Donor_D,/path/to/data/TREATED_2.rds
```

* Supported inputs: 10x directories (`matrix.mtx.gz`), `.h5`, `.h5ad`, `.txt.gz`, `.csv.gz`, `.rds`, or NCBI GEO accession IDs.

---

## 🔬 Command-Line Execution (Headless)

You can also run the Nextflow pipeline directly via CLI:

```bash
nextflow run pipeline/main.nf \
    --samples samples.csv \
    --outdir results/ \
    --organism human \
    -profile slurm,pixi \
    -resume
```

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## ✉️ Citation & Contact

If you use scRATool in your research, please cite our manuscript:
* **scRATool: A Nextflow DSL2-Orchestrated Universal Single-Cell RNA Sequencing Platform with Multi-Method Benchmarking and Interactive Web Analytics** (2026).
