# Tutorial 3: Samplesheet & Biological Metadata Guide

The samplesheet (`samples.csv`) defines your experimental cohort, biological conditions, and single-cell count matrix locations.

---

## Format Specification

The CSV must contain four mandatory columns:

```csv
sample_id,condition,patient_id,file_path
CTRL_Donor1,Control,Donor1,/data/counts/CTRL_1/filtered_feature_bc_matrix.h5
CTRL_Donor2,Control,Donor2,/data/counts/CTRL_2.csv.gz
TREAT_Donor1,Treated,Donor3,/data/counts/TREAT_1/
TREAT_Donor2,Treated,Donor4,https://ftp.ncbi.nlm.nih.gov/geo/series/GSE.../counts.txt.gz
```

### Column Definitions
* **`sample_id`**: Unique string identifier for each library/run.
* **`condition`**: Experimental or clinical group (e.g. `Control` vs. `Treated`, `WT` vs. `KO`, `Healthy` vs. `Disease`).
* **`patient_id`**: Biological donor or replicate identifier used by Stage 05 for multi-donor pseudo-bulk aggregation.
* **`file_path`**: Absolute path, relative path, or remote URL pointing to the count matrix.

---

## Supported File Types

1. **10x Chromium Outs Directory:**
   ```text
   data/sample1/outs/filtered_feature_bc_matrix/
   ├── barcodes.tsv.gz
   ├── features.tsv.gz
   └── matrix.mtx.gz
   ```
2. **10x HDF5 File (`.h5`):**
   ```text
   data/sample1/filtered_feature_bc_matrix.h5
   ```
3. **Compressed Count Matrix (`.csv.gz`, `.txt.gz`, `.tsv.gz`):**
   * Row names must be gene symbols (e.g. `CD3D`, `MS4A1`).
   * Column names must be cell barcodes.
4. **Serialized R Seurat Object (`.rds`):**
   * Direct ingestion of pre-filtered Seurat objects.
