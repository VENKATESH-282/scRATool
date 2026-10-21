import os
import csv
import json
from pathlib import Path
from typing import Optional, Dict, Any, List
from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel

from ..config import PIPELINE_DIR, DEFAULT_RESULTS_DIR, RUNS_DIR, SESSIONS_DIR
from ..db import get_run, list_runs

router = APIRouter(prefix="/api/explorer", tags=["explorer"])

# Workspace root for single-cell project data
WORKSPACE_ROOT = DEFAULT_RESULTS_DIR

STAGE_DIRECTORIES = [
    {"code": "01", "id": "01_qc", "name": "Stage 1: Quality Control & Filtering"},
    {"code": "02", "id": "02_qc_tool_compare", "name": "Stage 2: QC Tool Comparison"},
    {"code": "03", "id": "03_integration", "name": "Stage 3: Integration & Clustering"},
    {"code": "04", "id": "04_cell_annotation", "name": "Stage 4: Cell Type Annotation"},
    {"code": "05", "id": "05_differential_expression", "name": "Stage 5: Differential Expression & Scoring"},
    {"code": "06", "id": "06_object_structures", "name": "Stage 6: Cross-Platform Object Structures"},
    {"code": "07", "id": "07_trajectory_monocle3", "name": "Stage 7: Monocle 3 Trajectory"},
    {"code": "08", "id": "08_trajectory_slingshot", "name": "Stage 8: Slingshot Lineage Inference"},
    {"code": "09", "id": "09_cellchat", "name": "Stage 9: CellChat Communication"},
    {"code": "10", "id": "10_nichenet", "name": "Stage 10: NicheNet Signaling & Targets"},
    {"code": "11", "id": "11_copykat", "name": "Stage 11: CopyKAT Aneuploidy / CNV"},
    {"code": "12", "id": "12_hdwgcna", "name": "Stage 12: hdWGCNA Co-expression Networks"},
    {"code": "13", "id": "13_velocity_inputs", "name": "Stage 13: RNA Velocity Input Vectors"},
    {"code": "14", "id": "14_publication_figures", "name": "Stage 14: Publication Multi-Panel Figures"},
    {"code": "info", "id": "pipeline_info", "name": "Pipeline Execution & Provenance"}
]

def sync_remote_results_assets(run_id: str, record: Dict[str, Any]):
    """Sync lightweight plots, tables, manifest, and UMAP CSV (25MB) from remote cluster."""
    from ..remote.ssh_manager import SSHManager
    from ..remote.file_manager import RemoteFileManager
    from ..db import get_cluster_profile
    import tarfile

    local_dest = RUNS_DIR / run_id / "results"
    local_dest.mkdir(parents=True, exist_ok=True)
    local_tar = RUNS_DIR / run_id / "results_assets.tar.gz"

    prof = None
    if record.get("cluster_profile_id"):
        prof = get_cluster_profile(record["cluster_profile_id"])
    if not prof and record.get("remote_host"):
        from ..db import get_connection
        conn = get_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM cluster_profiles WHERE host = ?", (record["remote_host"],))
        row = cursor.fetchone()
        conn.close()
        if row:
            prof = dict(row)

    if not prof:
        return False

    remote_dir = record.get("remote_dir") or record.get("outdir", "").replace("/results", "")
    if not remote_dir:
        return False

    with SSHManager(
        host=prof["host"], user=prof["user"], port=prof["port"],
        auth_method=prof["auth_method"], password=prof.get("password"),
        private_key_path=prof.get("private_key_path")
    ) as ssh:
        ssh.execute_command(f"""
            find {remote_dir}/work -name "real_umap_data.csv" -exec cp -u {{}} {remote_dir}/results/06_object_structures/ \\; 2>/dev/null
            find {remote_dir}/work -name "real_umap_data.csv" -exec cp -u {{}} {remote_dir}/results/ \\; 2>/dev/null
            cd {remote_dir}/results && tar --exclude='*.rds' --exclude='*.h5' --exclude='*.txt.gz' -czf /tmp/assets_{run_id}.tar.gz .
        """)
        fm = RemoteFileManager(ssh)
        fm.download_file(f"/tmp/assets_{run_id}.tar.gz", str(local_tar))
        with tarfile.open(local_tar, "r:gz") as tar:
            tar.extractall(path=local_dest)
        local_tar.unlink()
        ssh.execute_command(f"rm -f /tmp/assets_{run_id}.tar.gz")
    return True

def resolve_results_dir(run_id: Optional[str] = None, token: Optional[str] = None) -> Path:
    if run_id:
        if run_id == "run_production_real":
            if DEFAULT_RESULTS_DIR.exists():
                return DEFAULT_RESULTS_DIR
            return WORKSPACE_ROOT
        
        # 1. First check local run results in RUNS_DIR
        local_run_res = RUNS_DIR / run_id / "results"
        if local_run_res.exists() and any(local_run_res.iterdir()):
            return local_run_res
        
        # 2. Check run record in DB
        record = get_run(run_id)
        if record:
            if record.get("outdir"):
                p = Path(record["outdir"])
                if p.exists() and any(p.iterdir()):
                    return p

    # If active session has local results
    if token:
        try:
            from ..session_manager import get_session_dir
            s_res = get_session_dir(token) / "results"
            if s_res.exists() and any(s_res.iterdir()):
                return s_res
        except Exception:
            pass

    # Check most recent run
    runs = list_runs(5, session_token=token)
    for r in runs:
        r_id = r.get("id")
        if r_id and r_id != "run_production_real":
            loc = RUNS_DIR / r_id / "results"
            if loc.exists() and any(loc.iterdir()):
                return loc
        if r.get("outdir"):
            p = Path(r["outdir"])
            if p.exists() and any(p.iterdir()):
                return p

    if DEFAULT_RESULTS_DIR.exists():
        return DEFAULT_RESULTS_DIR
    return WORKSPACE_ROOT

@router.get("/available_runs")
def get_available_runs(token: Optional[str] = None):
    """
    Returns available runs / datasets that can be inspected in Results Explorer.
    User's latest completed runs are listed first.
    """
    runs = list_runs(20, session_token=token)
    items = []
    has_prod = False
    for r in runs:
        if r["id"] == "run_production_real":
            has_prod = True
            continue
        items.append({
            "id": r["id"],
            "name": r["name"],
            "status": r["status"],
            "duration": r.get("duration", "N/A"),
            "created_at": r.get("created_at", "")
        })
    # Add production reference template at the end
    items.append({
        "id": "run_production_real",
        "name": "Reference Dataset: FSHD Muscle Study (6,688 cells)",
        "status": "COMPLETED",
        "duration": "1h 42m 18s",
        "created_at": "2026-09-28 11:15:00"
    })
    return {"runs": items}

@router.get("/stages")
def get_stages(run_id: Optional[str] = None, token: Optional[str] = None):
    res_dir = resolve_results_dir(run_id, token)
    stages = []

    for s in STAGE_DIRECTORIES:
        s_path = res_dir / s["id"]
        file_count = 0
        plots = []
        tables = []
        objects = []

        if s_path.exists():
            for root_dir, _, filenames in os.walk(s_path, followlinks=True):
                for fname in filenames:
                    f = Path(root_dir) / fname
                    if f.is_file():
                        file_count += 1
                        try:
                            rel = str(f.relative_to(res_dir))
                        except Exception:
                            rel = f.name
                        ext = f.suffix.lower()
                        sz = f.stat().st_size
                        if ext in [".png", ".pdf", ".svg", ".jpg"]:
                            plots.append({"name": f.name, "path": rel, "size": sz})
                        elif ext in [".csv", ".tsv", ".txt"]:
                            tables.append({"name": f.name, "path": rel, "size": sz})
                        elif ext in [".rds", ".h5ad", ".loom"]:
                            objects.append({"name": f.name, "path": rel, "size": sz})

        # Sort plots & tables alphabetically for predictable display
        plots.sort(key=lambda x: x["name"])
        tables.sort(key=lambda x: x["name"])
        objects.sort(key=lambda x: x["name"])

        stages.append({
            "code": s["code"],
            "id": s["id"],
            "name": s["name"],
            "available": s_path.exists() and file_count > 0,
            "total_files": file_count,
            "plots": plots,
            "tables": tables,
            "objects": objects
        })

    is_rem = False
    target_r_id = run_id
    if not target_r_id:
        runs = list_runs(5, session_token=token)
        for r in runs:
            if r.get("id") and r.get("id") != "run_production_real":
                target_r_id = r.get("id")
                break
    if target_r_id:
        from ..db import get_run
        record = get_run(target_r_id)
        if record and record.get("is_remote"):
            is_rem = True

    return {"results_dir": str(res_dir), "stages": stages, "is_remote": is_rem}

@router.get("/manifest")
def get_manifest(run_id: Optional[str] = None, token: Optional[str] = None):
    res_dir = resolve_results_dir(run_id, token)
    manifest_file = res_dir / "pipeline_info" / "results_manifest.json"
    if manifest_file.exists():
        try:
            with open(manifest_file, "r") as f:
                return json.load(f)
        except Exception:
            pass

    # Fallback: scan dynamically using followlinks
    files = []
    if res_dir.exists():
        for root_dir, _, filenames in os.walk(res_dir, followlinks=True):
            if "pipeline_info" in Path(root_dir).parts:
                continue
            for fname in filenames:
                f = Path(root_dir) / fname
                if f.is_file():
                    ext = f.suffix.lower()
                    cat = "other"
                    if ext in [".png", ".pdf", ".svg", ".jpg"]: cat = "plots"
                    elif ext in [".csv", ".tsv", ".txt"]: cat = "tables"
                    elif ext in [".rds", ".h5ad", ".loom"]: cat = "objects"
                    elif ext in [".html", ".json"]: cat = "reports"

                    try:
                        rel = str(f.relative_to(res_dir))
                    except Exception:
                        rel = f.name

                    files.append({
                        "relative_path": rel,
                        "file_name": f.name,
                        "category": cat,
                        "size_bytes": f.stat().st_size,
                        "last_modified": int(f.stat().st_mtime * 1000)
                    })

    return {
        "generated_at": None,
        "total_files": len(files),
        "files": files
    }

@router.get("/provenance")
def get_provenance(run_id: Optional[str] = None, token: Optional[str] = None):
    res_dir = resolve_results_dir(run_id, token)
    prov_file = res_dir / "pipeline_info" / "provenance.json"
    if prov_file.exists():
        try:
            with open(prov_file, "r") as f:
                return json.load(f)
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))
    return {"message": "provenance.json not found for this run"}

def _is_allowed_path(target: Path, res_dir: Path) -> bool:
    allowed_prefixes = [
        str(res_dir.resolve()),
        str(RUNS_DIR.resolve()),
        str(SESSIONS_DIR.resolve()),
        str(DEFAULT_RESULTS_DIR.resolve()),
        str(PIPELINE_DIR.resolve()),
        str(WORKSPACE_ROOT)
    ]
    target_str = str(target.resolve())
    return any(target_str.startswith(pfx) for pfx in allowed_prefixes)

@router.get("/file")
def get_result_file(path: str, run_id: Optional[str] = None, token: Optional[str] = None):
    res_dir = resolve_results_dir(run_id, token)
    target = (res_dir / path).resolve()
    if not _is_allowed_path(target, res_dir):
        raise HTTPException(status_code=403, detail="Access denied to requested path")
    if not target.exists() or not target.is_file():
        raise HTTPException(status_code=404, detail="File not found")

    media_type = "application/octet-stream"
    if target.suffix.lower() == ".png": media_type = "image/png"
    elif target.suffix.lower() == ".svg": media_type = "image/svg+xml"
    elif target.suffix.lower() == ".pdf": media_type = "application/pdf"
    elif target.suffix.lower() in [".csv", ".tsv"]: media_type = "text/csv"
    elif target.suffix.lower() in [".json"]: media_type = "application/json"

    return FileResponse(target, media_type=media_type, filename=target.name)

@router.get("/table")
def get_table_data(
    path: str,
    run_id: Optional[str] = None,
    token: Optional[str] = None,
    page: int = Query(1, ge=1),
    page_size: int = Query(25, ge=1, le=500),
    search: Optional[str] = None
):
    res_dir = resolve_results_dir(run_id, token)
    target = (res_dir / path).resolve()
    if not _is_allowed_path(target, res_dir):
        raise HTTPException(status_code=403, detail="Access denied")
    if not target.exists() or not target.is_file():
        raise HTTPException(status_code=404, detail="Table file not found")

    rows = []
    headers = []
    try:
        with open(target, "r", encoding="utf-8", errors="replace") as f:
            reader = csv.reader(f)
            headers = next(reader, [])
            for r in reader:
                if search:
                    if any(search.lower() in str(val).lower() for val in r):
                        rows.append(r)
                else:
                    rows.append(r)

        total_rows = len(rows)
        start_idx = (page - 1) * page_size
        end_idx = start_idx + page_size
        paginated_rows = rows[start_idx:end_idx]

        return {
            "file": target.name,
            "headers": headers,
            "total_rows": total_rows,
            "page": page,
            "page_size": page_size,
            "total_pages": (total_rows + page_size - 1) // page_size if total_rows > 0 else 1,
            "rows": paginated_rows
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to read table: {str(e)}")

@router.get("/umap_data")
def get_umap_data(run_id: Optional[str] = None, token: Optional[str] = None):
    """
    Returns authentic UMAP embedding coordinates and metadata for 6,688 cells
    derived from Seurat 5 Harmony integration of FSHD myogenic differentiation single-cell RNA-seq.
    Supports client-side Plotly rendering with lasso selection, categorical coloring, and continuous scoring.
    """
    res_dir = resolve_results_dir(run_id, token)
    gui_dir = Path(__file__).resolve().parent.parent.parent

    # Candidate locations for the unified single cell UMAP export
    unified_candidates = [
        res_dir / "real_umap_data.csv",
        res_dir / "13_velocity_inputs" / "real_umap_data.csv",
        res_dir / "04_cell_annotation" / "real_umap_data.csv",
        res_dir / "06_object_structures" / "real_umap_data.csv",
        res_dir / "06_object_conversion" / "real_umap_data.csv",
        res_dir / "06_object_sce_se" / "real_umap_data.csv",

        gui_dir / "assets" / "real_umap" / "real_umap_data.csv",
        DEFAULT_RESULTS_DIR / "real_umap_data.csv",
        DEFAULT_RESULTS_DIR / "13_velocity_inputs" / "real_umap_data.csv",
        DEFAULT_RESULTS_DIR / "real_umap_data.csv"
    ]

    for cand in unified_candidates:
        if cand.exists() and cand.is_file() and cand.stat().st_size > 1000:
            try:
                points = []
                with open(cand, "r", encoding="utf-8", errors="replace") as f:
                    reader = csv.DictReader(f)
                    for r in reader:
                        cid = r.get("cell_id", "")
                        x_val = float(r.get("UMAP_1") or r.get("umap_1") or 0.0)
                        y_val = float(r.get("UMAP_2") or r.get("umap_2") or 0.0)
                        cell_type = r.get("cell_type", "Unknown")
                        cond = r.get("condition", "Unknown")
                        samp = r.get("sample_id", "Unknown")
                        raw_clust = str(r.get("cluster", "0")).replace("Cluster_", "").replace("Cluster ", "")
                        dux4 = float(r.get("Custom_Panel_Score") or r.get("custom_panel_score") or r.get("custom_score") or r.get("dux4_score", 0.0) or 0.0)
                        myo = float(r.get("Myogenesis_Score") or r.get("myogenesis_score", 0.0) or 0.0)
                        affected = r.get("custom_biomarker_affected") or r.get("dux4_affected", "FALSE")

                        points.append({
                            "id": cid,
                            "x": round(x_val, 4),
                            "y": round(y_val, 4),
                            "cell_type": cell_type,
                            "condition": cond,
                            "sample_id": samp,
                            "cluster": f"Cluster {raw_clust}",
                            "dux4_score": round(dux4, 4),
                            "myogenesis_score": round(myo, 4),
                            "dux4_affected": str(affected).upper() == "TRUE",
                            "custom_panel_score": round(dux4, 4),
                            "custom_biomarker_affected": str(affected).upper() == "TRUE"
                        })

                if points:
                    cell_types = sorted(list(set(p["cell_type"] for p in points)))
                    conditions = sorted(list(set(p["condition"] for p in points)))
                    samples = sorted(list(set(p["sample_id"] for p in points)))
                    clusters = sorted(
                        list(set(p["cluster"] for p in points)),
                        key=lambda c: int(c.split()[1]) if len(c.split()) > 1 and c.split()[1].isdigit() else 99
                    )

                    return {
                        "points": points,
                        "source": "real_production_seurat_dataset",
                        "total_cells": len(points),
                        "metadata_categories": {
                            "cell_type": cell_types,
                            "condition": conditions,
                            "sample_id": samples,
                            "cluster": clusters
                        }
                    }
            except Exception as e:
                print(f"Error reading unified real UMAP data: {e}")

    # Fallback to paired velocity inputs
    meta_candidates = [
        res_dir / "13_velocity_inputs" / "seurat_metadata.csv",
        DEFAULT_RESULTS_DIR / "13_velocity_inputs" / "seurat_metadata.csv"
    ]
    emb_candidates = [
        res_dir / "13_velocity_inputs" / "seurat_umap.csv",
        DEFAULT_RESULTS_DIR / "13_velocity_inputs" / "seurat_umap.csv"
    ]
    vel_meta = next((p for p in meta_candidates if p.exists()), None)
    vel_emb = next((p for p in emb_candidates if p.exists()), None)

    if vel_meta and vel_emb:
        try:
            points = []
            with open(vel_meta, "r", encoding="utf-8", errors="replace") as f_meta, \
                 open(vel_emb, "r", encoding="utf-8", errors="replace") as f_emb:
                r_meta = csv.DictReader(f_meta)
                r_emb = csv.DictReader(f_emb)
                for m_row, e_row in zip(r_meta, r_emb):
                    cell_id = m_row.get("seurat_barcode") or m_row.get("cell_id") or ""
                    x_val = float(e_row.get("UMAP_1") or e_row.get("umap_1") or 0.0)
                    y_val = float(e_row.get("UMAP_2") or e_row.get("umap_2") or 0.0)
                    cell_type = m_row.get("final_annotation") or m_row.get("cell_type") or "Unknown"
                    points.append({
                        "id": cell_id,
                        "x": round(x_val, 4),
                        "y": round(y_val, 4),
                        "cell_type": cell_type,
                        "condition": m_row.get("condition", "Unknown"),
                        "sample_id": m_row.get("sample_id", "Unknown"),
                        "cluster": f"Cluster {m_row.get('seurat_clusters', '0')}",
                        "dux4_score": 0.0,
                        "myogenesis_score": 0.0,
                        "dux4_affected": False
                    })
            if points:
                return {
                    "points": points,
                    "source": "velocity_embeddings",
                    "total_cells": len(points),
                    "metadata_categories": {
                        "cell_type": sorted(list(set(p["cell_type"] for p in points))),
                        "condition": sorted(list(set(p["condition"] for p in points))),
                        "sample_id": sorted(list(set(p["sample_id"] for p in points))),
                        "cluster": sorted(list(set(p["cluster"] for p in points)))
                    }
                }
        except Exception as e:
            print(f"Error parsing velocity files: {e}")

    # Fallback to simulated cluster model if no real files found
    return {"points": [], "source": "none", "total_cells": 0, "metadata_categories": {}}

class LassoGroupRequest(BaseModel):
    group_name: str
    cell_ids: List[str]
    description: Optional[str] = ""
    token: Optional[str] = None

@router.post("/lasso_group")
def save_lasso_group(req: LassoGroupRequest):
    if req.token:
        try:
            from ..session_manager import get_session_dir
            out_dir = get_session_dir(req.token) / "exports"
        except Exception:
            out_dir = PIPELINE_DIR / "assets" / "custom_groups"
    else:
        out_dir = PIPELINE_DIR / "assets" / "custom_groups"

    out_dir.mkdir(parents=True, exist_ok=True)
    clean_name = "".join(c if c.isalnum() or c in "-_" else "_" for c in req.group_name)
    file_path = out_dir / f"{clean_name}.csv"

    try:
        with open(file_path, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["cell_id", "group_name", "description"])
            for cid in req.cell_ids:
                writer.writerow([cid, req.group_name, req.description or ""])

        return {
            "message": f"Saved {len(req.cell_ids)} cells to group '{req.group_name}'",
            "file_path": str(file_path),
            "cell_count": len(req.cell_ids)
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


from ..db import get_run, get_connection
import paramiko
import stat

@router.post("/{run_id}/sync_remote")
def sync_remote_results(run_id: str, token: str):
    record = get_run(run_id)
    if not record or not record.get("is_remote"):
        raise HTTPException(status_code=400, detail="Run is not remote")
    
    remote_host = record.get("remote_host")
    outdir = record.get("outdir")
    
    if not outdir:
        raise HTTPException(status_code=400, detail="No remote output directory specified")

    # Get credentials from profile
    conn = get_connection()
    c = conn.cursor()
    c.execute("SELECT * FROM cluster_profiles WHERE host = ?", (remote_host,))
    prof = c.fetchone()
    conn.close()
    
    if not prof:
        raise HTTPException(status_code=400, detail="Cluster profile not found")

    from ..session_manager import get_session_dir
    local_dir = get_session_dir(token) / "results"
    local_dir.mkdir(parents=True, exist_ok=True)
    
    try:
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        
        if prof["auth_method"] == "password":
            ssh.connect(hostname=prof["host"], username=prof["user"], password=prof["password"], port=prof["port"])
        else:
            ssh.connect(hostname=prof["host"], username=prof["user"], key_filename=prof["private_key_path"], port=prof["port"])
            
        sftp = ssh.open_sftp()
        
        def sync_dir(remote_path, local_path):
            os.makedirs(local_path, exist_ok=True)
            try:
                items = sftp.listdir_attr(remote_path)
            except IOError:
                return
            for item in items:
                r_path = remote_path + "/" + item.filename
                l_path = os.path.join(local_path, item.filename)
                
                if stat.S_ISDIR(item.st_mode):
                    sync_dir(r_path, l_path)
                else:
                    if item.filename.endswith(('.png', '.pdf', '.svg', '.csv', '.tsv', '.txt', '.json', '.html')):
                        if not os.path.exists(l_path) or os.path.getsize(l_path) != item.st_size:
                            sftp.get(r_path, l_path)
                        
        sync_dir(outdir, str(local_dir))
        sftp.close()
        ssh.close()
        return {"status": "success", "message": "Synced light results from cluster"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/lasso_groups")
def get_lasso_groups(token: Optional[str] = None):
    if token:
        try:
            from ..session_manager import get_session_dir
            out_dir = get_session_dir(token) / "exports"
        except Exception:
            out_dir = PIPELINE_DIR / "assets" / "custom_groups"
    else:
        out_dir = PIPELINE_DIR / "assets" / "custom_groups"
        
    groups = []
    if out_dir.exists():
        for f in out_dir.glob("*.csv"):
            try:
                with open(f, "r", encoding="utf-8") as file:
                    rows = sum(1 for line in file) - 1
                groups.append({
                    "name": f.stem,
                    "file": f.name,
                    "cells": max(0, rows),
                    "created": int(f.stat().st_mtime * 1000)
                })
            except Exception:
                pass
    return {"groups": sorted(groups, key=lambda x: x["created"], reverse=True)}

@router.get("/lasso_groups/download")
def download_lasso_group(file: str, token: Optional[str] = None):
    if token:
        try:
            from ..session_manager import get_session_dir
            out_dir = get_session_dir(token) / "exports"
        except Exception:
            out_dir = PIPELINE_DIR / "assets" / "custom_groups"
    else:
        out_dir = PIPELINE_DIR / "assets" / "custom_groups"
        
    fpath = out_dir / file
    if not fpath.exists() or not fpath.is_file() or not str(file).endswith(".csv"):
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(fpath, filename=file)
