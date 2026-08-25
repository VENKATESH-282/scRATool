import sys
import pexpect
import os
import json

pass_file = os.path.join(os.path.dirname(__file__), "ui_pass.txt")
cmd_file = os.path.join(os.path.dirname(__file__), "ui_cmd.txt")
config_file = os.path.join(os.path.dirname(__file__), ".server_config.json")

user_host = ""
server_dir = ""
export_dir = ""

if os.path.exists(config_file):
    try:
        with open(config_file, "r") as f:
            cfg = json.load(f)
            host = cfg.get('host', '').strip()
            user = cfg.get('user', '').strip()
            if host and user:
                user_host = f"{user}@{host}"
            server_dir = cfg.get('remote_dir', '').strip()
            export_dir = cfg.get('export_dir', "").strip()
    except Exception as e:
        print(f"Error reading server config: {e}")

if not user_host or not server_dir:
    print("ERROR: Server configuration is missing.")
    print("Please go to Settings -> Server Connection and configure your Host, Username, and Remote Directory.")
    sys.exit(1)

try:
    with open(pass_file, "r") as f:
        password = f.read().strip()
    os.remove(pass_file) # Delete immediately for security
except Exception as e:
    print(f"Error reading password file: {e}")
    sys.exit(1)

outdir_file = os.path.join(os.path.dirname(__file__), "ui_outdir.txt")
outdir_name = "results"
if os.path.exists(outdir_file):
    try:
        with open(outdir_file, "r") as f:
            outdir_name = f.read().strip()
        os.remove(outdir_file)
    except Exception as e:
        print(f"Error reading outdir file: {e}")

try:
    with open(cmd_file, "r") as f:
        cmd = f.read().strip()
    os.remove(cmd_file)
except Exception as e:
    print(f"Error reading cmd file: {e}")
    sys.exit(1)

# Handle automated transfers (CSV and GEO datasets) to the server
transfer_file = os.path.join(os.path.dirname(__file__), "ui_transfer.txt")
try:
    if os.path.exists(transfer_file):
        with open(transfer_file, "r") as f:
            transfers = f.read().strip().split(";")
        os.remove(transfer_file)
        
        csv_file = os.path.join(os.path.dirname(__file__), transfers[0])
        
        if os.path.exists(csv_file):
            print(f"Parsing {os.path.basename(csv_file)} for local paths...")
            import csv
            import tempfile
            
            # Read CSV and collect local absolute paths
            local_dirs_to_sync = set()
            modified_rows = []
            fieldnames = []
            
            with open(csv_file, "r") as f:
                reader = csv.DictReader(f)
                fieldnames = reader.fieldnames
                for row in reader:
                    for col in ["csv_file", "matrix_dir"]:
                        if col in row and row[col]:
                            path = row[col]
                            if path.startswith("/") and not path.startswith(server_dir):
                                # It's a local absolute path. Find the project/GEO base dir.
                                # E.g., /home/user/scRNA_project/GSE171524_RAW/file.csv.gz
                                parts = path.split("/")
                                if len(parts) > 2:
                                    # Assuming the dir right before the file is the base dir
                                    base_dir_path = os.path.dirname(path)
                                    # If it's something like GSE171524_RAW, we sync it
                                    local_dirs_to_sync.add(base_dir_path)
                                    
                                    # Rewrite path for server
                                    base_name = os.path.basename(base_dir_path)
                                    file_name = os.path.basename(path)
                                    row[col] = f"{server_dir}/results/GEO_Downloads/{base_name}/{file_name}"
                    modified_rows.append(row)
            
            # Write modified CSV to a temporary file
            fd, temp_csv = tempfile.mkstemp(suffix=".csv")
            with os.fdopen(fd, "w", newline="") as f:
                writer = csv.DictWriter(f, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerows(modified_rows)
            
            print(f"Uploading modified {os.path.basename(csv_file)} to server...")
            child = pexpect.spawn(f'scp -o StrictHostKeyChecking=no "{temp_csv}" "{user_host}:{server_dir}/{os.path.basename(csv_file)}"', encoding='utf-8')
            idx = child.expect(['[Pp]assword:', pexpect.EOF], timeout=20)
            if idx == 0:
                child.sendline(password)
                child.expect(pexpect.EOF, timeout=60)
            print("CSV upload finished.")
            os.remove(temp_csv)
            
            # Sync local absolute directories to server
            if local_dirs_to_sync:
                print(f"Syncing {len(local_dirs_to_sync)} local directories to server...")
                child = pexpect.spawn(f'ssh -o StrictHostKeyChecking=no {user_host} "mkdir -p {server_dir}/results/GEO_Downloads/"', encoding='utf-8')
                idx = child.expect(['[Pp]assword:', pexpect.EOF], timeout=20)
                if idx == 0:
                    child.sendline(password)
                    child.expect(pexpect.EOF, timeout=30)
                
                for local_dir in local_dirs_to_sync:
                    print(f"Running rsync for {local_dir}...")
                    base_name = os.path.basename(local_dir)
                    # Create the target dir first so rsync puts contents inside correctly
                    child = pexpect.spawn(f'ssh -o StrictHostKeyChecking=no {user_host} "mkdir -p {server_dir}/results/GEO_Downloads/{base_name}/"', encoding='utf-8')
                    idx = child.expect(['[Pp]assword:', pexpect.EOF], timeout=20)
                    if idx == 0:
                        child.sendline(password)
                        child.expect(pexpect.EOF, timeout=30)
                        
                    child = pexpect.spawn(f'rsync -avz -e "ssh -o StrictHostKeyChecking=no" "{local_dir}/" "{user_host}:{server_dir}/results/GEO_Downloads/{base_name}/"', encoding='utf-8')
                    idx = child.expect(['[Pp]assword:', pexpect.EOF], timeout=30)
                    if idx == 0:
                        child.sendline(password)
                        child.expect(pexpect.EOF, timeout=None)
                print("Sync complete.")
            
            # Also upload nextflow.config
            config_file = os.path.join(os.path.dirname(csv_file), "nextflow.config")
            if os.path.exists(config_file):
                print("Updating nextflow.config on server...")
                child = pexpect.spawn(f'scp -o StrictHostKeyChecking=no "{config_file}" "{user_host}:{server_dir}/"', encoding='utf-8')
                idx = child.expect(['[Pp]assword:', pexpect.EOF], timeout=20)
                if idx == 0:
                    child.sendline(password)
                    child.expect(pexpect.EOF, timeout=60)
                print("nextflow.config updated.")

            # Also upload main.nf
            main_nf = os.path.join(os.path.dirname(csv_file), "main.nf")
            if os.path.exists(main_nf):
                print("Updating main.nf on server...")
                child = pexpect.spawn(f'scp -o StrictHostKeyChecking=no "{main_nf}" "{user_host}:{server_dir}/"', encoding='utf-8')
                idx = child.expect(['[Pp]assword:', pexpect.EOF], timeout=20)
                if idx == 0:
                    child.sendline(password)
                    child.expect(pexpect.EOF, timeout=60)
                print("main.nf updated.")
                
except Exception as e:
    print(f"Transfer phase failed: {str(e)}")

print(f"Connecting to {user_host} to run pipeline...")
print(f"Executing: {cmd}")

# Pre-execution cleanup: Remove stale Nextflow lock files to prevent "Unable to acquire lock" errors
cleanup_cmd = f'find {server_dir}/.nextflow/cache -name LOCK -delete 2>/dev/null || true'
child = pexpect.spawn(f'ssh -o StrictHostKeyChecking=no {user_host} "{cleanup_cmd}"', encoding='utf-8')
idx = child.expect(['[Pp]assword:', pexpect.EOF], timeout=20)
if idx == 0:
    child.sendline(password)
    child.expect(pexpect.EOF, timeout=30)

# Spawn the SSH process
child = pexpect.spawn(f'ssh -o StrictHostKeyChecking=no {user_host} "{cmd}"', encoding='utf-8', timeout=None)

# Expect the password prompt
try:
    index = child.expect(['[Pp]assword:', pexpect.EOF, pexpect.TIMEOUT], timeout=10)
    if index == 0:
        child.sendline(password)
        
        # Stream the output directly to stdout so the UI can read it
        for line in child:
            sys.stdout.write(line)
            sys.stdout.flush()
            
    elif index == 1:
        print("SSH connection closed unexpectedly.")
    else:
        print("Timeout waiting for password prompt.")
        
except Exception as e:
    print(f"SSH execution failed: {str(e)}")

print("Server execution finished.")

# Sync results back to host so they are visible in the UI
print(f"==================================================")
print(f"🎯 CLUSTER RESULTS LOCATION:")
print(f"Your results are permanently saved on the cluster at:")
print(f"  {server_dir}/{outdir_name}/")
print(f"==================================================")
print("Syncing a copy of the results back to your laptop so the UI can display the plots...")

# Use the directory where the sample sheet is located as the local results root
local_results_dir = os.path.join(os.path.dirname(csv_file), outdir_name + "/")
os.makedirs(local_results_dir, exist_ok=True)

sync_cmd = f'rsync -avz -e "ssh -o StrictHostKeyChecking=no" "{user_host}:{server_dir}/{outdir_name}/" "{local_results_dir}"'
child_sync = pexpect.spawn(sync_cmd, encoding='utf-8')
try:
    idx = child_sync.expect(['[Pp]assword:', pexpect.EOF], timeout=30)
    if idx == 0:
        child_sync.sendline(password)
        child_sync.expect(pexpect.EOF, timeout=None)
    abs_path = os.path.abspath(local_results_dir)
    print(f"Results sync complete. System files saved to: {abs_path}")
    
    # Export if requested
    if export_dir:
        import shutil
        print(f"Exporting a copy of results to: {export_dir}")
        os.makedirs(export_dir, exist_ok=True)
        # Copy the contents of the local results dir to the export dir
        try:
            # We use rsync or cp -r via subprocess for safety
            import subprocess
            subprocess.run(["rsync", "-avz", f"{abs_path}/", f"{export_dir}/"], check=True, capture_output=True)
            print("Export complete.")
        except Exception as e:
            print(f"Failed to copy to export directory: {e}")

except:
    print(f"Results sync timed out or failed, but pipeline finished. Check {local_results_dir}")

