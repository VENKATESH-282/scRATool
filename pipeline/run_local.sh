#!/usr/bin/env bash
################################################################################
# Script: run_local.sh
# Purpose: Runs the Nextflow pipeline locally with Pixi environment
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "================================================================="
echo " Starting scRNA-seq Downstream Analysis Pipeline (Local Mode)"
echo " Project Directory: ${SCRIPT_DIR}"
echo "================================================================="

# Ensure Pixi and Nextflow are in PATH
export PATH="${SCRIPT_DIR}/bin:$HOME/.local/bin:$HOME/.pixi/bin:$HOME/miniconda3/bin:$PATH"

# Run pipeline with local profile and resume capability
nextflow run main.nf \
    -profile local,pixi \
    -resume \
    "$@"
