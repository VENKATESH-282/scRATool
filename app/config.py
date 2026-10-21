import os
import shutil
from pathlib import Path

# Base Paths
GUI_DIR = Path(__file__).resolve().parent.parent
DEFAULT_PIPELINE_DIR = (
    GUI_DIR / "pipeline"
    if (GUI_DIR / "pipeline" / "main.nf").exists()
    else GUI_DIR.parent / "scrna_downstream_pipeline"
)

PIPELINE_DIR = Path(os.getenv("SCRATOOL_PIPELINE_DIR", str(DEFAULT_PIPELINE_DIR))).resolve()
SCHEMA_FILE = GUI_DIR / "nextflow_schema.json" if (GUI_DIR / "nextflow_schema.json").exists() else PIPELINE_DIR / "nextflow_schema.json"
PLATFORM_ASSETS_DIR = GUI_DIR / "assets"
PLATFORM_ASSETS_DIR.mkdir(parents=True, exist_ok=True)
DEFAULT_SAMPLESHEET = PLATFORM_ASSETS_DIR / "samples.csv"
DEFAULT_ANNOTATION = PLATFORM_ASSETS_DIR / "cluster_annotations.csv"
DEFAULT_RESULTS_DIR = PIPELINE_DIR / "results"

RUNS_DIR = GUI_DIR / "runs"
RUNS_DIR.mkdir(parents=True, exist_ok=True)

SESSIONS_DIR = GUI_DIR / "sessions"
SESSIONS_DIR.mkdir(parents=True, exist_ok=True)

DB_PATH = GUI_DIR / "scratool.db"

# Nextflow Executable Resolution
def get_nextflow_binary() -> str:
    env_nf = os.getenv("NEXTFLOW_BIN")
    if env_nf and os.path.exists(env_nf):
        return env_nf
    which_nf = shutil.which("nextflow")
    if which_nf:
        return which_nf
    home_dir = Path.home()
    for candidate in [
        home_dir / "miniconda3" / "bin" / "nextflow",
        home_dir / ".local" / "bin" / "nextflow",
        Path("/usr/local/bin/nextflow"),
        Path("/opt/conda/bin/nextflow")
    ]:
        if candidate.exists():
            return str(candidate)
    return "nextflow"

NEXTFLOW_BIN = get_nextflow_binary()
