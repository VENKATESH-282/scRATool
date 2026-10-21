from typing import Dict, Any, List, Set, Tuple

# Mapping of parameter keys to the primary stage they affect
PARAM_TO_STAGE = {
    # Stage 01
    "samplesheet": "01",
    "nfeature_min": "01",
    "nfeature_max": "01",
    "ncount_min": "01",
    "ncount_max": "01",
    "mt_thresh": "01",
    "min_pct_cells": "01",
    "n_hvg": "01",
    "seed": "01",

    # Stage 02
    "skip_qc_compare": "02",
    "qc_npcs": "02",
    "qc_resolution": "02",
    "qc_seed": "02",

    # Stage 03
    "npcs": "03",
    "resolutions": "03",
    "default_resolution": "03",

    # Stage 04
    "tissue": "04",
    "marker_min_pct": "04",
    "marker_logfc_thresh": "04",
    "top_n_markers": "04",
    "sctype_quantile": "04",

    # Stage 05
    "annotation_map": "05",
    "reference_condition": "05",
    "de_test": "05",
    "de_min_pct": "05",
    "de_logfc_thresh": "05",
    "de_fdr_thresh": "05",
    "pb_min_counts": "05",
    "pb_min_samples": "05",

    # Stage 07
    "skip_monocle3": "07",
    "trajectory_root_celltype": "07",

    # Stage 08
    "skip_slingshot": "08",
    "slingshot_approx_points": "08",

    # Stage 09
    "skip_cellchat": "09",
    "cellchat_min_cells": "09",
    "cellchat_prob_type": "09",

    # Stage 10
    "skip_nichenet": "10",
    "models_dir": "10",
    "nichenet_receiver": "10",
    "nichenet_min_expr_pct": "10",
    "nichenet_top_ligands": "10",
    "nichenet_cutoff": "10",

    # Stage 11
    "skip_copykat": "11",
    "copykat_genome": "11",
    "copykat_ks_cut": "11",
    "copykat_min_cells": "11",

    # Stage 12
    "skip_hdwgcna": "12",
    "target_celltypes": "12",
    "hdwgcna_k_metacell": "12",
    "hdwgcna_min_cells": "12",
    "hdwgcna_target_metacells": "12",
    "hdwgcna_min_module_size": "12",
    "hdwgcna_merge_cut_height": "12",

    # Stage 13
    "skip_velocity": "13",

    # Stage 14
    "skip_figures": "14"
}

# Directed acyclic graph of stage dependencies in scrna_downstream_pipeline
STAGE_DEPENDENCIES = {
    "01": [],
    "02": ["01"],
    "03": ["01"],
    "04": ["03"],
    "05": ["04"],
    "06": ["05"],
    "07": ["05"],
    "08": ["05"],
    "09": ["05"],
    "10": ["05"],
    "11": ["05"],
    "12": ["05"],
    "13": ["05"],
    "14": ["05", "09"]
}

STAGE_NAMES = {
    "01": "QC_FILTERING",
    "02": "QC_TOOL_COMPARE",
    "03": "INTEGRATION_CLUSTERING",
    "04": "CELL_ANNOTATION",
    "05": "DIFFERENTIAL_EXPRESSION",
    "06": "OBJECT_CONVERSION",
    "07": "TRAJECTORY_MONOCLE3",
    "08": "TRAJECTORY_SLINGSHOT",
    "09": "CELLCHAT_COMMUNICATION",
    "10": "NICHENET_COMMUNICATION",
    "11": "COPYKAT_CNV",
    "12": "HDWGCNA_NETWORKS",
    "13": "VELOCITY_EXPORT",
    "14": "PUBLICATION_FIGURES"
}

def get_all_downstream_stages(stage_code: str) -> Set[str]:
    downstream = set()
    to_visit = [stage_code]
    while to_visit:
        curr = to_visit.pop()
        for s_code, deps in STAGE_DEPENDENCIES.items():
            if curr in deps and s_code not in downstream:
                downstream.add(s_code)
                to_visit.append(s_code)
    return downstream

def compute_cache_preview(
    old_params: Dict[str, Any],
    new_params: Dict[str, Any],
    last_run_success: bool = True
) -> Dict[str, Any]:
    """
    Diffs new_params against old_params and computes which Nextflow stages
    will be REUSED (cached) and which will RE-RUN.
    """
    changed_params = []
    affected_stages = set()
    reasons = {}

    all_keys = set(old_params.keys()).union(set(new_params.keys()))
    # Ignore purely output metadata paths that are dynamically generated
    ignore_keys = {"trace_timestamp"}

    for key in sorted(all_keys):
        if key in ignore_keys:
            continue
        v_old = old_params.get(key)
        v_new = new_params.get(key)
        if v_old != v_new:
            changed_params.append({
                "param": key,
                "old": v_old,
                "new": v_new,
                "stage": PARAM_TO_STAGE.get(key, "unknown")
            })
            stage = PARAM_TO_STAGE.get(key)
            if stage:
                affected_stages.add(stage)
                reasons[stage] = f"Parameter '{key}' changed ({v_old} -> {v_new})"

    # Cascade downstream
    rerun_stages = set(affected_stages)
    for s in affected_stages:
        downstream = get_all_downstream_stages(s)
        for d in downstream:
            rerun_stages.add(d)
            if d not in reasons:
                reasons[d] = f"Downstream of modified stage {s} ({STAGE_NAMES.get(s)})"

    # If the previous run failed or was incomplete, unfinished stages also re-run
    stage_predictions = {}
    for code, name in STAGE_NAMES.items():
        # Check skip flags
        skip_flag = f"skip_{name.split('_')[0].lower()}"
        if new_params.get(skip_flag) is True:
            stage_predictions[code] = {
                "name": name,
                "action": "SKIPPED",
                "reason": f"Flag '{skip_flag}' is enabled"
            }
        elif code in rerun_stages:
            stage_predictions[code] = {
                "name": name,
                "action": "RE-RUN",
                "reason": reasons.get(code, "Parameter modification cascade")
            }
        else:
            stage_predictions[code] = {
                "name": name,
                "action": "REUSED" if last_run_success else "REUSED / RESUMED",
                "reason": "Inputs and parameters unchanged"
            }

    reused_count = sum(1 for s in stage_predictions.values() if s["action"] in ["REUSED", "REUSED / RESUMED"])
    rerun_count = sum(1 for s in stage_predictions.values() if s["action"] == "RE-RUN")

    return {
        "changed_params": changed_params,
        "stage_predictions": stage_predictions,
        "rerun_stages": [code for code, s in stage_predictions.items() if s["action"] == "RE-RUN"],
        "reused_stages": [code for code, s in stage_predictions.items() if s["action"] in ["REUSED", "REUSED / RESUMED"]],
        "skipped_stages": [code for code, s in stage_predictions.items() if s["action"] == "SKIPPED"],
        "stages": [{"code": code, **s, "status": s["action"]} for code, s in stage_predictions.items()],
        "summary": {
            "total_stages": len(STAGE_NAMES),
            "reused_count": reused_count,
            "rerun_count": rerun_count,
            "skipped_count": sum(1 for s in stage_predictions.values() if s["action"] == "SKIPPED")
        }
    }
