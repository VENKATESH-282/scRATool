# Tutorial 7: Trajectories, Intercellular Signaling & Gene Networks

Moving beyond static clustering requires modeling dynamic cellular transitions, cell-cell communication networks, chromosomal alterations, and gene co-expression modules.

scRATool integrates seven advanced analytical modules in Stages 07 through 13.

---

## 🛤️ Part 1: Trajectory & Pseudotime Inference (Stages 07 & 08)

### 1. Monocle 3 (Stage 07)
* **Algorithmic Basis:** Constructs a low-dimensional manifold using reversed graph embedding (`learn_graph`).
* **Root Assignment & Pseudotime:** Calculates geodesic distance from designated stem or progenitor root cells to differentiated terminal states.
* **Kinetic Gene Discovery:** Identifies genes whose expression varies smoothly as a function of pseudotime using Moran's $I$ spatial autocorrelation.
* **Outputs:** `results/07_monocle3/monocle3_principal_graph.png`, `monocle3_pseudotime.png`, and ranked dynamic genes CSV.

### 2. Slingshot & tradeSeq (Stage 08)
* **Simultaneous Principal Curves:** Fits smooth non-parametric curves through clusters to resolve multi-branching developmental lineages.
* **tradeSeq GAM Modeling:** Fits Generalized Additive Models (GAMs) with cubic splines to detect:
  * **Association Test:** Genes significantly dynamic along any lineage.
  * **Early / Pattern Test:** Genes that diverge early between two competing branch fates.
* **Outputs:** `results/08_slingshot/slingshot_lineage_curves.png` and smooth temporal expression heatmaps.

---

## 📡 Part 2: Intercellular Communication & Signaling (Stages 09 & 10)

### 1. CellChat v2 (Stage 09)
* **Mass-Action Communication Modeling:** Quantifies communication probability between cell types using the law of mass action on curated ligand-receptor pairs from `CellChatDB` (supports human and mouse).
* **Pathway Level Aggregation:** Computes network centrality to identify dominant sender, receiver, mediator, and influencer populations for major pathways (e.g., TGF$\beta$, WNT, VEGF, Chemokines).
* **Outputs:**
  * Interaction chord diagrams (`results/09_cellchat/cellchat_chord_diagrams.png`).
  * Incoming and outgoing signaling pattern heatmaps.
  * Significant interaction tables with $p$-values and communication strength.

### 2. NicheNet v2 (Stage 10)
* **Mechanistic Sender-to-Receiver Modeling:** While CellChat evaluates whether ligands and receptors are co-expressed, NicheNet asks: *Does the ligand actually induce downstream target gene expression in the receiver cell?*
* **Prior-Model Regulatory Potential:** Combines ligand-receptor binding with intracellular signaling and gene regulatory network priors.
* **Prioritization:** Ranks ligands based on how well they predict the differentially expressed target genes observed in receiver cells.
* **Outputs:** Prioritized ligand activity heatmaps and ligand-target regulatory circus plots (`results/10_nichenet/`).

---

## 🧬 Part 3: Cancer Genetics & Co-Expression Networks (Stages 11, 12, 13)

### 1. CopyKAT Genomic CNV Profiling (Stage 11)
* **Aneuploidy vs. Diploid Resolution:** In tumor biopsies, identifying malignant cells from infiltrating stromal or immune cells can be challenging. CopyKAT estimates read-depth chromosomal copy-number alterations (CNAs) from scRNA-seq counts.
* **Bayesian Mixture Clustering:** Statistically classifies every cell as either **Aneuploid (Tumor)** or **Diploid (Non-malignant stromal/immune)** at an average resolution of 5 Mb.
* **Outputs:** Whole-genome chromosome CNV heatmap (`results/11_copykat/copykat_cnv_heatmap.png`) and aneuploid barcode assignments.

### 2. hdWGCNA Metacell Networks (Stage 12)
* **High-Dimensional WGCNA:** Overcomes the extreme sparsity and dropout of single-cell data by constructing **k-nearest neighbor Metacells** (aggregates of 10–20 biologically similar cells).
* **Module Eigengenes & Hub Genes:** Calculates soft-power threshold $\beta$, identifies co-expressed gene modules, and extracts intramodular hub genes that control cellular phenotypes.
* **Outputs:** Module dendrograms, eigengene expression UMAPs, and hub gene network files (`results/12_hdwgcna/`).

### 3. RNA Velocity Preparation (Stage 13)
* **Spliced / Unspliced Layers:** Formats and exports count layers into `.loom` and `.h5ad` objects compatible with **scVelo** and **CellRank** for calculating future cellular transition velocity vectors.
