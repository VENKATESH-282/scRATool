import json
from typing import Dict, Any, Optional
from fastapi import APIRouter, HTTPException
from ..config import SCHEMA_FILE, DEFAULT_SAMPLESHEET, DEFAULT_ANNOTATION, PIPELINE_DIR
from ..validator import validate_parameters

router = APIRouter(prefix="/api/params", tags=["params"])

@router.get("/schema")
def get_schema():
    if not SCHEMA_FILE.exists():
        raise HTTPException(status_code=404, detail="nextflow_schema.json not found")
    try:
        with open(SCHEMA_FILE, "r") as f:
            return json.load(f)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/presets")
def get_presets():
    # Base default params extracted from pipeline
    default_params = {
        "samplesheet": str(DEFAULT_SAMPLESHEET),
        "annotation_map": str(DEFAULT_ANNOTATION),
        "models_dir": str(PIPELINE_DIR / "models"),
        "outdir": str(PIPELINE_DIR / "results"),
        "reference_condition": "CTRL",
        "organism": "human",
        "custom_gene_allowlist": "",
        "custom_gene_panel": "",
        "scoring_gene_sets": "",
        "trajectory_exclude_pattern": "",
        "tissue": "auto",
        "target_celltypes": "auto",
        "seed": 42,
        "nfeature_min": 500,
        "nfeature_max": 6000,
        "ncount_min": 800,
        "ncount_max": 50000,
        "mt_thresh": 15,
        "min_pct_cells": 0.1,
        "n_hvg": 2000,
        "qc_npcs": 30,
        "qc_resolution": 0.8,
        "qc_seed": 12345,
        "npcs": 30,
        "resolutions": "0.2,0.4,0.6,0.8,1.0",
        "default_resolution": "auto",
        "marker_min_pct": 0.25,
        "marker_logfc_thresh": 0.25,
        "top_n_markers": 5,
        "sctype_quantile": 0.6,
        "de_test": "wilcox",
        "de_min_pct": 0.1,
        "de_logfc_thresh": 0.25,
        "de_fdr_thresh": 0.05,
        "pb_min_counts": 10,
        "pb_min_samples": 2,
        "trajectory_root_celltype": "auto",
        "slingshot_approx_points": 150,
        "cellchat_min_cells": 10,
        "cellchat_prob_type": "triMean",
        "nichenet_receiver": "auto",
        "nichenet_min_expr_pct": 0.05,
        "nichenet_top_ligands": 20,
        "nichenet_cutoff": 0.25,
        "copykat_genome": "hg20",
        "copykat_ks_cut": 0.1,
        "copykat_min_cells": 200,
        "hdwgcna_k_metacell": 20,
        "hdwgcna_min_cells": 40,
        "hdwgcna_target_metacells": 1000,
        "hdwgcna_min_module_size": 30,
        "hdwgcna_merge_cut_height": 0.25,
        "skip_cellranger": False,
        "skip_pdx": False,
        "skip_qc": False,
        "skip_integration": False,
        "skip_annotation": False,
        "skip_de": False,
        "skip_trajectory": False,
        "skip_qc_compare": False,
        "skip_monocle3": False,
        "skip_slingshot": False,
        "skip_cellchat": False,
        "skip_nichenet": False,
        "skip_copykat": False,
        "skip_hdwgcna": False,
        "skip_velocity": False,
        "skip_figures": False
    }

    # Fast test preset (matches conf/test.config)
    fast_test = dict(default_params)
    fast_test.update({
        "samplesheet": str(PIPELINE_DIR / "assets" / "test_data" / "samples_test.csv"),
        "annotation_map": str(PIPELINE_DIR / "assets" / "test_data" / "cluster_annotations_test.csv"),
        "outdir": str(PIPELINE_DIR / "results_test"),
        "nfeature_min": 10,
        "ncount_min": 20,
        "min_pct_cells": 0.01,
        "n_hvg": 100,
        "npcs": 10,
        "qc_npcs": 10,
        "copykat_min_cells": 10,
        "hdwgcna_min_cells": 5,
        "hdwgcna_k_metacell": 5,
        "hdwgcna_target_metacells": 50,
        "hdwgcna_min_module_size": 5,
        "cellchat_min_cells": 3,
        "pb_min_counts": 2,
        "pb_min_samples": 1
    })

    # Deep Discovery preset (stringent filtering, more HVGs, high metacell resolution)
    deep_discovery = dict(default_params)
    deep_discovery.update({
        "n_hvg": 3000,
        "npcs": 50,
        "top_n_markers": 10,
        "nichenet_top_ligands": 30,
        "hdwgcna_min_module_size": 20,
        "hdwgcna_k_metacell": 30
    })

    return {
        "presets": {
            "default": {
                "name": "Standard Publication Workflow",
                "description": "Standard production settings for generic scRNA-seq datasets.",
                "params": default_params
            },
            "fast_test": {
                "name": "Rapid Test / Stub Run",
                "description": "Uses minimal synthetic test dataset and relaxed thresholds for quick verification.",
                "params": fast_test
            },
            "deep_discovery": {
                "name": "Deep Discovery & Signaling",
                "description": "Higher dimensional reduction, 3000 HVGs, relaxed module size, and 30 top ligands.",
                "params": deep_discovery
            }
        }
    }

@router.post("/validate")
def validate(params: Dict[str, Any]):
    valid, errors = validate_parameters(params)
    return {"valid": valid, "errors": errors}

@router.get("")
def get_current_params(token: Optional[str] = None):
    if token:
        try:
            from ..session_manager import get_session_dir
            p_file = get_session_dir(token) / "params.json"
            if p_file.exists():
                with open(p_file, "r", encoding="utf-8") as f:
                    return json.load(f)
        except Exception:
            pass
    presets_data = get_presets()
    return presets_data["presets"]["default"]["params"]

@router.post("")
def save_current_params(params: Dict[str, Any], token: Optional[str] = None):
    valid, errors = validate_parameters(params)
    if not valid:
        raise HTTPException(status_code=400, detail={"message": "Invalid parameters", "errors": errors})
    
    if token:
        try:
            from ..session_manager import get_session_dir
            s_dir = get_session_dir(token)
            p_file = s_dir / "params.json"
            with open(p_file, "w", encoding="utf-8") as f:
                json.dump(params, f, indent=2)
            return {"message": "Parameters saved to session workspace", "path": str(p_file)}
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to save session params: {str(e)}")

    return {"message": "Parameters validated successfully", "params": params}

