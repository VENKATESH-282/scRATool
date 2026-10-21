// Samplesheet & Cluster Annotation Controller
const SamplesController = {
  samples: [],
  annotations: [],
  referenceCondition: "CTRL",

  init() {
    this.bindEvents();
    this.loadSamplesheet();
    this.loadAnnotations();
  },

  bindEvents() {
    // Row editing & persistence buttons
    const addBtn = document.getElementById("add-sample-row-btn");
    if (addBtn) addBtn.addEventListener("click", () => this.addSampleRow());
    
    const addRemoteBtn = document.getElementById("add-remote-url-btn");
    if (addRemoteBtn) addRemoteBtn.addEventListener("click", () => this.addRemoteUrlRow());
    
    const geoFetchBtn = document.getElementById("geo-fetch-btn");
    if (geoFetchBtn) geoFetchBtn.addEventListener("click", () => this.fetchGeoData());

    const saveSamplesBtn = document.getElementById("save-samplesheet-btn");
    if (saveSamplesBtn) saveSamplesBtn.addEventListener("click", () => this.saveSamplesheet());

    const validateBtn = document.getElementById("validate-samplesheet-btn");
    if (validateBtn) validateBtn.addEventListener("click", () => this.validate());

    const saveAnnotBtn = document.getElementById("save-annotations-btn");
    if (saveAnnotBtn) saveAnnotBtn.addEventListener("click", () => this.saveAnnotations());

    // Preset Templates Dropdown
    const presetSelect = document.getElementById("sample-preset-select");
    if (presetSelect) {
      presetSelect.addEventListener("change", (e) => {
        const val = e.target.value;
        if (val) {
          this.loadPreset(val);
          e.target.value = ""; // Reset dropdown after loading
        }
      });
    }

    // CSV Import (File Input)
    const importBtn = document.getElementById("btn-upload-csv");
    const fileInput = document.getElementById("samples-file-input");
    if (importBtn && fileInput) {
      importBtn.addEventListener("click", () => fileInput.click());
      fileInput.addEventListener("change", (e) => this.handleCsvFile(e));
    }

    // CSV Export
    const exportBtn = document.getElementById("btn-export-csv");
    if (exportBtn) {
      exportBtn.addEventListener("click", () => this.exportCsv());
    }

    // Prefix Directory Modal
    const prefixBtn = document.getElementById("btn-prefix-paths");
    if (prefixBtn) {
      prefixBtn.addEventListener("click", () => this.openPrefixModal());
    }

    const cancelPrefixBtn = document.getElementById("btn-cancel-prefix");
    const closePrefixBtn = document.getElementById("prefix-modal-close-btn");
    const prefixModal = document.getElementById("prefix-modal");
    if (cancelPrefixBtn) cancelPrefixBtn.addEventListener("click", () => this.closePrefixModal());
    if (closePrefixBtn) closePrefixBtn.addEventListener("click", () => this.closePrefixModal());
    if (prefixModal) {
      prefixModal.addEventListener("click", (e) => {
        if (e.target === prefixModal) this.closePrefixModal();
      });
    }

    const applyPrefixBtn = document.getElementById("btn-apply-prefix");
    if (applyPrefixBtn) {
      applyPrefixBtn.addEventListener("click", () => this.applyDirectoryPrefix());
    }

    // Reference Condition Dropdown
    const refSelect = document.getElementById("select-reference-condition");
    if (refSelect) {
      refSelect.addEventListener("change", (e) => {
        this.referenceCondition = e.target.value;
        this.updateDashboardReference(this.referenceCondition);
        if (window.SessionsController) {
          window.SessionsController.showToast(`Baseline reference condition set to: ${this.referenceCondition}`);
        }
      });
    }
  },

  async loadSamplesheet() {
    try {
      const token = window.SessionsController ? SessionsController.getToken() : null;
      const url = token ? `/api/samples?token=${encodeURIComponent(token)}` : "/api/samples";
      const res = await fetch(url);
      if (res.ok) {
        const data = await res.json();
        this.samples = data.samples || [];
        this.referenceCondition = data.reference_condition || "CTRL";
        this.renderSamplesTable();
        this.updateConditionsUI();
        this.updateDashboardStats(data);
      }
    } catch (e) {
      console.error("Failed to load samples:", e);
    }
  },

  updateConditionsUI() {
    // Extract unique conditions from current samples
    const uniqueConds = Array.from(new Set(this.samples.map(s => (s.condition || "").trim()).filter(Boolean)));
    
    // Update badge in toolbar
    const badge = document.getElementById("detected-conditions-badge");
    if (badge) {
      badge.textContent = uniqueConds.length > 0 ? uniqueConds.join(", ") : "(None detected)";
    }

    this.updateDashboardStats();
    // Update select dropdown
    const select = document.getElementById("select-reference-condition");
    if (select) {
      if (uniqueConds.length === 0) {
        select.innerHTML = `<option value="CTRL">CTRL</option>`;
        this.referenceCondition = "CTRL";
      } else {
        // If current referenceCondition is not in uniqueConds, pick default candidate
        if (!uniqueConds.includes(this.referenceCondition)) {
          if (uniqueConds.includes("CTRL")) this.referenceCondition = "CTRL";
          else if (uniqueConds.includes("WT")) this.referenceCondition = "WT";
          else if (uniqueConds.includes("Control")) this.referenceCondition = "Control";
          else this.referenceCondition = uniqueConds[0];
        }

        select.innerHTML = uniqueConds.map(c => `
          <option value="${c}" ${c === this.referenceCondition ? "selected" : ""}>${c}</option>
        `).join("");
      }
    }

    // Update Dashboard stats
    this.updateDashboardReference(this.referenceCondition);
    const condsEl = document.getElementById("stat-conditions-list");
    if (condsEl) {
      condsEl.textContent = uniqueConds.join(", ") || "-";
    }
  },

  updateDashboardStats(data) {
    const dataObj = data || {};
    const countEl = document.getElementById("stat-sample-count");
    if (countEl) countEl.textContent = this.samples.length || 0;

    const condsEl = document.getElementById("stat-conditions-list");
    if (condsEl) {
      const uniqueConds = Array.from(new Set(this.samples.map(s => (s.condition || "").trim()).filter(Boolean)));
      condsEl.textContent = uniqueConds.length > 0 ? uniqueConds.join(", ") : "-";
    }

    const ref = dataObj.reference_condition || this.referenceCondition;
    if (ref) {
      this.updateDashboardReference(ref);
    }
  },


  updateDashboardReference(ref) {
    const dashRefEl = document.getElementById("stat-reference-condition");
    if (dashRefEl) {
      dashRefEl.textContent = ref || "CTRL";
    }
  },

  toggleAllSamples(checked) {
    this.samples.forEach(s => s.enabled = checked);
    this.renderSamplesTable();
  },

  renderSamplesTable() {
    const tbody = document.getElementById("samplesheet-tbody");
    if (!tbody) return;

    if (this.samples.length === 0) {
      tbody.innerHTML = `<tr><td colspan="6" style="text-align: center; color: #94a3b8; padding: 24px;">No samples configured yet. Load a template or click '+ Add Sample' above.</td></tr>`;
      return;
    }

    tbody.innerHTML = this.samples.map((s, idx) => `
      <tr data-idx="${idx}">
        <td><input type="text" class="form-input" style="padding: 5px 8px; font-size: 12px; font-weight: 500;" value="${escapeHtml(s.sample_id)}" onchange="SamplesController.updateField(${idx}, 'sample_id', this.value)"></td>
        <td><input type="text" class="form-input" style="padding: 5px 8px; font-size: 12px; font-weight: 600; color: #1e40af;" value="${escapeHtml(s.condition)}" onchange="SamplesController.updateField(${idx}, 'condition', this.value)"></td>
        <td><input type="text" class="form-input" style="padding: 5px 8px; font-size: 12px;" value="${escapeHtml(s.patient_id || '')}" placeholder="(optional)" onchange="SamplesController.updateField(${idx}, 'patient_id', this.value)"></td>
        <td>
          <div style="display: flex; gap: 4px;">
            <input type="text" id="sample-path-input-${idx}" class="form-input" style="padding: 5px 8px; font-size: 12px; font-family: monospace; flex: 1;" value="${escapeHtml(s.file_path)}" placeholder="/path/to/matrix (.txt, .csv, .h5, .rds, 10x dir)" onchange="SamplesController.updateField(${idx}, 'file_path', this.value)">
            <button class="btn btn-secondary btn-sm" onclick="RemoteProfilesController.openBrowser('sample-path-input-${idx}')" title="Browse Cluster" style="padding: 2px 6px; font-size: 12px;">📁</button>
          </div>
        </td>
        <td style="text-align: center;">
          ${s.file_exists
            ? '<span class="status-badge online" style="font-size: 10px; display: inline-flex;">Found on disk</span>'
            : `<div style="display:flex; flex-direction:column; align-items:center; gap:4px;">
                 <span class="status-badge" style="background:#fee2e2; color:#991b1b; font-size: 10px; display: inline-flex;">Not Found</span>
                 <button class="btn btn-secondary btn-sm" onclick="SamplesController.verifyRemotePaths()" style="padding: 2px 6px; font-size: 10px; border-color: #3b82f6; color: #3b82f6;" title="Check if this file exists on the cluster">Check Remote</button>
               </div>`}
        </td>
        <td style="text-align: center;">
          <button class="btn btn-danger" style="padding: 3px 7px; font-size: 12px; line-height: 1;" title="Remove sample row" onclick="SamplesController.removeRow(${idx})">×</button>
        </td>
      </tr>
    `).join("");

    const countEl = document.getElementById("stat-sample-count");
    if (countEl) countEl.textContent = this.samples.length;
  },

  updateField(idx, field, value) {
    if (this.samples[idx]) {
      this.samples[idx][field] = value.trim();
      if (field === "condition") {
        this.updateConditionsUI();
      }
    }
  },

  async fetchGeoData() {
    const inputEl = document.getElementById("geo-accession-input");
    const statusEl = document.getElementById("geo-fetch-status");
    if (!inputEl || !statusEl) return;
    
    const accession = inputEl.value.trim();
    if (!accession) {
      statusEl.textContent = "Please enter an accession number.";
      statusEl.style.color = "#ef4444";
      return;
    }
    
    statusEl.textContent = "Fetching data from NCBI GEO...";
    statusEl.style.color = "#64748b";
    document.getElementById("geo-fetch-btn").disabled = true;
    
    try {
      const res = await fetch(`/api/samples/geo_fetch?accession=${encodeURIComponent(accession)}`);
      const data = await res.json();
      
      if (!res.ok) {
        throw new Error(data.detail || "Failed to fetch");
      }
      
      const files = data.files;
      if (!files || files.length === 0) {
        statusEl.textContent = "No valid supplementary files found.";
        statusEl.style.color = "#ef4444";
        document.getElementById("geo-fetch-btn").disabled = false;
        return;
      }
      
      const curCond = this.referenceCondition || "CTRL";
      let added = 0;
      
      for (const url of files) {
        // filter out unwanted extensions if necessary, but we'll accept tar, gz, h5, h5ad
        let sample_name = `GEO_${this.samples.length + 1}`;
        const filename = url.split('/').pop();
        const match = filename.match(/(GSM\d+)/i);
        if (match) {
          sample_name = match[1];
        } else {
          const cleanName = filename.replace(/\.(txt|csv|tsv|h5|h5ad|rds)(\.gz)?$/i, '').replace(/^GSE\d+_raw\.(expMatrix_)?/i, '').replace(/^GSE\d+_/i, '');
          if (cleanName) sample_name = cleanName;
        }
        
        let sampleCond = curCond;
        if (/tumor|treat|stim|mut|ko|disease/i.test(filename)) {
          sampleCond = "TREATED";
        } else if (/pbmc|ctrl|control|wt|normal|healthy/i.test(filename)) {
          sampleCond = "CTRL";
        }
        
        this.samples.push({
          sample_id: sample_name,
          condition: sampleCond,
          patient_id: "",
          file_path: url,
          file_exists: true // Bypass local validation for remote URLs
        });
        added++;
      }
      
      this.renderSamplesTable();
      this.updateConditionsUI();
      
      statusEl.textContent = `Successfully added ${added} file(s) to the samplesheet!`;
      statusEl.style.color = "#10b981";
      inputEl.value = "";
    } catch (e) {
      statusEl.textContent = e.message;
      statusEl.style.color = "#ef4444";
    } finally {
      document.getElementById("geo-fetch-btn").disabled = false;
    }
  },

  addRemoteUrlRow() {
    const url = prompt("Enter a direct HTTP or FTP download URL (e.g., from GEO):\n\nSupported formats: .h5, .h5ad, .txt.gz, .csv.gz, .mtx.gz");
    if (!url) return;
    const curCond = this.referenceCondition || "CTRL";
    
    let sample_name = `GEO_Sample_${this.samples.length + 1}`;
    // try to guess sample name from GSM
    const match = url.match(/GSM\d+/i);
    if (match) {
      sample_name = match[0];
    }
    
    this.samples.push({
      sample_id: sample_name,
      condition: curCond,
      patient_id: "",
      file_path: url.trim(),
      file_exists: true // Bypass local validation for remote URLs
    });
    this.renderSamplesTable();
    this.updateConditionsUI();
  },

  addSampleRow() {
    const curCond = this.referenceCondition || "CTRL";
    this.samples.push({
      sample_id: `Sample_${this.samples.length + 1}`,
      condition: curCond,
      patient_id: "",
      file_path: "",
      file_exists: false
    });
    this.renderSamplesTable();
    this.updateConditionsUI();
  },

  removeRow(idx) {
    this.samples.splice(idx, 1);
    this.renderSamplesTable();
    this.updateConditionsUI();
  },

  async loadPreset(presetId) {
    try {
      const token = window.SessionsController ? SessionsController.getToken() : null;
      const url = token
        ? `/api/samples/presets/${encodeURIComponent(presetId)}?token=${encodeURIComponent(token)}`
        : `/api/samples/presets/${encodeURIComponent(presetId)}`;

      const res = await fetch(url, { method: "POST" });
      if (!res.ok) {
        const err = await res.json();
        throw new Error(err.detail || "Failed to load preset");
      }

      const resData = await res.json();
      const data = resData.data;
      this.samples = data.samples || [];
      this.referenceCondition = data.reference_condition || "CTRL";
      this.renderSamplesTable();
      this.updateConditionsUI();
      this.updateDashboardStats(data);

      if (window.SessionsController) {
        window.SessionsController.showToast(resData.message || `Loaded template: ${presetId}`);
      }
    } catch (e) {
      alert("Error loading template: " + e.message);
    }
  },

  handleCsvFile(event) {
    const file = event.target.files && event.target.files[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = (e) => {
      const content = e.target.result;
      this.parseAndApplyCsvContent(content, file.name);
    };
    reader.readAsText(file);
    // Reset file input so same file can be re-selected if desired
    event.target.value = "";
  },

  parseAndApplyCsvContent(content, filename) {
    const lines = content.split(/\r?\n/).filter(line => line.trim().length > 0);
    if (lines.length < 2) {
      alert("Invalid CSV: Must have at least 1 header row and 1 data row.");
      return;
    }

    // Parse header
    const headers = lines[0].split(",").map(h => h.trim().toLowerCase().replace(/^["']|["']$/g, ""));
    const sIdIdx = headers.indexOf("sample_id");
    const condIdx = headers.indexOf("condition");
    const fPathIdx = headers.indexOf("file_path");
    const pIdIdx = headers.indexOf("patient_id");

    if (sIdIdx === -1 || condIdx === -1 || fPathIdx === -1) {
      alert("CSV missing required columns! Expected headers: sample_id, condition, file_path (and optional patient_id). Found: " + headers.join(", "));
      return;
    }

    const parsedSamples = [];
    for (let i = 1; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line) continue;
      // Basic CSV comma splitting (handling optional quotes)
      const cols = this.splitCsvLine(line);
      const sId = (cols[sIdIdx] || "").trim();
      const cond = (cols[condIdx] || "").trim();
      const fPath = (cols[fPathIdx] || "").trim();
      const pId = pIdIdx !== -1 ? (cols[pIdIdx] || "").trim() : "";

      if (sId) {
        parsedSamples.push({
          sample_id: sId,
          condition: cond,
          patient_id: pId,
          file_path: fPath,
          file_exists: false
        });
      }
    }

    if (parsedSamples.length === 0) {
      alert("No valid sample rows found in CSV.");
      return;
    }

    this.samples = parsedSamples;
    this.renderSamplesTable();
    this.updateConditionsUI();

    if (window.SessionsController) {
      window.SessionsController.showToast(`Imported ${this.samples.length} samples from '${filename}'. Click 'Save Changes' to commit.`);
    }
  },

  splitCsvLine(text) {
    // Robust regex-based CSV line parser supporting quoted values
    const result = [];
    let cur = "";
    let inQuotes = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (c === '"') {
        inQuotes = !inQuotes;
      } else if (c === ',' && !inQuotes) {
        result.push(cur.trim().replace(/^"|"$/g, ""));
        cur = "";
      } else {
        cur += c;
      }
    }
    result.push(cur.trim().replace(/^"|"$/g, ""));
    return result;
  },

  exportCsv() {
    if (this.samples.length === 0) {
      alert("No samples to export.");
      return;
    }

    const rows = [["sample_id", "condition", "patient_id", "file_path"]];
    this.samples.forEach(s => {
      rows.push([
        s.sample_id,
        s.condition,
        s.patient_id || "",
        s.file_path
      ]);
    });

    const csvContent = "data:text/csv;charset=utf-8," + rows.map(e => e.map(val => `"${String(val).replace(/"/g, '""')}"`).join(",")).join("\n");
    const encodedUri = encodeURI(csvContent);
    const link = document.createElement("a");
    link.setAttribute("href", encodedUri);
    const token = window.SessionsController ? SessionsController.getToken() : "session";
    link.setAttribute("download", `samples_${token.slice(0, 9)}.csv`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  },

  openPrefixModal() {
    const modal = document.getElementById("prefix-modal");
    if (modal) modal.classList.add("active");
    const input = document.getElementById("prefix-input-path");
    if (input) input.focus();
  },

  closePrefixModal() {
    const modal = document.getElementById("prefix-modal");
    if (modal) modal.classList.remove("active");
  },

  applyDirectoryPrefix() {
    const input = document.getElementById("prefix-input-path");
    if (!input) return;

    let prefix = input.value.trim();
    if (!prefix) {
      alert("Please enter a base directory path.");
      return;
    }

    if (!prefix.endsWith("/")) prefix += "/";

    let modifiedCount = 0;
    this.samples.forEach(s => {
      let path = s.file_path.trim();
      if (!path) return;
      // If path does not already begin with prefix
      if (!path.startsWith(prefix)) {
        // Strip leading slash if any
        if (path.startsWith("/")) {
          // If already an absolute path, replace the parent folder or prepend if requested
          // If user gave full base path e.g. /scratch/data/.../ and file was relative or filename:
          const filename = path.split("/").pop();
          s.file_path = prefix + filename;
        } else {
          s.file_path = prefix + path;
        }
        modifiedCount++;
      }
    });

    this.renderSamplesTable();
    this.closePrefixModal();

    if (window.SessionsController) {
      window.SessionsController.showToast(`Updated paths for ${modifiedCount} samples with prefix: ${prefix}`);
    }
  },

  async verifyRemotePaths() {
    const profileId = document.getElementById('remote-profile-select') ? document.getElementById('remote-profile-select').value : null;
    if (!profileId) {
      alert("Please go to the Run Monitor tab and select a Remote Profile first!");
      return;
    }
    
    const feedbackEl = document.getElementById("samplesheet-feedback");
    if (feedbackEl) {
      feedbackEl.innerHTML = `<div style="padding: 10px; background: #eff6ff; color: #1e3a8a; border: 1px solid #bfdbfe; border-radius: 6px; font-size: 13px;">Checking paths on remote cluster... Please wait.</div>`;
    }

    try {
      const res = await fetch(`/api/cluster/verify_paths/${profileId}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ samples: this.samples })
      });
      
      const data = await res.json();
      if (!res.ok) {
        throw new Error(data.detail || data.message || "Failed to verify paths");
      }
      
      
      const newSamples = data.samples || this.samples;
      for (let i = 0; i < this.samples.length; i++) {
          if (this.samples[i] && this.samples[i].file_exists && newSamples[i]) {
              newSamples[i].file_exists = true; // Preserve remote verification!
          }
      }
      this.samples = newSamples;

      this.renderSamplesTable();
      
      if (feedbackEl) {
        const found = this.samples.filter(s => s.file_exists).length;
        const missing = this.samples.length - found;
        if (missing === 0) {
          feedbackEl.innerHTML = `<div style="padding: 10px 14px; background: #ecfdf5; color: #065f46; border: 1px solid #a7f3d0; border-radius: 6px; font-size: 13px;">✔ All ${this.samples.length} paths exist on the remote cluster!</div>`;
        } else {
          feedbackEl.innerHTML = `<div style="padding: 10px 14px; background: #fffbeb; color: #92400e; border: 1px solid #fde68a; border-radius: 6px; font-size: 13px;">⚠️ ${found} found, ${missing} missing on the remote cluster.</div>`;
        }
      }
    } catch (e) {
      alert("Remote verification failed: " + e.message);
      if (feedbackEl) feedbackEl.innerHTML = "";
    }
  },

  async validate() {
    const feedbackEl = document.getElementById("samplesheet-feedback");
    try {
      const token = window.SessionsController ? SessionsController.getToken() : null;
      // First save to make sure server validates the latest table in memory
      await this.saveSamplesheet(false);

      const url = token ? `/api/samples?token=${encodeURIComponent(token)}` : "/api/samples";
      const res = await fetch(url);
      const data = await res.json();
      
      const newSamples = data.samples || this.samples;
      for (let i = 0; i < this.samples.length; i++) {
          if (this.samples[i] && this.samples[i].file_exists && newSamples[i]) {
              newSamples[i].file_exists = true; // Preserve remote verification!
          }
      }
      this.samples = newSamples;

      this.renderSamplesTable();

      if (feedbackEl) {
        if (data.valid && (!data.warnings || data.warnings.length === 0)) {
          feedbackEl.innerHTML = `<div style="padding: 10px 14px; background: #ecfdf5; color: #065f46; border: 1px solid #a7f3d0; border-radius: 6px; font-size: 13px;">✔ All ${data.total_samples} samples validated successfully. Matrices exist on disk.</div>`;
        } else {
          let html = '<div style="padding: 10px 14px; background: #fffbeb; color: #92400e; border: 1px solid #fde68a; border-radius: 6px; font-size: 13px;">';
          if (data.errors && data.errors.length) {
            html += `<strong>Errors:</strong><ul style="margin: 4px 0 0 16px;">${data.errors.map(e => `<li>${escapeHtml(e)}</li>`).join("")}</ul>`;
          }
          if (data.warnings && data.warnings.length) {
            html += `<strong>Warnings:</strong><ul style="margin: 4px 0 0 16px;">${data.warnings.map(w => `<li>${escapeHtml(w)}</li>`).join("")}</ul>`;
          }
          html += '</div>';
          feedbackEl.innerHTML = html;
        }
      }
    } catch (e) {
      alert("Validation failed: " + e.message);
    }
  },

  async saveSamplesheet(showToastNotification = true) {
    try {
      const token = window.SessionsController ? SessionsController.getToken() : null;
      const res = await fetch("/api/samples", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          token: token,
          reference_condition: this.referenceCondition,
          samples: this.samples
        })
      });

      if (res.ok) {
        const resData = await res.json();
        if (resData.data) {
          
          const newSamples = resData.data.samples || this.samples;
          for (let i = 0; i < this.samples.length; i++) {
              if (this.samples[i] && this.samples[i].file_exists && newSamples[i]) {
                  newSamples[i].file_exists = true; // Preserve remote verification!
              }
          }
          this.samples = newSamples;

          this.renderSamplesTable();
        }
        if (showToastNotification) {
          const isCluster = window.RemoteProfilesController && window.RemoteProfilesController.connectedProfile;
          if (isCluster) {
            this.syncToCluster();
          } else {
            if (window.SessionsController) {
              window.SessionsController.showToast("Samplesheet saved locally to session workspace!");
            } else {
              alert("Samplesheet saved successfully!");
            }
          }
        }
      } else {
        const err = await res.json();
        alert("Error saving samplesheet: " + JSON.stringify(err));
      }
    } catch (e) {
      alert("Network error: " + e.message);
    }
  },

  async syncToCluster() {
    const profile = window.RemoteProfilesController ? window.RemoteProfilesController.connectedProfile : null;
    const select = document.getElementById('remote-profile-select');
    const profileId = profile ? profile.id : (select ? select.value : null);
    
    if (!profileId) {
      alert("Please connect to a cluster profile first (via the top-bar button or Run Monitor tab)!");
      return false;
    }
    
    const remoteDirInput = document.getElementById('remote-dir-input');
    const remoteDir = remoteDirInput && remoteDirInput.value.trim() ? remoteDirInput.value.trim() : (localStorage.getItem('scratool_remote_dir') || "");
    
    const feedbackEl = document.getElementById("samplesheet-feedback");
    if (feedbackEl) {
      feedbackEl.innerHTML = `<div style="padding: 10px; background: #eff6ff; color: #1e3a8a; border: 1px solid #bfdbfe; border-radius: 6px; font-size: 13px;">Syncing samplesheet to remote cluster (${remoteDir}/samples.csv)... Please wait.</div>`;
    }
    
    try {
      const res = await fetch(`/api/cluster/sync_samplesheet/${profileId}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          remote_dir: remoteDir,
          samples: this.samples
        })
      });
      const data = await res.json();
      if (res.ok && data.success) {
        if (feedbackEl) {
          feedbackEl.innerHTML = `<div style="padding: 10px 14px; background: #ecfdf5; color: #065f46; border: 1px solid #a7f3d0; border-radius: 6px; font-size: 13px;">✔ ${data.message}</div>`;
        }
        if (window.SessionsController) {
          window.SessionsController.showToast(`✔ Synced samples.csv to cluster at ${data.remote_path}`);
        }
        return true;
      } else {
        throw new Error(data.detail || data.message || "Failed to sync to cluster");
      }
    } catch (e) {
      if (feedbackEl) {
        feedbackEl.innerHTML = `<div style="padding: 10px 14px; background: #fef2f2; color: #991b1b; border: 1px solid #fecaca; border-radius: 6px; font-size: 13px;">✖ Sync failed: ${e.message}</div>`;
      }
      alert("Failed to sync samples.csv to cluster: " + e.message);
      return false;
    }
  },

  async loadAnnotations() {
    try {
      const res = await fetch("/api/samples/annotations");
      if (res.ok) {
        const data = await res.json();
        this.annotations = data.annotations || [];
        this.renderAnnotationsTable();
      }
    } catch (e) {
      console.error("Failed to load annotations:", e);
    }
  },

  toggleAllClusters(checked) {
    this.annotations.forEach(a => a.enabled = checked);
    this.renderAnnotationsTable();
  },

  renderAnnotationsTable() {
    const tbody = document.getElementById("annotations-tbody");
    if (!tbody) return;

    if (this.annotations.length === 0) {
      tbody.innerHTML = `
        <tr>
          <td colspan="5" style="text-align: center; color: #64748b; padding: 32px 16px;">
            <div style="font-weight: 600; font-size: 14px; margin-bottom: 6px; color: #334155;">No Cluster Annotations Generated Yet</div>
            <div style="font-size: 13px; max-width: 520px; margin: 0 auto; line-height: 1.5; color: #64748b;">
              Unsupervised clusters and biological cell-type predictions will be automatically populated here after executing the pipeline (Stage 04: Clustering & Stage 05: Cell Annotation). You can also click <strong>+ Add Cluster Row</strong> to define custom cluster mappings manually.
            </div>
          </td>
        </tr>
      `;
      return;
    }

    tbody.innerHTML = this.annotations.map((a, idx) => `
      <tr>
        <td style="text-align: center;">
          <input type="checkbox" style="width: 16px; height: 16px; cursor: pointer;" ${a.enabled !== false ? "checked" : ""} onchange="SamplesController.updateAnnotField(${idx}, 'enabled', this.checked)" title="Enable or disable cluster for analysis">
        </td>
        <td><input type="text" class="form-input" style="padding: 4px 8px; font-size: 12px; font-weight: 600;" value="${escapeHtml(a.cluster)}" onchange="SamplesController.updateAnnotField(${idx}, 'cluster', this.value)"></td>
        <td>${escapeHtml(a.n_cells || "-")}</td>
        <td style="color: #64748b; font-size: 12px;">${escapeHtml(a.sctype_type || a.singler_type || "Unassigned")}</td>
        <td>
          <input type="text" class="form-input" style="padding: 4px 8px; font-size: 12px;" value="${escapeHtml(a.consensus_annotation || '')}" onchange="SamplesController.updateAnnotField(${idx}, 'consensus_annotation', this.value)">
        </td>
      </tr>
    `).join("");
  },

  addAnnotationRow() {
    const nextClusterId = String(this.annotations.length);
    this.annotations.push({
      cluster: nextClusterId,
      n_cells: "-",
      sctype_type: "Unassigned",
      singler_type: "Unassigned",
      consensus_annotation: "",
      enabled: true
    });
    this.renderAnnotationsTable();
  },

  updateAnnot(idx, value) {
    this.updateAnnotField(idx, 'consensus_annotation', value);
  },

  updateAnnotField(idx, field, value) {
    if (this.annotations[idx]) {
      this.annotations[idx][field] = typeof value === "string" ? value.trim() : value;
    }
  },

  async saveAnnotations() {
    try {
      const res = await fetch("/api/samples/annotations", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ annotations: this.annotations })
      });
      if (res.ok) {
        if (window.SessionsController) {
          window.SessionsController.showToast("Cluster annotations saved successfully!");
        } else {
          alert("Annotations saved successfully!");
        }
      } else {
        const err = await res.json();
        alert("Error saving: " + JSON.stringify(err));
      }
    } catch (e) {
      alert("Error saving: " + e.message);
    }
  }
};

window.SamplesController = SamplesController;
