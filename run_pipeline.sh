#!/bin/bash

# =============================================================================
# Master scRNA-seq Pipeline Orchestrator
# Tutorial: NGS101 – scRNA-seq Complete Beginner's Guide
# Usage: ./run_pipeline.sh [--step N]
# =============================================================================

# Exit on error
set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
cd "${SCRIPT_DIR}"

echo "========================================================="
echo "   scRNA-seq Automated Pipeline - NGS101 Guide"
echo "========================================================="

# 1. QC & Filtering
echo -e "\n[STEP 1/7] Running QC & Filtering (Part 2)..."
# Rscript part2_qc_filtering.R

# 2. Integration & Clustering
echo -e "\n[STEP 2/7] Running Integration & Clustering (Part 3)..."
# Rscript part3_integration_clustering.R

# 3. Cell Type Annotation
echo -e "\n[STEP 3/7] Running Cell Type Annotation (Part 4)..."
# Rscript part4_cell_annotation.R

# 4. Differential Expression
echo -e "\n[STEP 4/7] Running Differential Expression (Part 5)..."
# Rscript part5_differential_expression.R

# 5. Object Exploration & SCE Conversion
echo -e "\n[STEP 5/7] Running Object Exploration (Part 6)..."
# Rscript part6_object_exploration.R

# 6. Trajectory Analysis
echo -e "\n[STEP 6/7] Running Trajectory Analysis (Part 7)..."
# Rscript part7_trajectory_analysis.R

# 7. PDX Processing (Optional/Conditional)
echo -e "\n[STEP 7/7 (Optional)] Running PDX Processing (Part 8)..."
# Rscript part8_pdx_processing.R

# 8. Cell-Cell Communication
echo -e "\n[STEP 8] Running CellChat (Part 9)..."
# Rscript part9_cellchat.R

# 9. NicheNet Analysis
echo -e "\n[STEP 9] Running NicheNet (Part 10)..."
# Rscript part10_nichenet.R

echo -e "\n========================================================="
echo "   Pipeline Configuration Complete"
echo "   Note: It is recommended to run steps individually on the cluster"
echo "   using Slurm for better resource management."
echo "========================================================="
