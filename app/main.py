import os
from pathlib import Path
from typing import Optional
from fastapi import FastAPI, Request
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.responses import HTMLResponse
from fastapi.middleware.cors import CORSMiddleware

from .config import GUI_DIR, PIPELINE_DIR, SCHEMA_FILE, DEFAULT_SAMPLESHEET, RUNS_DIR
from .db import init_db, list_runs
from .routers import api_runs, api_params, api_samples, api_logs, api_explorer, api_sessions, api_cluster
from .session_manager import get_or_create_default_session, get_session, create_session

app = FastAPI(
    title="scRNA Platform",
    description="Browser-based Graphical User Interface for scRNA-seq Downstream Analysis Automated Nextflow Pipeline (Universal Trajectories Enabled)",
    version="1.0.2"
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Prevent aggressive browser caching of JS/CSS during development
@app.middleware("http")
async def add_no_cache_header(request: Request, call_next):
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
    return response

# Static files & Templates
static_dir = GUI_DIR / "static"
templates_dir = GUI_DIR / "templates"

app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")
templates = Jinja2Templates(directory=str(templates_dir))

# Include Routers
app.include_router(api_sessions.router)
app.include_router(api_runs.router)
app.include_router(api_params.router)
app.include_router(api_samples.router)
app.include_router(api_logs.router)
app.include_router(api_explorer.router)
app.include_router(api_cluster.router)

@app.on_event("startup")
def on_startup():
    init_db()

@app.get("/", response_class=HTMLResponse)
def index(request: Request, token: Optional[str] = None):
    active_token = None
    if token:
        sess = get_session(token, touch=True)
        if sess:
            active_token = sess["token"]
    if not active_token:
        # Each new visit without a specific token generates a fresh unique session ID
        new_sess = create_session(name="Analysis Workspace")
        active_token = new_sess["token"]

    latest_prov = None
    for candidate in [
        PIPELINE_DIR / "results_test" / "pipeline_info" / "provenance.json",
        PIPELINE_DIR / "results" / "pipeline_info" / "provenance.json"
    ]:
        if candidate.exists():
            try:
                import json
                with open(candidate, "r") as f:
                    latest_prov = json.dumps(json.load(f), indent=2)
                break
            except Exception:
                pass

    initial_run_log = None
    initial_stages = None
    runs = list_runs(1, session_token=active_token)
    if not runs:
        runs = list_runs(1)
    if runs:
        r_log_path = RUNS_DIR / runs[0]["id"] / "run.log"
        if r_log_path.exists():
            try:
                with open(r_log_path, "r", encoding="utf-8") as f:
                    initial_run_log = f.read()
            except Exception:
                pass
        st_path = RUNS_DIR / runs[0]["id"] / "stages.json"
        if st_path.exists():
            try:
                with open(st_path, "r", encoding="utf-8") as f:
                    initial_stages = json.load(f)
            except Exception:
                pass

    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={
            "pipeline_dir": str(PIPELINE_DIR),
            "schema_exists": SCHEMA_FILE.exists(),
            "samplesheet_exists": DEFAULT_SAMPLESHEET.exists(),
            "initial_token": active_token,
            "initial_provenance": latest_prov,
            "initial_run_log": initial_run_log,
            "initial_stages": initial_stages or {}
        }
    )

@app.get("/api/status")
def system_status():
    return {
        "status": "online",
        "pipeline_directory": str(PIPELINE_DIR),
        "pipeline_exists": (PIPELINE_DIR / "main.nf").exists(),
        "schema_available": SCHEMA_FILE.exists(),
        "default_samplesheet": str(DEFAULT_SAMPLESHEET),
        "samplesheet_exists": DEFAULT_SAMPLESHEET.exists()
    }
