import csv
import json
from pathlib import Path
from typing import List, Dict, Any, Optional
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from ..config import DEFAULT_SAMPLESHEET, DEFAULT_ANNOTATION
from ..validator import validate_samplesheet
from ..session_manager import get_session_dir

router = APIRouter(prefix="/api/samples", tags=["samples"])

class SampleRow(BaseModel):
    sample_id: str
    condition: str
    patient_id: Optional[str] = ""
    file_path: str

class SaveSamplesheetRequest(BaseModel):
    token: Optional[str] = None
    file_path: Optional[str] = None
    reference_condition: Optional[str] = None
    samples: List[SampleRow]

class CsvUploadRequest(BaseModel):
    token: Optional[str] = None
    file_path: Optional[str] = None
    csv_content: str
    reference_condition: Optional[str] = None

class AnnotationRow(BaseModel):
    cluster: str
    n_cells: Optional[str] = ""
    manual_type: Optional[str] = "Unassigned"
    singler_type: Optional[str] = ""
    sctype_type: Optional[str] = ""
    sccatch_type: Optional[str] = "NotRun"
    consensus_annotation: str

class SaveAnnotationRequest(BaseModel):
    token: Optional[str] = None
    file_path: Optional[str] = None
    annotations: List[AnnotationRow]

def resolve_samplesheet_path(token: Optional[str] = None, file_path: Optional[str] = None) -> Path:
    if file_path:
        return Path(file_path)
    if token:
        try:
            s_path = get_session_dir(token) / "samples.csv"
            if s_path.exists():
                return s_path
        except Exception:
            pass
    return DEFAULT_SAMPLESHEET

SAMPLE_PRESETS = {
    "pbmc_human": {
        "id": "pbmc_human",
        "name": "Human PBMC Benchmark (GSE117988)",
        "description": "Human single-cell RNA-seq comparing PBMC immune cells against Tumor cells (Zhang et al., NCBI GEO GSE117988).",
        "reference_condition": "CTRL",
        "samples": [
            {"sample_id": "PBMC_CTRL", "condition": "CTRL", "patient_id": "Donor_PBMC", "file_path": "https://ftp.ncbi.nlm.nih.gov/geo/series/GSE117nnn/GSE117988/suppl/GSE117988_raw.expMatrix_PBMC.csv.gz"},
            {"sample_id": "TUMOR_TREATED", "condition": "TREATED", "patient_id": "Donor_TUMOR", "file_path": "https://ftp.ncbi.nlm.nih.gov/geo/series/GSE117nnn/GSE117988/suppl/GSE117988_raw.expMatrix_Tumor.csv.gz"}
        ]
    },
    "twocond_wt_ko": {
        "id": "twocond_wt_ko",
        "name": "WT vs KO 2-Condition (4 Samples)",
        "description": "Standard 2-condition design with 2 Wild-Type (WT) controls and 2 Knock-Out (KO) replicates.",
        "reference_condition": "WT",
        "samples": [
            {"sample_id": "WT_rep1", "condition": "WT", "patient_id": "WT_donor1", "file_path": "data/WT_rep1/GSM_WT1.txt.gz"},
            {"sample_id": "WT_rep2", "condition": "WT", "patient_id": "WT_donor2", "file_path": "data/WT_rep2/GSM_WT2.txt.gz"},
            {"sample_id": "KO_rep1", "condition": "KO", "patient_id": "KO_donor1", "file_path": "data/KO_rep1/GSM_KO1.txt.gz"},
            {"sample_id": "KO_rep2", "condition": "KO", "patient_id": "KO_donor2", "file_path": "data/KO_rep2/GSM_KO2.txt.gz"}
        ]
    },
    "tenx_dir": {
        "id": "tenx_dir",
        "name": "10x Genomics Directory Format (CellRanger outs)",
        "description": "Points directly to 10x filtered_feature_bc_matrix directories (contains barcodes.tsv.gz, features.tsv.gz, matrix.mtx.gz).",
        "reference_condition": "CTRL",
        "samples": [
            {"sample_id": "Sample_CTRL_1", "condition": "CTRL", "patient_id": "Donor_A", "file_path": "data/10x_runs/CTRL_1/outs/filtered_feature_bc_matrix"},
            {"sample_id": "Sample_CTRL_2", "condition": "CTRL", "patient_id": "Donor_B", "file_path": "data/10x_runs/CTRL_2/outs/filtered_feature_bc_matrix"},
            {"sample_id": "Sample_TREAT_1", "condition": "TREAT", "patient_id": "Donor_C", "file_path": "data/10x_runs/TREAT_1/outs/filtered_feature_bc_matrix"},
            {"sample_id": "Sample_TREAT_2", "condition": "TREAT", "patient_id": "Donor_D", "file_path": "data/10x_runs/TREAT_2/outs/filtered_feature_bc_matrix"}
        ]
    },
    "blank": {
        "id": "blank",
        "name": "Blank / Custom Starter",
        "description": "Clean template with placeholder rows ready for custom inputs.",
        "reference_condition": "Control",
        "samples": [
            {"sample_id": "Sample_01", "condition": "Control", "patient_id": "P01", "file_path": "/path/to/counts_sample1.txt.gz"},
            {"sample_id": "Sample_02", "condition": "Treated", "patient_id": "P02", "file_path": "/path/to/counts_sample2.txt.gz"}
        ]
    }
}

@router.get("/presets")
def get_sample_presets():
    return {"presets": list(SAMPLE_PRESETS.values())}

@router.get("/geo_fetch")
def geo_fetch(accession: str):
    import urllib.request
    import re
    accession = accession.upper().strip()
    prefix = accession[:3]
    if prefix not in ["GSE", "GSM"]:
        raise HTTPException(status_code=400, detail="Invalid accession format. Must start with GSE or GSM.")
    number_str = accession[3:]
    bucket = f'{prefix}nnn' if len(number_str) <= 3 else f'{prefix}{number_str[:-3]}nnn'
    
    subpath = f"geo/series/{bucket}/{accession}/suppl/" if prefix == 'GSE' else f"geo/samples/{bucket}/{accession}/suppl/"
    https_url = f"https://ftp.ncbi.nlm.nih.gov/{subpath}"
    ftp_url = f"ftp://ftp.ncbi.nlm.nih.gov/{subpath}"
    
    files = []
    # 1. Try HTTPS directory listing first (bypasses FTP port 21 firewall blocks)
    try:
        req = urllib.request.Request(https_url, headers={"User-Agent": "scRATool/1.0 (Mozilla/5.0)"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            html = resp.read().decode('utf-8', errors='ignore')
            # Extract links to count matrices / data files
            matched_names = re.findall(r'href=["\']([^"\'?#/]+\.(?:txt|csv|tsv|h5|h5ad|rds|mtx)(?:\.gz)?)["\']', html, re.IGNORECASE)
            # Remove duplicates while preserving order
            seen = set()
            for fn in matched_names:
                if fn not in seen and fn.lower() != 'filelist.txt':
                    seen.add(fn)
                    files.append(f"{https_url}{fn}")
    except Exception:
        pass

    # 2. If no files discovered via HTTPS, try FTP listing fallback
    if not files:
        try:
            with urllib.request.urlopen(ftp_url, timeout=10) as resp:
                lines = resp.read().decode('utf-8', errors='ignore').strip().split('\n')
                for line in lines:
                    parts = line.split()
                    if len(parts) >= 9:
                        filename = ' '.join(parts[8:])
                        if filename != 'filelist.txt' and not filename.startswith('.'):
                            files.append(f"{https_url}{filename}")
        except Exception as e:
            if not files:
                raise HTTPException(status_code=404, detail=f"Failed to fetch GEO data for {accession}: {str(e)}")

    if not files:
        raise HTTPException(status_code=404, detail=f"No matrix or supplementary files found for {accession}")

    return {"accession": accession, "files": files}

@router.post("/presets/{preset_id}")
def load_sample_preset(preset_id: str, token: Optional[str] = None):
    if preset_id not in SAMPLE_PRESETS:
        raise HTTPException(status_code=404, detail=f"Preset '{preset_id}' not found")
    preset = SAMPLE_PRESETS[preset_id]
    target = resolve_samplesheet_path(token)
    target.parent.mkdir(parents=True, exist_ok=True)

    try:
        with open(target, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["sample_id", "condition", "patient_id", "file_path"])
            for s in preset["samples"]:
                writer.writerow([s["sample_id"], s["condition"], s.get("patient_id", ""), s["file_path"]])

        # Also update session's params.reference_condition if token provided
        if token:
            try:
                p_file = get_session_dir(token) / "params.json"
                if p_file.exists():
                    with open(p_file, "r", encoding="utf-8") as pf:
                        pdata = json.load(pf)
                else:
                    pdata = {}
                pdata["reference_condition"] = preset["reference_condition"]
                with open(p_file, "w", encoding="utf-8") as pf:
                    json.dump(pdata, pf, indent=2)
            except Exception:
                pass

        val_res = validate_samplesheet(str(target))
        val_res["reference_condition"] = preset["reference_condition"]
        return {"message": f"Preset '{preset['name']}' loaded successfully", "data": val_res}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to load preset: {str(e)}")

@router.post("/upload")
def upload_samplesheet_csv(req: CsvUploadRequest):
    target = resolve_samplesheet_path(req.token, req.file_path)
    target.parent.mkdir(parents=True, exist_ok=True)

    try:
        # Write CSV content directly to target file
        with open(target, "w", encoding="utf-8") as f:
            f.write(req.csv_content.strip() + "\n")

        val_res = validate_samplesheet(str(target))

        # Update reference condition if given
        ref_cond = req.reference_condition
        if not ref_cond and val_res.get("conditions"):
            # If current reference condition not set or not in conditions, pick first or CTRL/WT if present
            conds = val_res["conditions"]
            ref_cond = "CTRL" if "CTRL" in conds else ("WT" if "WT" in conds else conds[0])

        if req.token and ref_cond:
            try:
                p_file = get_session_dir(req.token) / "params.json"
                if p_file.exists():
                    with open(p_file, "r", encoding="utf-8") as pf:
                        pdata = json.load(pf)
                else:
                    pdata = {}
                pdata["reference_condition"] = ref_cond
                with open(p_file, "w", encoding="utf-8") as pf:
                    json.dump(pdata, pf, indent=2)
            except Exception:
                pass

        val_res["reference_condition"] = ref_cond
        return {"message": "Samplesheet uploaded and validated", "data": val_res}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to save uploaded CSV: {str(e)}")

@router.get("")
def get_samplesheet(token: Optional[str] = None, file_path: Optional[str] = None):
    target = resolve_samplesheet_path(token, file_path)
    val_res = validate_samplesheet(str(target))

    # Read reference_condition from session params if available
    ref_cond = "CTRL"
    if token:
        try:
            p_file = get_session_dir(token) / "params.json"
            if p_file.exists():
                with open(p_file, "r", encoding="utf-8") as pf:
                    pdata = json.load(pf)
                    if "reference_condition" in pdata:
                        ref_cond = pdata["reference_condition"]
        except Exception:
            pass
    elif val_res.get("conditions"):
        conds = val_res["conditions"]
        if "CTRL" in conds:
            ref_cond = "CTRL"
        elif "WT" in conds:
            ref_cond = "WT"
        else:
            ref_cond = conds[0]

    val_res["reference_condition"] = ref_cond
    return val_res

@router.post("")
def save_samplesheet(req: SaveSamplesheetRequest):
    target = resolve_samplesheet_path(req.token, req.file_path)
    target.parent.mkdir(parents=True, exist_ok=True)

    try:
        with open(target, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["sample_id", "condition", "patient_id", "file_path"])
            for s in req.samples:
                writer.writerow([s.sample_id, s.condition, s.patient_id or "", s.file_path])

        # If reference_condition is passed and token is present, update session's params.json
        if req.token and req.reference_condition:
            try:
                p_file = get_session_dir(req.token) / "params.json"
                if p_file.exists():
                    with open(p_file, "r", encoding="utf-8") as pf:
                        pdata = json.load(pf)
                else:
                    pdata = {}
                pdata["reference_condition"] = req.reference_condition
                with open(p_file, "w", encoding="utf-8") as pf:
                    json.dump(pdata, pf, indent=2)
            except Exception:
                pass

        val_res = validate_samplesheet(str(target))
        val_res["reference_condition"] = req.reference_condition or "CTRL"
        return {"message": "Samplesheet saved successfully", "path": str(target), "data": val_res}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to save samplesheet: {str(e)}")

@router.get("/annotations")
def get_annotations(file_path: Optional[str] = None):
    target = Path(file_path) if file_path else DEFAULT_ANNOTATION
    if not target.exists():
        return {"annotations": []}

    rows = []
    try:
        with open(target, "r", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for r in reader:
                rows.append(r)
        return {"annotations": rows, "file_path": str(target)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/annotations")
def save_annotations(req: SaveAnnotationRequest):
    target = Path(req.file_path) if req.file_path else DEFAULT_ANNOTATION
    target.parent.mkdir(parents=True, exist_ok=True)

    try:
        headers = ["cluster", "n_cells", "manual_type", "singler_type", "sctype_type", "sccatch_type", "consensus_annotation"]
        with open(target, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(headers)
            for a in req.annotations:
                writer.writerow([
                    a.cluster,
                    a.n_cells or "",
                    a.manual_type or "Unassigned",
                    a.singler_type or "",
                    a.sctype_type or "",
                    a.sccatch_type or "NotRun",
                    a.consensus_annotation
                ])
        return {"message": "Annotations saved successfully", "path": str(target)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to save annotations: {str(e)}")

@router.post("/validate_file")
def validate_input_file(path: str):
    from ..validator import validate_generic_file
    return validate_generic_file(path)

