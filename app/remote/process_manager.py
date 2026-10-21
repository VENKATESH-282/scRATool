import os
import json
from typing import Dict, Any, Tuple
from .ssh_manager import SSHManager

class RemoteProcessManager:
    def __init__(self, ssh_manager: SSHManager):
        self.ssh = ssh_manager

    def start_remote_pipeline(self, remote_project_dir: str, command: str, env_init: str = "") -> Tuple[int, str]:
        """
        Starts the pipeline in the background using nohup and returns (PID, log_file_path).
        """
        log_file = f"{remote_project_dir}/pipeline.log"
        stages_file = f"{remote_project_dir}/stages.json"
        
        # Build the shell script to run
        script = f"""#!/bin/bash
cd {remote_project_dir}
{env_init}
{command}
echo $? > .exit_code
"""
        # Upload script
        script_path = f"{remote_project_dir}/run_pipeline.sh"
        self.ssh.execute_command(f"mkdir -p {remote_project_dir}")
        
        sftp = self.ssh.get_sftp()
        with sftp.open(script_path, 'w') as f:
            f.write(script)
            
        self.ssh.execute_command(f"chmod +x {script_path}")
        
        # Execute with nohup and capture PID
        nohup_cmd = f"cd {remote_project_dir} && nohup ./run_pipeline.sh > pipeline.log 2>&1 & echo $!"
        status, out, err = self.ssh.execute_command(nohup_cmd)
        
        if status != 0 or not out.strip().isdigit():
            raise Exception(f"Failed to start remote process: {err} | {out}")
            
        return int(out.strip()), log_file
        
    def get_process_status(self, pid: int, remote_project_dir: str) -> Dict[str, Any]:
        """Checks if process is running and retrieves exit code if finished."""
        # Check if process is running
        status, out, err = self.ssh.execute_command(f"ps -p {pid} > /dev/null; echo $?")
        is_running = out.strip() == "0"
        
        exit_code = None
        if not is_running:
            # Check for .exit_code file
            s, out_code, _ = self.ssh.execute_command(f"cat {remote_project_dir}/.exit_code 2>/dev/null")
            if s == 0 and out_code.strip().lstrip('-').isdigit():
                exit_code = int(out_code.strip())
                
        return {
            "is_running": is_running,
            "exit_code": exit_code
        }
        
    def cancel_process(self, pid: int) -> bool:
        """Kills the process and its child processes."""
        # Use pkill to kill process group if possible, or just kill the process and its children
        cmd = f"pkill -P {pid}; kill -9 {pid}"
        status, _, _ = self.ssh.execute_command(cmd)
        return status == 0
        
    def get_logs(self, log_file: str, last_n_lines: int = 100) -> str:
        """Tails the remote log file."""
        status, out, err = self.ssh.execute_command(f"tail -n {last_n_lines} {log_file} 2>/dev/null")
        return out

    def get_stages_status(self, remote_project_dir: str) -> Dict[str, str]:
        """Reads stages.json from remote dir."""
        status, out, err = self.ssh.execute_command(f"cat {remote_project_dir}/stages.json 2>/dev/null")
        if status == 0 and out.strip():
            try:
                return json.loads(out.strip())
            except Exception:
                pass
        return {}
