import paramiko
import os
from typing import Optional, Dict, Any, Tuple

class SSHManager:
    def __init__(self, host: str, user: str, port: int = 22, 
                 auth_method: str = "password", password: Optional[str] = None, 
                 private_key_path: Optional[str] = None):
        self.host = host
        self.user = user
        self.port = port
        self.auth_method = auth_method
        self.password = password
        self.private_key_path = private_key_path
        self.client: Optional[paramiko.SSHClient] = None
        self.sftp: Optional[paramiko.SFTPClient] = None

    def connect(self):
        if self.client is not None:
            return
        
        self.client = paramiko.SSHClient()
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        
        connect_kwargs = {
            "hostname": self.host,
            "port": self.port,
            "username": self.user,
            "timeout": 15
        }
        
        if self.auth_method == "password" and self.password:
            connect_kwargs["password"] = self.password
        elif self.auth_method == "key" and self.private_key_path:
            # Try to resolve home directory shortcuts
            key_path = os.path.expanduser(self.private_key_path)
            if os.path.exists(key_path):
                connect_kwargs["key_filename"] = key_path
            else:
                raise Exception(f"Private key file not found: {key_path}")
                
        try:
            self.client.connect(**connect_kwargs)
        except Exception as e:
            self.client = None
            raise Exception(f"SSH connection failed: {str(e)}")

    def get_sftp(self) -> paramiko.SFTPClient:
        if not self.sftp:
            self.connect()
            self.sftp = self.client.open_sftp()
        return self.sftp

    def execute_command(self, command: str, timeout: int = None) -> Tuple[int, str, str]:
        """Returns (exit_status, stdout, stderr)"""
        self.connect()
        stdin, stdout, stderr = self.client.exec_command(command, timeout=timeout)
        exit_status = stdout.channel.recv_exit_status()
        out = stdout.read().decode("utf-8", errors="replace").strip()
        err = stderr.read().decode("utf-8", errors="replace").strip()
        return exit_status, out, err

    def disconnect(self):
        if self.sftp:
            self.sftp.close()
            self.sftp = None
        if self.client:
            self.client.close()
            self.client = None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.disconnect()
