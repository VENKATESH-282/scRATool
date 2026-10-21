import uuid
from typing import Dict, Any, Optional
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from ..db import list_runs, get_run, delete_run
from ..runner import run_nextflow_job, cancel_run, get_run_stages
from ..validator import validate_parameters

router = APIRouter(prefix="/api/runs", tags=["runs"])

class LaunchRunRequest(BaseModel):
    name: Optional[str] = None
    profile: Optional[str] = "local,pixi"
    resume: Optional[bool] = True
    stub_run: Optional[bool] = False
    token: Optional[str] = None
    params: Dict[str, Any]
    is_remote: Optional[bool] = False
    cluster_profile_id: Optional[int] = None
    remote_dir: Optional[str] = None
    env_init: Optional[str] = ""

@router.get("")
def get_all_runs(limit: int = 50, token: Optional[str] = None):
    return {"runs": list_runs(limit, session_token=token)}

@router.post("")
def launch_run(req: LaunchRunRequest):
    valid, errors = validate_parameters(req.params)
    if not valid:
        raise HTTPException(status_code=400, detail={"message": "Parameter validation failed", "errors": errors})

    run_id = f"run_{uuid.uuid4().hex[:8]}"
    run_name = req.name or f"Run-{run_id}"

    if req.is_remote:
        if not req.cluster_profile_id or not req.remote_dir:
            raise HTTPException(status_code=400, detail={"message": "Remote cluster profile and directory are required for remote execution."})
        from ..remote_runner import start_remote_run
        try:
            record = start_remote_run(
                run_id=run_id,
                name=run_name,
                profile=req.profile or "standard",
                resume=req.resume,
                stub_run=req.stub_run,
                params=req.params,
                session_token=req.token,
                cluster_profile_id=req.cluster_profile_id,
                remote_dir=req.remote_dir,
                env_init=req.env_init or ""
            )
        except Exception as e:
            raise HTTPException(status_code=500, detail={"message": f"Failed to start remote run: {str(e)}"})
    else:
        record = run_nextflow_job(
            run_id=run_id,
            name=run_name,
            profile=req.profile or "local,pixi",
            resume=req.resume,
            stub_run=req.stub_run,
            params=req.params,
            session_token=req.token
        )
    return {"message": "Run launched successfully", "run": record}

@router.get("/{run_id}")
def get_run_details(run_id: str):
    record = get_run(run_id)
    if not record:
        raise HTTPException(status_code=404, detail="Run not found")
    return {"run": record}

@router.post("/{run_id}/cancel")
def cancel_active_run(run_id: str):
    record = get_run(run_id)
    if not record:
        raise HTTPException(status_code=404, detail="Run not found")
        
    if record.get("is_remote"):
        from ..remote_runner import cancel_remote_run
        success = cancel_remote_run(run_id)
    else:
        success = cancel_run(run_id)
        
    if not success:
        raise HTTPException(status_code=400, detail="Could not cancel run or run is not active")
    return {"message": "Run cancelled successfully"}

@router.get("/{run_id}/stages")
def get_stages(run_id: str):
    return get_run_stages(run_id)

@router.delete("/{run_id}")
def delete_run_record(run_id: str):
    delete_run(run_id)
    return {"message": "Run record deleted"}
