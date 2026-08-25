<p align="center">
  <h1 align="center">🔬 scRATool</h1>
  <p align="center"><strong>Single-Cell RNA-seq Analysis Tool</strong></p>
  <p align="center">
    An end-to-end Nextflow + Flask pipeline for scRNA-seq data analysis — from raw FASTQs or count matrices to publication-ready figures.
  </p>
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#web-interface">Web Interface</a> •
  <a href="#server-setup">Server Setup</a> •
  <a href="#pipeline-steps">Pipeline Steps</a> •
  <a href="#license">License</a>
</p>

---

## Features

| Feature | Description |
|---------|-------------|
| **11-Step Pipeline** | CellRanger → QC → Integration → Annotation → DE → Exploration → Trajectory → CellChat → NicheNet → CopyKAT |
| **Web GUI** | Modern Flask-based dashboard to launch, monitor, and visualize results |
| **Multi-Dataset Support** | Run multiple experiments; switch between results using the Active Dataset dropdown |
| **4 Input Modes** | Raw FASTQs, 10X Count Matrices, Seurat RDS, or GEO Accession auto-download |
| **Remote Execution** | Run on a high-memory server via SSH, with automatic results sync back to your laptop |
| **Report Generation** | One-click HTML analysis report with all plots per dataset |
| **Docker & SLURM** | Profiles for laptop, workstation, server, HPC (SLURM), Docker, and Singularity |

## Quick Start

### Prerequisites

- **Nextflow** ≥ 24.0.0 ([install guide](https://www.nextflow.io/docs/latest/getstarted.html))
- **R** ≥ 4.3 with Bioconductor packages
- **Python** ≥ 3.9 with Flask
- **CellRanger** (only if starting from raw FASTQs)

### 1. Clone the Repository

```bash
git clone https://github.com/YOUR_USERNAME/scRATool.git
cd scRATool
```

### 2. Install R Dependencies

```bash
Rscript install_dependencies.R
```

### 3. Set Up the Web Interface

```bash
cd webapp
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python3 app.py
```

Open your browser at **http://localhost:5000**

### 4. Prepare Your Sample Sheet

Create a CSV file with columns: `sample_id`, `matrix_dir`, `condition`, `patient_id`

See [`nextflow/samples_example.csv`](nextflow/samples_example.csv) for the expected format.

### 5. Launch the Pipeline

**Option A: From the Web UI**
1. Select your input mode and sample sheet
2. Name your output folder (e.g., `results_my_experiment`)
3. Choose a compute profile
4. Click **Launch Pipeline**

**Option B: From the command line**
```bash
cd nextflow
nextflow run main.nf \
  --matrix samples_example.csv \
  --outdir results_my_experiment \
  -profile local \
  --skip_cellranger --skip_pdx
```

---

## Architecture

```
scRATool/
├── webapp/                     # Flask web application (GUI)
│   ├── app.py                  # Main Flask server
│   ├── static/
│   │   ├── css/style.css       # UI stylesheet
│   │   └── js/                 # Frontend JavaScript (app.js, plots.js, session.js)
│   ├── templates/
│   │   └── index.html          # Single-page application template
│   └── requirements.txt        # Python dependencies
│
├── nextflow/                   # Nextflow pipeline engine
│   ├── main.nf                 # Main Nextflow workflow (DSL2)
│   ├── nextflow.config         # Pipeline configuration & profiles
│   ├── ssh_wrapper.py          # Remote server execution helper
│   ├── bin/                    # R scripts called by Nextflow processes
│   └── samples_example.csv     # Example sample sheet
│
├── part*.R                     # Standalone R analysis scripts (Parts 2–10)
├── config.R                    # Global R configuration
├── install_dependencies.R      # Automated R package installer
├── Dockerfile                  # Docker build file
├── docker-compose.yml          # Docker Compose configuration
└── run_pipeline.sh             # Bash orchestrator for manual execution
```

---

## Web Interface

The web interface provides a complete dashboard for managing and visualizing your scRNA-seq analyses:

| Tab | Description |
|-----|-------------|
| **Data** | Configure input, select sample sheet, set compute profile, launch pipeline, view live logs |
| **Preprocessing** | QC plots, normalization, dimensionality reduction, clustering |
| **Downstream** | Cell annotation, differential expression, enrichment analysis, feature plots, trajectory |
| **Advanced** | CellChat communication networks, NicheNet ligand activity, CopyKAT CNV analysis |
| **Tools** | Settings (server config, color assignments, metadata editing), Report generation |

### Active Dataset Dropdown

When you run multiple experiments, each gets its own output folder. Use the **Active Dataset** dropdown in the top-right corner to instantly switch between results — all plots, tables, and reports will update to reflect the selected dataset.

---

## Server Setup

To run the pipeline on a remote high-memory server:

### 1. Configure Server Connection

Go to **Settings → Server Connection** in the web UI and fill in:

| Field | Description | Example |
|-------|-------------|---------|
| Server Host / IP | Your server's IP address | `192.168.1.100` |
| SSH Username | Your login username | `myuser` |
| Remote Pipeline Dir | Path to the pipeline on the server | `/data/myuser/scrna/pipeline` |
| SSH Password | Your SSH password (stored securely, used once) | `********` |

### 2. Copy the Pipeline to Your Server

```bash
rsync -avz --exclude='webapp/venv' --exclude='*.log' \
  ./ myuser@192.168.1.100:/data/myuser/scrna/pipeline/
```

### 3. Install Dependencies on the Server

```bash
ssh myuser@192.168.1.100
cd /data/myuser/scrna/pipeline
Rscript install_dependencies.R
```

### 4. Set Reference Genome Paths

Edit `nextflow/nextflow.config` and set the paths in the `server` profile:

```groovy
server {
    process.executor   = 'local'
    params.max_cpus    = 128
    params.max_memory  = 512.GB
    params.ref_human   = "/path/to/refdata-gex-GRCh38-2024-A"
    params.nichenet_models = "/path/to/nichenet/models"
}
```

Or pass them on the command line:
```bash
nextflow run main.nf --ref_human /path/to/ref -profile server
```

---

## Pipeline Steps

| Step | Name | Description |
|------|------|-------------|
| 1 | **CellRanger** | Align raw FASTQs and generate count matrices |
| 2 | **QC & Filtering** | EmptyDrops, SoupX, scDblFinder, cell/gene filtering |
| 3 | **Integration & Clustering** | CCA/RPCA/Harmony/FastMNN integration, PCA, UMAP, clustering |
| 4 | **Cell Annotation** | SingleR + scType automated cell type labeling |
| 5 | **Differential Expression** | Pseudobulk DE (DESeq2, limma), FindMarkers, volcano plots |
| 6 | **Object Exploration** | Feature plots, gene expression UMAPs, violin plots |
| 7 | **Trajectory Analysis** | Slingshot pseudotime, lineage curves |
| 8 | **PDX Processing** | Human-mouse xenograft species demultiplexing (optional) |
| 9 | **CellChat** | Ligand-receptor interaction networks, chord diagrams |
| 10 | **NicheNet** | Ligand activity prioritization, target gene prediction |
| 11 | **CopyKAT** | Copy number variation inference, tumor/normal classification |

### Skip Flags

Skip any step using command-line flags:
```bash
nextflow run main.nf --skip_trajectory --skip_nichenet --skip_copykat -profile local
```

Or check the corresponding boxes in the web UI before launching.

---

## Compute Profiles

| Profile | Description | Resources |
|---------|-------------|-----------|
| `laptop` | Low-resource workstation | 8 CPU, 12 GB RAM |
| `local` | Standard workstation | 32 CPU, 64 GB RAM |
| `server` | High-memory server | 128 CPU, 512 GB RAM |
| `hpc_small` | SLURM small partition | 32 CPU, 64 GB RAM |
| `hpc_large` | SLURM high-mem partition | 128 CPU, 512 GB RAM |
| `docker` | Docker container | System resources |
| `singularity` | Singularity container | System resources |
| `test` | Minimal test run | 8 CPU, 16 GB RAM |

---

## GEO Auto-Download

scRATool can automatically download and process datasets from NCBI GEO:

1. Select **GEO Accession** as your input mode
2. Enter an accession ID (e.g., `GSE171524`)
3. Click **Download + Run End-to-End**

The pipeline will download supplementary files, detect the matrix format (MEX/H5/DGE), generate a sample sheet, and launch the full analysis.

---

## Docker

```bash
# Build the image
docker build -t scratool .

# Run with Docker Compose
docker-compose up -d

# Access the web UI
open http://localhost:5000
```

---

## License

This project is developed by the **Tata Institute for Genetics and Society (TIGS)**.

---

## Citation

If you use scRATool in your research, please cite:

```
scRATool: Single-Cell RNA-seq Analysis Tool
Tata Institute for Genetics and Society
https://github.com/YOUR_USERNAME/scRATool
```
