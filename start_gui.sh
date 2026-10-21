#!/usr/bin/env bash
################################################################################
# scRATool GUI Launcher
# Browser-based Graphical User Interface for scRNA-seq Downstream Analysis
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Detect Conda / Pixi / Python paths dynamically
if [ -d "$HOME/miniconda3/bin" ]; then
    export PATH="$HOME/miniconda3/bin:$PATH"
elif [ -d "$HOME/anaconda3/bin" ]; then
    export PATH="$HOME/anaconda3/bin:$PATH"
fi
export PATH="$HOME/.local/bin:$HOME/.pixi/bin:$PATH"

PORT="${PORT:-8051}"
HOST="${HOST:-0.0.0.0}"

echo "================================================================="
echo "   scRATool GUI - scRNA-seq Downstream Analysis Workbench"
echo "================================================================="
echo " Directory:   ${SCRIPT_DIR}"
echo " Server URL:  http://localhost:${PORT}"
echo " Network URL: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo '127.0.0.1'):${PORT}"
echo " Press Ctrl+C to stop the server."
echo "================================================================="

exec python3 -m uvicorn app.main:app --host "${HOST}" --port "${PORT}"
