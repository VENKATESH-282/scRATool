# Tutorial 3: Comprehensive Samplesheet & Biological Metadata Guide

The samplesheet (`samples.csv`) defines your experimental cohort, biological conditions, patient replicates, and count matrix file paths.

Because scRATool is designed to be **universal**, it directly ingests count matrices in **five distinct formats** without requiring you to re-run upstream FASTQ alignment or write manual Seurat conversion scripts.

---

## 📋 The Standard 4-Column Samplesheet Format

Your samplesheet must be a standard comma-separated CSV file with a header containing four mandatory columns:

```csv
sample_id,condition,patient_id,file_path
```

### Column Specifications:

| Column | Type | Description | Best Practice / Example |
| :--- | :--- | :--- | :--- |
| **`sample_id`** | String | Unique identifier for each sequencing library or droplet run. | `PBMC_Healthy_1`, `Tumor_Core_A` (Use alphanumeric and underscores; avoid spaces and special characters). |
| **`condition`** | String | Experimental, genetic, or clinical condition. | `Control` vs. `Treated`, `WildType` vs. `Knockout`, `Healthy` vs. `Disease`. |
| **`patient_id`** | String | Biological donor or animal replicate identifier. | `Donor_1`, `Mouse_B`, `Patient_104`. **Critical for Stage 05 pseudo-bulk aggregation.** |
| **`file_path`** | Path / URL | Absolute local path, relative path, or remote URL to the count matrix. | `data/sample1/outs/filtered_feature_bc_matrix.h5` |

---

## 🗂️ In-Depth Examples for Each Input Format

### 1. 10x Genomics Chromium Output Directory
Points to the standard folder produced by `cellranger count`:
```csv
sample_id,condition,patient_id,file_path
Run_CTRL_1,Control,Donor_A,/data/cellranger_outs/CTRL_1/outs/filtered_feature_bc_matrix/
Run_CTRL_2,Control,Donor_B,/data/cellranger_outs/CTRL_2/outs/filtered_feature_bc_matrix/
```
The folder must contain the three standard 10x files:
* `matrix.mtx.gz` (Matrix Market format count values)
* `barcodes.tsv.gz` (Cell barcode identifiers)
* `features.tsv.gz` or `genes.tsv.gz` (Gene identifiers and symbols)

### 2. 10x Genomics HDF5 Matrix (`.h5`)
Points directly to the single HDF5 container:
```csv
sample_id,condition,patient_id,file_path
PBMC_1,Healthy,Donor_01,data/pbmc_1k_filtered_feature_bc_matrix.h5
PBMC_2,Healthy,Donor_02,data/pbmc_5k_filtered_feature_bc_matrix.h5
```

### 3. Compressed Tabular Text Matrices (`.csv.gz`, `.tsv.gz`, `.txt.gz`)
Commonly found in GEO supplementary files or published single-cell studies:
```csv
sample_id,condition,patient_id,file_path
Tumor_Biopsy_1,Tumor,Pt_01,data/GSE144236_Tumor_counts.tsv.gz
Tumor_Biopsy_2,Tumor,Pt_02,data/GSE144236_Tumor_2_counts.csv.gz
```
* **Format requirements:** Rows are gene symbols (e.g. *CD3D*, *CD8A*), columns are cell barcodes. Header row contains the barcode list.

### 4. Serialized Seurat Objects (`.rds`)
If you have already performed initial pre-processing or quality control:
```csv
sample_id,condition,patient_id,file_path
Dataset_Preprocessed_1,Baseline,Donor_X,data/seurat_filtered_cohort_1.rds
```

### 5. Remote NCBI GEO Accessions & Direct URLs
scRATool automatically downloads and parses remote supplementary matrices over HTTPS:
```csv
sample_id,condition,patient_id,file_path
GEO_Sample_1,Healthy,Donor_G1,https://ftp.ncbi.nlm.nih.gov/geo/series/GSE117nnn/GSE117988/suppl/GSE117988_raw_counts.csv.gz
```

---

## 🎯 Multi-Donor Experimental Design: Why `patient_id` is Critical

In Stage 05 (Differential Expression), scRATool avoids false discoveries caused by pseudoreplication by performing **multi-donor pseudo-bulk DESeq2 testing**.

### ⚠️ Common Mistake:
```csv
# WRONG: Setting patient_id equal to sample_id when multiple samples come from the same individual
sample_id,condition,patient_id,file_path
Sample_Day0,Control,Donor_1,data/d0.h5
Sample_Day7,Treated,Donor_2,data/d7.h5  <-- Mistake! Both were drawn from Donor_1
```

### ✅ Correct Design:
```csv
# RIGHT: Properly mapping biological replicates
sample_id,condition,patient_id,file_path
Sample_Pt1_CTRL,Control,Patient_01,data/p1_ctrl.h5
Sample_Pt1_TREAT,Treated,Patient_01,data/p1_treat.h5
Sample_Pt2_CTRL,Control,Patient_02,data/p2_ctrl.h5
Sample_Pt2_TREAT,Treated,Patient_02,data/p2_treat.h5
```
By accurately declaring `Patient_01` as the shared biological donor, Stage 05 can model paired donor effects in DESeq2 (`design = ~ patient_id + condition`), dramatically increasing statistical power to detect true treatment-induced expression changes.

---

## 🔍 Validation Checklist Before Running

Before launching your pipeline, verify:
* [ ] No duplicate `sample_id` values exist.
* [ ] The `condition` column has at least two groups if you plan to run Differential Expression in Stage 05.
* [ ] The designated baseline reference condition (e.g. `Control`) exists exactly as spelled in the `condition` column.
* [ ] File paths are either accessible locally or valid URLs.
* [ ] In the Web GUI, all sample rows show green existence indicators.
