import os
import time
import json
import threading
from datetime import datetime
from typing import Dict, Any, Optional

from app.db import create_run, update_run, get_run, get_cluster_profile
from app.remote.ssh_manager import SSHManager
from app.remote.file_manager import RemoteFileManager
from app.remote.process_manager import RemoteProcessManager
from app.config import RUNS_DIR, PIPELINE_DIR

_REMOTE_MONITOR_THREAD: Optional[threading.Thread] = None
_MONITOR_LOCK = threading.Lock()
_STOP_MONITOR = False

def start_remote_run(run_id: str, name: str, profile: str, resume: bool,
                     stub_run: bool, params: Dict[str, Any],
                     session_token: Optional[str],
                     cluster_profile_id: int, remote_dir: str,
                     env_init: str) -> Dict[str, Any]:
    
    prof = get_cluster_profile(cluster_profile_id)
    if not prof:
        raise ValueError("Cluster profile not found")

    with SSHManager(
        host=prof["host"], user=prof["user"], port=prof["port"],
        auth_method=prof["auth_method"], password=prof.get("password"),
        private_key_path=prof.get("private_key_path")
    ) as ssh:
        file_mgr = RemoteFileManager(ssh)
        proc_mgr = RemoteProcessManager(ssh)
        
        # Ensure remote project dir
        ssh.execute_command(f"mkdir -p {remote_dir}")
        
        # Upload params.json and samplesheet if needed
        local_params_path = RUNS_DIR / run_id / "params.json"
        local_params_path.parent.mkdir(parents=True, exist_ok=True)
        
        # Check for samplesheet
        if "samplesheet" in params:
            import os as local_os
            ss_path = params["samplesheet"]
            if local_os.path.exists(ss_path):
                remote_ss = f"{remote_dir}/samples.csv"
                file_mgr.upload_file(ss_path, remote_ss)
                params["samplesheet"] = remote_ss
        


        # Fix absolute paths for remote execution
        if "annotation_map" in params:
            import os as local_os
            am_path = params["annotation_map"]
            if local_os.path.exists(am_path):
                remote_am = f"{remote_dir}/cluster_annotations.csv"
                file_mgr.upload_file(am_path, remote_am)
                params["annotation_map"] = remote_am
        if "models_dir" in params:
            params["models_dir"] = f"{remote_dir}/models"
        if "outdir" in params:
            params["outdir"] = f"{remote_dir}/results"
            
        with open(local_params_path, "w") as f:


            json.dump(params, f, indent=2)
            
        file_mgr.upload_file(str(local_params_path), f"{remote_dir}/params.json")
        
        # Initialize stages remotely
        from app.runner import ALL_STAGES
        stages_status = {s["id"]: "PENDING" for s in ALL_STAGES}
        local_stages_path = RUNS_DIR / run_id / "stages.json"
        with open(local_stages_path, "w") as f:
            json.dump(stages_status, f, indent=2)
            
        file_mgr.upload_file(str(local_stages_path), f"{remote_dir}/stages.json")
        
        # Create a python script to tail logs and update stages.json remotely
        # For simplicity, we can just run nextflow and parse logs locally during monitoring,
        # or just let nextflow run and download stages.json if we had a remote parser.
        # Let's keep it simple: we run nextflow. We'll parse the log in the python monitor loop.
        
        # Build command
        cmd = [
            "nextflow", "run", "main.nf", "-ansi-log", "false",
            "-params-file", "params.json",
            "-profile", profile
        ]
        if resume:
            cmd.append("-resume")
        if stub_run:
            cmd.append("-stub-run")
            
        # The user said: "The application should NOT rewrite the analysis pipeline... reuse the existing commands... ssh user@cluster cd /remote/project/ <existing command>"
        # Wait, the pipeline directory (main.nf) must exist on the remote cluster!
        # The user said: "If the input is on my local machine, provide Upload to Cluster... The application should transfer the required files".
        # We also need to transfer the pipeline directory `pipeline/` to the remote cluster! Or assume the user cloned it.
        # Actually, let's just upload `main.nf`, `nextflow.config` and `bin/` directory if they don't exist.
        

        # Upload pipeline files
        from app.config import PIPELINE_DIR
        pipeline_dir = PIPELINE_DIR
        for item in pipeline_dir.iterdir():
            if item.is_file() and item.name in ["main.nf", "nextflow.config", "nextflow_schema.json"]:
                file_mgr.upload_file(str(item), f"{remote_dir}/{item.name}")

        
        command_str = " ".join(cmd)
        
        # Enforce isolated R libraries and ensure Pixi path
        env_init = f"export PATH=$HOME/.pixi/bin:$HOME/.local/bin:$PATH\n{env_init}\nexport R_LIBS_USER=\"\"\nexport R_LIBS=\"\""

        # Tar and upload pipeline files
        import subprocess
        tar_path = "/tmp/pipeline_upload.tar.gz"
        subprocess.run(["tar", "-czf", tar_path, "-C", str(PIPELINE_DIR), "."], check=True)
        file_mgr.upload_file(tar_path, f"{remote_dir}/pipeline.tar.gz")
        
        # Extract on remote
        _, out, _ = ssh.client.exec_command(f"cd {remote_dir} && tar -xzf pipeline.tar.gz && rm pipeline.tar.gz")
        out.read()
        
        # Ensure .pixi environment is linked in remote_dir if missing
        ssh.execute_command(f"if [ ! -e {remote_dir}/.pixi ] && [ -d \"$HOME/.pixi\" ]; then ln -s \"$HOME/.pixi\" {remote_dir}/.pixi; fi")
        
        pid, log_file = proc_mgr.start_remote_pipeline(remote_dir, command_str, env_init)
        
        run_record = create_run(
            run_id=run_id, name=name, profile=profile, resume=resume,
            stub_run=stub_run, params=params, command=command_str,
            outdir=remote_dir, session_token=session_token,
            is_remote=True, remote_host=prof["host"], remote_user=prof["user"],
            remote_dir=remote_dir, remote_pid=pid
        )
        
        ensure_monitor_thread()
        return run_record

def remote_monitor_worker():
    global _STOP_MONITOR
    from app.db import get_connection
    from app.runner import parse_log_line_for_progress, ALL_STAGES
    
    while not _STOP_MONITOR:
        conn = get_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM runs WHERE status = 'RUNNING' AND is_remote = 1")
        active_runs = [dict(r) for r in cursor.fetchall()]
        conn.close()
        
        if not active_runs:
            time.sleep(5)
            continue
            
        for run in active_runs:
            run_id = run["id"]
            host = run["remote_host"]
            pid = run["remote_pid"]
            remote_dir = run["remote_dir"]
            
            # Find the cluster profile by host/user (Ideally we stored profile_id, but we can match by host)
            conn = get_connection()
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM cluster_profiles WHERE host = ?", (host,))
            prof = cursor.fetchone()
            conn.close()
            
            if not prof:
                continue
            
            try:
                with SSHManager(
                    host=prof["host"], user=prof["user"], port=prof["port"],
                    auth_method=prof["auth_method"], password=prof["password"],
                    private_key_path=prof["private_key_path"]
                ) as ssh:
                    proc_mgr = RemoteProcessManager(ssh)
                    file_mgr = RemoteFileManager(ssh)
                    
                    status = proc_mgr.get_process_status(pid, remote_dir)
                    
                    # Download log and parse it
                    try:
                        log_content = file_mgr.read_remote_text(f"{remote_dir}/pipeline.log")
                        local_log = RUNS_DIR / run_id / "run.log"
                        with open(local_log, "w", encoding="utf-8") as lf:
                            lf.write(log_content)
                            
                        # Parse stages
                        stages_status = {s["id"]: "PENDING" for s in ALL_STAGES}
                        for line in log_content.splitlines():
                            parse_log_line_for_progress(line, stages_status)
                            
                        # If process is done, mark all non-failed as completed if exit_code == 0
                        if not status["is_running"] and status["exit_code"] == 0:
                            for s in stages_status:
                                if stages_status[s] != "FAILED":
                                    stages_status[s] = "COMPLETED"
                                    
                        local_stages = RUNS_DIR / run_id / "stages.json"
                        with open(local_stages, "w") as sf:
                            json.dump(stages_status, sf, indent=2)
                            
                    except Exception as e:
                        print(f"Error fetching logs for {run_id}: {e}")
                    
                    if not status["is_running"]:
                        exit_code = status.get("exit_code", -1)
                        final_status = "COMPLETED" if exit_code == 0 else "FAILED"
                        end_time = datetime.now().isoformat()
                        
                        # Calculate duration
                        try:
                            start_time = datetime.fromisoformat(run["start_time"])
                            duration_sec = (datetime.now() - start_time).total_seconds()
                            duration_str = f"{round(duration_sec, 1)}s" if duration_sec < 60 else f"{round(duration_sec/60, 1)}m"
                        except Exception:
                            duration_str = ""
                            
                        update_run(
                            run_id,
                            status=final_status,
                            end_time=end_time,
                            duration=duration_str,
                            exit_code=exit_code
                        )
                        if exit_code == 0:
                            try:
                                from app.routers.api_explorer import sync_remote_results_assets
                                sync_remote_results_assets(run_id, run)
                            except Exception as sync_err:
                                print(f"Background sync of results for {run_id} failed: {sync_err}")
            except Exception as e:
                print(f"Monitor error for run {run_id}: {e}")
                
        time.sleep(5)

def ensure_monitor_thread():
    global _REMOTE_MONITOR_THREAD
    with _MONITOR_LOCK:
        if _REMOTE_MONITOR_THREAD is None or not _REMOTE_MONITOR_THREAD.is_alive():
            _REMOTE_MONITOR_THREAD = threading.Thread(target=remote_monitor_worker, daemon=True)
            _REMOTE_MONITOR_THREAD.start()

def cancel_remote_run(run_id: str) -> bool:
    from app.db import get_connection
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM runs WHERE id = ?", (run_id,))
    run = cursor.fetchone()
    conn.close()
    
    if not run or not run["is_remote"]:
        return False
        
    host = run["remote_host"]
    pid = run["remote_pid"]
    
    if not pid:
        return False
        
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM cluster_profiles WHERE host = ?", (host,))
    prof = cursor.fetchone()
    conn.close()
    
    if not prof:
        return False
        
    try:
        with SSHManager(
            host=prof["host"], user=prof["user"], port=prof["port"],
            auth_method=prof["auth_method"], password=prof["password"],
            private_key_path=prof["private_key_path"]
        ) as ssh:
            proc_mgr = RemoteProcessManager(ssh)
            success = proc_mgr.cancel_process(pid)
            if success:
                update_run(
                    run_id,
                    status="CANCELLED",
                    end_time=datetime.now().isoformat(),
                    exit_code=130
                )
            return success
    except Exception as e:
        print(f"Error cancelling remote run {run_id}: {e}")
        return False
