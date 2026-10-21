from typing import Optional, Dict, Any, List
from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

from ..session_manager import (
    normalize_token, create_session, get_session, list_sessions,
    get_or_create_default_session, duplicate_session, rename_session, delete_session
)

router = APIRouter(prefix="/api/sessions", tags=["sessions"])

class CreateSessionRequest(BaseModel):
    name: Optional[str] = None

class RenameSessionRequest(BaseModel):
    name: str

@router.get("")
def get_all_sessions() -> List[Dict[str, Any]]:
    return list_sessions()

@router.get("/active")
def get_active_session() -> Dict[str, Any]:
    return get_or_create_default_session()

@router.post("")
def create_new_session(req: Optional[CreateSessionRequest] = None) -> Dict[str, Any]:
    name = req.name if req else None
    return create_session(name=name)

@router.get("/{token}")
def get_session_info(token: str) -> Dict[str, Any]:
    sess = get_session(token, touch=True)
    if not sess:
        raise HTTPException(status_code=404, detail=f"Session workspace '{token}' not found.")
    return sess

@router.post("/{token}/duplicate")
def duplicate_existing_session(token: str, req: Optional[CreateSessionRequest] = None) -> Dict[str, Any]:
    try:
        new_name = req.name if req else None
        return duplicate_session(token, new_name=new_name)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@router.patch("/{token}")
def rename_existing_session(token: str, req: RenameSessionRequest) -> Dict[str, Any]:
    updated = rename_session(token, req.name)
    if not updated:
        raise HTTPException(status_code=404, detail=f"Session workspace '{token}' not found.")
    return updated

@router.delete("/{token}")
def delete_existing_session(token: str) -> Dict[str, Any]:
    success = delete_session(token)
    if not success:
        raise HTTPException(status_code=400, detail=f"Could not delete session workspace '{token}'.")
    return {"success": True, "token": token}
