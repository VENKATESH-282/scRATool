import os
import shutil
import json
import secrets
from pathlib import Path
from datetime import datetime
from typing import Optional, Dict, Any, List

from .config import (
    GUI_DIR, PIPELINE_DIR, SESSIONS_DIR,
    DEFAULT_SAMPLESHEET, DEFAULT_ANNOTATION, DEFAULT_RESULTS_DIR
)
from .db import (
    create_session_db, get_session_db, list_sessions_db,
    update_session_access, update_session_name, delete_session_db, list_runs
)

# 32 unambiguous characters (no 0, 1, I, L, O)
ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"

def generate_token() -> str:
    raw = "".join(secrets.choice(ALPHABET) for _ in range(16))
    return f"{raw[0:4]}-{raw[4:8]}-{raw[8:12]}-{raw[12:16]}"

def normalize_token(token: str) -> str:
    clean = token.strip().upper().replace("-", "").replace(" ", "")
    if len(clean) != 16 or any(c not in ALPHABET for c in clean):
        raise ValueError("Invalid session token format. Must be 16 characters from unambiguous alphabet (2-9, A-Z without 0, 1, I, L, O).")
    return f"{clean[0:4]}-{clean[4:8]}-{clean[8:12]}-{clean[12:16]}"

def get_session_dir(token: str) -> Path:
    normalized = normalize_token(token)
    return SESSIONS_DIR / normalized

def calculate_dir_size(path: Path) -> int:
    total = 0
    if not path.exists():
        return 0
    for root, _, files in os.walk(path):
        for f in files:
            fp = os.path.join(root, f)
            try:
                total += os.path.getsize(fp)
            except OSError:
                pass
    return total

def format_bytes(size: int) -> str:
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size < 1024.0:
            return f"{size:3.1f} {unit}"
        size /= 1024.0
    return f"{size:.1f} TB"

def get_default_pipeline_params(session_dir: Path) -> Dict[str, Any]:
    samplesheet_path = session_dir / "samples.csv"
    results_path = session_dir / "results"
    models_dir = PIPELINE_DIR / "models"
    
    return {
        "samplesheet": str(samplesheet_path.resolve()),
        "annotation_map": str(DEFAULT_ANNOTATION.resolve()) if DEFAULT_ANNOTATION.exists() else "",
        "models_dir": str(models_dir.resolve()) if models_dir.exists() else "",
        "outdir": str(results_path.resolve()),
        "reference_condition": "CTRL",
        "tissue": "Muscle",
        "target_celltypes": "Satellite cells (quiescent-activating, MYF5-high),Differentiating myocytes (MYOG-MYH3-high)",
        "seed": 42,
        "nfeature_min": 500,
        "nfeature_max": 6000,
        "ncount_min": 800,
        "ncount_max": 50000,
        "mt_thresh": 15,
        "min_pct_cells": 0.1,
        "n_hvg": 2000,
        "qc_npcs": 30,
        "qc_resolution": 0.8,
        "qc_seed": 12345,
        "npcs": 30,
        "resolutions": "0.2,0.4,0.6,0.8,1.0",
        "default_resolution": "auto",
        "marker_min_pct": 0.25,
        "marker_logfc_thresh": 0.25,
        "top_n_markers": 5,
        "sctype_quantile": 0.6,
        "de_test": "wilcox",
        "de_min_pct": 0.1,
        "de_logfc_thresh": 0.25,
        "de_fdr_thresh": 0.05,
        "pb_min_counts": 10,
        "pb_min_samples": 2,
        "trajectory_root_celltype": "auto",
        "slingshot_approx_points": 150,
        "cellchat_min_cells": 10,
        "cellchat_prob_type": "triMean",
        "nichenet_receiver": "auto",
        "nichenet_min_expr_pct": 0.05,
        "nichenet_top_ligands": 20,
        "nichenet_cutoff": 0.25,
        "copykat_genome": "hg20",
        "copykat_ks_cut": 0.1,
        "copykat_min_cells": 200,
        "hdwgcna_k_metacell": 20,
        "hdwgcna_min_cells": 40,
        "hdwgcna_target_metacells": 1000,
        "hdwgcna_min_module_size": 30,
        "hdwgcna_merge_cut_height": 0.25,
        "skip_qc_compare": False,
        "skip_monocle3": False,
        "skip_slingshot": False,
        "skip_cellchat": False,
        "skip_nichenet": False,
        "skip_copykat": False,
        "skip_hdwgcna": False,
        "skip_velocity": False,
        "skip_figures": False
    }

def create_session(name: Optional[str] = None, base_token: Optional[str] = None) -> Dict[str, Any]:
    for _ in range(10):
        tok = generate_token()
        s_dir = SESSIONS_DIR / tok
        if not s_dir.exists() and get_session_db(tok) is None:
            break
    else:
        raise RuntimeError("Failed to generate unique session token.")

    s_dir.mkdir(parents=True, exist_ok=True)
    (s_dir / "runs").mkdir(parents=True, exist_ok=True)
    (s_dir / "results").mkdir(parents=True, exist_ok=True)
    (s_dir / "exports").mkdir(parents=True, exist_ok=True)

    session_samplesheet = s_dir / "samples.csv"
    session_params = s_dir / "params.json"

    if base_token:
        # Clone from base token workspace
        base_dir = get_session_dir(base_token)
        if (base_dir / "samples.csv").exists():
            shutil.copy2(base_dir / "samples.csv", session_samplesheet)
        elif DEFAULT_SAMPLESHEET.exists():
            shutil.copy2(DEFAULT_SAMPLESHEET, session_samplesheet)

        if (base_dir / "params.json").exists():
            try:
                with open(base_dir / "params.json", "r", encoding="utf-8") as f:
                    params_data = json.load(f)
                params_data["samplesheet"] = str(session_samplesheet.resolve())
                params_data["outdir"] = str((s_dir / "results").resolve())
                with open(session_params, "w", encoding="utf-8") as f:
                    json.dump(params_data, f, indent=2)
            except Exception:
                params_data = get_default_pipeline_params(s_dir)
                with open(session_params, "w", encoding="utf-8") as f:
                    json.dump(params_data, f, indent=2)
        else:
            params_data = get_default_pipeline_params(s_dir)
            with open(session_params, "w", encoding="utf-8") as f:
                json.dump(params_data, f, indent=2)
    else:
        # Initialize fresh workspace
        if DEFAULT_SAMPLESHEET.exists():
            shutil.copy2(DEFAULT_SAMPLESHEET, session_samplesheet)
        else:
            with open(session_samplesheet, "w", encoding="utf-8") as f:
                f.write("sample_id,condition,patient_id,file_path\n")

        params_data = get_default_pipeline_params(s_dir)
        with open(session_params, "w", encoding="utf-8") as f:
            json.dump(params_data, f, indent=2)

    now = datetime.now().isoformat()
    session_name = name.strip() if name and name.strip() else f"Workspace {tok[:4]}"

    meta = {
        "token": tok,
        "name": session_name,
        "created_at": now,
        "last_accessed": now,
        "status": "ACTIVE"
    }

    with open(s_dir / "session.json", "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)

    create_session_db(
        token=tok,
        name=session_name,
        created_at=now,
        last_accessed=now,
        status="ACTIVE"
    )

    meta["session_dir"] = str(s_dir)
    meta["disk_usage"] = format_bytes(calculate_dir_size(s_dir))
    return meta

def get_session(token: str, touch: bool = True) -> Optional[Dict[str, Any]]:
    try:
        tok = normalize_token(token)
    except ValueError:
        return None

    s_dir = SESSIONS_DIR / tok
    db_rec = get_session_db(tok)
    
    if not s_dir.exists() and not db_rec:
        return None

    now = datetime.now().isoformat()
    if touch:
        update_session_access(tok, now)

    meta_file = s_dir / "session.json"
    meta = {}
    if meta_file.exists():
        try:
            with open(meta_file, "r", encoding="utf-8") as f:
                meta = json.load(f)
        except Exception:
            pass

    if touch and meta:
        meta["last_accessed"] = now
        try:
            with open(meta_file, "w", encoding="utf-8") as f:
                json.dump(meta, f, indent=2)
        except Exception:
            pass

    name = db_rec["name"] if db_rec else meta.get("name", f"Workspace {tok[:4]}")
    created_at = db_rec["created_at"] if db_rec else meta.get("created_at", now)
    last_accessed = now if touch else (db_rec["last_accessed"] if db_rec else meta.get("last_accessed", now))

    runs = list_runs(50, session_token=tok)

    return {
        "token": tok,
        "name": name,
        "created_at": created_at,
        "last_accessed": last_accessed,
        "status": "ACTIVE",
        "session_dir": str(s_dir),
        "samplesheet_exists": (s_dir / "samples.csv").exists(),
        "params_exists": (s_dir / "params.json").exists(),
        "runs_count": len(runs),
        "disk_usage": format_bytes(calculate_dir_size(s_dir))
    }

def list_sessions() -> List[Dict[str, Any]]:
    db_sessions = list_sessions_db()
    results = []
    seen = set()

    for s in db_sessions:
        tok = s["token"]
        seen.add(tok)
        s_dir = SESSIONS_DIR / tok
        results.append({
            "token": tok,
            "name": s["name"],
            "created_at": s["created_at"],
            "last_accessed": s["last_accessed"],
            "status": s["status"],
            "exists_on_disk": s_dir.exists(),
            "disk_usage": format_bytes(calculate_dir_size(s_dir)) if s_dir.exists() else "0 B"
        })

    # Also discover any session folder in SESSIONS_DIR not yet in DB
    if SESSIONS_DIR.exists():
        for item in SESSIONS_DIR.iterdir():
            if item.is_dir() and item.name not in seen:
                try:
                    tok = normalize_token(item.name)
                    meta_file = item / "session.json"
                    name = f"Workspace {tok[:4]}"
                    created_at = datetime.now().isoformat()
                    last_accessed = created_at
                    if meta_file.exists():
                        try:
                            with open(meta_file, "r") as f:
                                m = json.load(f)
                                name = m.get("name", name)
                                created_at = m.get("created_at", created_at)
                                last_accessed = m.get("last_accessed", last_accessed)
                        except Exception:
                            pass
                    create_session_db(tok, name, created_at, last_accessed, "ACTIVE")
                    results.append({
                        "token": tok,
                        "name": name,
                        "created_at": created_at,
                        "last_accessed": last_accessed,
                        "status": "ACTIVE",
                        "exists_on_disk": True,
                        "disk_usage": format_bytes(calculate_dir_size(item))
                    })
                except Exception:
                    continue

    results.sort(key=lambda x: x.get("last_accessed", ""), reverse=True)
    return results

def get_or_create_default_session() -> Dict[str, Any]:
    sessions = list_sessions()
    if sessions:
        sess = get_session(sessions[0]["token"], touch=True)
        if sess:
            return sess
    return create_session(name="Primary Analysis Workspace")

def rename_session(token: str, new_name: str) -> Optional[Dict[str, Any]]:
    tok = normalize_token(token)
    s_dir = SESSIONS_DIR / tok
    update_session_name(tok, new_name)
    meta_file = s_dir / "session.json"
    if meta_file.exists():
        try:
            with open(meta_file, "r", encoding="utf-8") as f:
                meta = json.load(f)
            meta["name"] = new_name
            with open(meta_file, "w", encoding="utf-8") as f:
                json.dump(meta, f, indent=2)
        except Exception:
            pass
    return get_session(tok, touch=False)

def duplicate_session(token: str, new_name: Optional[str] = None) -> Dict[str, Any]:
    base_sess = get_session(token, touch=False)
    name = new_name or (f"{base_sess['name']} (Copy)" if base_sess else "Cloned Workspace")
    return create_session(name=name, base_token=token)

def delete_session(token: str) -> bool:
    try:
        tok = normalize_token(token)
    except ValueError:
        return False
    s_dir = SESSIONS_DIR / tok
    if s_dir.exists():
        shutil.rmtree(s_dir, ignore_errors=True)
    delete_session_db(tok)
    return True
