import os
import stat
from typing import Callable, Optional
from .ssh_manager import SSHManager

class RemoteFileManager:
    def __init__(self, ssh_manager: SSHManager):
        self.ssh = ssh_manager

    def upload_file(self, local_path: str, remote_path: str, callback: Optional[Callable[[int, int], None]] = None):
        """Uploads a local file to the remote server via SFTP."""
        if not os.path.exists(local_path):
            raise FileNotFoundError(f"Local file not found: {local_path}")
            
        sftp = self.ssh.get_sftp()
        # Ensure remote directory exists
        remote_dir = os.path.dirname(remote_path)
        try:
            sftp.stat(remote_dir)
        except IOError:
            self.ssh.execute_command(f"mkdir -p '{remote_dir}'")
            
        sftp.put(local_path, remote_path, callback=callback)

    def download_file(self, remote_path: str, local_path: str, callback: Optional[Callable[[int, int], None]] = None):
        """Downloads a remote file to the local server via SFTP."""
        sftp = self.ssh.get_sftp()
        
        # Ensure local directory exists
        local_dir = os.path.dirname(local_path)
        if local_dir:
            os.makedirs(local_dir, exist_ok=True)
            
        sftp.get(remote_path, local_path, callback=callback)
        
    def file_exists(self, remote_path: str) -> bool:
        sftp = self.ssh.get_sftp()
        try:
            sftp.stat(remote_path)
            return True
        except IOError:
            return False
            
    def read_remote_text(self, remote_path: str) -> str:
        sftp = self.ssh.get_sftp()
        try:
            with sftp.open(remote_path, 'r') as f:
                return f.read().decode('utf-8')
        except IOError:
            return ""
