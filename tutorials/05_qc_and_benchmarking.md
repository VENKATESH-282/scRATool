# Tutorial 5: QC Decontamination & Batch Integration Benchmarking

Single-cell RNA sequencing datasets suffer from systematic technical artifacts: ambient RNA soup leaking from lysed cells, artificial multiplets/doublets from co-encapsulated droplets, and batch effects introduced across different library preparation dates, sequencing flow cells, or donors.

scRATool tackles these artifacts through **dual-method decontamination benchmarking** in Stages 01–02 and **multi-algorithm integration benchmarking** in Stage 03.

---

## Part 1: Ambient RNA Removal (SoupX vs. DecontX)

### The Problem
During droplet generation in microfluidic channels, a fraction of cells inevitably lyse. Their released messenger RNA enters the cell suspension ("the soup") and is co-encapsulated into droplets alongside intact cells. This leads to false background detection of highly expressed tissue-specific genes across all cell types (e.g., hemoglobin genes in immune cells, or collagen in epithelial clusters).

### The Dual Approach
scRATool runs both **SoupX** and **Celda DecontX** in parallel:

```text
                        ┌──────────────────────────────────────────────┐
                        │              Raw Droplet Matrix              │
                        └──────────────────────┬───────────────────────┘
                                               │
                       ┌───────────────────────┴───────────────────────┐
                       ▼                                               ▼
     ┌───────────────────────────────────┐           ┌───────────────────────────────────┐
     │           SoupX v1.6.2            │           │         Celda DecontX v1.14       │
     ├───────────────────────────────────┤           ├───────────────────────────────────┤
     │ • Estimates global ambient soup   │           │ • Bayesian mixture model          │
     │   profile from empty droplets     │           │ • Disentangles cell-specific      │
     │ • Identifies non-expressing cells │           │   from shared ambient counts      │
     │ • Calculates global contam frac ρ │           │ • Estimates per-cell contam frac  │
     └─────────────────┬─────────────────┘           └─────────────────┬─────────────────┘
                       │                                               │
                       └───────────────────────┬───────────────────────┘
                                               ▼
                        ┌──────────────────────────────────────────────┐
                        │       Empirical Benchmark Comparison         │
                        │  (Scatterplots, Pearson r, Overlap Analysis) │
                        └──────────────────────────────────────────────┘
```

1. **SoupX:** Uses empty droplets ($< 100$ UMIs) to model the ambient RNA profile, identifies marker genes that should be exclusively negative in specific cell subsets, and calculates an accurate global contamination fraction $\rho$.
2. **DecontX:** Uses a Bayesian mixture model to estimate per-cell and per-cluster contamination without requiring empty droplets.
3. **Stage 02 Benchmark Output:** Generates a concordance scatterplot (`decontx_vs_soupx_scatter.png`). If both methods agree ($r > 0.85$), confidence in corrected expression values is maximized.

---

## Part 2: Multiplet & Doublet Detection (scDblFinder vs. DoubletFinder)

### The Problem
When two distinct cells are co-encapsulated in the same oil droplet (heterotypic doublets), they produce an artificial hybrid transcriptome (e.g., a droplet expressing both T-cell *CD3D* and B-cell *MS4A1*). If uncorrected, these false intermediates corrupt trajectory graphs and generate spurious intermediate cell types.

### Benchmarking Methodology
* **scDblFinder:** Simulates synthetic doublets from the observed count matrix, projects them into a low-dimensional PCA space, and trains an iterative gradient-boosted classifier to score real cells based on their neighborhood density relative to synthetic doublets.
* **DoubletFinder:** Generates artificial doublets ($pN$), runs PCA, and calculates $pANN$ (the proportion of artificial nearest neighbors) followed by thresholding based on the expected 10x loading rate.
* **Output Concordance:** Stage 02 outputs a Venn diagram (`doublet_callers_concordance.png`) and summary CSV displaying the exact intersection of flagged doublets. Heterotypic doublets flagged by consensus are purged from the downstream Seurat object.

---

## Part 3: Multi-Method Batch Integration (CCA vs. RPCA vs. Harmony vs. FastMNN)

A common challenge in multi-donor single-cell studies is distinguishing true biological variation from technical batch effects (different sequencing runs, chemistry versions, or clinical sites).

scRATool tests **four state-of-the-art integration methods** on SCTransform v2 normalized residuals:

| Method | Algorithm Class | Best Used For | Algorithmic Mechanism |
| :--- | :--- | :--- | :--- |
| **Seurat CCA** | Canonical Correlation Analysis | Strong technical divergence | Identifies shared gene correlation structures across batches before finding mutual nearest neighbors (MNNs). |
| **Seurat RPCA** | Reciprocal PCA | Large-scale cohorts (>50k cells) | Projects each dataset onto the PCA space of the other; faster and less prone to over-correction than CCA. |
| **Harmony** | Iterative Maximum Diversity Soft Clustering | Complex multi-level batch designs | Clusters cells in low-dimensional space while penalizing cluster assignments that over-represent a single batch. |
| **FastMNN** | Fast Mutual Nearest Neighbors | High dimensional linear correction | Identifies cell pairs between batches that are mutually closest neighbors in PCA space and aligns orthogonal subspaces. |

---

## Part 4: Quantitative Evaluation with kBET & LISI

Instead of relying solely on subjective visual inspection of UMAP plots, scRATool computes rigorous quantitative metrics in `results/03_integration/integration_benchmarking.csv`:

### 1. kBET (k-nearest neighbor Batch Effect Test)
* **What it measures:** Tests whether the distribution of batch labels in any cell's local neighborhood matches the overall cohort distribution ($H_0$).
* **Score range:** Rejection rate between $0.0$ and $1.0$.
* **Interpretation:** **Lower kBET rejection rate = superior batch mixing.** A score close to $0.05$ indicates near-perfect statistical batch homogeneity without technical clustering.

### 2. LISI (Local Inverse Simpson's Index)
LISI assesses whether batches are mixed while simultaneously preserving biological cell-type identity:
* **iLISI (integration LISI):** Measures batch diversity within a cell's neighborhood.
  * **Range:** $1$ (no mixing, only 1 batch in neighborhood) to $B$ (perfect mixing across all $B$ batches).
  * **Goal:** High iLISI.
* **cLISI (cell-type LISI):** Measures biological cell-type separation.
  * **Range:** $1$ (pure neighborhood, only 1 cell type) to $C$ (blurred cell types).
  * **Goal:** cLISI should remain close to $1.0$ (ensuring distinct biological cell types were not artificially merged).

---

## Automated Integration Selection

scRATool ranks each method by the composite harmonic score:
$$\text{Score} = \frac{\text{iLISI}}{\text{cLISI}} \times (1 - \text{kBET})$$

The winning integration is automatically serialized into `results/03_integration/seurat_integrated.rds` and propagated to Stage 04 for consensus cell-type annotation.
