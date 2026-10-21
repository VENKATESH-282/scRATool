"""
Pipeline runner for the General-Purpose scRNA-seq Platform.
Launches and monitors Nextflow DSL2 pipelines per project.
"""
import json
import os
import subprocess
import threading
import uuid
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Optional

from .config import NEXTFLOW_BIN, PLATFORM_DIR
from .db import create_run, update_run_status, get_run
from .project_manager import get_project_dir, full_project_info

PIPELINE_NF = PLATFORM_DIR / "pipeline" / "main.nf"

# In-memory tracking of active processes
_active_processes: Dict[str, subprocess.Popen] = {}


def _run_id() -> str:
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    uid = uuid.uuid4().hex[:6].upper()
    return f"RUN-{ts}-{uid}"


def launch_pipeline(project_id: str, run_name: str = "") -> Dict[str, Any]:
    """
    Launch the generalized scRNA-seq Nextflow pipeline for a project.
    Returns run record.
    """
    proj = full_project_info(project_id)
    if not proj:
        raise ValueError(f"Project not found: {project_id}")

    proj_dir = get_project_dir(project_id)
    run_id = _run_id()
    run_dir = proj_dir / "logs" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    params = proj.get("params", {})
    params_file = run_dir / "params.json"
    params["outdir"] = str(proj_dir / "results")
    params["input_path"] = params.get("input_path", proj.get("input_path", ""))
    with open(params_file, "w") as f:
        json.dump(params, f, indent=2)

    log_file = run_dir / "run.log"
    import json as _json
    params_snapshot = _json.dumps(params)

    create_run(
        run_id=run_id,
        project_id=project_id,
        name=run_name or f"Run {datetime.now().strftime('%Y-%m-%d %H:%M')}",
        pipeline_dir=str(proj_dir),
        params_snapshot=params_snapshot
    )

    if not PIPELINE_NF.exists():
        # No Nextflow pipeline installed yet - record as SKIPPED
        update_run_status(run_id, "ERROR")
        _write_log(log_file, (
            f"[{datetime.now().isoformat()}] ERROR: Pipeline not found at {PIPELINE_NF}\n"
            f"Please install the Nextflow pipeline or run analysis scripts directly.\n"
        ))
        return get_run(run_id)

    cmd = [
        NEXTFLOW_BIN, "run", str(PIPELINE_NF),
        "-params-file", str(params_file),
        "-work-dir", str(run_dir / "work"),
        "-with-trace", str(run_dir / "trace.txt"),
        "-with-report", str(run_dir / "report.html"),
        "-ansi-log", "false"
    ]

    _write_log(log_file, f"[{datetime.now().isoformat()}] Launching pipeline...\n")
    _write_log(log_file, f"Command: {' '.join(cmd)}\n")

    def _run_in_thread():
        try:
            update_run_status(run_id, "RUNNING")
            proc = subprocess.Popen(
                cmd,
                stdout=open(log_file, 'a'),
                stderr=subprocess.STDOUT,
                cwd=str(proj_dir),
                env=os.environ.copy()
            )
            _active_processes[run_id] = proc
            exit_code = proc.wait()
            _active_processes.pop(run_id, None)
            status = "COMPLETED" if exit_code == 0 else "FAILED"
            update_run_status(run_id, status, exit_code)
        except Exception as e:
            _write_log(log_file, f"\n[ERROR] {e}\n")
            update_run_status(run_id, "FAILED")

    t = threading.Thread(target=_run_in_thread, daemon=True)
    t.start()

    return get_run(run_id)


def get_run_log(run_id: str) -> str:
    """Read the log for a run."""
    run = get_run(run_id)
    if not run:
        return ""
    proj_dir = Path(run["pipeline_dir"])
    log_file = proj_dir / "logs" / run_id / "run.log"
    if log_file.exists():
        try:
            return log_file.read_text(encoding='utf-8', errors='replace')[-50000:]
        except Exception:
            return ""
    return ""


def abort_run(run_id: str) -> bool:
    proc = _active_processes.get(run_id)
    if proc and proc.poll() is None:
        proc.terminate()
        update_run_status(run_id, "ABORTED")
        return True
    return False


def _write_log(log_file: Path, text: str):
    try:
        with open(log_file, 'a', encoding='utf-8') as f:
            f.write(text)
    except Exception:
        pass
