# Tutorial 1: End-to-End Web GUI Walkthrough

This tutorial demonstrates how to use the **scRATool Web Interface** to run a complete single-cell analysis from start to finish.

---

## Step 1: Launch the Server
In your terminal, navigate to the scRATool directory and execute:
```bash
./start.sh
```
Open **`http://localhost:8051`** in Chrome, Firefox, or Edge.

---

## Step 2: Understand Workspaces & Session Tokens
scRATool assigns a unique 16-character workspace session token (e.g. `8CPN-MM8W-3A2Q-Z6U4`) to your project.
* **Workspace Isolation:** Your samples, custom parameters, and output results are saved within your workspace folder.
* **Cloning:** Click **+ New Session** to clone your current parameter settings into a fresh workspace without affecting previous runs.

---

## Step 3: Populate Your Samplesheet
1. Click the **Samples & Inputs** tab.
2. You can either:
   * **Click '+ Add Sample Row'** and type sample IDs, conditions (e.g. `CTRL`, `TREAT`), patient IDs, and file paths.
   * **Click '1-Click Presets'** to load a pre-configured template (e.g., 10x directory format or WT vs. KO).
   * **Use GEO Auto-Fetch:** Enter a GSE accession ID (e.g., `GSE174609`) to retrieve remote files automatically.
3. Set the **Baseline Reference Condition** (e.g., `CTRL` or `Healthy`) so differential expression contrasts are automatically formatted correctly.

---

## Step 4: Fine-Tune Parameters
1. Navigate to the **Parameters** tab.
2. Select an analytical preset:
   * **Standard Publication Workflow:** Balanced thresholds suitable for most 10x Chromium studies.
   * **Rapid Test / Stub Run:** For instant pipeline validation.
3. Adjust thresholds for QC filtering (`nFeature`, `nCount`, `% mitochondrial RNA`), batch integration methods (CCA, RPCA, Harmony, FastMNN), and downstream trajectory roots.

---

## Step 5: Launch & Monitor Pipeline Execution
1. Open the **Run Monitor** tab.
2. Select **Execution Target: Local Machine**.
3. Click **Run Pipeline**.
4. Watch the 14-stage workflow progress bar update in real time:
   * **Green Checkmarks:** Stages that completed successfully.
   * **Spinning Indicator:** The active stage currently executing.
   * **Terminal Box:** Live streaming logs from `.nextflow.log`.

---

## Step 6: Explore Figures, Tables & UMAP Lasso
1. Once completed, open the **Results Explorer** tab.
2. **Plot Gallery:** Click on any stage (Stage 01 to Stage 14) to view generated plots. Click any plot to open the full-resolution Lightbox Zoom.
3. **Interactive UMAP:**
   * Color cells by **Consensus Cell Type**, **Condition**, or **Gene Expression**.
   * Switch to the **Lasso Select** tool on the Plotly toolbar.
   * Draw around any cell population of interest.
   * In the sidebar, type a custom group name (e.g. `Activated_Immune_Subset`) and click **Save Selected Cells to CSV**.
