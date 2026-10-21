/**
 * Cluster Execution & Remote SSH Connector Controller
 */
const ClusterController = {
  activeSession: null,

  init() {
    // Add event listeners if needed
  },

  openModal() {
    const modal = document.getElementById("cluster-modal");
    if (modal) modal.classList.add("active");
  },

  async connect() {
    const host = document.getElementById("cluster-ssh-host").value.trim();
    const user = document.getElementById("cluster-ssh-user").value.trim();
    const pass = document.getElementById("cluster-ssh-pass").value;
    const port = parseInt(document.getElementById("cluster-ssh-port").value || "22", 10);
    const feedback = document.getElementById("cluster-connect-feedback");

    if (feedback) feedback.innerHTML = `<div style="padding: 8px; color: #2563eb;">Connecting to cluster...</div>`;

    try {
      const res = await fetch("/api/cluster/connect", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ssh_host: host,
          ssh_user: user,
          ssh_password: pass,
          ssh_port: port
        })
      });

      const data = await res.json();
      if (data.success) {
        if (window.RemoteProfilesController) {
          window.RemoteProfilesController.setConnectedProfile({
            id: null,
            name: `${user}@${host}`,
            host: host,
            user: user
          });
        }
        if (feedback) {
          feedback.innerHTML = `
            <div style="padding: 10px; background: #ecfdf5; color: #065f46; border: 1px solid #a7f3d0; border-radius: 6px; font-size: 13px;">
              <strong>✔ ${data.message}</strong><br>
              Home Directory: <code>${data.home_dir}</code><br>
              Detected Slurm Queues: ${data.queues ? data.queues.map(q => `<span class="status-badge online" style="font-size:10px; margin-right:4px;">${q}</span>`).join("") : "None"}
            </div>
          `;
        }
        // Open Directory Browser
        const dirBrowser = document.getElementById("cluster-dir-browser");
        if (dirBrowser) dirBrowser.style.display = "block";
        this.browse(data.recommended_project_dir || data.home_dir);
      } else {
        if (feedback) {
          feedback.innerHTML = `<div style="padding: 10px; background: #fef2f2; color: #991b1b; border: 1px solid #fecaca; border-radius: 6px; font-size: 13px;">✖ ${data.message}</div>`;
        }
      }
    } catch (e) {
      if (feedback) feedback.innerHTML = `<div style="padding: 10px; background: #fef2f2; color: #991b1b; border: 1px solid #fecaca; border-radius: 6px; font-size: 13px;">✖ Connection failed: ${e.message}</div>`;
    }
  },

  async browse(targetPath) {
    const host = document.getElementById("cluster-ssh-host").value.trim();
    const user = document.getElementById("cluster-ssh-user").value.trim();
    const pass = document.getElementById("cluster-ssh-pass").value;
    const port = parseInt(document.getElementById("cluster-ssh-port").value || "22", 10);
    const listEl = document.getElementById("cluster-dirs-list");
    const pathInput = document.getElementById("cluster-current-path");

    if (pathInput) pathInput.value = targetPath;
    if (listEl) listEl.innerHTML = `<div style="padding: 6px; color: #94a3b8;">Loading directories...</div>`;

    try {
      const res = await fetch("/api/cluster/browse", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ssh_host: host,
          ssh_user: user,
          ssh_password: pass,
          ssh_port: port,
          path: targetPath
        })
      });

      const data = await res.json();
      if (data.current_path && pathInput) pathInput.value = data.current_path;

      if (listEl) {
        let html = "";
        if (data.parent_path && data.parent_path !== data.current_path) {
          html += `<div style="padding: 4px 6px; cursor: pointer; color: #2563eb; font-weight: 600;" onclick="ClusterController.browse('${data.parent_path.replace(/'/g, "\\'")}')">📁 .. (parent directory)</div>`;
        }
        if (data.directories && data.directories.length > 0) {
          html += data.directories.map(d => `
            <div style="padding: 4px 6px; cursor: pointer; color: #334155; display: flex; align-items: center; justify-content: space-between;" onclick="ClusterController.browse('${d.path.replace(/'/g, "\\'")}')">
              <span>📁 ${d.name}</span>
              <span style="font-size: 10px; color: #94a3b8;">dir</span>
            </div>
          `).join("");
        } else {
          html += `<div style="padding: 6px; color: #94a3b8;">No subdirectories found.</div>`;
        }
        listEl.innerHTML = html;
      }
    } catch (e) {
      if (listEl) listEl.innerHTML = `<div style="padding: 6px; color: #ef4444;">Failed to browse directory: ${e.message}</div>`;
    }
  },

  async useSelectedDir() {
    const selectedPath = document.getElementById("cluster-current-path").value.trim();
    if (!selectedPath) return;

    const host = document.getElementById("cluster-ssh-host").value.trim();
    const user = document.getElementById("cluster-ssh-user").value.trim();
    const pass = document.getElementById("cluster-ssh-pass").value;
    const port = parseInt(document.getElementById("cluster-ssh-port").value || "22", 10);

    try {
      const res = await fetch("/api/cluster/create_directory", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ssh_host: host,
          ssh_user: user,
          ssh_password: pass,
          ssh_port: port,
          path: selectedPath
        })
      });

      const data = await res.json();
      if (data.success) {
        // Populate param fields if present
        const workDirField = document.querySelector('[data-key="remote_work_dir"] input');
        if (workDirField) {
          workDirField.value = selectedPath;
          if (window.ParamsController) window.ParamsController.updateParam("remote_work_dir", selectedPath);
        }
        const sshHostField = document.querySelector('[data-key="ssh_host"] input');
        if (sshHostField && host) {
          sshHostField.value = host;
          if (window.ParamsController) window.ParamsController.updateParam("ssh_host", host);
        }
        const sshUserField = document.querySelector('[data-key="ssh_user"] input');
        if (sshUserField && user) {
          sshUserField.value = user;
          if (window.ParamsController) window.ParamsController.updateParam("ssh_user", user);
        }

        if (window.SessionsController) {
          window.SessionsController.showToast(`Selected project directory location: ${selectedPath}`);
        }
        document.getElementById("cluster-modal").classList.remove("active");
      }
    } catch (e) {
      alert("Error: " + e.message);
    }
  }
};

window.ClusterController = ClusterController;
const RemoteProfilesController = {
  profiles: [],
  connectedProfile: null, // Holds active { id, name, host, user } or null. Cleared on refresh!

  init() {
    // Automatically disconnect on every page refresh / load
    this.connectedProfile = null;
    this.updateConnectionUI();

    this.loadProfiles();
    const btn = document.getElementById("btn-detect-remote-env");
    if (btn) {
      btn.addEventListener("click", () => this.detectEnv());
    }

    // Explicitly reset on page unload / refresh
    window.addEventListener("beforeunload", () => {
      this.connectedProfile = null;
    });
  },

  setConnectedProfile(profile) {
    if (!profile) return;
    this.connectedProfile = {
      id: profile.id || null,
      name: profile.name || `${profile.user}@${profile.host}`,
      host: profile.host,
      user: profile.user
    };
    this.updateConnectionUI();
    if (window.ExplorerController) {
      ExplorerController.loadStages(ExplorerController.selectedRunId);
    }
    if (window.SessionsController) {
      window.SessionsController.showToast(`Cluster connected: ${this.connectedProfile.user}@${this.connectedProfile.host}`);
    }
  },

  disconnectProfile() {
    const prev = this.connectedProfile;
    this.connectedProfile = null;
    this.updateConnectionUI();
    if (window.ExplorerController) {
      ExplorerController.loadStages(ExplorerController.selectedRunId);
    }
    if (prev && window.SessionsController) {
      window.SessionsController.showToast(`Cluster disconnected (${prev.user}@${prev.host})`);
    }
  },

  async toggleConnection() {
    if (this.connectedProfile) {
      this.disconnectProfile();
      return;
    }

    const select = document.getElementById('remote-profile-select');
    const profileId = select ? select.value : null;
    if (!profileId) {
      alert("Please select a cluster profile to connect.");
      const modal = document.getElementById('remote-profile-modal');
      if (modal) modal.classList.add('active');
      return;
    }

    await this.connectProfile(profileId);
  },

  async connectProfile(profileId) {
    const prof = this.profiles.find(p => p.id == profileId);
    const toggleBtn = document.getElementById('btn-cluster-toggle');
    if (toggleBtn) {
      toggleBtn.disabled = true;
      toggleBtn.innerHTML = '<span class="status-dot running" style="width:6px; height:6px;"></span> Connecting...';
    }

    const feedback = document.getElementById('remote-env-feedback');
    if (feedback) feedback.innerHTML = '<span style="color: #2563eb;">Connecting to remote cluster...</span>';

    try {
      const res = await fetch(`/api/cluster/test_profile/${profileId}`, { method: 'POST' });
      const data = await res.json();
      if (data.success) {
        this.setConnectedProfile(prof || { id: profileId, name: (prof && prof.name) || "Cluster", host: (prof && prof.host) || "", user: (prof && prof.user) || "" });
        if (feedback) feedback.innerHTML = `<span style="color: #166534; font-weight:600;">✔ Connection verified. Cluster is online!</span>`;
      } else {
        alert("Cluster connection failed: " + (data.message || "Host unreachable"));
        if (feedback) feedback.innerHTML = `<span style="color: #991b1b;">✖ Connection failed: ${data.message}</span>`;
        this.disconnectProfile();
      }
    } catch (e) {
      alert("Cluster connection error: " + e.message);
      if (feedback) feedback.innerHTML = `<span style="color: #991b1b;">✖ Connection error: ${e.message}</span>`;
      this.disconnectProfile();
    } finally {
      if (toggleBtn) toggleBtn.disabled = false;
      this.updateConnectionUI();
    }
  },

  onProfileSelectChanged() {
    const select = document.getElementById('remote-profile-select');
    if (this.connectedProfile && select && select.value != this.connectedProfile.id) {
      // Switched profile while connected
      this.disconnectProfile();
    }
  },

  handleTopBarClick() {
    if (this.connectedProfile) {
      if (confirm(`Cluster is currently online and connected as ${this.connectedProfile.user}@${this.connectedProfile.host}.\n\nDo you want to disconnect?`)) {
        this.disconnectProfile();
      }
    } else {
      // Switch to Run Monitor view and configure remote
      if (window.App) {
        App.switchView('runner');
      }
      const locSelect = document.getElementById('run-location-select');
      if (locSelect) {
        locSelect.value = 'remote';
        locSelect.dispatchEvent(new Event('change'));
      }
      const select = document.getElementById('remote-profile-select');
      if (select && select.value) {
        if (confirm(`Connect to saved cluster profile '${select.options[select.selectedIndex]?.text}'?`)) {
          this.connectProfile(select.value);
        }
      } else {
        const modal = document.getElementById('remote-profile-modal');
        if (modal) modal.classList.add('active');
      }
    }
  },

  updateConnectionUI() {
    // 1. Top bar button
    const headerBtn = document.getElementById('header-cluster-btn');
    const headerDot = document.getElementById('header-cluster-dot');
    const headerText = document.getElementById('header-cluster-text');

    if (headerBtn) {
      if (this.connectedProfile) {
        headerBtn.className = "status-badge online";
        headerBtn.style.background = "#dcfce7";
        headerBtn.style.borderColor = "#86efac";
        headerBtn.style.color = "#166534";
        headerBtn.style.fontWeight = "600";
        headerBtn.title = `Cluster Connected: ${this.connectedProfile.user}@${this.connectedProfile.host} (Online). Click to disconnect.`;
        if (headerDot) headerDot.style.background = "#16a34a";
        if (headerText) headerText.innerHTML = `${this.connectedProfile.user} (Cluster Connected)`;
      } else {
        headerBtn.className = "status-badge";
        headerBtn.style.background = "#f8fafc";
        headerBtn.style.borderColor = "#cbd5e1";
        headerBtn.style.color = "#64748b";
        headerBtn.style.fontWeight = "500";
        headerBtn.title = "Cluster Disconnected. Click to view and connect.";
        if (headerDot) headerDot.style.background = "#94a3b8";
        if (headerText) headerText.innerHTML = `Cluster: Disconnected`;
      }
    }

    // 2. Remote configuration panel button & banner
    const toggleBtn = document.getElementById('btn-cluster-toggle');
    const banner = document.getElementById('cluster-connection-banner');

    if (toggleBtn) {
      if (this.connectedProfile) {
        toggleBtn.textContent = "Disconnect";
        toggleBtn.className = "btn btn-danger btn-sm";
        toggleBtn.style.background = "#fee2e2";
        toggleBtn.style.borderColor = "#fca5a5";
        toggleBtn.style.color = "#991b1b";
        toggleBtn.style.fontWeight = "600";
      } else {
        toggleBtn.textContent = "Connect";
        toggleBtn.className = "btn btn-primary btn-sm";
        toggleBtn.style.background = "#3b82f6";
        toggleBtn.style.borderColor = "#2563eb";
        toggleBtn.style.color = "white";
        toggleBtn.style.fontWeight = "600";
      }
    }

    if (banner) {
      if (this.connectedProfile) {
        banner.style.display = "block";
        banner.style.background = "#ecfdf5";
        banner.style.border = "1px solid #a7f3d0";
        banner.style.color = "#065f46";
        banner.innerHTML = `<strong>Cluster Connected (Online):</strong> Active session established with <code>${this.connectedProfile.host}</code> as <strong>${this.connectedProfile.user}</strong>.`;
      } else {
        banner.style.display = "none";
        banner.innerHTML = "";
      }
    }
  },


  async installEnv() {
    const profileId = document.getElementById('remote-profile-select').value;
    const feedback = document.getElementById('remote-env-feedback');
    const installBtn = document.getElementById('btn-install-remote-env');
    
    if (!profileId) return;
    
    installBtn.disabled = true;
    installBtn.innerHTML = 'Installing... (This may take a minute)';
    feedback.innerHTML = '<span style="color: blue;">Attempting to install missing components (Nextflow, R packages)...</span>';
    
    try {
      const res = await fetch(`/api/cluster/install_env/${profileId}`, { method: 'POST' });
      const data = await res.json();
      
      if (data.success) {
        feedback.innerHTML = '<span style="color: green;">Installation successful! Click "Detect Remote Environment" again to verify.</span>';
      } else {
        feedback.innerHTML = `<span style="color: red;">Installation failed: ${data.message}</span>`;
      }
    } catch (e) {
      feedback.innerHTML = `<span style="color: red;">Error: ${e.message}</span>`;
    } finally {
      installBtn.disabled = false;
      installBtn.innerHTML = 'Install Missing Tools';
    }
  },
  async loadProfiles() {
    try {
      const res = await fetch('/api/cluster/profiles');
      const data = await res.json();
      if (data.success) {
        this.profiles = data.profiles;
        this.renderProfiles();
        this.populateSelects();
      }
    } catch (e) {
      console.error("Error loading remote profiles", e);
    }
  },

  renderProfiles() {
    const tbody = document.getElementById('remote-profiles-tbody');
    if (!tbody) return;
    if (this.profiles.length === 0) {
      tbody.innerHTML = '<tr><td colspan="4" style="text-align: center; padding: 10px; color: #94a3b8;">No profiles saved yet.</td></tr>';
      return;
    }
    
    tbody.innerHTML = this.profiles.map(p => `
      <tr>
        <td style="font-weight: 600;">${p.name}</td>
        <td>${p.host}</td>
        <td>${p.user}</td>
        <td>
          <button class="btn btn-secondary btn-sm" onclick="RemoteProfilesController.testProfile(${p.id})">Test</button>
          <button class="btn btn-secondary btn-sm" onclick="RemoteProfilesController.deleteProfile(${p.id})">Delete</button>
        </td>
      </tr>
    `).join('');
  },
  
  populateSelects() {
    const select = document.getElementById('remote-profile-select');
    if (!select) return;
    
    const currentVal = select.value;
    select.innerHTML = '<option value="" disabled selected>Select a cluster profile...</option>' + 
      this.profiles.map(p => `<option value="${p.id}">${p.name} (${p.user}@${p.host})</option>`).join('');
      
    if (currentVal && this.profiles.find(p => p.id == currentVal)) {
      select.value = currentVal;
    }
  },

  async addProfile() {
    const name = document.getElementById('prof-name').value;
    const host = document.getElementById('prof-host').value;
    const user = document.getElementById('prof-user').value;
    const port = document.getElementById('prof-port').value;
    const auth = document.getElementById('prof-auth').value;
    const pass = document.getElementById('prof-pass').value;
    const key = document.getElementById('prof-key').value;
    
    if (!name || !host || !user) {
      alert("Name, Host, and User are required.");
      return;
    }

    try {
      const res = await fetch('/api/cluster/profiles', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name, host, user, port: parseInt(port), auth_method: auth,
          password: pass, private_key_path: key
        })
      });
      const data = await res.json();
      if (data.success) {
        document.getElementById('profile-action-feedback').innerHTML = '<span style="color: green;">Profile added successfully.</span>';
        this.loadProfiles();
      } else {
        document.getElementById('profile-action-feedback').innerHTML = '<span style="color: red;">Error: ' + data.detail + '</span>';
      }
    } catch (e) {
      document.getElementById('profile-action-feedback').innerHTML = '<span style="color: red;">Error: ' + e.message + '</span>';
    }
  },

  async deleteProfile(id) {
    if (!confirm("Are you sure you want to delete this profile?")) return;
    try {
      const res = await fetch(`/api/cluster/profiles/${id}`, { method: 'DELETE' });
      const data = await res.json();
      if (data.success) {
        this.loadProfiles();
      }
    } catch (e) {
      alert("Error deleting profile: " + e.message);
    }
  },

  async testProfile(id) {
    document.getElementById('profile-action-feedback').innerHTML = '<span style="color: blue;">Testing connection...</span>';
    try {
      const res = await fetch(`/api/cluster/test_profile/${id}`, { method: 'POST' });
      const data = await res.json();
      
      if (data.success) {
        let msg = `<strong>✔ SSH Connection Successful!</strong><br>`;
        if (data.resources) {
          msg += `OS: ${data.resources.os}<br>`;
          msg += `CPU: ${data.resources.cpu_cores} cores<br>`;
          msg += `RAM: ${Math.round(data.resources.mem_total_bytes / 1024 / 1024 / 1024)} GB<br>`;
          msg += `GPU: ${data.resources.gpu_info}<br>`;
        }
        document.getElementById('profile-action-feedback').innerHTML = `<div style="background: #ecfdf5; padding: 10px; border: 1px solid #a7f3d0; border-radius: 6px; color: #065f46;">${msg}</div>`;
        const prof = this.profiles.find(p => p.id == id);
        if (prof) {
          this.setConnectedProfile(prof);
          const select = document.getElementById('remote-profile-select');
          if (select) select.value = id;
        }
      } else {
        document.getElementById('profile-action-feedback').innerHTML = `<div style="background: #fef2f2; padding: 10px; border: 1px solid #fecaca; border-radius: 6px; color: #991b1b;">✖ ${data.message}</div>`;
      }
    } catch (e) {
      document.getElementById('profile-action-feedback').innerHTML = `<span style="color: red;">Error: ${e.message}</span>`;
    }
  },

  async detectEnv() {
    const profileId = document.getElementById('remote-profile-select').value;
    const feedback = document.getElementById('remote-env-feedback');
    if (!profileId) {
      feedback.innerHTML = '<span style="color: red;">Please select a saved profile first.</span>';
      return;
    }
    
    feedback.innerHTML = '<span style="color: blue;">Detecting environment...</span>';
    try {
      const remoteDir = document.getElementById('remote-dir-input') ? document.getElementById('remote-dir-input').value.trim() : "";
      const envInit = document.getElementById('remote-env-input') ? document.getElementById('remote-env-input').value.trim() : "";
      
      const res = await fetch(`/api/cluster/test_profile/${profileId}`, { 
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ env_init: envInit, remote_dir: remoteDir })
      });
      const data = await res.json();
      
      if (data.success && data.environment) {
        const env = data.environment;
        let html = '<div style="background: #ecfdf5; padding: 10px; border: 1px solid #a7f3d0; border-radius: 6px; color: #065f46; margin-top: 8px;">';
        html += `<strong>Environment Detected:</strong><br>`;
        html += `Python: ${env.python ? `✔ ${env.python}` : '✖ Not Found'}<br>`;
        html += `R: ${env.R ? `✔ ${env.R}` : '✖ Not Found'}<br>`;
        html += `Conda: ${env.conda ? `✔ ${env.conda}` : '✖ Not Found'}<br>`;
        html += `Nextflow: ${env.nextflow ? `✔ ${env.nextflow}` : '✖ Not Found'}<br>`;
        html += '</div>';
        feedback.innerHTML = html;
        const prof = this.profiles.find(p => p.id == profileId);
        if (prof) {
          this.setConnectedProfile(prof);
        }
      } else {
        feedback.innerHTML = `<span style="color: red;">Failed to detect: ${data.message}</span>`;
      }
    } catch (e) {
      feedback.innerHTML = `<span style="color: red;">Error: ${e.message}</span>`;
    }
  },

  openBrowser(targetInputId = 'remote-dir-input') {
    this.targetInputId = targetInputId;
    const profileId = document.getElementById('remote-profile-select').value;
    if (!profileId) {
      alert("Please select a saved remote profile first.");
      return;
    }
    document.getElementById('remote-dir-modal').classList.add('active');
    const currentInput = document.getElementById('remote-dir-input');
    const path = currentInput ? currentInput.value.trim() : "";
    this.browseDir(path);
  },

  async browseDir(targetPath) {
    const profileId = document.getElementById('remote-profile-select').value;
    const listEl = document.getElementById("cluster-dirs-list");
    const pathInput = document.getElementById("cluster-current-path");

    if (pathInput) pathInput.value = targetPath;
    if (listEl) listEl.innerHTML = `<div style="padding: 6px; color: #94a3b8;">Loading directories...</div>`;

    try {
      const res = await fetch(`/api/cluster/browse_profile/${profileId}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: targetPath })
      });

      const data = await res.json();
      if (data.current_path && pathInput) pathInput.value = data.current_path;

      if (listEl) {
        let html = "";
        if (data.parent_path && data.parent_path !== data.current_path) {
          html += `<div style="padding: 4px 6px; cursor: pointer; color: #2563eb; font-weight: 600;" onclick="RemoteProfilesController.browseDir('${data.parent_path.replace(/'/g, "\\'")}')">📁 .. (parent directory)</div>`;
        }
        if (data.directories && data.directories.length > 0) {
          html += data.directories.map(d => {
            const icon = d.is_dir ? "📁" : "📄";
            const typeLabel = d.is_dir ? "dir" : "file";
            const clickAction = d.is_dir 
              ? `RemoteProfilesController.browseDir('${d.path.replace(/'/g, "\\'")}')`
              : `RemoteProfilesController.selectFile('${d.path.replace(/'/g, "\\'")}')`;
            return `
            <div style="padding: 4px 6px; cursor: pointer; color: #334155; display: flex; align-items: center; justify-content: space-between;" onclick="${clickAction}">
              <span>${icon} ${d.name}</span>
              <span style="font-size: 10px; color: #94a3b8;">${typeLabel}</span>
            </div>
            `;
          }).join("");
        } else {
          html += `<div style="padding: 6px; color: #94a3b8;">No subdirectories found.</div>`;
        }
        listEl.innerHTML = html;
      }
    } catch (e) {
      if (listEl) listEl.innerHTML = `<div style="padding: 6px; color: #ef4444;">Failed to browse directory: ${e.message}</div>`;
    }
  },


  async createFolder() {
    const profileId = document.getElementById('remote-profile-select').value;
    if (!profileId) return;
    
    const currentPath = document.getElementById('cluster-current-path').value.trim();
    if (!currentPath) {
        alert("Please navigate to a valid directory first.");
        return;
    }
    
    let folderInput = document.getElementById('new-folder-name');
    
    // Fallback if HTML is cached and missing the input box: dynamically create it
    if (!folderInput) {
        const folderNamePrompt = prompt("Please enter the new folder name (e.g. run_02):");
        if (folderNamePrompt) {
            const newPathPrompt = currentPath.endsWith("/") ? currentPath + folderNamePrompt : currentPath + "/" + folderNamePrompt;
            this.executeMkdir(profileId, currentPath, newPathPrompt);
        }
        return;
    }
    
    const folderName = folderInput.value.trim();
    if (!folderName) {
        alert("Please enter a folder name in the box.");
        return;
    }
    
    // basic sanitization
    if (folderName.includes("/") || folderName.includes("..")) {
        alert("Invalid folder name.");
        return;
    }
    
    const newPath = currentPath.endsWith("/") ? currentPath + folderName : currentPath + "/" + folderName;
    this.executeMkdir(profileId, currentPath, newPath);
  },
  
  async executeMkdir(profileId, currentPath, newPath) {
    try {
      const res = await fetch(`/api/cluster/mkdir/${profileId}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ path: newPath })
      });
      const data = await res.json();
      if (data.success) {
        this.browseDir(currentPath);
        const folderInput = document.getElementById('new-folder-name');
        if (folderInput) {
            folderInput.value = '';
            document.getElementById('new-folder-container').style.display = 'none';
            document.getElementById('btn-show-new-folder').style.display = 'inline-block';
        }
      } else {
        alert("Failed to create folder: " + data.message);
      }
    } catch (e) {
      alert("Error creating folder: " + e.message);
    }
  },
  selectFile(filePath) {
    const pathInput = document.getElementById("cluster-current-path");
    if (pathInput) pathInput.value = filePath;
    this.selectDir();
  },
  selectDir() {
    const selectedPath = document.getElementById("cluster-current-path").value.trim();
    if (!selectedPath) return;
    const input = document.getElementById(this.targetInputId || "remote-dir-input");
    if (input) {
        input.value = selectedPath;
        input.dispatchEvent(new Event('change'));
    }
    document.getElementById('remote-dir-modal').classList.remove('active');
  }
};

window.RemoteProfilesController = RemoteProfilesController;

// Auto-load profiles on DOM ready
document.addEventListener("DOMContentLoaded", () => {
  RemoteProfilesController.init();
});
