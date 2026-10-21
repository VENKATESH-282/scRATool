import pytest
from app.cache_preview import compute_cache_preview, STAGE_NAMES

def test_cache_preview_identical_params():
    old_params = {
        "nfeature_min": 200,
        "mt_thresh": 15,
        "npcs": 30,
        "resolutions": "0.4,0.6,0.8"
    }
    new_params = {
        "nfeature_min": 200,
        "mt_thresh": 15,
        "npcs": 30,
        "resolutions": "0.4,0.6,0.8"
    }
    preview = compute_cache_preview(old_params, new_params)
    assert len(preview["changed_params"]) == 0
    assert len(preview["rerun_stages"]) == 0
    assert len(preview["reused_stages"]) == len(STAGE_NAMES)
    for st in preview["stages"]:
        assert st["status"] == "REUSED"

def test_cache_preview_early_stage_change_cascades():
    # Changing nfeature_min (stage 01) should invalidate everything downstream
    old_params = {"nfeature_min": 200}
    new_params = {"nfeature_min": 300}
    preview = compute_cache_preview(old_params, new_params)

    param_names = [p["param"] for p in preview["changed_params"]]
    assert "nfeature_min" in param_names
    assert "01" in preview["rerun_stages"]
    assert "02" in preview["rerun_stages"]
    assert "03" in preview["rerun_stages"]
    assert "04" in preview["rerun_stages"]
    assert "05" in preview["rerun_stages"]
    assert "06" in preview["rerun_stages"]
    assert "07" in preview["rerun_stages"]
    assert "14" in preview["rerun_stages"]

def test_cache_preview_middle_stage_change():
    # Changing npcs affects stage 03 and downstream, but NOT stage 01 or 02
    old_params = {"npcs": 30}
    new_params = {"npcs": 50}
    preview = compute_cache_preview(old_params, new_params)

    param_names = [p["param"] for p in preview["changed_params"]]
    assert "npcs" in param_names
    assert "01" in preview["reused_stages"]
    assert "02" in preview["reused_stages"]
    assert "03" in preview["rerun_stages"]
    assert "04" in preview["rerun_stages"]

def test_cache_preview_leaf_stage_change():
    # Changing trajectory_root_celltype affects stage 07, but NOT stages 01-06 or copykat or cellchat
    old_params = {"trajectory_root_celltype": "Satellite cells"}
    new_params = {"trajectory_root_celltype": "Intermediate"}
    preview = compute_cache_preview(old_params, new_params)

    param_names = [p["param"] for p in preview["changed_params"]]
    assert "trajectory_root_celltype" in param_names
    assert "07" in preview["rerun_stages"]
    assert "01" in preview["reused_stages"]
    assert "02" in preview["reused_stages"]
    assert "03" in preview["reused_stages"]
    assert "04" in preview["reused_stages"]
    assert "09" in preview["reused_stages"]
    assert "11" in preview["reused_stages"]
