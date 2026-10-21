# Tutorial 2: Complete Web GUI Walkthrough & Interactive UMAP Manual

The **scRATool Graphical User Interface (GUI)** is a high-performance web application powered by **FastAPI**, **Plotly.js**, and asynchronous Server-Sent Events (SSE). It gives researchers complete visual control over their single-cell projects—from samplesheet preparation and parameter configuration to real-time cluster monitoring and interactive cell sub-clustering—without writing any shell scripts or R code.

---

## 🚀 Launching the Web Interface

### Local Machine
In the root directory of scRATool:
```bash
./start.sh
```
Open your browser to:
👉 **`http://localhost:8051`**

### Remote Server / HPC Head Node (via SSH Port Forwarding)
If scRATool is running on a remote server or university compute node, forward port `8051` to your local machine:
```bash
# Run on your local laptop:
ssh -L 8051:localhost:8051 username@remote-server.institution.edu

# Then on the remote server:
cd /path/to/scRATool
./start.sh
```
Now navigate to `http://localhost:8051` in your local browser!

---

## 🗂️ 1. Workspace Isolation & Session Token System

Every analysis project in scRATool is tied to a secure **16-character session token** (e.g. `8CPN-MM8W-3A2Q-Z6U4`).

<p align="center">
  <img src="../screenshots/landing_1440x900.png" width="95%" alt="scRATool Dashboard" />
</p>

### Why Sessions Matter:
* **Complete Isolation:** Each session stores its own `samples.csv`, customized parameter JSON, execution history, and generated outputs in `sessions/<TOKEN>/`.
* **Zero Interference:** Multiple researchers can use the same scRATool instance simultaneously without overwriting each other's configurations or results.
* **1-Click Session Cloning:** Click **+ New Session** to spawn a fresh analysis workspace with your current parameter settings cloned as defaults.
* **Session Persistence:** Bookmark or save your token. When you return tomorrow, enter your token in the dashboard to immediately resume your work.

---

## 📋 2. Interactive Samplesheet & Input Manager

The **Samples & Inputs** view lets you construct, edit, and validate your single-cell experimental cohort.

<p align="center">
  <img src="../screenshots/samples_tab_preview.png" width="95%" alt="Samplesheet Manager" />
</p>

### Key Features:
1. **Interactive Spreadsheet Table:** Add, delete, and reorder sample rows directly in the browser.
2. **File Path Verification:** As you enter matrix paths (`.h5`, `.csv.gz`, or 10x folders), scRATool checks in real-time whether the path exists on disk or cluster storage and displays a green checkmark or warning indicator.
3. **Bulk Directory Prefix Helper:** If your raw count matrices are stored in `/shared/storage/single_cell_runs/`, enter this prefix once in the helper box to automatically prepend it to all sample paths.
4. **NCBI GEO Auto-Fetch:** Enter a GSE accession (e.g., `GSE174609`) and click **Fetch GEO Data**. The backend automatically queries NCBI FTP servers, retrieves the supplementary count matrices, unpacks them into your session workspace, and populates the table rows.
5. **Reference Baseline Condition:** Designate your baseline control condition (e.g., `Control`, `WildType`, `Healthy`) so that downstream differential expression contrasts in Stage 05 are automatically computed as `Treated vs. Control`.

---

## ⚙️ 3. Dynamic Parameter Configuration

Every parameter across all 14 stages is dynamically rendered and validated against the Nextflow JSON schema (`nextflow_schema.json`).

<p align="center">
  <img src="../screenshots/params_1440x900_light.png" width="95%" alt="Parameters Configuration" />
</p>

### 1-Click Biological Presets:
* **Standard Publication Workflow:** Balanced, publication-tested thresholds for 10x Chromium datasets (e.g., 200 min genes, 20% mito cap, SCTransform v2, Harmony batch correction, consensus annotation).
* **Rapid Test / Stub Run:** Lightweight configuration designed for CI/CD or fast validation on small cohorts.
* **Deep Discovery & Signaling:** Enables all computationally demanding downstream modules (Monocle 3, Slingshot, CellChat v2, NicheNet v2, CopyKAT CNV, and hdWGCNA networks).

### Stage-by-Stage Customization:
* **Stage 01 (QC & Decontamination):** Set minimum genes per cell (`nfeature_min`), minimum UMIs (`ncount_min`), maximum mitochondrial percentage (`pct_mito_max`), and custom gene allowlists.
* **Stage 03 (Batch Integration):** Select your preferred integration method (`harmony`, `cca`, `rpca`, `fastmnn`, or `none`) and clustering resolution.
* **Stage 04 (Annotation):** Choose reference atlas (`HumanPrimaryCellAtlasData`, `BlueprintEncodeData`, `MonacoImmuneData`) and tissue type.

---

## 📊 4. Run Monitor & Real-Time Log Streaming

Execute your single-cell analysis locally or dispatch it to an institutional compute cluster.

<p align="center">
  <img src="../screenshots/monitor_1440x900_light.png" width="95%" alt="Run Monitor & Live Terminal" />
</p>

### Real-Time Features:
* **Visual 14-Stage Progress Tracker:** Watch the workflow progress from Stage 01 through Stage 14. Completed stages show green status tags; the currently running stage shows an active pulse animation.
* **Server-Sent Events (SSE) Terminal:** Live streaming logs from `.nextflow.log` are piped directly to the web terminal. No page refreshes are required.
* **Checkpoint & Resume:** The pipeline runs with `-resume` enabled by default. If you stop the run or update a parameter in Stage 07, Nextflow re-uses cached outputs from Stages 01–06, finishing downstream tasks in seconds.

---

## 🖼️ 5. Results Explorer & High-Resolution Lightbox

The **Results Explorer** view organizes all plots and quantitative tables produced across all 14 stages.

<p align="center">
  <img src="../screenshots/explorer_stage04_real_plots.png" width="95%" alt="Results Explorer Gallery" />
</p>

### Capabilities:
* **Stage-by-Stage Tab Navigation:** Switch between stages to view violin plots, UMAPs, heatmaps, and chord diagrams.
* **Modal Lightbox Zoom:** Click any figure thumbnail to open a high-resolution lightbox viewer. Use mouse wheel zoom and pan to inspect subtle cluster boundaries or small text labels.
* **Interactive CSV Data Tables:** Search, filter, and paginate differential expression results, cell-type annotation tables, and QC summary metrics directly inside the web interface.

---

## 🎯 6. Interactive Plotly UMAP & Lasso Sub-Clustering

One of scRATool's most powerful capabilities is its **interactive single-cell embedding viewer**.

<p align="center">
  <img src="../screenshots/explorer_real_umap_celltype.png" width="95%" alt="Interactive UMAP & Lasso Sub-Clustering" />
</p>

### How to Isolate Custom Cell Cohorts:
1. Navigate to the **Interactive UMAP** panel in the Results Explorer.
2. Select your coloring mode from the dropdown:
   * **Consensus Cell Type**
   * **Biological Condition** (e.g. Control vs. Treated)
   * **Continuous Gene Expression** (type any gene symbol, e.g. *CD8A*, *MS4A1*, *FOXP3*)
3. In the Plotly top toolbar, click the **Lasso Select** tool (or **Box Select**).
4. Draw freely around any interesting cell population or transitional state on the 2D embedding.
5. In the **Cohort Metadata** sidebar:
   * Enter a descriptive cohort name (e.g., `Activated_CD8_T_Cells`).
   * Add optional experimental notes.
6. Click **Save Selected Cells to CSV**.
7. scRATool exports a targeted barcode metadata CSV into `assets/custom_groups/<cohort_name>.csv`. You can immediately use this cohort for targeted sub-clustering, branch trajectory analysis, or focused differential expression!
