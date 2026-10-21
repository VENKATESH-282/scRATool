import os
import subprocess
from pathlib import Path
from typing import Optional, List, Dict, Any
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

router = APIRouter(prefix="/api/cluster", tags=["cluster"])

class SshConnectRequest(BaseModel):
    ssh_host: str
    ssh_user: str
    ssh_password: Optional[str] = ""
    ssh_port: Optional[int] = 22

class BrowseDirectoryRequest(BaseModel):
    ssh_host: Optional[str] = ""
    ssh_user: Optional[str] = ""
    ssh_password: Optional[str] = ""
    ssh_port: Optional[int] = 22
    path: Optional[str] = ""

class CreateDirectoryRequest(BaseModel):
    ssh_host: Optional[str] = ""
    ssh_user: Optional[str] = ""
    ssh_password: Optional[str] = ""
    ssh_port: Optional[int] = 22
    path: str

@router.post("/connect")
def test_cluster_connection(req: SshConnectRequest):
    """
    Tests connection to a remote cluster via SSH or checks local Slurm environment.
    Returns connection status, queue list, free disk space, and default home directory.
    """
    if not req.ssh_host or req.ssh_host.strip() in ("localhost", "127.0.0.1", "local"):
        # Local system / local Slurm check
        cpu_count = os.cpu_count() or 8
        has_slurm = subprocess.run(["which", "sbatch"], capture_output=True).returncode == 0
        queues = []
        if has_slurm:
            try:
                res = subprocess.run(["sinfo", "-h", "-o", "%P"], capture_output=True, text=True, timeout=5)
                if res.returncode == 0:
                    queues = [q.replace("*", "").strip() for q in res.stdout.strip().split("\n") if q.strip()]
            except Exception:
                pass

        home_dir = str(Path.home())
        return {
            "success": True,
            "mode": "local",
            "message": "Connected to local system / local cluster node.",
            "cpus": cpu_count,
            "has_slurm": has_slurm,
            "queues": queues or ["general", "batch"],
            "home_dir": home_dir,
            "recommended_project_dir": str(Path.home() / "scrna_projects")
        }

    # Remote SSH cluster connection
    try:
        import paramiko
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        ssh.connect(
            hostname=req.ssh_host.strip(),
            port=req.ssh_port or 22,
            username=req.ssh_user.strip(),
            password=req.ssh_password or None,
            timeout=10
        )

        # Retrieve home directory
        stdin, stdout, stderr = ssh.exec_command("pwd && echo '---' && which sbatch && sinfo -h -o %P 2>/dev/null || true")
        out = stdout.read().decode("utf-8", errors="replace").strip()
        ssh.close()

        parts = out.split("---")
        home_dir = parts[0].strip() if parts else f"/home/{req.ssh_user.strip()}"
        queues_raw = parts[1].strip() if len(parts) > 1 else ""
        queues = [q.replace("*", "").strip() for q in queues_raw.split("\n") if q.strip() and "sbatch" not in q]

        return {
            "success": True,
            "mode": "remote_ssh",
            "message": f"Successfully connected to remote cluster '{req.ssh_host}' as user '{req.ssh_user}'.",
            "host": req.ssh_host,
            "user": req.ssh_user,
            "home_dir": home_dir,
            "queues": queues or ["general", "batch", "gpu", "highmem"],
            "recommended_project_dir": f"{home_dir}/scrna_projects"
        }
    except ImportError:
        # Fallback using system ssh command if paramiko not installed
        cmd = ["ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no",
               "-p", str(req.ssh_port or 22), f"{req.ssh_user}@{req.ssh_host}", "pwd"]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=8)
            if res.returncode == 0:
                home_dir = res.stdout.strip()
                return {
                    "success": True,
                    "mode": "remote_ssh",
                    "message": f"Connected to {req.ssh_host} as {req.ssh_user}.",
                    "home_dir": home_dir,
                    "queues": ["general", "batch"],
                    "recommended_project_dir": f"{home_dir}/scrna_projects"
                }
            else:
                return {
                    "success": False,
                    "message": f"SSH connection failed: {res.stderr.strip() or 'Host unreachable'}"
                }
        except Exception as e:
            return {"success": False, "message": f"Connection error: {str(e)}"}
    except Exception as e:
        return {"success": False, "message": f"SSH connection failed: {str(e)}"}


@router.post("/browse")
def browse_cluster_directory(req: BrowseDirectoryRequest):
    """
    Browses directories on the local system or remote cluster.
    Returns subdirectories and current path for location selection.
    """
    target_path = req.path.strip() if req.path else str(Path.home())

    if not req.ssh_host or req.ssh_host.strip() in ("localhost", "127.0.0.1", "local"):
        p = Path(target_path)
        if not p.exists():
            p = Path.home()
        dirs = []
        try:
            for item in sorted(p.iterdir()):
                if item.is_dir() and not item.name.startswith("."):
                    dirs.append({
                        "name": item.name,
                        "path": str(item),
                        "is_dir": True
                    })
        except PermissionError:
            pass

        parent = str(p.parent) if p != p.parent else str(p)
        return {
            "current_path": str(p),
            "parent_path": parent,
            "directories": dirs
        }

    # Remote SSH directory listing
    try:
        import paramiko
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        ssh.connect(
            hostname=req.ssh_host.strip(),
            port=req.ssh_port or 22,
            username=req.ssh_user.strip(),
            password=req.ssh_password or None,
            timeout=10
        )
        cmd = f"cd {target_path} 2>/dev/null && pwd && echo '---' && ls -1p 2>/dev/null"
        stdin, stdout, stderr = ssh.exec_command(cmd)
        out = stdout.read().decode("utf-8", errors="replace").strip()
        ssh.close()

        parts = out.split("---")
        curr_path = parts[0].strip() if parts else target_path
        dirs_raw = parts[1].strip() if len(parts) > 1 else ""
        dirs = []
        for d in dirs_raw.split("\n"):
            dname = d.strip().rstrip("/")
            if dname:
                dirs.append({
                    "name": dname,
                    "path": f"{curr_path}/{dname}".replace("//", "/"),
                    "is_dir": True
                })

        parent = str(Path(curr_path).parent)
        return {
            "current_path": curr_path,
            "parent_path": parent,
            "directories": dirs
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to list remote directory: {str(e)}")


@router.post("/create_directory")
def create_cluster_directory(req: CreateDirectoryRequest):
    """
    Creates a new project directory on the local or remote cluster.
    """
    target_path = req.path.strip()
    if not target_path:
        raise HTTPException(status_code=400, detail="Target directory path cannot be empty.")

    if not req.ssh_host or req.ssh_host.strip() in ("localhost", "127.0.0.1", "local"):
        p = Path(target_path)
        p.mkdir(parents=True, exist_ok=True)
        return {"success": True, "path": str(p), "message": f"Created local project directory at {p}"}

    # Remote SSH directory creation
    try:
        import paramiko
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        ssh.connect(
            hostname=req.ssh_host.strip(),
            port=req.ssh_port or 22,
            username=req.ssh_user.strip(),
            password=req.ssh_password or None,
            timeout=10
        )
        stdin, stdout, stderr = ssh.exec_command(f"mkdir -p '{target_path}' && echo OK")
        res = stdout.read().decode("utf-8").strip()
        ssh.close()
        if "OK" in res:
            return {"success": True, "path": target_path, "message": f"Created remote cluster project directory at {target_path}"}
        else:
            raise HTTPException(status_code=500, detail="Failed to create remote directory.")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


class ClusterProfileCreateRequest(BaseModel):
    name: str
    host: str
    user: str
    port: int = 22
    auth_method: str = "password"
    password: Optional[str] = None
    private_key_path: Optional[str] = None
    is_default: bool = False

@router.get("/profiles")
def get_profiles():
    from app.db import list_cluster_profiles
    return {"success": True, "profiles": list_cluster_profiles()}

@router.post("/profiles")
def add_profile(req: ClusterProfileCreateRequest):
    from app.db import create_cluster_profile
    try:
        pid = create_cluster_profile(
            name=req.name, host=req.host, user=req.user, port=req.port,
            auth_method=req.auth_method, password=req.password,
            private_key_path=req.private_key_path, is_default=req.is_default
        )
        return {"success": True, "profile_id": pid, "message": "Profile created successfully"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.delete("/profiles/{profile_id}")
def delete_profile(profile_id: int):
    from app.db import delete_cluster_profile
    try:
        delete_cluster_profile(profile_id)
        return {"success": True, "message": "Profile deleted"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

class TestProfileRequest(BaseModel):
    env_init: Optional[str] = ""
    remote_dir: Optional[str] = ""

@router.post("/test_profile/{profile_id}")
def test_profile(profile_id: int, req: TestProfileRequest = None):
    from app.db import get_cluster_profile
    from app.remote.ssh_manager import SSHManager
    from app.remote.resource_monitor import RemoteResourceMonitor
    
    prof = get_cluster_profile(profile_id)
    if not prof:
        raise HTTPException(status_code=404, detail="Profile not found")
        
    try:
        with SSHManager(
            host=prof["host"], user=prof["user"], port=prof["port"],
            auth_method=prof["auth_method"], password=prof.get("password"),
            private_key_path=prof.get("private_key_path")
        ) as ssh:
            monitor = RemoteResourceMonitor(ssh)
            resources = monitor.fetch_resources()
            env_init = req.env_init if req else ""
            remote_dir = req.remote_dir if req else ""
            env = monitor.check_environment(env_init, remote_dir)
            
            return {
                "success": True,
                "message": "SSH connection successful",
                "resources": resources,
                "environment": env
            }
    except Exception as e:
        return {"success": False, "message": f"Connection failed: {str(e)}"}


@router.post("/install_env/{profile_id}")
def install_env(profile_id: int):
    from app.db import get_cluster_profile
    from app.remote.ssh_manager import SSHManager
    
    prof = get_cluster_profile(profile_id)
    if not prof:
        raise HTTPException(status_code=404, detail="Profile not found")
        
    try:
        with SSHManager(
            host=prof["host"], user=prof["user"], port=prof["port"],
            auth_method=prof["auth_method"], password=prof.get("password"),
            private_key_path=prof.get("private_key_path")
        ) as ssh:
            # Install Nextflow to ~/.local/bin and install sp package if Rscript exists
            install_cmd = (
                "mkdir -p ~/.local/bin; "
                "if ! command -v nextflow &> /dev/null; then "
                "  cd ~/.local/bin && curl -s https://get.nextflow.io | bash; "
                "fi; "
                "mkdir -p ~/R/x86_64-pc-linux-gnu-library/4.3; "
                "if command -v Rscript &> /dev/null; then "
                "  Rscript -e \"if(!require('sp')) install.packages('sp', repos='https://cloud.r-project.org', lib='~/R/x86_64-pc-linux-gnu-library/4.3')\" || true; "
                "fi;"
            )
            status, out, err = ssh.execute_command(install_cmd)
            return {"success": True, "message": "Installation routines executed.", "output": out}
    except Exception as e:
        return {"success": False, "message": f"Installation failed: {str(e)}"}

class MkdirRequest(BaseModel):
    path: str

@router.post("/mkdir/{profile_id}")
def make_remote_directory(profile_id: int, req: MkdirRequest):
    from app.db import get_cluster_profile
    from app.remote.ssh_manager import SSHManager
    
    prof = get_cluster_profile(profile_id)
    if not prof:
        raise HTTPException(status_code=404, detail="Profile not found")
        
    try:
        with SSHManager(
            host=prof["host"], user=prof["user"], port=prof["port"],
            auth_method=prof["auth_method"], password=prof.get("password"),
            private_key_path=prof.get("private_key_path")
        ) as ssh:
            # Create the directory safely
            cmd = f"mkdir -p {req.path}"
            status, out, err = ssh.execute_command(cmd)
            if status != 0:
                return {"success": False, "message": f"Failed to create directory: {err}"}
            return {"success": True, "message": f"Created {req.path}"}
    except Exception as e:
        return {"success": False, "message": f"SSH error: {str(e)}"}

class BrowseProfileRequest(BaseModel):

    path: Optional[str] = ""

@router.post("/browse_profile/{profile_id}")
def browse_profile_directory(profile_id: int, req: BrowseProfileRequest):
    from app.db import get_cluster_profile
    from app.remote.ssh_manager import SSHManager
    
    prof = get_cluster_profile(profile_id)
    if not prof:
        raise HTTPException(status_code=404, detail="Profile not found")
        
    target_path = req.path.strip() if req.path else f"/home/{prof['user']}"
    
    try:
        with SSHManager(
            host=prof["host"], user=prof["user"], port=prof["port"],
            auth_method=prof["auth_method"], password=prof.get("password"),
            private_key_path=prof.get("private_key_path")
        ) as ssh:
            cmd = f"cd {target_path} 2>/dev/null && pwd && echo '---' && ls -1p 2>/dev/null"
            status, out, err = ssh.execute_command(cmd)
            
            parts = out.split("---")
            curr_path = parts[0].strip() if parts else target_path
            dirs_raw = parts[1].strip() if len(parts) > 1 else ""
            
            dirs = []
            for item in dirs_raw.split("\n"):
                item = item.strip()
                if not item: continue
                is_dir = item.endswith('/')
                name = item.rstrip('/')
                # if not is_dir and not (name.endswith('.csv') or name.endswith('.h5') or name.endswith('.rds') or name.endswith('.mtx') or name.endswith('.txt') or name.endswith('.tsv')): continue
                dirs.append({
                    "name": name,
                    "path": f"{curr_path}/{name}".replace("//", "/"),
                    "is_dir": is_dir
                })
            # sort dirs first, then files
            dirs.sort(key=lambda x: (not x["is_dir"], x["name"].lower()))
                    
            parent = str(Path(curr_path).parent)
            return {
                "success": True,
                "current_path": curr_path,
                "parent_path": parent,
                "directories": dirs
            }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to list remote directory: {str(e)}")

from typing import List, Dict, Any

class VerifyPathsRequest(BaseModel):
    samples: List[Dict[str, Any]]

@router.post("/verify_paths/{profile_id}")
def verify_remote_paths(profile_id: int, req: VerifyPathsRequest):
    from app.db import get_cluster_profile
    from app.remote.ssh_manager import SSHManager
    
    prof = get_cluster_profile(profile_id)
    if not prof:
        raise HTTPException(status_code=404, detail="Profile not found")
        
    try:
        with SSHManager(
            host=prof["host"], user=prof["user"], port=prof["port"],
            auth_method=prof["auth_method"], password=prof.get("password"),
            private_key_path=prof.get("private_key_path")
        ) as ssh:
            samples = req.samples
            for s in samples:
                p = s.get("file_path", "")
                if p:
                    # check if it exists using ls
                    status, out, err = ssh.execute_command(f"ls '{p}' >/dev/null 2>&1 && echo 'EXISTS' || echo 'MISSING'")
                    if "EXISTS" in out:
                        s["file_exists"] = True
                    else:
                        s["file_exists"] = False
                else:
                    s["file_exists"] = False
            return {"samples": samples}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

class SyncSamplesheetRequest(BaseModel):
    remote_dir: str
    samples: List[Dict[str, Any]]

@router.post("/sync_samplesheet/{profile_id}")
def sync_samplesheet_to_cluster(profile_id: int, req: SyncSamplesheetRequest):
    from app.db import get_cluster_profile
    from app.remote.ssh_manager import SSHManager
    import csv, io
    
    prof = get_cluster_profile(profile_id)
    if not prof:
        raise HTTPException(status_code=404, detail="Profile not found")
        
    try:
        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(["sample_id", "condition", "patient_id", "file_path"])
        for s in req.samples:
            writer.writerow([s.get("sample_id",""), s.get("condition",""), s.get("patient_id",""), s.get("file_path","")])
        csv_content = output.getvalue()
        
        with SSHManager(
            host=prof["host"], user=prof["user"], port=prof["port"],
            auth_method=prof["auth_method"], password=prof.get("password"),
            private_key_path=prof.get("private_key_path")
        ) as ssh:
            remote_dir = req.remote_dir.strip().rstrip('/')
            if not remote_dir:
                remote_dir = f"/home/{prof['user']}"
            remote_path = f"{remote_dir}/samples.csv"
            
            ssh.execute_command(f"mkdir -p '{remote_dir}'")
            sftp = ssh.client.open_sftp()
            with sftp.file(remote_path, 'w') as f:
                f.write(csv_content)
            sftp.close()
            return {"success": True, "message": f"Successfully synced samples.csv to cluster at {remote_path}", "remote_path": remote_path}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

