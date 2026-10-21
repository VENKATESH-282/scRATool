// scRATool GUI Main Application Controller
const App = {
  state: {
    activeView: "dashboard",
    systemStatus: null,
    runs: [],
    activeRunId: null,
    params: {},
    schema: null,
    presets: {}
  },

  async init() {
    this.bindNavigation();
    if (window.SessionsController) await SessionsController.init();
    this.fetchSystemStatus();
    this.fetchRuns();

    // Initialize sub-controllers
    if (window.SamplesController) SamplesController.init();
    if (window.ParamsController) ParamsController.init();
    if (window.RunnerController) RunnerController.init();
    if (window.ExplorerController) ExplorerController.init();
    if (window.RemoteProfilesController) RemoteProfilesController.disconnectProfile();

    // Check for hash route (e.g. #samples, #params)
    const hash = window.location.hash.replace("#", "").replace("view-", "");
    if (hash && ["dashboard", "samples", "params", "runner", "explorer", "provenance"].includes(hash)) {
      this.switchView(hash);
    }

    // Check for specific run query parameter (e.g. ?run=run_12345)
    const urlParams = new URLSearchParams(window.location.search);
    const targetRun = urlParams.get("run");
    if (targetRun && window.RunnerController) {
      RunnerController.viewRun(targetRun);
    }

    // Check system status periodically
    setInterval(() => this.fetchSystemStatus(), 10000);
  },

  bindNavigation() {
    const navItems = document.querySelectorAll(".nav-item");
    navItems.forEach(item => {
      item.addEventListener("click", () => {
        const view = item.getAttribute("data-view");
        this.switchView(view);
      });
    });
  },

  switchView(viewName) {
    this.state.activeView = viewName;

    // Update nav active classes
    document.querySelectorAll(".nav-item").forEach(item => {
      if (item.getAttribute("data-view") === viewName) {
        item.classList.add("active");
      } else {
        item.classList.remove("active");
      }
    });

    // Update view sections
    document.querySelectorAll(".view-section").forEach(sec => {
      if (sec.id === `view-${viewName}`) {
        sec.classList.add("active");
      } else {
        sec.classList.remove("active");
      }
    });

    // Update top bar title
    const titles = {
      dashboard: "System Overview & Status",
      samples: "Samplesheet & Input Setup",
      params: "Pipeline Parameters Configuration",
      runner: "Run Execution & Live Monitor",
      explorer: "Results & Visualization Explorer",
      provenance: "Reproducibility & Provenance Report"
    };
    const titleEl = document.getElementById("current-page-title");
    if (titleEl) titleEl.textContent = titles[viewName] || "Workbench";

    // View specific hooks
    if (viewName === "explorer" && window.ExplorerController) {
      ExplorerController.loadStages(ExplorerController.selectedRunId);
    } else if (viewName === "samples" && window.SamplesController) {
      SamplesController.loadSamplesheet();
    } else if (viewName === "params" && window.ParamsController) {
      ParamsController.renderForm();
    } else if (viewName === "runner" && window.RunnerController) {
      RunnerController.refreshRunList();
      RunnerController.onViewActivated();
    } else if (viewName === "provenance") {
      const token = window.SessionsController ? SessionsController.getToken() : null;
      const url = token ? `/api/explorer/provenance?token=${encodeURIComponent(token)}` : "/api/explorer/provenance";
      fetch(url).then(r => r.json()).then(data => {
        const pre = document.getElementById("provenance-json-pre");
        if (pre) pre.textContent = JSON.stringify(data, null, 2);
      }).catch(e => console.error(e));
    }
  },

  async fetchSystemStatus() {
    try {
      const res = await fetch("/api/status");
      if (res.ok) {
        const data = await res.json();
        this.state.systemStatus = data;
        const badge = document.getElementById("system-status-badge");
        if (badge) {
          badge.className = "status-badge online";
          badge.innerHTML = `<span class="status-dot"></span> Pipeline Ready`;
        }
        const pipeDirEl = document.getElementById("stat-pipeline-dir");
        if (pipeDirEl) pipeDirEl.textContent = data.pipeline_directory;
      }
    } catch (e) {
      const badge = document.getElementById("system-status-badge");
      if (badge) {
        badge.className = "status-badge";
        badge.innerHTML = `<span class="status-dot"></span> Offline`;
      }
    }
  },

  async fetchRuns() {
    try {
      const token = window.SessionsController ? SessionsController.getToken() : null;
      const url = token ? `/api/runs?limit=20&token=${encodeURIComponent(token)}` : "/api/runs?limit=20";
      const res = await fetch(url);
      if (res.ok) {
        const data = await res.json();
        this.state.runs = data.runs || [];
        this.renderRecentRunsTable();
        const totalRunsEl = document.getElementById("stat-total-runs");
        if (totalRunsEl) totalRunsEl.textContent = this.state.runs.length;

        // If runner view is open and no active run is in progress, ensure config preview is fresh
        if (this.state.activeView === "runner" && window.RunnerController && !RunnerController.activeRunId) {
          RunnerController.renderCurrentConfigPreview();
        }
      }
    } catch (e) {
      console.error("Error fetching runs:", e);
    }
  },

  renderRecentRunsTable() {
    const tbody = document.getElementById("recent-runs-tbody");
    if (!tbody) return;

    if (this.state.runs.length === 0) {
      tbody.innerHTML = `<tr><td colspan="6" style="text-align: center; color: #94a3b8; padding: 24px;">No pipeline runs yet. Start one from the Run Monitor.</td></tr>`;
      return;
    }

    tbody.innerHTML = this.state.runs.map(r => `
      <tr>
        <td style="font-weight: 600;">
          ${r.name}
          ${r.is_remote ? '<span class="status-badge" style="background:#e0e7ff; color:#3730a3; margin-left:6px; font-size:10px;">REMOTE</span>' : ''}
        </td>
        <td><code>${r.id}</code></td>
        <td><span class="status-badge ${r.status.toLowerCase()}"><span class="status-dot"></span> ${r.status}</span></td>
        <td>${r.duration || "-"}</td>
        <td style="font-size: 11px; color: #64748b;">${new Date(r.created_at).toLocaleString()}</td>
        <td>
          <button class="btn btn-secondary" style="padding: 4px 8px; font-size: 11px;" onclick="RunnerController.viewRun('${r.id}')">Inspect</button>
        </td>
      </tr>
    `).join("");
  }
};

document.addEventListener("DOMContentLoaded", () => {
  App.init();
});
