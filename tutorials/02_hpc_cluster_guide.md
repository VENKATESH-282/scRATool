# Tutorial 2: Remote HPC Cluster & SLURM Deployment

scRATool features built-in remote cluster dispatch, allowing you to control high-performance compute clusters directly from your local browser without manual SSH scripting.

---

## Architecture

```text
[ Local Laptop / Browser ]  <--- SSH / SFTP --->  [ HPC Head Node ]
         │                                                │
         │ (Configures via Web GUI)                       │ (Slurm sbatch)
         ▼                                                ▼
[ scRATool FastAPI Server ]                      [ Slurm Compute Nodes ]
                                                    (14 Analysis Stages)
```

---

## Step 1: Configure Remote Profile
1. In the **Run Monitor** tab of the web GUI, select **Run Location: Remote HPC Cluster**.
2. Click **+ Add Profile**:
   * **Profile Name:** `Institutional Cluster`
   * **Host:** `cluster.university.edu` (or cluster IP)
   * **User:** Your cluster username
   * **Port:** `22`
   * **Auth Method:** `Password` or `Private Key`
3. Click **Save & Connect**.

---

## Step 2: Set Remote Scratch Directory
1. In the **Remote Project Directory** field, enter your cluster scratch folder:
   ```text
   /scratch/users/my_username/scratool_project
   ```
2. Click **📁 Browse Cluster** to visually navigate remote directories and create new folders via SFTP.

---

## Step 3: Remote Environment Detection
Click **Detect Remote Environment**. scRATool executes automated checks to verify:
* Nextflow version (`nextflow -v`)
* Pixi or Conda installation
* Slurm job submission availability (`squeue`, `sbatch`)

---

## Step 4: Dispatch the Job
Click **Launch Remote Pipeline**:
1. scRATool packages your local pipeline configuration and uploads it via SFTP.
2. It initiates the Nextflow process on the cluster with `-profile slurm,pixi`.
3. Slurm allocates compute nodes for CPU-intensive stages (e.g. SCTransform integration, CopyKAT CNV, hdWGCNA).
4. Terminal logs stream live back to your browser over an encrypted SSH connection.
