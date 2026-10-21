# Tutorial 4: Enterprise HPC & SLURM Cluster Deployment

Single-cell datasets with tens or hundreds of thousands of cells require substantial RAM and multi-core CPU compute, particularly for **SCTransform v2 normalization**, **CopyKAT genomic CNV inference**, and **hdWGCNA metacell co-expression**.

scRATool provides native, built-in remote HPC cluster integration. You can configure, monitor, and manage SLURM, SGE, or PBS compute clusters directly from your browser without touching the command line on the remote machine.

---

## ️ Remote Execution Architecture

```text
┌─────────────────────────────────┐               ┌─────────────────────────────────┐
│     Local Machine / Browser     │               │        Remote HPC Cluster       │
│                                 │               │                                 │
│  FastAPI Server (localhost:8051)│               │  Head / Login Node              │
│               │                 │               │               │                 │
│        Paramiko SSH/SFTP ───────┼───────────────┼────────► Nextflow Orchestrator   │
│               │                 │  Encrypted    │               │                 │
│   • Live SSE Log Streaming      │  Connection   │        sbatch │                 │
│   • Remote Directory Browsing   │               │               ▼                 │
│   • Samplesheet Sync            │               │      SLURM Compute Nodes        │
│                                 │               │  ┌───────────────────────────┐  │
└─────────────────────────────────┘               │  │ Stage 01: QC & Decontam   │  │
                                                  │  │ Stage 03: SCTransform v2  │  │
                                                  │  │ Stage 11: CopyKAT CNV     │  │
                                                  │  │ Stage 12: hdWGCNA Modules │  │
                                                  │  └───────────────────────────┘  │
                                                  └─────────────────────────────────┘
```

---

## Step 1: HPC Cluster Authentication Setup

scRATool connects to your cluster's login node over standard SSH (port 22).

### Option A: SSH Key Authentication (Recommended)
1. On your local machine, check or generate an SSH key pair:
   ```bash
   ssh-keygen -t ed25519 -C "scratool_hpc_key"
   ```
2. Copy the public key to your cluster:
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub username@cluster.institution.edu
   ```
3. In scRATool's web interface, navigate to the **Run Monitor** tab and select **Target: Remote HPC Cluster**.
4. In the connection settings:
   * **Host:** `cluster.institution.edu`
   * **Port:** `22`
   * **Username:** `username`
   * **Auth Method:** `Private Key`
   * **Private Key Path:** `/home/username/.ssh/id_ed25519`

### Option B: Password Authentication
If your institution uses password authentication, simply select `Password` and enter your password. Passwords are held only in memory during the active session and are never logged or stored in version control.

---

## Step 2: Remote Scratch Directory & Directory Browser

1. Enter your designated cluster scratch directory in the **Remote Project Directory** field:
   ```text
   /scratch/users/username/scratool_runs/experiment_01
   ```
2. Click **Browse Cluster**. The modal file browser communicates via SFTP to let you:
   * Visually verify that input count matrices exist on cluster storage.
   * Create new project folders.
   * Select reference genome or annotation directories.

---

## ️ Step 3: SLURM Configuration (`pipeline/conf/cluster.config`)

Nextflow automatically translates stage resource directives into SLURM job submission parameters. Inspect `pipeline/conf/cluster.config`:

```groovy
/*
================================================================================
  SLURM Cluster Profile: Resource Allocations & Queue Directives
================================================================================
*/

process {
    executor       = 'slurm'
    clusterOptions = '--partition=compute --qos=normal'

    // Automated error recovery: double memory on OOM exit codes
    errorStrategy  = { task.exitStatus in [140, 143, 137, 247] ? 'retry' : 'finish' }
    maxRetries     = 2

    // Lightweight tasks (QC summary, file conversions)
    withLabel: 'process_low' {
        cpus   = { 2 * task.attempt }
        memory = { 8.GB * task.attempt }
        time   = { 2.h * task.attempt }
    }

    // Medium tasks (Doublet detection, Cell annotation, Differential expression)
    withLabel: 'process_medium' {
        cpus   = { 4 * task.attempt }
        memory = { 32.GB * task.attempt }
        time   = { 6.h * task.attempt }
    }

    // Heavy tasks (SCTransform v2, Harmony, CopyKAT CNV, hdWGCNA)
    withLabel: 'process_high' {
        cpus   = { 16 * task.attempt }
        memory = { 128.GB * task.attempt }
        time   = { 24.h * task.attempt }
    }
}
```

### Dynamic Memory Escalation:
If a stage encounters an Out-Of-Memory (OOM) event (Exit code 137 or 247), Nextflow automatically catches the signal, doubles the requested RAM (e.g. from 64 GB to 128 GB), and re-submits the job to the SLURM queue without failing the pipeline.

---

## Step 4: Dispatching the Pipeline

1. In the Web GUI, click **Launch Remote Pipeline**.
2. scRATool performs the following automated steps:
   * **SFTP Synchronization:** Uploads your session's `samples.csv` and `params.json` to the cluster scratch folder.
   * **Job Launch:** Dispatches Nextflow using `nohup` on the login node with `-profile slurm,pixi`.
   * **Terminal Stream:** Opens an encrypted SSH channel to pipe `.nextflow.log` live into your browser.
3. **Detached Autonomous Execution:** Once launched, the pipeline runs entirely under SLURM management. You can safely close your browser or disconnect your laptop. When you reconnect later, entering your session token re-establishes the live monitoring stream!

---

## Step 5: Headless Command-Line Execution (CLI)

If you prefer executing directly from a remote terminal or `tmux` session on the cluster:

```bash
# SSH into cluster login node
ssh username@cluster.institution.edu

# Navigate to project directory
cd /scratch/users/username/scRATool

# Launch Nextflow in a detached tmux session
tmux new -s singlecell_run

nextflow run pipeline/main.nf \
    --samples samples.csv \
    --outdir results/ \
    --organism human \
    -profile slurm,pixi \
    -resume
```

---

## ️ Troubleshooting Cluster Issues

### 1. `sbatch: error: Memory specification exceeds partition limit`
* Edit `pipeline/conf/cluster.config` and lower the maximum memory in `process_high` to fit your institution's partition limit (e.g., change `128.GB` to `64.GB`).

### 2. Singularity / Apptainer on HPC Nodes
If your compute nodes do not allow direct internet access or local package installation, scRATool supports container execution via Apptainer/Singularity:
```bash
nextflow run pipeline/main.nf \
    --samples samples.csv \
    --outdir results/ \
    -profile slurm,singularity \
    -resume
```

### 3. SSH Connection Dropped during Execution
Because the Nextflow process is launched using background process management (`nohup`), a network drop will **not** terminate your pipeline. Simply re-open scRATool or re-connect via SSH; Nextflow continues coordinating the SLURM tasks seamlessly.
