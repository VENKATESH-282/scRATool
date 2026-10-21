"""
FastAPI router for exploring analysis results (plots, tables, UMAP) in the General-Purpose scRNA-seq Platform.
"""
import csv
import json
from pathlib import Path
from typing import Optional, List
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from ..project_manager import get_project_dir, full_project_info

router = APIRouter(prefix="/api/results", tags=["results"])


@router.get("/{project_id}/stages")
def list_result_stages(project_id: str):
    """List all result stage directories for a project."""
    proj = full_project_info(project_id)
    if not proj:
        raise HTTPException(status_code=404, detail="Project not found")
    results_dir = get_project_dir(project_id) / "results"
    if not results_dir.exists():
        return {"stages": []}
    stages = []
    for d in sorted(results_dir.iterdir()):
        if d.is_dir():
            plots = list(d.glob("*.png")) + list(d.glob("*.pdf")) + list(d.glob("*.svg"))
            tables = list(d.glob("*.csv")) + list(d.glob("*.tsv"))
            stages.append({
                "name": d.name,
                "path": str(d),
                "n_plots": len(plots),
                "n_tables": len(tables),
                "plots": [p.name for p in plots],
                "tables": [t.name for t in tables],
            })
    return {"stages": stages}


@router.get("/{project_id}/table")
def read_table(project_id: str, stage: str, filename: str,
               page: int = 1, page_size: int = 100, search: str = ""):
    """Read a paginated CSV/TSV result table."""
    proj_dir = get_project_dir(project_id)
    table_path = proj_dir / "results" / stage / filename
    if not table_path.exists():
        raise HTTPException(status_code=404, detail=f"Table not found: {filename}")
    try:
        sep = '\t' if table_path.suffix in ('.tsv', '.txt') else ','
        rows = []
        with open(table_path, 'r', encoding='utf-8', errors='replace') as f:
            reader = csv.DictReader(f, delimiter=sep)
            headers = reader.fieldnames or []
            for r in reader:
                if search:
                    if not any(search.lower() in str(v).lower() for v in r.values()):
                        continue
                rows.append(dict(r))
        total = len(rows)
        start = (page - 1) * page_size
        end = start + page_size
        return {
            "headers": list(headers),
            "rows": rows[start:end],
            "total_rows": total,
            "page": page,
            "page_size": page_size,
            "total_pages": max(1, (total + page_size - 1) // page_size)
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{project_id}/umap")
def get_umap_data(project_id: str):
    """
    Return UMAP coordinates and cell metadata for interactive plotting.
    Reads from results if available; falls back to a helpful empty response.
    """
    proj_dir = get_project_dir(project_id)
    candidates = [
        proj_dir / "results" / "umap_data.csv",
        proj_dir / "results" / "04_cell_annotation" / "umap_data.csv",
        proj_dir / "results" / "03_clustering" / "umap_data.csv",
    ]
    for cand in candidates:
        if cand.exists() and cand.stat().st_size > 100:
            try:
                points = []
                with open(cand, 'r', encoding='utf-8', errors='replace') as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        pt = {}
                        # Auto-detect coordinate columns
                        for xcol in ['UMAP_1', 'umap_1', 'X_umap_1']:
                            if xcol in row:
                                pt['x'] = float(row[xcol] or 0)
                                break
                        for ycol in ['UMAP_2', 'umap_2', 'X_umap_2']:
                            if ycol in row:
                                pt['y'] = float(row[ycol] or 0)
                                break
                        if 'x' not in pt or 'y' not in pt:
                            continue
                        pt['id'] = row.get('cell_id', row.get('barcode', ''))
                        # All remaining columns become metadata
                        for k, v in row.items():
                            if k not in ('UMAP_1', 'UMAP_2', 'umap_1', 'umap_2',
                                         'X_umap_1', 'X_umap_2', 'cell_id', 'barcode'):
                                pt[k] = v
                        points.append(pt)
                if points:
                    # Auto-detect categorical columns for coloring
                    all_keys = set()
                    for pt in points[:100]:
                        all_keys.update(pt.keys())
                    cat_cols = [k for k in all_keys
                                if k not in ('x', 'y', 'id')
                                and len(set(p.get(k, '') for p in points)) < 500]
                    return {
                        "points": points,
                        "total_cells": len(points),
                        "color_by_options": cat_cols,
                        "source": str(cand)
                    }
            except Exception as e:
                print(f"Error reading UMAP: {e}")
    return {
        "points": [],
        "total_cells": 0,
        "color_by_options": [],
        "source": "none",
        "message": "No UMAP data found. Run the pipeline first."
    }


class SaveGroupRequest(BaseModel):
    project_id: str
    group_name: str
    cell_ids: List[str]
    description: Optional[str] = ""


@router.post("/save_group")
def save_cell_group(req: SaveGroupRequest):
    """Save a lasso-selected cell group to the project's exports folder."""
    proj_dir = get_project_dir(req.project_id)
    exports_dir = proj_dir / "exports"
    exports_dir.mkdir(parents=True, exist_ok=True)
    clean_name = "".join(c if c.isalnum() or c in '-_' else '_' for c in req.group_name)
    out_file = exports_dir / f"{clean_name}.csv"
    try:
        with open(out_file, 'w', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            writer.writerow(['cell_id', 'group_name', 'description'])
            for cid in req.cell_ids:
                writer.writerow([cid, req.group_name, req.description or ''])
        return {
            "saved": len(req.cell_ids),
            "file": str(out_file),
            "group_name": req.group_name
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
