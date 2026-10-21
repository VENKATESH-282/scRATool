// Run Execution & Live Monitor Controller
const RunnerController = {
  activeRunId: null,
  pollTimer: null,
  logOffset: 0,
  autoscroll: true,

  init() {
    this.bindEvents();
    this.renderDefaultStages();
    this.renderCurrentConfigPreview();
  },

  bindEvents() {
    const startBtn = document.getElementById("start-run-btn");
    if (startBtn) startBtn.addEventListener("click", () => this.startRun());

    const cancelBtn = document.getElementById("cancel-run-btn");
    if (cancelBtn) cancelBtn.addEventListener("click", () => this.cancelRun());

    const clearLogBtn = document.getElementById("clear-log-btn");
    if (clearLogBtn) clearLogBtn.addEventListener("click", () => this.clearLog());

    const autoscrollCb = document.getElementById("autoscroll-cb");
    if (autoscrollCb) autoscrollCb.addEventListener("change", (e) => this.autoscroll = e.target.checked);

    const downloadLogBtn = document.getElementById("download-log-btn");
    if (downloadLogBtn) downloadLogBtn.addEventListener("click", () => this.downloadLog());
  },

  renderDefaultStages() {
    const container = document.getElementById("stages-tracker-container");
    if (!container) return;

    const stages = [
      { id: "QC_FILTERING", code: "01", name: "QC Filtering" },
      { id: "QC_TOOL_COMPARE", code: "02", name: "QC Compare" },
      { id: "INTEGRATION_CLUSTERING", code: "03", name: "Integration" },
      { id: "CELL_ANNOTATION", code: "04", name: "Annotation" },
      { id: "DIFFERENTIAL_EXPRESSION", code: "05", name: "DE & Scoring" },
      { id: "OBJECT_CONVERSION", code: "06", name: "Object SCE/SE" },
      { id: "TRAJECTORY_MONOCLE3", code: "07", name: "Monocle3" },
      { id: "TRAJECTORY_SLINGSHOT", code: "08", name: "Slingshot" },
      { id: "CELLCHAT_COMMUNICATION", code: "09", name: "CellChat" },
      { id: "NICHENET_COMMUNICATION", code: "10", name: "NicheNet" },
      { id: "COPYKAT_CNV", code: "11", name: "CopyKAT" },
      { id: "HDWGCNA_NETWORKS", code: "12", name: "hdWGCNA" },
      { id: "VELOCITY_EXPORT", code: "13", name: "Velocity" },
      { id: "PUBLICATION_FIGURES", code: "14", name: "Pub Figures" }
    ];

    const initMap = window.__INITIAL_STAGES__ || {};

    container.innerHTML = stages.map(s => {
      const st = initMap[s.id] || "PENDING";
      return `
        <div class="stage-pill ${st}" id="stage-pill-${s.code}">
          <span style="display:inline-block; width:18px; height:18px; border-radius:50%; background:#cbd5e1; text-align:center; line-height:18px; font-size:10px; color:#334155;">${s.code}</span>
          <span>${s.name}</span>
        </div>
      `;
    }).join("");
  },

  async startRun() {
    const nameInput = document.getElementById("run-name-input");
    const profileSelect = document.getElementById("run-profile-select");
    const resumeCb = document.getElementById("run-resume-cb");
    const stubCb = document.getElementById("run-stub-cb");
    const locationSelect = document.getElementById("run-location-select");
    
    const runName = nameInput ? nameInput.value.trim() : "";
    const profile = profileSelect ? profileSelect.value : "local,pixi";
    const resume = resumeCb ? resumeCb.checked : true;
    const stubRun = stubCb ? stubCb.checked : false;
    const isRemote = locationSelect && locationSelect.value === "remote";
    
    let clusterProfileId = null;
    let remoteDir = null;
    let envInit = "";
    
    if (isRemote) {
      clusterProfileId = document.getElementById("remote-profile-select").value;
      remoteDir = document.getElementById("remote-dir-input").value.trim();
      envInit = document.getElementById("remote-env-input").value.trim();
      
      if (!clusterProfileId || !remoteDir) {
        alert("Please select a remote profile and specify a remote working directory.");
        return;
      }
    }

    const params = window.ParamsController ? ParamsController.getParams() : {};

    const startBtn = document.getElementById("start-run-btn");
    const cancelBtn = document.getElementById("cancel-run-btn");
    if (startBtn) startBtn.disabled = true;
    if (cancelBtn) cancelBtn.disabled = false;

    this.clearLog();
    this.appendLog(`[scRATool] Submitting pipeline run '${runName || 'scRATool-Run'}'...\n`);

    const token = window.SessionsController ? SessionsController.getToken() : null;

    try {
      const res = await fetch("/api/runs", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: runName || "scRATool-Run",
          profile: profile,
          resume: resume,
          stub_run: stubRun,
          token: token,
          params: params,
          is_remote: isRemote,
          cluster_profile_id: isRemote ? parseInt(clusterProfileId) : null,
          remote_dir: remoteDir,
          env_init: envInit
        })
      });

      if (!res.ok) {
        const err = await res.json();
        alert("Failed to start run: " + JSON.stringify(err));
        if (startBtn) startBtn.disabled = false;
        if (cancelBtn) cancelBtn.disabled = true;
        return;
      }

      const data = await res.json();
      this.activeRunId = data.run.id;
      this.appendLog(`[scRATool] Run started with ID: ${this.activeRunId}\n\n`);
      this.startPolling(this.activeRunId);
      App.fetchRuns();

    } catch (e) {
      alert("Error starting run: " + e.message);
      if (startBtn) startBtn.disabled = false;
      if (cancelBtn) cancelBtn.disabled = true;
    }
  },

  startPolling(runId) {
    if (this.pollTimer) clearInterval(this.pollTimer);
    this.logOffset = 0;

    const statusBadge = document.getElementById("active-run-status-badge");
    if (statusBadge) {
      statusBadge.className = "status-badge running";
      statusBadge.innerHTML = `<span class="status-dot"></span> Running: ${runId}`;
    }

    const pollFn = async () => {
      try {
        // Poll logs
        const logRes = await fetch(`/api/runs/${runId}/logs?offset=${this.logOffset}`);
        if (logRes.ok) {
          const logData = await logRes.json();
          if (logData.lines && logData.lines.length > 0) {
            this.appendLog(logData.lines.join("\n") + "\n");
            this.logOffset = logData.next_offset;
          }

          if (logData.completed) {
            this.onRunFinished(runId);
          }
        }

        // Poll stages
        const stageRes = await fetch(`/api/runs/${runId}/stages`);
        if (stageRes.ok) {
          const stageData = await stageRes.json();
          this.updateStagesUI(stageData.stages);
        }

      } catch (e) {
        console.error("Polling error:", e);
      }
    };

    pollFn();
    this.pollTimer = setInterval(pollFn, 1500);
  },

  updateStagesUI(stages) {
    if (!stages) return;
    stages.forEach(s => {
      const pill = document.getElementById(`stage-pill-${s.code}`);
      if (pill) {
        pill.className = `stage-pill ${s.status}`;
      }
    });
  },

  onRunFinished(runId) {
    if (this.pollTimer) clearInterval(this.pollTimer);
    const startBtn = document.getElementById("start-run-btn");
    const cancelBtn = document.getElementById("cancel-run-btn");
    if (startBtn) startBtn.disabled = false;
    if (cancelBtn) cancelBtn.disabled = true;

    const statusBadge = document.getElementById("active-run-status-badge");
    if (statusBadge) {
      statusBadge.className = "status-badge online";
      statusBadge.innerHTML = `<span class="status-dot"></span> Ready`;
    }

    App.fetchRuns();
    this.appendLog(`\n[scRATool] Run completed. Outputs are ready in Results Explorer.`);
  },

  async cancelRun() {
    if (!this.activeRunId) return;
    if (!confirm("Are you sure you want to stop this run?")) return;

    try {
      const res = await fetch(`/api/runs/${this.activeRunId}/cancel`, { method: "POST" });
      if (res.ok) {
        this.appendLog(`\n[scRATool] Stop signal sent to run ${this.activeRunId}.\n`);
      }
    } catch (e) {
      alert("Error cancelling run: " + e.message);
    }
  },

  appendLog(text) {
    const el = document.getElementById("terminal-output");
    if (!el) return;
    const clean = text.replace(/\x1B\[[0-9;]*[a-zA-Z]/g, ""); el.textContent += clean;
    if (this.autoscroll) {
      el.scrollTop = el.scrollHeight;
    }
  },

  clearLog() {
    const el = document.getElementById("terminal-output");
    if (el) el.textContent = "";
    this.logOffset = 0;
  },

  downloadLog() {
    const el = document.getElementById("terminal-output");
    if (!el) return;
    const blob = new Blob([el.textContent], { type: "text/plain" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `run_${this.activeRunId || 'log'}.log`;
    a.click();
  },

  viewRun(runId) {
    if (App.state.activeView !== "runner") {
      App.switchView("runner");
    }
    this.clearLog();
    this.activeRunId = runId;
    this.startPolling(runId);
    this.fetchAndRenderRunParams(runId);
  },

  resetToNewRunConfig() {
    this.activeRunId = null;
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
    const statusBadge = document.getElementById("active-run-status-badge");
    if (statusBadge) {
      statusBadge.className = "status-badge online";
      statusBadge.innerHTML = `<span class="status-dot"></span> Ready`;
    }
    const histBanner = document.getElementById("historical-run-banner");
    if (histBanner) histBanner.style.display = "none";
    const backBtn = document.getElementById("btn-back-to-new-run");
    if (backBtn) backBtn.style.display = "none";

    this.renderDefaultStages();
    this.renderCurrentConfigPreview();
  },

  async renderCurrentConfigPreview() {
    const summaryContainer = document.getElementById("run-params-summary");
    const grid = document.getElementById("run-params-grid");
    const titleEl = document.getElementById("run-params-title");
    const subtitleEl = document.getElementById("run-params-subtitle");
    const histBanner = document.getElementById("historical-run-banner");
    const backBtn = document.getElementById("btn-back-to-new-run");

    if (!summaryContainer || !grid) return;

    if (titleEl) titleEl.textContent = "Selected Pipeline Run Configuration";
    if (subtitleEl) subtitleEl.textContent = "Active settings configured in Parameters tab (ready for launch).";
    if (histBanner) histBanner.style.display = "none";
    if (backBtn) backBtn.style.display = "none";
    summaryContainer.style.display = "block";

    let params = window.ParamsController ? ParamsController.getParams() : {};
    if (!params || Object.keys(params).length === 0) {
      const token = window.SessionsController ? SessionsController.getToken() : null;
      const url = token ? `/api/params?token=${encodeURIComponent(token)}` : "/api/params";
      try {
        const res = await fetch(url);
        if (res.ok) params = await res.json();
      } catch (e) {}
    }

    const organism = (params.organism || "human").toUpperCase();
    const refCond = params.reference_condition || "CTRL";
    const tissue = params.tissue || "auto";
    const targetCellTypes = params.target_celltypes || "auto";
    const customPanel = params.custom_gene_panel || "(None)";
    const pbMinSamples = params.pb_min_samples !== undefined ? params.pb_min_samples : 1;
    const pbMinCounts = params.pb_min_counts !== undefined ? params.pb_min_counts : 10;
    
    // QC
    const nfeatMin = params.nfeature_min || 500;
    const nfeatMax = params.nfeature_max || 6000;
    const ncountMin = params.ncount_min || 800;
    const ncountMax = params.ncount_max || 50000;
    const mtThresh = params.mt_thresh || 15;
    const nHvg = params.n_hvg || 2000;

    // DE
    const deTest = (params.de_test || "wilcox").toUpperCase();
    const deLogfc = params.de_logfc_thresh || 0.25;
    const deFdr = params.de_fdr_thresh || 0.05;
    const deMinPct = params.de_min_pct || 0.1;

    // Location & cluster
    const locSelect = document.getElementById("run-location-select");
    const isRemote = locSelect && locSelect.value === "remote";
    const remoteDirInput = document.getElementById("remote-dir-input");
    const remoteDir = (remoteDirInput && remoteDirInput.value) || localStorage.getItem("scratool_remote_dir") || "";
    
    // Samples count
    const sampleCount = (window.SamplesController && SamplesController.samples) ? SamplesController.samples.length : 0;

    // Card generator
    const badgeCard = (label, val, sub, isHighlight = false) => `
      <div style="background: ${isHighlight ? '#f0fdf4' : '#f8fafc'}; border: 1px solid ${isHighlight ? '#bbf7d0' : '#e2e8f0'}; border-radius: 6px; padding: 10px 12px; display: flex; flex-direction: column; justify-content: space-between;">
        <div style="font-size: 11px; font-weight: 600; color: ${isHighlight ? '#15803d' : '#64748b'}; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 4px;">
          <span>${label}</span>
        </div>
        <div style="font-size: 13px; font-weight: 700; color: #0f172a; word-break: break-word;">
          ${val}
        </div>
        ${sub ? `<div style="font-size: 11px; color: #64748b; margin-top: 3px;">${sub}</div>` : ""}
      </div>
    `;

    let html = "";
    html += badgeCard("Target Organism", organism, "Annotation & DB selection");
    html += badgeCard("Baseline Condition (DE)", `<span style="color: #2563eb; font-weight: bold;">${refCond}</span>`, "Control contrast group", true);
    html += badgeCard("Tissue / Annotation", tissue, "scType reference atlas");
    html += badgeCard("Target Cell Types", targetCellTypes.length > 25 ? targetCellTypes.slice(0, 25) + "..." : targetCellTypes, "hdWGCNA module target");
    html += badgeCard("Custom Gene Panel", customPanel.length > 25 ? customPanel.slice(0, 25) + "..." : customPanel, "Monocle3, Figures & Profiling");
    html += badgeCard("QC Genes (nFeature)", `${nfeatMin} – ${nfeatMax}`, `Max MT: ${mtThresh}%, HVGs: ${nHvg}`);
    html += badgeCard("QC UMIs (nCount)", `${ncountMin} – ${ncountMax}`, `min_pct_cells: ${params.min_pct_cells || 0.1}`);
    html += badgeCard("DE Stat Test & FDR", `${deTest} (FDR &lt; ${deFdr})`, `log2FC &ge; ${deLogfc}, min_pct &ge; ${deMinPct}`);
    html += badgeCard("Pseudobulk Min Samples", `${pbMinSamples} sample(s)`, `pb_min_counts: ${pbMinCounts}`);
    html += badgeCard("Execution Target", isRemote ? `<span style="color: #059669; font-weight: bold;">Remote Cluster (SSH)</span>` : "Local Machine", isRemote ? remoteDir : "Current Host Machine", isRemote);
    html += badgeCard("Input Samplesheet", `${sampleCount} sample(s) registered`, "Samplesheet Configuration");

    grid.innerHTML = html;
  },

  async fetchAndRenderRunParams(runId) {
    const summaryContainer = document.getElementById("run-params-summary");
    const grid = document.getElementById("run-params-grid");
    const titleEl = document.getElementById("run-params-title");
    const subtitleEl = document.getElementById("run-params-subtitle");
    const histBanner = document.getElementById("historical-run-banner");
    const histIdLabel = document.getElementById("historical-run-id-label");
    const histStatusLabel = document.getElementById("historical-run-status-label");
    const backBtn = document.getElementById("btn-back-to-new-run");

    if (!summaryContainer || !grid) return;
    
    try {
      const res = await fetch(`/api/runs/${runId}`);
      if (!res.ok) return;
      const data = await res.json();
      if (data && data.run) {
        let params = {};
        try {
          params = typeof data.run.params === 'string' ? JSON.parse(data.run.params) : data.run.params;
        } catch (e) {}
        
        if (titleEl) titleEl.textContent = `Historical Run Configuration: ${data.run.name}`;
        if (subtitleEl) subtitleEl.textContent = `Execution parameters snapshot recorded for run ${runId}.`;
        if (histBanner) {
          histBanner.style.display = "flex";
          if (histIdLabel) histIdLabel.textContent = data.run.id;
          if (histStatusLabel) histStatusLabel.textContent = data.run.status;
        }
        if (backBtn) backBtn.style.display = "inline-flex";

        const keyMap = {
          "organism": "Target Organism",
          "reference_condition": "Baseline Condition",
          "tissue": "Tissue Model",
          "target_celltypes": "Target Cell Types",
          "custom_gene_panel": "Custom Gene Panel",
          "de_test": "DE Stat Test",
          "de_logfc_thresh": "DE Log2FC Cutoff",
          "de_fdr_thresh": "DE P-Value / FDR",
          "pb_min_samples": "Pseudobulk Min Samples",
          "n_hvg": "Highly Variable Genes",
          "mt_thresh": "Max MT %",
          "outdir": "Output Directory",
          "samplesheet": "Samplesheet Path"
        };
        
        let html = `
          <div style="background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 6px; padding: 10px 12px;">
            <div style="font-size: 11px; font-weight: 600; color: #64748b; text-transform: uppercase;">Run Name &amp; ID</div>
            <div style="font-size: 13px; font-weight: 700; color: var(--accent-base); margin-top: 4px;">${data.run.name} (<code>${data.run.id}</code>)</div>
          </div>
          <div style="background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 6px; padding: 10px 12px;">
            <div style="font-size: 11px; font-weight: 600; color: #64748b; text-transform: uppercase;">Profile &amp; Status</div>
            <div style="font-size: 13px; font-weight: 700; color: #0f172a; margin-top: 4px;">${data.run.profile} &bull; <span class="status-badge ${data.run.status.toLowerCase()}">${data.run.status}</span></div>
          </div>
        `;
        
        if (params) {
          for (let k of Object.keys(keyMap)) {
            if (params[k] !== undefined) {
              html += `
                <div style="background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 6px; padding: 10px 12px;">
                  <div style="font-size: 11px; font-weight: 600; color: #64748b; text-transform: uppercase;">${keyMap[k]}</div>
                  <div style="font-size: 13px; font-weight: 700; color: #0f172a; margin-top: 4px; word-break: break-word;">${params[k]}</div>
                </div>
              `;
            }
          }
        }
        
        grid.innerHTML = html;
        summaryContainer.style.display = "block";
      }
    } catch (e) {
      console.error("Failed to load run params:", e);
    }
  },

  onViewActivated() {
    if (this.activeRunId) {
      this.fetchAndRenderRunParams(this.activeRunId);
    } else {
      this.renderCurrentConfigPreview();
    }
  },

  refreshRunList() {
    App.fetchRuns();
  }
};

window.RunnerController = RunnerController;
