from typing import Dict, Any
from .ssh_manager import SSHManager

class RemoteResourceMonitor:
    def __init__(self, ssh_manager: SSHManager):
        self.ssh = ssh_manager

    def fetch_resources(self) -> Dict[str, Any]:
        """Fetches remote resources using standard Linux commands."""
        # Bundle commands to reduce SSH overhead
        cmd = (
            "uname -srm && echo '---' && "
            "nproc && echo '---' && "
            "free -b && echo '---' && "
            "df -B1 /home || df -B1 / && echo '---' && "
            "command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader || echo 'No GPU'"
        )
        status, out, err = self.ssh.execute_command(cmd)
        
        if status != 0 and not out:
            raise Exception(f"Failed to fetch resources: {err}")
            
        parts = out.split("---")
        
        os_info = parts[0].strip() if len(parts) > 0 else "Unknown"
        cpu_cores = int(parts[1].strip()) if len(parts) > 1 and parts[1].strip().isdigit() else 0
        
        # Parse free -b
        mem_total = 0
        mem_free = 0
        if len(parts) > 2:
            lines = parts[2].strip().split('\n')
            if len(lines) > 1:
                # Mem: total used free shared buff/cache available
                mem_parts = lines[1].split()
                if len(mem_parts) >= 4:
                    mem_total = int(mem_parts[1])
                    mem_free = int(mem_parts[3]) + int(mem_parts[5]) if len(mem_parts) >= 6 else int(mem_parts[3])
                    
        # Parse df
        disk_total = 0
        disk_avail = 0
        if len(parts) > 3:
            lines = parts[3].strip().split('\n')
            if len(lines) > 1:
                disk_parts = lines[1].split()
                if len(disk_parts) >= 4:
                    disk_total = int(disk_parts[1])
                    disk_avail = int(disk_parts[3])
                    
        # Parse GPU
        gpu_info = "Not detected"
        gpu_mem_total = 0
        gpu_mem_free = 0
        if len(parts) > 4:
            gpu_out = parts[4].strip()
            if "No GPU" not in gpu_out and gpu_out:
                gpu_lines = gpu_out.split('\n')
                if gpu_lines:
                    gparts = gpu_lines[0].split(',')
                    if len(gparts) >= 3:
                        gpu_info = gparts[0].strip()
                        # Output format is typically '16384 MiB'
                        t_mem = gparts[1].strip().split()[0]
                        f_mem = gparts[2].strip().split()[0]
                        if t_mem.isdigit() and f_mem.isdigit():
                            gpu_mem_total = int(t_mem) * 1024 * 1024
                            gpu_mem_free = int(f_mem) * 1024 * 1024
                            gpu_info = f"{gpu_info} ({int(t_mem)} MiB)"

        return {
            "os": os_info,
            "cpu_cores": cpu_cores,
            "mem_total_bytes": mem_total,
            "mem_free_bytes": mem_free,
            "disk_total_bytes": disk_total,
            "disk_avail_bytes": disk_avail,
            "gpu_info": gpu_info,
            "gpu_mem_total_bytes": gpu_mem_total,
            "gpu_mem_free_bytes": gpu_mem_free
        }

    def check_environment(self, env_init: str = "", work_dir: str = "") -> Dict[str, str]:
        prefix = ""
        if work_dir:
            prefix += f"mkdir -p {work_dir} && cd {work_dir}; "
        if env_init:
            prefix += f"{env_init}; "
            
        cmd = prefix + (
            "command -v python3 >/dev/null 2>&1 && python3 --version || echo 'Not Found'; echo '---';"
            "command -v Rscript >/dev/null 2>&1 && Rscript --version 2>&1 | head -n1 || echo 'Not Found'; echo '---';"
            "command -v conda >/dev/null 2>&1 && conda --version || echo 'Not Found'; echo '---';"
            "command -v nextflow >/dev/null 2>&1 && nextflow -v || echo 'Not Found'"
        )
        status, out, err = self.ssh.execute_command(cmd)
        parts = [p.strip() for p in out.split("---")]
        
        return {
            "python": parts[0] if len(parts) > 0 and "Not Found" not in parts[0] else None,
            "R": parts[1] if len(parts) > 1 and "Not Found" not in parts[1] else None,
            "conda": parts[2] if len(parts) > 2 and "Not Found" not in parts[2] else None,
            "nextflow": parts[3] if len(parts) > 3 and "Not Found" not in parts[3] else None
        }
