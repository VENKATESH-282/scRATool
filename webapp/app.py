"""
scRNA-seq Pipeline Web Application
Inspired by scRun — Flask-based interface for the 11-part Nextflow pipeline
"""
import os, json, uuid, time, subprocess, threading, glob
from pathlib import Path
from flask import Flask, render_template, request, jsonify, Response, send_file
from flask_cors import CORS

# ── Paths ──────────────────────────────────────────────────────────────────
BASE_DIR     = Path(__file__).parent
PIPELINE_DIR = BASE_DIR.parent          # nextflow/ lives here
NEXTFLOW_DIR = PIPELINE_DIR / "nextflow"
RESULTS_DIR  = NEXTFLOW_DIR / "results"
SESSIONS_DIR = BASE_DIR / "sessions"
UPLOADS_DIR  = BASE_DIR / "uploads"
for d in [SESSIONS_DIR, UPLOADS_DIR, RESULTS_DIR]:
    d.mkdir(parents=True, exist_ok=True)

# ── Nextflow binary auto-detection ────────────────────────────────────────
def _find_nextflow():
    """Find nextflow binary — checks PATH, conda envs, and common install locations."""
    import shutil
    nf = shutil.which("nextflow")
    if nf:
        return nf
    # Common locations
    for candidate in [
        Path.home() / "miniconda3/bin/nextflow",
        Path.home() / "anaconda3/bin/nextflow",
        Path("/usr/local/bin/nextflow"),
        Path("/opt/nextflow/nextflow"),
        Path("/usr/bin/nextflow"),
        Path.home() / ".local/bin/nextflow",
    ]:
        if candidate.exists():
            return str(candidate)
    return "nextflow"   # fallback — let the shell error speak for itself

NEXTFLOW_BIN = _find_nextflow()

# ── Server config file (stores host/user/dir — NOT password) ──────────────
SERVER_CONFIG_FILE = NEXTFLOW_DIR / ".server_config.json"
_DEFAULT_SERVER_CFG = {
    "host": "",
    "user": "",
    "remote_dir": "",
    "ssh_key": "",        # optional: path to identity file
    "export_dir": "",     # optional: path to export results to locally
}

def _load_server_cfg():
    if SERVER_CONFIG_FILE.exists():
        try:
            return {**_DEFAULT_SERVER_CFG, **json.loads(SERVER_CONFIG_FILE.read_text())}
        except Exception:
            pass
    return dict(_DEFAULT_SERVER_CFG)

def _save_server_cfg(cfg):
    SERVER_CONFIG_FILE.write_text(json.dumps(cfg, indent=2))

# ── App Factory ────────────────────────────────────────────────────────────
app = Flask(__name__)
app.secret_key = os.urandom(24)
CORS(app)

# ── In-memory pipeline state ───────────────────────────────────────────────
pipeline_state = {
    "status":   "idle",          # idle | running | done | failed
    "pid":      None,
    "logs":     [],
    "progress": {},              # step → status
    "session":  None,
}
_log_lock = threading.Lock()

# ── Step → results directory mapping ──────────────────────────────────────
STEP_DIRS = {
    "data":          "00_fastq",
    "cellranger":    "01_cellranger",
    "qc":            "02_qc",
    "integration":   "03_clustering",
    "annotation":    "04_annotation",
    "de":            "05_de",
    "exploration":   "06_exploration",
    "trajectory":    "07_trajectory",
    "pdx":           "08_pdx",
    "cellchat":      "09_cellchat",
    "nichenet":      "10_nichenet",
    "copykat":       "11_copykat",
    "enrichment":    "12_enrichment",
}

# ══════════════════════════════════════════════════════════════════════════
#  ROUTES — Pages
# ══════════════════════════════════════════════════════════════════════════
@app.route("/")
def index():
    return render_template("index.html")


# ══════════════════════════════════════════════════════════════════════════
#  API — Session Management
# ══════════════════════════════════════════════════════════════════════════
@app.route("/api/session/new", methods=["POST"])
def new_session():
    token = str(uuid.uuid4())[:8].upper()
    pipeline_state["session"] = token
    sess_dir = SESSIONS_DIR / token
    sess_dir.mkdir(exist_ok=True)
    return jsonify({"token": token})


@app.route("/api/session/load", methods=["POST"])
def load_session():
    token = request.json.get("token", "").strip().upper()
    sess_dir = SESSIONS_DIR / token
    if not sess_dir.exists():
        return jsonify({"error": "Session not found"}), 404
    pipeline_state["session"] = token
    meta_file = sess_dir / "meta.json"
    meta = json.loads(meta_file.read_text()) if meta_file.exists() else {}
    return jsonify({"token": token, "meta": meta})


@app.route("/api/session/save", methods=["POST"])
def save_session():
    token = pipeline_state.get("session")
    if not token:
        return jsonify({"error": "No active session"}), 400
    sess_dir = SESSIONS_DIR / token
    sess_dir.mkdir(exist_ok=True)
    meta = request.json or {}
    meta["saved_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    (sess_dir / "meta.json").write_text(json.dumps(meta, indent=2))
    return jsonify({"ok": True, "token": token})


# ══════════════════════════════════════════════════════════════════════════
#  API — File Upload
# ══════════════════════════════════════════════════════════════════════════
@app.route("/api/upload/samples", methods=["POST"])
def upload_samples():
    if "file" not in request.files:
        return jsonify({"error": "No file"}), 400
    f = request.files["file"]
    dest = UPLOADS_DIR / f.filename
    f.save(dest)
    # Parse CSV for preview
    import csv
    rows = []
    with open(dest) as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            rows.append(row)
    return jsonify({"filename": f.filename, "rows": rows, "count": len(rows)})


# ══════════════════════════════════════════════════════════════════════════
#  API — Pipeline Launch & Status
# ══════════════════════════════════════════════════════════════════════════
# ── Server profile set ────────────────────────────────────────────────────
SERVER_PROFILES = {"server", "tigshp", "hpc_small", "hpc_large"}


@app.route("/api/server/config", methods=["GET"])
def get_server_config():
    return jsonify(_load_server_cfg())


@app.route("/api/server/config", methods=["POST"])
def save_server_config():
    cfg = _load_server_cfg()
    body = request.json or {}
    for key in ["host", "user", "remote_dir", "ssh_key", "export_dir"]:
        if key in body:
            val = body[key].strip()
            # If the user accidentally types user@host in the host field, split it
            if key == "host" and "@" in val:
                parts = val.split("@", 1)
                cfg["user"] = parts[0]
                cfg["host"] = parts[1]
            else:
                cfg[key] = val
    _save_server_cfg(cfg)
    return jsonify({"ok": True, "config": cfg})


def _run_via_ssh_wrapper(mode_flag, profile, extra_flags, csv_path,
                         geo_dir_path=None, ssh_password="", outdir_name="results"):
    """Write trigger files and invoke ssh_wrapper.py for server-profile runs."""
    cfg = _load_server_cfg()
    user_host  = f"{cfg['user']}@{cfg['host']}"
    server_dir = cfg["remote_dir"]
    csv_basename = Path(csv_path).name

    # Build remote nextflow command (replace local path with remote path)
    remote_mode_flag = mode_flag.replace(str(csv_path), f"{server_dir}/{csv_basename}")
    nf_cmd_remote = (
        f"bash -ic 'cd {server_dir} && "
        f"nextflow run main.nf {remote_mode_flag} "
        f"--outdir {outdir_name} -profile {profile} {extra_flags} -resume'"
    )

    # Write control files
    (NEXTFLOW_DIR / "ui_pass.txt").write_text(ssh_password)
    (NEXTFLOW_DIR / "ui_cmd.txt").write_text(nf_cmd_remote)
    (NEXTFLOW_DIR / "ui_outdir.txt").write_text(outdir_name)

    # Transfer spec: csv filename ; geo_dir (or empty)
    geo_path_str = str(geo_dir_path) if geo_dir_path and Path(geo_dir_path).exists() else ""
    (NEXTFLOW_DIR / "ui_transfer.txt").write_text(f"{csv_basename};{geo_path_str}")

    wrapper    = NEXTFLOW_DIR / "ssh_wrapper.py"
    venv_python = BASE_DIR / "venv" / "bin" / "python3"
    python_bin  = str(venv_python) if venv_python.exists() else "python3"

    proc = subprocess.Popen(
        f"{python_bin} {wrapper}",
        shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1, cwd=str(NEXTFLOW_DIR)
    )
    return proc


@app.route("/api/pipeline/launch", methods=["POST"])
def launch_pipeline():
    global pipeline_state
    if pipeline_state["status"] == "running":
        return jsonify({"error": "Pipeline already running"}), 400

    data        = request.json or {}
    mode        = data.get("mode", "matrix")
    samples_csv = data.get("samples_csv", "samples_test.csv")
    profile     = data.get("profile", "local")
    profile     = data.get("profile", "local")
    extra_flags = data.get("extra_flags", "")
    ssh_password= data.get("ssh_password", "")   # only used for server profiles
    outdir_name = data.get("outdir_name", "results")

    # Build mode flag — resolve full path to CSV
    csv_full = NEXTFLOW_DIR / samples_csv if not Path(samples_csv).is_absolute() else Path(samples_csv)
    if mode == "input":
        mode_flag = f"--input {csv_full}"
    elif mode == "seurat_rds":
        mode_flag = f"--seurat_rds {csv_full}"
    else:
        mode_flag = f"--matrix {csv_full}"

    is_server = profile in SERVER_PROFILES

    if is_server:
        cmd_display = f"[server: {_load_server_cfg()['user']}@{_load_server_cfg()['host']}] nextflow run main.nf --outdir {outdir_name} ..."
    else:
        cmd_display = (
            f"cd {NEXTFLOW_DIR} && {NEXTFLOW_BIN} run main.nf {mode_flag} "
            f"--outdir {outdir_name} -profile {profile} {extra_flags} -resume"
        )

    pipeline_state["status"]   = "running"
    pipeline_state["logs"]     = [f"[{_ts()}] Launching pipeline...", f"[{_ts()}] Profile: {profile}",
                                   f"[{_ts()}] CMD: {cmd_display}"]
    pipeline_state["progress"] = {}
    pipeline_state["current_csv"] = str(csv_full)
    (NEXTFLOW_DIR / ".current_csv").write_text(str(csv_full))

    def _run():
        if is_server:
            # Resolve password: request body first, then stored .server_password file
            resolved_pwd = ssh_password
            if not resolved_pwd:
                pass_store = NEXTFLOW_DIR / ".server_password"
                if pass_store.exists():
                    resolved_pwd = pass_store.read_text().strip()

            if not resolved_pwd:
                with _log_lock:
                    pipeline_state["logs"].append(f"[{_ts()}] ✗ No SSH password provided or saved.")
                    pipeline_state["logs"].append(f"[{_ts()}] Go to Settings → Server Connection and save your password.")
                pipeline_state["status"] = "failed"
                return
            proc = _run_via_ssh_wrapper(mode_flag, profile, extra_flags, csv_full,
                                        ssh_password=resolved_pwd, outdir_name=outdir_name)
        else:
            local_cmd = (
                f"cd {NEXTFLOW_DIR} && {NEXTFLOW_BIN} run main.nf {mode_flag} "
                f"--outdir {outdir_name} -profile {profile} {extra_flags} -resume"
            )
            proc = subprocess.Popen(
                local_cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1
            )
        pipeline_state["pid"] = proc.pid
        for line in proc.stdout:
            line = line.rstrip()
            with _log_lock:
                pipeline_state["logs"].append(f"[{_ts()}] {line}")
                _parse_progress(line)
        proc.wait()
        
        with _log_lock:
            if proc.returncode == 0:
                pipeline_state["status"] = "done"
                if not is_server:
                    pipeline_state["logs"].append(f"[{_ts()}] ✔ Local pipeline execution completed successfully.")
            else:
                pipeline_state["status"] = "failed"
                pipeline_state["logs"].append(f"[{_ts()}] ✗ Pipeline execution failed with exit code {proc.returncode}.")
        pipeline_state["pid"]    = None

    threading.Thread(target=_run, daemon=True).start()
    return jsonify({"ok": True, "cmd": cmd_display})


@app.route("/api/pipeline/status")
def pipeline_status():
    return jsonify({
        "status":   pipeline_state["status"],
        "progress": pipeline_state["progress"],
        "log_count": len(pipeline_state["logs"]),
    })


@app.route("/api/pipeline/stop", methods=["POST"])
def stop_pipeline():
    import signal
    pid = pipeline_state.get("pid")
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    pipeline_state["status"] = "idle"
    pipeline_state["pid"]    = None
    return jsonify({"ok": True})


@app.route("/api/geo/download", methods=["POST"])
def download_geo():
    """Download GEO dataset, auto-detect matrix format, build sample sheet, optionally launch pipeline."""
    global pipeline_state
    if pipeline_state["status"] == "running":
        return jsonify({"error": "A pipeline or download is already running"}), 400

    data     = request.json or {}
    geo_id   = data.get("geo_id", "").strip().upper()
    auto_run = data.get("auto_run", False)
    profile  = data.get("profile", "local")
    extra_flags = data.get("extra_flags", "")

    if not geo_id:
        return jsonify({"error": "No GEO ID provided"}), 400

    pipeline_state["status"]   = "running"
    pipeline_state["logs"]     = [f"[{_ts()}] ── GEO Download Started: {geo_id} ──"]
    pipeline_state["progress"] = {"GEO_DOWNLOAD": 0}
    pipeline_state["pid"]      = None

    def _geo_worker():
        import tarfile, gzip, shutil, re, csv as csv_mod

        def _log(msg):
            with _log_lock:
                pipeline_state["logs"].append(f"[{_ts()}] {msg}")

        try:
            # ── Step 1: Parse GEO soft file to get metadata ───────────────
            _log(f"Fetching GEO metadata for {geo_id}...")
            import urllib.request
            # Use uploads dir (writable by Flask user) instead of results/ (may be root-owned)
            geo_base = UPLOADS_DIR / "GEO_Downloads"
            geo_base.mkdir(parents=True, exist_ok=True)
            geo_dir  = geo_base / geo_id
            geo_dir.mkdir(parents=True, exist_ok=True)

            # ── Step 2: Download supplementary files via FTP ──────────────
            _log("Connecting to NCBI GEO FTP to list supplementary files...")
            import ftplib, io
            ftp_base = f"/geo/series/{geo_id[:-3]}nnn/{geo_id}/suppl/"
            ftp_host = "ftp.ncbi.nlm.nih.gov"

            # ── Step 2: Download supplementary files via HTTPS ──────────────
            _log("Connecting to NCBI GEO HTTPS to list supplementary files...")
            import urllib.request, re
            https_base = f"https://ftp.ncbi.nlm.nih.gov/geo/series/{geo_id[:-3]}nnn/{geo_id}/suppl/"
            
            try:
                req = urllib.request.Request(https_base, headers={'User-Agent': 'Mozilla/5.0'})
                with urllib.request.urlopen(req, timeout=30) as response:
                    html = response.read().decode('utf-8')
                # Extract hrefs
                files = re.findall(r'<a href="([^"]+)">', html)
                # Filter out Parent Directory or sort links
                files = [f for f in files if f != "filelist.txt" and not f.startswith("/") and not f.startswith("?") and not f.startswith("http")]
            except Exception as e:
                _log(f"HTTPS listing failed: {e}")
                files = []

            _log(f"Found {len(files)} supplementary file(s): {', '.join(files)}")
            
            # Download each file
            import requests as req_lib
            # Make sure we use the https_base for the download URL
            ftp_base = f"/geo/series/{geo_id[:-3]}nnn/{geo_id}/suppl/"
            downloaded = []
            total = len(files)
            for i, fname in enumerate(files):
                dest = geo_dir / fname
                if dest.exists() and dest.stat().st_size > 1000:
                    _log(f"  [skip] {fname} (already downloaded)")
                    downloaded.append(dest)
                    continue
                url = f"https://ftp.ncbi.nlm.nih.gov{ftp_base}{fname}"
                _log(f"  Downloading ({i+1}/{total}): {fname}")
                try:
                    r = req_lib.get(url, stream=True, timeout=300)
                    r.raise_for_status()
                    with open(dest, "wb") as fh:
                        for chunk in r.iter_content(chunk_size=1024*1024):
                            fh.write(chunk)
                    downloaded.append(dest)
                    _log(f"  ✔ {fname} ({dest.stat().st_size // 1024} KB)")
                except Exception as e:
                    _log(f"  ✗ Failed to download {fname}: {e}")

            pipeline_state["progress"]["GEO_DOWNLOAD"] = 50

            # ── Step 3: Unpack archives ───────────────────────────────────
            _log("Unpacking downloaded archives...")
            for f in list(downloaded):
                fname = f.name
                if fname.endswith(".tar"):
                    _log(f"  Extracting {fname}...")
                    with tarfile.open(f) as tf:
                        tf.extractall(geo_dir)
                    f.unlink()
                elif fname.endswith(".tar.gz") or fname.endswith(".tgz"):
                    _log(f"  Extracting {fname}...")
                    with tarfile.open(f, "r:gz") as tf:
                        tf.extractall(geo_dir)
                    f.unlink()

            pipeline_state["progress"]["GEO_DOWNLOAD"] = 70

            # ── Step 4: Detect matrix format and build sample sheet ───────
            _log("Detecting matrix format...")
            all_files = list(geo_dir.rglob("*"))

            # Priority 1: 10X MEX directories (barcodes/features/matrix triplet)
            barcode_files = [f for f in all_files if "barcode" in f.name.lower() and f.is_file()]
            mex_dirs = set()
            if barcode_files:
                for bf in barcode_files:
                    parent = bf.parent
                    has_matrix = any("matrix" in x.name.lower() for x in parent.iterdir())
                    has_features = any("feature" in x.name.lower() or "gene" in x.name.lower() for x in parent.iterdir())
                    if has_matrix and has_features:
                        mex_dirs.add(str(parent))
                _log(f"  Detected {len(mex_dirs)} 10X MEX directory/ies")

            # Priority 2: H5 files
            h5_files = [f for f in all_files if f.suffix == ".h5" and f.is_file()]

            # Priority 3: DGE / count CSV / TSV files
            csv_files = [f for f in all_files if re.search(r"\.(dge|counts?|matrix|raw)\.(txt|csv)(\.gz)?$", f.name, re.I) and f.is_file()]
            gz_csv_files = [f for f in all_files if f.name.endswith("_raw_counts.csv.gz") or f.name.endswith("_counts.csv.gz")]
            if gz_csv_files:
                csv_files = gz_csv_files
                
            if not csv_files:
                # Fallback: any plain .txt.gz or .csv.gz files
                csv_files = [f for f in all_files if (f.name.endswith(".txt.gz") or f.name.endswith(".csv.gz")) and f.is_file()]

            # Build sample rows
            rows = []

            def _extract_sample_id(filepath):
                fname = Path(filepath).name
                # Remove common suffixes
                sid = re.sub(r"_?(barcodes|matrix|features|raw_counts?|dge|counts?).*$", "", fname, flags=re.I)
                sid = re.sub(r"\.(tar|gz|h5|csv|txt)$", "", sid, flags=re.I)
                # Remove GSM prefix duplication
                sid = re.sub(r"^(GSM\d+_?)", "", sid, flags=re.I) or sid
                return sid.strip("_") or fname

            if mex_dirs:
                mode_detected = "matrix"
                for d in sorted(mex_dirs):
                    sid = _extract_sample_id(Path(d).name)
                    rows.append({"sample_id": sid, "matrix_dir": d, "condition": "GEO", "patient_id": sid})
            elif h5_files:
                mode_detected = "matrix"
                for f in sorted(h5_files):
                    sid = _extract_sample_id(f)
                    rows.append({"sample_id": sid, "matrix_dir": str(f), "condition": "GEO", "patient_id": sid})
            elif csv_files:
                mode_detected = "matrix"
                for f in sorted(csv_files):
                    sid = _extract_sample_id(f)
                    rows.append({"sample_id": sid, "csv_file": str(f), "condition": "GEO", "patient_id": sid})
            else:
                _log("⚠ Could not auto-detect matrix format. Please inspect downloaded files and build sample sheet manually.")
                pipeline_state["status"] = "idle"
                pipeline_state["progress"]["GEO_DOWNLOAD"] = 100
                return

            # Write sample sheet
            csv_out = NEXTFLOW_DIR / f"samples_{geo_id.lower()}.csv"
            cols = list(rows[0].keys())
            with open(csv_out, "w", newline="") as fh:
                writer = csv_mod.DictWriter(fh, fieldnames=cols)
                writer.writeheader()
                writer.writerows(rows)

            _log(f"✔ Sample sheet written: {csv_out.name} ({len(rows)} samples)")
            _log(f"  Format detected: {mode_detected}")
            pipeline_state["progress"]["GEO_DOWNLOAD"] = 100

            # ── Step 5: Optionally launch the pipeline ────────────────────
            if auto_run:
                _log(f"── Auto-launching Nextflow pipeline ──")
                _log(f"  Profile: {profile} | Mode: {mode_detected}")
                _log(f"  Sample sheet: {csv_out.name}")

                if mode_detected == "matrix":
                    mode_flag = f"--matrix {csv_out}"
                else:
                    mode_flag = f"--input {csv_out}"

                # Server-based profiles → use ssh_wrapper.py exactly like the main pipeline
                SERVER_PROFILES = {"server", "tigshp", "hpc_small", "hpc_large"}
                if profile in SERVER_PROFILES:
                    server_dir = ""  # Configure via Settings → Server Connection
                    csv_basename = csv_out.name

                    nf_cmd_remote = (
                        f"bash -ic 'cd {server_dir} && "
                        f"nextflow run main.nf {mode_flag.replace(str(csv_out), f'{server_dir}/{csv_basename}')} "
                        f"--outdir results -profile {profile} {extra_flags} -resume'"
                    )

                    _log(f"  Server mode: writing trigger files for ssh_wrapper.py")

                    # Write password file
                    pass_file  = NEXTFLOW_DIR / "ui_pass.txt"
                    cmd_file   = NEXTFLOW_DIR / "ui_cmd.txt"
                    xfer_file  = NEXTFLOW_DIR / "ui_transfer.txt"

                    # Read password from ui_pass.txt if it exists from a prior run, else prompt
                    # For the webapp flow we rely on the user having set the password via Settings
                    stored_pass = ""
                    pass_store  = NEXTFLOW_DIR / ".server_password"
                    if pass_store.exists():
                        stored_pass = pass_store.read_text().strip()

                    if not stored_pass:
                        _log("⚠ No server password configured. Please set it in Settings → Server Password.")
                        pipeline_state["status"] = "idle"
                        pipeline_state["pid"]    = None
                        return

                    pass_file.write_text(stored_pass)
                    cmd_file.write_text(nf_cmd_remote)

                    # Transfer file: CSV path (relative to nextflow dir) ; geo_dir absolute path
                    rel_csv = csv_out.name   # relative to NEXTFLOW_DIR
                    xfer_file.write_text(f"{rel_csv};{str(geo_dir)}")

                    _log(f"  Invoking ssh_wrapper.py to upload data and run on server...")
                    wrapper = NEXTFLOW_DIR / "ssh_wrapper.py"
                    proc = subprocess.Popen(
                        f"python3 {wrapper}",
                        shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, bufsize=1, cwd=str(NEXTFLOW_DIR)
                    )
                    pipeline_state["pid"] = proc.pid
                    for line in proc.stdout:
                        line = line.rstrip()
                        with _log_lock:
                            pipeline_state["logs"].append(f"[{_ts()}] {line}")
                            _parse_progress(line)
                    proc.wait()
                    pipeline_state["status"] = "done" if proc.returncode == 0 else "failed"
                    pipeline_state["pid"]    = None
                    _log(f"── Server pipeline finished: {pipeline_state['status']} ──")

                else:
                    # Local / laptop / docker → run nextflow directly
                    nf_cmd = (
                        f"cd {NEXTFLOW_DIR} && nextflow run main.nf {mode_flag} "
                        f"--outdir results -profile {profile} {extra_flags} -resume"
                    )
                    _log(f"CMD: {nf_cmd}")
                    proc = subprocess.Popen(
                        nf_cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, bufsize=1
                    )
                    pipeline_state["pid"] = proc.pid
                    for line in proc.stdout:
                        line = line.rstrip()
                        with _log_lock:
                            pipeline_state["logs"].append(f"[{_ts()}] {line}")
                            _parse_progress(line)
                    proc.wait()
                    pipeline_state["status"] = "done" if proc.returncode == 0 else "failed"
                    pipeline_state["pid"]    = None
                    _log(f"── Pipeline finished: {pipeline_state['status']} ──")
            else:
                pipeline_state["status"] = "idle"
                pipeline_state["pid"]    = None
                _log(f"── Download complete. Select '{csv_out.name}' in the Data tab and click Launch Pipeline. ──")

        except Exception as exc:
            import traceback
            _log(f"✗ GEO Download error: {exc}")
            _log(traceback.format_exc())
            pipeline_state["status"] = "failed"
            pipeline_state["pid"]    = None

    threading.Thread(target=_geo_worker, daemon=True).start()
    return jsonify({"ok": True, "message": f"Started download for {geo_id}"})


# ── SSE log stream ─────────────────────────────────────────────────────────
@app.route("/api/pipeline/logs")
def stream_logs():
    def generate():
        sent = 0
        while True:
            with _log_lock:
                batch = pipeline_state["logs"][sent:]
            for line in batch:
                yield f"data: {json.dumps(line)}\n\n"
            sent += len(batch)
            if pipeline_state["status"] not in ("running",) and sent >= len(pipeline_state["logs"]):
                yield "data: __DONE__\n\n"
                break
            time.sleep(0.4)
    return Response(generate(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


# ══════════════════════════════════════════════════════════════════════════
#  API — Plots & Results
# ══════════════════════════════════════════════════════════════════════════
@app.route("/api/plots/<step>")
def get_plots(step):
    """Return list of PNG paths for a given step."""
    step_dir_name = STEP_DIRS.get(step)
    if not step_dir_name:
        return jsonify({"plots": [], "csvs": []})

    run_dir = request.args.get("run_dir", "results")
    if not run_dir or ".." in run_dir: run_dir = "results"
    target_results_dir = NEXTFLOW_DIR / run_dir

    base = target_results_dir / step_dir_name
    plots, csvs = [], []

    if base.exists():
        for png in sorted(base.rglob("*.png")):
            rel = str(png.relative_to(target_results_dir))
            plots.append(rel)
            
        for cfile in sorted(base.rglob("*.csv")):
            rel = str(cfile.relative_to(target_results_dir))
            csvs.append(rel)

    return jsonify({"step": step, "plots": plots, "csvs": csvs,
                    "ready": len(plots) > 0})


@app.route("/results/<path:filename>")
def serve_result(filename):
    """Serve a file from the results directory."""
    run_dir = request.args.get("run_dir", "results")
    if not run_dir or ".." in run_dir: run_dir = "results"
    full = NEXTFLOW_DIR / run_dir / filename
    if not full.exists():
        return "Not found", 404
    return send_file(full)


@app.route("/api/results/<step>/table")
def results_table(step):
    """Return CSV data as JSON for the given step."""
    run_dir = request.args.get("run_dir", "results")
    if not run_dir or ".." in run_dir: run_dir = "results"
    
    step_dir_name = STEP_DIRS.get(step, "")
    base = NEXTFLOW_DIR / run_dir / step_dir_name
    tables = {}
    if base.exists():
        for csv_path in sorted(base.rglob("*.csv")):
            import csv as csv_mod
            rows = []
            try:
                with open(csv_path, newline="") as fh:
                    reader = csv_mod.DictReader(fh)
                    for i, row in enumerate(reader):
                        if i > 200: break
                        rows.append(dict(row))
                if csv_path.name not in tables:
                    tables[csv_path.name] = []
                tables[csv_path.name].extend(rows)
            except Exception as e:
                tables[csv_path.name] = [{"error": str(e)}]
    return jsonify(tables)


# ══════════════════════════════════════════════════════════════════════════
#  API — Pipeline Config
# ══════════════════════════════════════════════════════════════════════════
@app.route("/api/config")
def get_config():
    """Return available sample CSVs and profiles."""
    csvs = [f.name for f in NEXTFLOW_DIR.glob("*.csv")]
    return jsonify({
        "sample_csvs": csvs,
        "profiles":    ["laptop", "local", "server", "hpc_small", "hpc_large", "docker"],
        "modes":       ["matrix", "input", "seurat_rds"],
        "results_dir": str(RESULTS_DIR),
        "pipeline_dir": str(NEXTFLOW_DIR),
    })


@app.route("/api/samples/list")
def list_samples():
    """List sample CSVs in the nextflow dir."""
    result = []
    for f in NEXTFLOW_DIR.glob("*.csv"):
        result.append({"name": f.name, "path": str(f)})
    return jsonify(result)

@app.route("/api/runs")
def list_runs():
    """List all available result directories."""
    runs = []
    for d in NEXTFLOW_DIR.iterdir():
        if d.is_dir() and (d.name.startswith("results") or (d / "02_qc").exists() or (d / "05_de").exists()):
            runs.append(d.name)
    return jsonify(sorted(runs))


# ══════════════════════════════════════════════════════════════════════════
#  API — Report Generation
# ══════════════════════════════════════════════════════════════════════════
# ══════════════════════════════════════════════════════════════════════════
#  API — Server Password (used by ssh_wrapper.py for server profiles)
# ══════════════════════════════════════════════════════════════════════════
@app.route("/api/server/password", methods=["POST"])
def save_server_password():
    """Securely store the SSH server password for server-profile pipeline runs."""
    pwd = (request.json or {}).get("password", "").strip()
    if not pwd:
        return jsonify({"error": "Password cannot be empty"}), 400
    pass_store = NEXTFLOW_DIR / ".server_password"
    pass_store.write_text(pwd)
    pass_store.chmod(0o600)  # Only owner can read
    return jsonify({"ok": True})


@app.route("/api/server/password/status")
def server_password_status():
    """Check if a server password is saved."""
    pass_store = NEXTFLOW_DIR / ".server_password"
    return jsonify({"configured": pass_store.exists() and pass_store.stat().st_size > 0})


@app.route("/api/server/clear-password", methods=["POST"])
def clear_server_password():
    """Remove the stored server password."""
    pass_store = NEXTFLOW_DIR / ".server_password"
    if pass_store.exists():
        pass_store.unlink()
    return jsonify({"ok": True})


@app.route("/api/server/test", methods=["POST"])
def test_server_connection():
    """Test SSH connection to the configured server using the stored password."""
    pass_store = NEXTFLOW_DIR / ".server_password"
    if not pass_store.exists():
        return jsonify({"ok": False, "error": "No password saved. Go to Settings → Server Connection."})

    cfg = _load_server_cfg()
    user_host = f"{cfg['user']}@{cfg['host']}"
    password  = pass_store.read_text().strip()

    try:
        import pexpect
        child = pexpect.spawn(
            f'ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 {user_host} "echo SSH_OK && hostname"',
            encoding='utf-8', timeout=20
        )
        idx = child.expect(['[Pp]assword:', 'SSH_OK', pexpect.EOF, pexpect.TIMEOUT])
        if idx == 0:
            child.sendline(password)
            child.expect(pexpect.EOF, timeout=15)
            output = child.before.strip()
        elif idx == 1:
            child.expect(pexpect.EOF, timeout=10)
            output = ("SSH_OK " + child.before).strip()
        else:
            return jsonify({"ok": False, "error": "Connection timed out or refused", "host": user_host})

        if "SSH_OK" in output or output:
            return jsonify({"ok": True, "host": user_host, "output": output.replace("SSH_OK", "").strip() or "Connected"})
        return jsonify({"ok": False, "error": f"Unexpected response: {output}", "host": user_host})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e), "host": user_host})


@app.route("/api/report/generate", methods=["POST"])
def generate_report():
    """Generate an HTML analysis report from all completed steps."""
    run_dir = request.args.get("run_dir", "results")
    if not run_dir or ".." in run_dir: run_dir = "results"
    target_results_dir = NEXTFLOW_DIR / run_dir

    sections = []
    for step, step_dir in STEP_DIRS.items():
        base = target_results_dir / step_dir
        if not base.exists():
            continue
        plots = list(base.rglob("*.png"))
        if not plots:
            continue
        section_html = f'<h2 class="report-section">{step.upper().replace("_"," ")}</h2>\n<div class="report-plots">\n'
        for p in sorted(plots)[:8]:
            rel = p.relative_to(target_results_dir)
            section_html += f'  <img src="/results/{rel}?run_dir={run_dir}" class="report-img" />\n'
        section_html += "</div>\n"
        sections.append(section_html)

    if not sections:
        return jsonify({"error": "No results found. Run the pipeline first."}), 400

    html = _build_report_html(sections)
    report_path = target_results_dir / "analysis_report.html"
    report_path.write_text(html)
    return jsonify({"ok": True, "path": str(report_path)})


@app.route("/api/report/download")
def download_report():
    run_dir = request.args.get("run_dir", "results")
    if not run_dir or ".." in run_dir: run_dir = "results"
    report_path = NEXTFLOW_DIR / run_dir / "analysis_report.html"
    if not report_path.exists():
        return "Report not generated yet. Use /api/report/generate first.", 404
    return send_file(report_path, as_attachment=True, download_name=f"{run_dir}_report.html")


# ══════════════════════════════════════════════════════════════════════════
#  Helpers
# ══════════════════════════════════════════════════════════════════════════
def _ts():
    return time.strftime("%H:%M:%S")


def _parse_progress(line: str):
    """Parse Nextflow output to extract process completion status."""
    import re
    # e.g. "[100%] 12 of 12 ✔" or "process > QC_FILTERING (Sample_1) [100%]"
    m = re.search(r'(\w+)\s+\[(\d+)%\]', line)
    if m:
        pipeline_state["progress"][m.group(1)] = int(m.group(2))
    # Detect completed process
    m2 = re.search(r'process\s+>\s+(\w+).*\[100%\]', line)
    if m2:
        pipeline_state["progress"][m2.group(1)] = 100


def _build_report_html(sections):
    body = "\n".join(sections)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>scRNA-seq Analysis Report</title>
<style>
  body {{font-family: 'Segoe UI', sans-serif; background: #0f0f1a; color: #e0e0e0; margin: 0; padding: 2rem;}}
  h1 {{color: #a78bfa; text-align: center; font-size: 2rem; margin-bottom: 0.5rem;}}
  .subtitle {{text-align: center; color: #94a3b8; margin-bottom: 2rem;}}
  .report-section {{color: #7dd3fc; border-bottom: 1px solid #334155; padding-bottom: 0.5rem; margin-top: 2rem;}}
  .report-plots {{display: flex; flex-wrap: wrap; gap: 1rem; margin: 1rem 0;}}
  .report-img {{width: calc(50% - 0.5rem); border-radius: 8px; border: 1px solid #334155; background: #1e293b;}}
  @media (max-width: 800px) {{ .report-img {{ width: 100%; }} }}
</style>
</head>
<body>
<h1>🔬 scRNA-seq Analysis Report</h1>
<p class="subtitle">Generated {time.strftime('%Y-%m-%d %H:%M:%S')} · Powered by venkatbioinfo/v-scrna-seq-pipeline</p>
{body}
</body>
</html>"""


# ══════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
    print(f"\n  🔬 scRNA-seq Pipeline UI  →  http://localhost:{port}\n")
    app.run(host="0.0.0.0", port=port, debug=True, threaded=True)
