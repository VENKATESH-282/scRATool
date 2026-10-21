# Tutorial 8: Custom Organisms, Tissues & Allowlist Biomarker Rescue

Most single-cell pipelines assume standard human samples and aggressively filter out rare transcripts. When researchers study non-human organisms, specialized tissues, or ultra-rare biomarkers (such as rare transcription factors, transgenes, or disease-specific drivers), rigid pipelines often fail or silently discard critical biological signal.

scRATool provides built-in mechanisms to adapt to any organism, tissue, or custom biomarker set.

---

## 🐭 Part 1: Analyzing Mouse & Other Model Organisms

scRATool dynamically configures its annotation engines, signaling databases, and annotation dictionaries based on the `--organism` parameter:

```bash
nextflow run pipeline/main.nf \
    --samples samples_mouse.csv \
    --outdir results_mouse/ \
    --organism mouse \
    --tissue Brain \
    -profile local,pixi \
    -resume
```

### What Happens Automatically Under the Hood:
1. **Annotation Databases:** Switches Bioconductor organism database from `org.Hs.eg.db` to `org.Mm.eg.db` for Entrez ID mapping and GO term enrichment.
2. **Cell-Cell Communication:** Wires **CellChat v2** to `CellChatDB.mouse` instead of the human database, accurately matching murine ligand-receptor pairs.
3. **Reference Atlases:** Configures **SingleR** and **scType** to use mouse-specific cell reference databases (e.g., `MouseRNAseqData`).

---

## 🛡️ Part 2: Custom Gene Allowlist (Rescuing Rare Biomarkers)

### The Problem: Why Rare Disease Genes Get Discarded
In standard scRNA-seq quality control:
* Genes with low total counts across the dataset are routinely removed to reduce dimensionality.
* Cells with low overall UMI counts or rare bursty expression (e.g. 1 in 1,000 cells) may be flagged as empty droplets or background noise.
* For diseases driven by ultra-rare burst expression of master transcription factors (e.g., *DUX4* in Facioscapulohumeral Muscular Dystrophy, rare stem-cell pioneer factors like *OCT4* or *NANOG*, or low-copy CRISPR sgRNA transcripts), standard filtering purges the exact cells that drive the pathology.

### The scRATool Allowlist Mechanism:
When you provide `--custom_gene_allowlist`:

```bash
nextflow run pipeline/main.nf \
    --samples samples.csv \
    --outdir results/ \
    --organism human \
    --custom_gene_allowlist "DUX4,LEUTX,TRIM43,KHDC1L,PRAMEF2" \
    -profile local,pixi \
    -resume
```

1. **Exemption from Gene Filtering:** Genes in the allowlist are strictly preserved regardless of the global minimum cell-count cutoff (`min_pct_cells`).
2. **Cell Rescue:** Any droplet containing genuine, non-zero reads for an allowlist gene is given a protective flag during adaptive MAD outlier filtering, preventing true biomarker-positive cells from being discarded as low-UMI debris.
3. **Stage 01 QC Summary:** A separate section in `results/01_qc/allowlist_rescued_cells.csv` documents exactly how many cells expressing your designated genes were preserved and their distribution across biological conditions.

---

## 🎯 Part 3: Custom Marker Gene Panels (`--custom_gene_panel`)

If your project focuses on a defined biological pathway or therapeutic target panel, pass them via `--custom_gene_panel`:

```bash
nextflow run pipeline/main.nf \
    --samples samples.csv \
    --outdir results/ \
    --custom_gene_panel "CD3D,CD4,CD8A,MS4A1,CD14,FCGR3A,NCAM1,PPBP" \
    -profile local,pixi \
    -resume
```

### Impact Across Pipeline Stages:
* **Stage 04 (Annotation):** Computes dedicated module scores for your custom panel across all identified cell clusters.
* **Stage 05 (Differential Expression):** Generates specialized high-resolution expression violin plots and dotplots highlighting your panel genes across disease conditions.
* **Stage 07 & 08 (Trajectories):** Evaluates kinetic expression curves of your panel genes smoothly plotted against pseudotime progression.
* **Stage 14 (Publication Figures):** Automatically incorporates your gene panel into composite publication figures (`Figure_1_Composite_Overview.png`).
