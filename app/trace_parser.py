import os
import csv
from pathlib import Path
from typing import Dict, Any, List, Optional

# Match process names in main.nf to stage codes
PROCESS_MAP = {
    "QC_FILTERING": "01",
    "QC_TOOL_COMPARE": "02",
    "INTEGRATION_CLUSTERING": "03",
    "CELL_ANNOTATION": "04",
    "DIFFERENTIAL_EXPRESSION": "05",
    "OBJECT_CONVERSION": "06",
    "TRAJECTORY_MONOCLE3": "07",
    "TRAJECTORY_SLINGSHOT": "08",
    "CELLCHAT_COMMUNICATION": "09",
    "NICHENET_COMMUNICATION": "10",
    "COPYKAT_CNV": "11",
    "HDWGCNA_NETWORKS": "12",
    "VELOCITY_EXPORT": "13",
    "PUBLICATION_FIGURES": "14"
}

def parse_trace_file(trace_path: Path) -> Dict[str, Dict[str, Any]]:
    """
    Parses Nextflow trace.txt (tab-delimited) into per-stage execution metadata.
    Returns: { "01": { "status": "COMPLETED"|"CACHED"|"FAILED", "duration": "...", ... } }
    """
    results = {}
    if not trace_path.exists() or trace_path.stat().st_size == 0:
        return results

    try:
        with open(trace_path, "r", encoding="utf-8", errors="replace") as f:
            reader = csv.DictReader(f, delimiter="\t")
            for row in reader:
                process_name = row.get("process") or row.get("name") or ""
                # Strip process tags or brackets e.g. "QC_FILTERING (QC_Filtering)" -> "QC_FILTERING"
                clean_name = process_name.split()[0].split(":")[-1].strip()

                code = PROCESS_MAP.get(clean_name)
                if not code:
                    # Try partial match
                    for p_name, p_code in PROCESS_MAP.items():
                        if p_name in clean_name or clean_name in p_name:
                            code = p_code
                            clean_name = p_name
                            break

                if not code:
                    continue

                raw_status = (row.get("status") or "").strip().upper()
                status = "COMPLETED"
                if raw_status == "CACHED":
                    status = "CACHED"
                elif raw_status in ["FAILED", "ABORTED", "ERROR"]:
                    status = "FAILED"
                elif raw_status in ["SUBMITTED", "RUNNING"]:
                    status = "RUNNING"

                exit_code = row.get("exit")
                workdir = row.get("workdir") or row.get("native_id")

                # If failed, attempt to read last lines of command log in workdir
                error_log = None
                if status == "FAILED" and workdir:
                    w_path = Path(workdir)
                    for log_candidate in [w_path / ".command.err", w_path / ".command.log"]:
                        if log_candidate.exists():
                            try:
                                with open(log_candidate, "r", errors="replace") as lf:
                                    lines = lf.readlines()
                                    error_log = "".join(lines[-20:])
                                break
                            except Exception:
                                pass

                results[code] = {
                    "code": code,
                    "process": clean_name,
                    "status": status,
                    "exit_code": int(exit_code) if exit_code and exit_code.isdigit() else exit_code,
                    "duration": row.get("realtime") or row.get("duration") or "-",
                    "cpu_pct": row.get("%cpu") or "-",
                    "peak_rss": row.get("peak_rss") or row.get("memory") or "-",
                    "workdir": workdir,
                    "error_log": error_log
                }
    except Exception as e:
        print(f"Error parsing trace file {trace_path}: {e}")

    return results

def handle_weblog_event(event_data: Dict[str, Any], stages_file: Path):
    """
    Handles Nextflow weblog POST payload and updates stages.json incrementally.
    """
    event = event_data.get("event")
    trace = event_data.get("trace") or {}

    process_name = trace.get("process") or ""
    clean_name = process_name.split()[0].split(":")[-1].strip()
    code = PROCESS_MAP.get(clean_name)
    if not code:
        return

    raw_status = (trace.get("status") or "").strip().upper()
    status = "RUNNING"
    if event == "process_completed":
        if raw_status == "CACHED":
            status = "CACHED"
        elif trace.get("exit") == 0:
            status = "COMPLETED"
        else:
            status = "FAILED"

    # Update stages_file
    import json
    data = {}
    if stages_file.exists():
        try:
            with open(stages_file, "r") as f:
                data = json.load(f)
        except Exception:
            pass

    data[code] = {
        "code": code,
        "process": clean_name,
        "status": status,
        "exit_code": trace.get("exit"),
        "duration": trace.get("realtime") or "-",
        "cpu_pct": trace.get("%cpu") or "-",
        "peak_rss": trace.get("peak_rss") or "-",
        "workdir": trace.get("workdir")
    }

    with open(stages_file, "w") as f:
        json.dump(data, f, indent=2)
