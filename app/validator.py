import os
import csv
import json
from pathlib import Path
from typing import Dict, Any, List, Tuple
from .config import SCHEMA_FILE

def validate_samplesheet(file_path: str) -> Dict[str, Any]:
    path = Path(file_path)
    if not path.exists():
        return {"valid": False, "errors": [f"Samplesheet file not found: {file_path}"], "samples": []}

    required_cols = {"sample_id", "condition", "file_path"}
    errors = []
    warnings = []
    samples = []
    seen_ids = set()

    try:
        with open(path, "r", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            headers = set(reader.fieldnames or [])
            missing = required_cols - headers
            if missing:
                errors.append(f"Missing required columns in samplesheet: {', '.join(missing)}")
                return {"valid": False, "errors": errors, "warnings": warnings, "samples": []}

            for idx, row in enumerate(reader, start=1):
                sid = (row.get("sample_id") or "").strip()
                cond = (row.get("condition") or "").strip()
                mat_path = (row.get("file_path") or "").strip()
                pid = (row.get("patient_id") or "").strip()

                sample_entry = {
                    "row": idx,
                    "sample_id": sid,
                    "condition": cond,
                    "patient_id": pid,
                    "file_path": mat_path,
                    "file_exists": False
                }

                if not sid:
                    errors.append(f"Row {idx}: 'sample_id' cannot be blank.")
                elif sid in seen_ids:
                    errors.append(f"Row {idx}: Duplicate sample_id '{sid}'.")
                else:
                    seen_ids.add(sid)

                if not cond:
                    errors.append(f"Row {idx}: 'condition' cannot be blank.")

                if not mat_path:
                    errors.append(f"Row {idx}: 'file_path' cannot be blank.")
                else:
                    if mat_path.startswith("http://") or mat_path.startswith("https://") or mat_path.startswith("ftp://"):
                        sample_entry["file_exists"] = True
                    else:
                        p = Path(mat_path)
                        if p.exists():
                            sample_entry["file_exists"] = True
                        else:
                            warnings.append(f"Row {idx} ({sid}): File path does not exist locally: {mat_path}")

                samples.append(sample_entry)

    except Exception as e:
        return {"valid": False, "errors": [f"Failed to read samplesheet: {str(e)}"], "samples": []}

    is_valid = len(errors) == 0
    return {
        "valid": is_valid,
        "errors": errors,
        "warnings": warnings,
        "total_samples": len(samples),
        "conditions": list(set(s["condition"] for s in samples if s["condition"])),
        "samples": samples
    }

def validate_parameters(params: Dict[str, Any]) -> Tuple[bool, List[str]]:
    errors = []
    if not SCHEMA_FILE.exists():
        return True, []

    try:
        with open(SCHEMA_FILE, "r") as f:
            schema = json.load(f)

        definitions = schema.get("definitions", {})
        all_props = {}
        for group in definitions.values():
            props = group.get("properties", {})
            all_props.update(props)

        for key, val in params.items():
            if key in all_props:
                prop = all_props[key]
                p_type = prop.get("type")

                # Allow 'auto' for default_resolution
                if key == "default_resolution" and str(val).strip().lower() == "auto":
                    continue

                if p_type == "integer":
                    try:
                        int(val)
                    except (ValueError, TypeError):
                        errors.append(f"Parameter '{key}' must be an integer (got '{val}').")
                elif p_type == "number":
                    try:
                        float(val)
                    except (ValueError, TypeError):
                        errors.append(f"Parameter '{key}' must be a numeric value (got '{val}').")
                elif p_type == "boolean":
                    if not isinstance(val, bool) and str(val).lower() not in ["true", "false"]:
                        errors.append(f"Parameter '{key}' must be a boolean.")

                # Non-negative check
                if isinstance(val, (int, float)) and val < 0:
                    errors.append(f"Parameter '{key}' ({val}) cannot be negative.")
    except Exception as e:
        errors.append(f"Schema validation error: {str(e)}")

    return len(errors) == 0, errors


def validate_generic_file(path_str: str) -> Dict[str, Any]:
    """Validate input file format (H5AD, H5, MTX, CSV, TSV, TXT)."""
    p = Path(path_str)
    if not p.exists():
        return {"valid": False, "format": "", "errors": [f"File not found: {path_str}"]}

    ext = p.suffix.lower()
    if p.is_dir():
        has_mtx = (p / "matrix.mtx").exists() or (p / "matrix.mtx.gz").exists()
        if has_mtx:
            return {"valid": True, "format": "10x MTX Directory", "errors": [], "info": "10x Genomics MTX directory detected."}
        return {"valid": False, "format": "Directory", "errors": ["Directory does not contain matrix.mtx file."]}

    if ext == ".h5ad":
        return {"valid": True, "format": "AnnData H5AD", "errors": [], "info": f"H5AD file ({round(p.stat().st_size/1048576, 2)} MB)."}
    elif ext == ".h5":
        return {"valid": True, "format": "10x HDF5 (.h5)", "errors": [], "info": f"10x H5 file ({round(p.stat().st_size/1048576, 2)} MB)."}
    elif ext in (".csv", ".tsv", ".txt"):
        return {"valid": True, "format": f"Matrix ({ext})", "errors": [], "info": f"Delimited count matrix ({round(p.stat().st_size/1048576, 2)} MB)."}
    elif ext == ".mtx":
        return {"valid": True, "format": "Matrix Market (.mtx)", "errors": [], "info": f"MTX matrix file."}
    else:
        return {"valid": False, "format": ext or "Unknown", "errors": [f"Unsupported format '{ext}'. Supported: .h5ad, .h5, .mtx, .csv, .tsv, .txt"]}

