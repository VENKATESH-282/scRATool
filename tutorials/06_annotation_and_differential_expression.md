# Tutorial 6: Consensus Cell Typing & Pseudo-bulk Differential Expression

Accurate cell-type identification and robust differential expression testing are the foundation of any single-cell study. Single-method annotation tools often produce conflicting results, while traditional single-cell statistical tests suffer from extreme false-positive rates due to pseudoreplication.

scRATool solves both challenges in **Stage 04 (Triangulated Consensus Annotation)** and **Stage 05 (Multi-Donor Pseudo-Bulk DESeq2)**.

---

## 🏷️ Part 1: Triangulated Cell-Type Annotation (Stage 04)

Rather than trusting a single automated caller, scRATool combines **three independent annotation paradigms**:

```text
                                 ┌───────────────────────────────────┐
                                 │      Integrated Seurat Object     │
                                 └─────────────────┬─────────────────┘
                                                   │
                ┌──────────────────────────────────┼──────────────────────────────────┐
                ▼                                  ▼                                  ▼
 ┌─────────────────────────────┐    ┌─────────────────────────────┐    ┌─────────────────────────────┐
 │       SingleR v2.4          │    │         scType v1.1         │    │        scCATCH v3.2         │
 ├─────────────────────────────┤    ├─────────────────────────────┤    ├─────────────────────────────┤
 │ • Reference correlation     │    │ • Marker gene database      │    │ • Automated tissue evidence │
 │ • Bulk reference profiles   │    │ • Positive & negative       │    │ • Resolves tissue-specific  │
 │   (HPCA, Blueprint, Monaco) │    │   marker enrichment scoring │    │   sub-populations           │
 └──────────────┬──────────────┘    └──────────────┬──────────────┘    └──────────────┬──────────────┘
                │                                  │                                  │
                └──────────────────────────────────┼──────────────────────────────────┘
                                                   │
                                                   ▼
                                    ┌─────────────────────────────┐
                                    │  Consensus Majority Voting  │
                                    │  (High Confidence Labeling) │
                                    └─────────────────────────────┘
```

### 1. SingleR (Reference Transcriptome Correlation)
* **How it works:** Computes Spearman correlation between the single-cell expression profile and curated reference bulk RNA-seq databases (e.g. `HumanPrimaryCellAtlasData`, `BlueprintEncodeData`, or `MonacoImmuneData`).
* **Strength:** Excellent at identifying canonical lineages (T cells, B cells, Monocytes, Fibroblasts, Endothelial cells).

### 2. scType (Marker Enrichment Scoring)
* **How it works:** Leverages an extensive database of cell-type specific marker genes. For each cluster, it computes an enrichment score that rewards expression of known positive markers while penalizing expression of negative markers.
* **Strength:** Unbiased detection of activation states and tissue-specific subtypes.

### 3. scCATCH (Tissue Heterogeneity Automated Curation)
* **How it works:** Matches top cluster marker genes against published tissue-specific cell-marker evidence.
* **Strength:** Distinguishes rare organ-specific parenchymal cells.

### 4. Consensus Majority Voting
For every single cell and cluster:
* If 2 or 3 algorithms agree $\rightarrow$ the label is assigned with **High Confidence**.
* If all 3 algorithms disagree $\rightarrow$ scRATool assigns the highest-correlation SingleR label flagged as **Ambiguous** in `results/04_annotation/cluster_annotations.csv`, giving the researcher full visibility to review.

---

## ⚖️ Part 2: Multi-Donor Pseudo-Bulk Differential Expression (Stage 05)

### The "Pseudoreplication Trap" in Single-Cell DE
Traditional single-cell workflows often run two-sample Wilcoxon rank-sum tests or $t$-tests treating **each cell as an independent biological replicate**.

> **⚠️ Why this is statistically flawed:**
> Cells sampled from the same patient are **not independent**; they share the same genetic background, microenvironment, and library prep artifacts.
> 
> When you test 10,000 cells from 3 Control donors against 10,000 cells from 3 Disease donors using a cell-level test, the effective degrees of freedom is artificially inflated by orders of magnitude. The test produces thousands of statistically significant genes with microscopic p-values ($p < 10^{-300}$), most of which are false discoveries driven by donor-level technical noise rather than true disease biology.

### The Solution: Pseudo-Bulk Aggregation + DESeq2
scRATool aggregates single-cell counts into **donor pseudo-bulks** before differential testing:

```r
# scRATool pseudo-bulk aggregation logic:
pseudo_bulk_counts <- AggregateExpression(
    seurat_obj,
    assays = "RNA",
    return.seurat = FALSE,
    group.by = c("consensus_celltype", "patient_id", "condition")
)
```

1. **Summing Counts:** For each cell type and each donor, raw UMI counts are summed across cells into a single synthetic bulk RNA-seq profile.
2. **Negative Binomial GLM:** Stage 05 fits a **DESeq2** Generalized Linear Model:
   $$\log_2(\mu_{ijk}) = \beta_{0} + \beta_{\text{condition}} \cdot X_{\text{condition}} + \epsilon_{ijk}$$
   using Wald tests and Benjamini-Hochberg False Discovery Rate (FDR) adjustments.
3. **Biological Validity:** Replicates represent actual patients/donors, ensuring that reported differentially expressed genes reflect genuine, reproducible condition-associated biology.

---

## 📈 Part 3: Functional Pathway Enrichment (GSEA & Enrichr)

All significant differentially expressed genes ($\text{FDR} < 0.05$, $|\log_2 \text{FC}| > 0.5$) are automatically routed through functional enrichment analysis:

* **Gene Ontology (GO):** Biological Process, Molecular Function, and Cellular Component.
* **KEGG & Reactome Pathways:** Mechanistic metabolic and signaling cascades.
* **MSigDB Hallmark Gene Sets:** Standardized 50 hallmark cellular processes (e.g. Interferon Gamma Response, Epithelial-Mesenchymal Transition, Hypoxia).
* **Output Plots:** High-resolution volcano plots, dotplots of top enriched terms, and gene-concept network plots saved in `results/05_differential_expression/`.
