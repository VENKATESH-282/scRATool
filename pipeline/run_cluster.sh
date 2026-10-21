#!/usr/bin/env bash
#SBATCH --job-name=scrna_nf_master
#SBATCH --output=scrna_nf_master_%j.log
#SBATCH --error=scrna_nf_master_%j.err
#SBATCH --time=48:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G

################################################################################
# Script: run_cluster.sh
# Purpose: Executes or submits the Nextflow scRNA-seq downstream pipeline
#          on an HPC Slurm cluster using the Pixi environment.
#
# Usage:
#   1. Submit as a background Slurm job (Recommended for full pipeline runs):
#      sbatch run_cluster.sh
#
#   2. Run directly in an interactive cluster shell:
#      bash run_cluster.sh --queue my_partition
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "================================================================="
echo " Starting scRNA-seq Downstream Analysis Pipeline (HPC Cluster)"
echo " Working Directory: ${SCRIPT_DIR}"
echo " Time: $(date)"
echo "================================================================="

# Ensure Pixi and Nextflow are in PATH
export PATH="${SCRIPT_DIR}/bin:$HOME/.local/bin:$HOME/.pixi/bin:$HOME/miniconda3/bin:$PATH"

# Execute Nextflow with Slurm + Pixi profile
# If you need to specify a partition or account:
#   ./run_cluster.sh --queue gpu_or_cpu_partition
nextflow run main.nf \
    -profile slurm,pixi \
    -resume \
    "$@"
