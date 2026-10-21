"""
FastAPI router for project management in the General-Purpose scRNA-seq Platform.
"""
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from typing import Optional
from ..project_manager import new_project, list_all_projects, full_project_info, update_project_params, remove_project
from ..validator import validate_input

router = APIRouter(prefix="/api/projects", tags=["projects"])


class CreateProjectRequest(BaseModel):
    name: str
    description: Optional[str] = ""
    organism: Optional[str] = "human"
    tissue: Optional[str] = ""
    input_format: Optional[str] = ""
    input_path: Optional[str] = ""


class UpdateParamsRequest(BaseModel):
    params: dict


@router.get("")
def list_projects():
    return list_all_projects()


@router.post("")
def create_project(req: CreateProjectRequest):
    return new_project(
        name=req.name,
        description=req.description or "",
        organism=req.organism or "human",
        tissue=req.tissue or "",
        input_format=req.input_format or "",
        input_path=req.input_path or ""
    )


@router.get("/{project_id}")
def get_project(project_id: str):
    proj = full_project_info(project_id)
    if not proj:
        raise HTTPException(status_code=404, detail="Project not found")
    return proj


@router.put("/{project_id}/params")
def update_params(project_id: str, req: UpdateParamsRequest):
    ok = update_project_params(project_id, req.params)
    if not ok:
        raise HTTPException(status_code=404, detail="Project not found")
    return full_project_info(project_id)


@router.delete("/{project_id}")
def delete_project_route(project_id: str, delete_files: bool = False):
    remove_project(project_id, delete_files=delete_files)
    return {"message": f"Project {project_id} deleted."}


@router.post("/validate")
def validate_file(input_path: str):
    """Validate an input file and return format info + metadata preview."""
    return validate_input(input_path)
