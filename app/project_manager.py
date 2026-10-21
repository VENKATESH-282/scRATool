"""
Project lifecycle manager for the General-Purpose scRNA-seq Platform.
Handles project creation, workspace isolation, parameter management.
"""
import json
import shutil
import uuid
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Optional, List

from .config import PROJECTS_DIR, DEFAULT_PIPELINE_PARAMS
from .db import create_project, get_project, list_projects, update_project, delete_project


def _generate_project_id() -> str:
    """Generate a short, readable project ID."""
    ts = datetime.now().strftime("%Y%m%d")
    uid = uuid.uuid4().hex[:6].upper()
    return f"PROJ-{ts}-{uid}"


def get_project_dir(project_id: str) -> Path:
    return PROJECTS_DIR / project_id


def new_project(name: str, description: str = "", organism: str = "human",
                tissue: str = "", input_format: str = "",
                input_path: str = "") -> Dict[str, Any]:
    """
    Create a new analysis project with isolated workspace.
    Returns the full project record including directories.
    """
    pid = _generate_project_id()
    proj_dir = get_project_dir(pid)

    # Create workspace directories
    (proj_dir / "inputs").mkdir(parents=True, exist_ok=True)
    (proj_dir / "results").mkdir(parents=True, exist_ok=True)
    (proj_dir / "exports").mkdir(parents=True, exist_ok=True)
    (proj_dir / "logs").mkdir(parents=True, exist_ok=True)
    (proj_dir / "config").mkdir(parents=True, exist_ok=True)

    # Write default params
    params = dict(DEFAULT_PIPELINE_PARAMS)
    params["organism"] = organism
    params["tissue"] = tissue
    if input_path:
        params["input_path"] = input_path
    if input_format:
        params["input_format"] = input_format

    params_file = proj_dir / "config" / "params.json"
    with open(params_file, "w") as f:
        json.dump(params, f, indent=2)

    # Write project manifest
    manifest = {
        "id": pid,
        "name": name,
        "description": description,
        "organism": organism,
        "tissue": tissue,
        "input_format": input_format,
        "input_path": input_path,
        "created_at": datetime.now().isoformat(),
        "status": "CREATED"
    }
    with open(proj_dir / "manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)

    # Store in DB
    create_project(
        pid=pid, name=name, description=description, organism=organism,
        tissue=tissue, input_format=input_format, input_path=input_path
    )

    return full_project_info(pid)


def full_project_info(project_id: str) -> Optional[Dict[str, Any]]:
    """Get complete project info including filesystem state."""
    proj = get_project(project_id)
    if not proj:
        return None
    proj_dir = get_project_dir(project_id)
    proj["project_dir"] = str(proj_dir)
    proj["exists_on_disk"] = proj_dir.exists()
    proj["has_params"] = (proj_dir / "config" / "params.json").exists()
    proj["has_results"] = any((proj_dir / "results").iterdir()) if (proj_dir / "results").exists() else False
    # Read params
    params_file = proj_dir / "config" / "params.json"
    if params_file.exists():
        try:
            with open(params_file) as f:
                proj["params"] = json.load(f)
        except Exception:
            proj["params"] = {}
    else:
        proj["params"] = dict(DEFAULT_PIPELINE_PARAMS)
    return proj


def list_all_projects() -> List[Dict[str, Any]]:
    projects = list_projects()
    return [full_project_info(p["id"]) or p for p in projects]


def update_project_params(project_id: str, params: Dict[str, Any]) -> bool:
    proj_dir = get_project_dir(project_id)
    params_file = proj_dir / "config" / "params.json"
    params_file.parent.mkdir(parents=True, exist_ok=True)
    # Merge with existing
    existing = {}
    if params_file.exists():
        try:
            with open(params_file) as f:
                existing = json.load(f)
        except Exception:
            pass
    existing.update(params)
    with open(params_file, "w") as f:
        json.dump(existing, f, indent=2)
    update_project(project_id, updated_at=datetime.now().isoformat())
    return True


def remove_project(project_id: str, delete_files: bool = False) -> bool:
    if delete_files:
        proj_dir = get_project_dir(project_id)
        if proj_dir.exists():
            shutil.rmtree(proj_dir, ignore_errors=True)
    delete_project(project_id)
    return True
