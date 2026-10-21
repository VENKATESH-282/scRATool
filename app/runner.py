import os
import sys
import time
import json
import signal
import subprocess
import threading
from pathlib import Path
from datetime import datetime
from typing import Dict, Any, Optional

from .config import PIPELINE_DIR, RUNS_DIR, NEXTFLOW_BIN
from .db import create_run, update_run, get_run

# Global active subprocesses map
_ACTIVE_PROCESSES: Dict[str, subprocess.Popen] = {}
_ACTIVE_LOCK = threading.Lock()

ALL_STAGES = [
    {"id": "QC_FILTERING", "name": "Quality Control & Filtering", "code": "01"},
    {"id": "QC_TOOL_COMPARE", "name": "QC Tool Comparison", "code": "02"},
    {"id": "INTEGRATION_CLUSTERING", "name": "Integration & Clustering", "code": "03"},
    {"id": "CELL_ANNOTATION", "name": "Cell Type Annotation", "code": "04"},
    {"id": "DIFFERENTIAL_EXPRESSION", "name": "Differential Expression & Scoring", "code": "05"},
    {"id": "OBJECT_CONVERSION", "name": "Cross-Platform Conversions (SCE/SE)", "code": "06"},
    {"id": "TRAJECTORY_MONOCLE3", "name": "Monocle 3 Trajectory", "code": "07"},
    {"id": "TRAJECTORY_SLINGSHOT", "name": "Slingshot Trajectory", "code": "08"},
    {"id": "CELLCHAT_COMMUNICATION", "name": "CellChat Communication", "code": "09"},
    {"id": "NICHENET_COMMUNICATION", "name": "NicheNet Mechanistic Signaling", "code": "10"},
    {"id": "COPYKAT_CNV", "name": "CopyKAT CNV Inference", "code": "11"},
    {"id": "HDWGCNA_NETWORKS", "name": "hdWGCNA Co-expression Networks", "code": "12"},
    {"id": "VELOCITY_EXPORT", "name": "RNA Velocity Export", "code": "13"},
    {"id": "PUBLICATION_FIGURES", "name": "Publication Figures Synthesis", "code": "14"}
]

def parse_log_line_for_progress(line: str, stages_status: Dict[str, str]):
    for stage in ALL_STAGES:
        sid = stage["id"]
        if sid in line:
            if "✔" in line or "1 of 1" in line:
                stages_status[sid] = "COMPLETED"
            elif "FAILED" in line or "Error" in line:
                stages_status[sid] = "FAILED"
            else:
                stages_status[sid] = "RUNNING"

def run_nextflow_job(run_id: str, name: str, profile: str, resume: bool,
                     stub_run: bool, params: Dict[str, Any],
                     session_token: Optional[str] = None) -> Dict[str, Any]:
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    if session_token:
        try:
            from .session_manager import get_session_dir
            sess_dir = get_session_dir(session_token)
            sess_samples = sess_dir / "samples.csv"
            # If session has custom samplesheet and not running fast stub test on test_data
            if sess_samples.exists() and not (stub_run and "samples_test.csv" in str(params.get("samplesheet", ""))):
                # If samplesheet was default or points to session
                if "samplesheet" not in params or params["samplesheet"] == str(DEFAULT_SAMPLESHEET):
                    params["samplesheet"] = str(sess_samples)

            # Check if session has saved reference_condition in its params.json
            sess_params_file = sess_dir / "params.json"
            if sess_params_file.exists():
                with open(sess_params_file, "r", encoding="utf-8") as spf:
                    sp_data = json.load(spf)
                    if "reference_condition" in sp_data and "reference_condition" not in params:
                        params["reference_condition"] = sp_data["reference_condition"]
        except Exception:
            pass

    params_file = run_dir / "params.json"
    with open(params_file, "w", encoding="utf-8") as f:
        json.dump(params, f, indent=2)

    log_file = run_dir / "run.log"
    stages_file = run_dir / "stages.json"

    # Initialize stages tracking
    stages_status = {s["id"]: "PENDING" for s in ALL_STAGES}
    with open(stages_file, "w") as f:
        json.dump(stages_status, f, indent=2)

    # Output directory
    outdir = params.get("outdir", str(PIPELINE_DIR / "results"))

    # Build command line
    cmd = [
        NEXTFLOW_BIN,
        "run",
        str(PIPELINE_DIR / "main.nf"),
        "-params-file", str(params_file),
        "-profile", profile
    ]
    if resume:
        cmd.append("-resume")
    if stub_run:
        cmd.append("-stub-run")

    command_str = " ".join(cmd)

    # Save to DB
    run_record = create_run(
        run_id=run_id,
        name=name,
        profile=profile,
        resume=resume,
        stub_run=stub_run,
        params=params,
        command=command_str,
        outdir=outdir,
        session_token=session_token
    )

    if session_token:
        try:
            from .session_manager import get_session_dir
            sess_run_dir = get_session_dir(session_token) / "runs" / run_id
            sess_run_dir.mkdir(parents=True, exist_ok=True)
            with open(sess_run_dir / "params.json", "w", encoding="utf-8") as sf:
                json.dump(params, sf, indent=2)
            with open(sess_run_dir / "stages.json", "w") as sf:
                json.dump(stages_status, sf, indent=2)
        except Exception:
            pass

    def worker():
        start_time = time.time()
        env = os.environ.copy()
        user_home = str(Path.home())
        conda_bin = f"{user_home}/miniconda3/bin"
        pipeline_bin = str(PIPELINE_DIR / "bin")
        env["PATH"] = f"{pipeline_bin}:{conda_bin}:{user_home}/anaconda3/bin:{user_home}/.local/bin:{user_home}/.pixi/bin:{env.get('PATH', '')}"

        with open(log_file, "w", encoding="utf-8") as log_f:
            log_f.write(f"=== scRATool Run: {name} (ID: {run_id}) ===\n")
            log_f.write(f"Start Time: {datetime.now().isoformat()}\n")
            log_f.write(f"Command: {command_str}\n")
            log_f.write(f"Directory: {PIPELINE_DIR}\n")
            log_f.write("=" * 60 + "\n\n")
            log_f.flush()

            try:
                proc = subprocess.Popen(
                    cmd,
                    cwd=str(PIPELINE_DIR),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                    env=env,
                    preexec_fn=os.setsid
                )

                with _ACTIVE_LOCK:
                    _ACTIVE_PROCESSES[run_id] = proc

                update_run(run_id, pid=proc.pid)

                for line in proc.stdout:
                    log_f.write(line)
                    log_f.flush()
                    parse_log_line_for_progress(line, stages_status)
                    with open(stages_file, "w") as sf:
                        json.dump(stages_status, sf)

                proc.wait()
                exit_code = proc.returncode

            except Exception as e:
                log_f.write(f"\n[Execution Exception]: {str(e)}\n")
                exit_code = -1
            finally:
                with _ACTIVE_LOCK:
                    _ACTIVE_PROCESSES.pop(run_id, None)

        duration_sec = round(time.time() - start_time, 1)
        duration_str = f"{duration_sec}s" if duration_sec < 60 else f"{round(duration_sec/60, 1)}m"
        final_status = "COMPLETED" if exit_code == 0 else "FAILED"
        now_str = datetime.now().isoformat()

        # Update remaining stages if completed
        if exit_code == 0:
            for s in stages_status:
                if stages_status[s] != "FAILED":
                    stages_status[s] = "COMPLETED"
            with open(stages_file, "w") as sf:
                json.dump(stages_status, sf)

        update_run(
            run_id,
            status=final_status,
            end_time=now_str,
            duration=duration_str,
            exit_code=exit_code
        )

    t = threading.Thread(target=worker, daemon=True)
    t.start()

    return run_record

def cancel_run(run_id: str) -> bool:
    with _ACTIVE_LOCK:
        proc = _ACTIVE_PROCESSES.get(run_id)
        if proc:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                time.sleep(1)
                if proc.poll() is None:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                update_run(
                    run_id,
                    status="CANCELLED",
                    end_time=datetime.now().isoformat(),
                    exit_code=130
                )
                return True
            except Exception as e:
                print(f"Error cancelling run {run_id}: {e}")
                return False
    return False

def get_run_stages(run_id: str) -> Dict[str, Any]:
    stages_file = RUNS_DIR / run_id / "stages.json"
    if stages_file.exists():
        try:
            with open(stages_file, "r") as f:
                statuses = json.load(f)
        except Exception:
            statuses = {}
    else:
        statuses = {}

    return {
        "stages": [
            {
                "id": s["id"],
                "name": s["name"],
                "code": s["code"],
                "status": statuses.get(s["id"], "PENDING")
            }
            for s in ALL_STAGES
        ]
    }
