#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────
# scRATool Platform - Startup Script
# Default Port: 8051 (override via PLATFORM_PORT environment variable)
# ────────────────────────────────────────────────────────────────────
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PORT=${PLATFORM_PORT:-8051}
HOST=${PLATFORM_HOST:-0.0.0.0}

if [ -z "${PYTHON_BIN:-}" ]; then
    if command -v python3 &>/dev/null; then
        PYTHON="$(command -v python3)"
    elif [ -x "$HOME/miniconda3/bin/python3" ]; then
        PYTHON="$HOME/miniconda3/bin/python3"
    elif [ -x "$HOME/anaconda3/bin/python3" ]; then
        PYTHON="$HOME/anaconda3/bin/python3"
    else
        PYTHON="python3"
    fi
else
    PYTHON="$PYTHON_BIN"
fi

echo "============================================================"
echo " scRATool - Universal Single-Cell RNA-seq Analysis Platform"
echo " Local URL:    http://localhost:$PORT"
echo " Network URL:  http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo '127.0.0.1'):$PORT"
echo " Press Ctrl+C to stop the server."
echo "============================================================"

exec "$PYTHON" -m uvicorn app.main:app --host "$HOST" --port "$PORT" --reload
