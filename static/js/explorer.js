// Results & Visualization Explorer Controller
const ExplorerController = {
  stages: [],
  selectedStageCode: "01",
  activeSubTab: "plots",
  currentTableFile: null,
  tablePage: 1,
  selectedCellIds: [],
  availableRuns: [],
  selectedRunId: null,
  umapPoints: [],
  umapMetadata: {},

  init() {
    this.bindEvents();
    this.loadAvailableRuns();
  },

  bindEvents() {
    // Run selection
    const runSelect = document.getElementById("explorer-run-select");
    if (runSelect) {
      runSelect.addEventListener("change", (e) => {
        this.selectedRunId = e.target.value;
        this.loadStages(this.selectedRunId);
        this.initPlotlyUMAP(this.selectedRunId);
      });
    }

    // Stage selection
    const stageSelect = document.getElementById("explorer-stage-select");
    if (stageSelect) {
      stageSelect.addEventListener("change", (e) => this.selectStage(e.target.value));
    }

    // Sub-tabs
    document.querySelectorAll(".explorer-tab-btn").forEach(btn => {
      btn.addEventListener("click", () => {
        const tab = btn.getAttribute("data-tab");
        this.switchSubTab(tab);
      });
    });

    // Lightbox modal close
    const modalClose = document.getElementById("lightbox-close-btn");
    const modal = document.getElementById("lightbox-modal");
    if (modalClose) modalClose.addEventListener("click", () => modal.classList.remove("active"));
    if (modal) modal.addEventListener("click", (e) => {
      if (e.target === modal) modal.classList.remove("active");
    });

    // Table search & pagination
    const tableSearch = document.getElementById("table-search-input");
    if (tableSearch) {
      tableSearch.addEventListener("input", (e) => this.loadTableData(this.currentTableFile, 1, e.target.value));
    }

    // UMAP controls
    const colorBySelect = document.getElementById("umap-color-by");
    if (colorBySelect) {
      colorBySelect.addEventListener("change", () => this.renderPlotlyTraces());
    }

    const pointSizeSlider = document.getElementById("umap-point-size");
    if (pointSizeSlider) {
      pointSizeSlider.addEventListener("input", (e) => {
        const valSpan = document.getElementById("umap-point-size-val");
        if (valSpan) valSpan.textContent = `${e.target.value}px`;
        this.renderPlotlyTraces();
      });
    }

    const resetZoomBtn = document.getElementById("umap-reset-view-btn");
    if (resetZoomBtn) {
      resetZoomBtn.addEventListener("click", () => {
        const plotDiv = document.getElementById("plotly-umap-container");
        if (plotDiv && typeof Plotly !== "undefined") {
          Plotly.relayout(plotDiv, { 'xaxis.autorange': true, 'yaxis.autorange': true });
        }
      });
    }

    // Lasso Save Group button
    const saveGroupBtn = document.getElementById("save-lasso-group-btn");
    if (saveGroupBtn) {
      saveGroupBtn.addEventListener("click", () => this.saveLassoGroup());
    }
  },

  async loadAvailableRuns() {
    try {
      const token = (typeof SessionsController !== 'undefined') ? SessionsController.getToken() : null;
      let url = "/api/explorer/available_runs";
      if (token) url += "?token=" + encodeURIComponent(token);
      const res = await fetch(url + (url.includes("?") ? "&" : "?") + "t=" + new Date().getTime());
      if (res.ok) {
        const data = await res.json();
        this.availableRuns = data.runs || [];
        if (this.availableRuns.length > 0) {
          if (!this.selectedRunId || !this.availableRuns.some(r => r.id === this.selectedRunId)) {
            this.selectedRunId = this.availableRuns[0].id;
          }
        }
        this.renderRunDropdown();
      }
    } catch (e) {
      console.warn("Failed to load available runs:", e);
    }
    // Proceed to load stages and UMAP for active run
    this.loadStages(this.selectedRunId);
    this.initPlotlyUMAP(this.selectedRunId);
  },

  renderRunDropdown() {
    const select = document.getElementById("explorer-run-select");
    if (!select) return;

    if (this.availableRuns.length === 0) {
      select.innerHTML = `<option value="run_production_real">Reference Dataset: FSHD Muscle Study (6,688 cells)</option>`;
      this.selectedRunId = "run_production_real";
      return;
    }

    if (!this.selectedRunId || !this.availableRuns.some(r => r.id === this.selectedRunId)) {
      this.selectedRunId = this.availableRuns[0].id;
    }

    select.innerHTML = this.availableRuns.map(r => `
      <option value="${r.id}" ${r.id === this.selectedRunId ? 'selected' : ''}>
        ${r.name} (${r.status})
      </option>
    `).join("");

    select.value = this.selectedRunId;
  },


  async loadSavedLassoGroups() {
    const listEl = document.getElementById("lasso-saved-groups-list");
    if (!listEl) return;
    
    try {
      const token = (typeof SessionsController !== 'undefined') ? SessionsController.getToken() : null;
      const url = `/api/explorer/lasso_groups${token ? `?token=${encodeURIComponent(token)}` : ''}`;
      const res = await fetch(url);
      if (res.ok) {
        const data = await res.json();
        if (!data.groups || data.groups.length === 0) {
            listEl.innerHTML = `<div style="font-size: 12px; color: #94a3b8; text-align: center;">No custom cohorts saved yet.</div>`;
            return;
        }
        
        listEl.innerHTML = data.groups.map(g => {
            const dlUrl = `/api/explorer/lasso_groups/download?file=${encodeURIComponent(g.file)}${token ? `&token=${encodeURIComponent(token)}` : ''}`;
            const dDate = new Date(g.created).toLocaleString();
            return `
            <div style="background: #ffffff; border: 1px solid var(--border); border-radius: 6px; padding: 10px; display: flex; flex-direction: column; gap: 6px;">
                <div style="display: flex; justify-content: space-between; align-items: flex-start;">
                    <div style="font-weight: 600; font-size: 13px; color: #1e293b;">${g.name}</div>
                    <a href="${dlUrl}" download class="btn btn-secondary" style="padding: 2px 8px; font-size: 11px;">⬇ CSV</a>
                </div>
                <div style="display: flex; justify-content: space-between; align-items: center; font-size: 11px; color: #64748b;">
                    <span>${g.cells.toLocaleString()} cells</span>
                    <span>${dDate}</span>
                </div>
            </div>`;
        }).join("");
      }
    } catch(e) {
      console.error(e);
      listEl.innerHTML = `<div style="font-size: 12px; color: #ef4444;">Failed to load cohorts</div>`;
    }
  },

  switchSubTab(tabName) {
    this.activeSubTab = tabName;
    document.querySelectorAll(".explorer-tab-btn").forEach(btn => {
      if (btn.getAttribute("data-tab") === tabName) {
        btn.classList.add("btn-primary");
        btn.classList.remove("btn-secondary");
      } else {
        btn.classList.remove("btn-primary");
        btn.classList.add("btn-secondary");
      }
    });

    document.querySelectorAll(".explorer-tab-panel").forEach(panel => {
      if (panel.id === `tab-panel-${tabName}`) {
        panel.style.display = "block";
      } else {
        panel.style.display = "none";
      }
    });

    if (tabName === "umap") {
      setTimeout(() => {
        if (!this.umapPoints || this.umapPoints.length === 0) {
          this.initPlotlyUMAP(this.selectedRunId);
        } else {
          this.renderPlotlyTraces();
          this.refreshUMAPPlot();
        }
        this.loadSavedLassoGroups();
      }, 50);
    }
  },

  async fetchStages(runId = null) {
    return this.loadAvailableRuns();
  },

  async loadStages(runId = null) {
    try {
      const targetRun = runId || this.selectedRunId;
      const token = (typeof SessionsController !== 'undefined') ? SessionsController.getToken() : null;
      let url = "/api/explorer/stages?";
      if (targetRun) url += "run_id=" + encodeURIComponent(targetRun) + "&";
      if (token) url += "token=" + encodeURIComponent(token);
      const res = await fetch(url + (url.includes("?") ? "&" : "?") + "t=" + new Date().getTime());
      if (res.ok) {
        const data = await res.json();
        this.stages = data.stages || [];
        
        let container = document.getElementById("remote-sync-container");
        if (container) {
          const isClusterConnected = (typeof RemoteProfilesController !== 'undefined' && Boolean(RemoteProfilesController.connectedProfile));
          if (isClusterConnected && data.is_remote) {
              let totalFiles = this.stages.reduce((acc, s) => acc + s.total_files, 0);
              container.innerHTML = `
                  <button id="btn-sync-remote" class="btn btn-secondary" onclick="ExplorerController.syncRemoteResults()">
                      Sync Remote Results
                  </button>
                  ${totalFiles > 0 ? '<span class="status-badge online" style="font-size: 13px; font-weight: 500;"><span class="status-dot"></span> Results synced from cluster</span>' : ''}
              `;
          } else {
              container.innerHTML = "";
          }
        }
        
        this.renderStageDropdown();
        this.selectStage(this.selectedStageCode);
      }
    } catch (e) {
      console.error("Failed to load explorer stages:", e);
    }
  },


  async syncRemoteResults() {
    const btn = document.getElementById("btn-sync-remote");
    if (btn) {
        btn.textContent = "Tunneling to Cluster (~20s)...";
        btn.disabled = true;
    }
    try {
        const token = window.SessionsController ? SessionsController.getToken() : null;
        let url = `/api/explorer/${encodeURIComponent(this.selectedRunId)}/sync_remote?token=${encodeURIComponent(token)}`;
        const res = await fetch(url, {method: 'POST'});
        if (res.ok) {
            await this.loadStages(this.selectedRunId);
        } else {
            const err = await res.json();
            alert("Sync failed: " + (err.detail || "Unknown error"));
            if (btn) { btn.textContent = "Try Sync Again"; btn.disabled = false; }
        }
    } catch (e) {
        alert("Sync error: " + e.message);
        if (btn) { btn.textContent = "Try Sync Again"; btn.disabled = false; }
    }
  },

  renderStageDropdown() {
    const select = document.getElementById("explorer-stage-select");
    if (!select) return;

    select.innerHTML = this.stages.map(s => `
      <option value="${s.code}">
        ${s.name} ${s.available ? `(${s.total_files} files)` : '(empty)'}
      </option>
    `).join("");

    // Retain currently selected code if available
    const exists = this.stages.some(s => s.code === this.selectedStageCode);
    if (!exists && this.stages.length > 0) {
      this.selectedStageCode = this.stages[0].code;
    }
    select.value = this.selectedStageCode;
  },

  selectStage(code) {
    this.selectedStageCode = code;
    const stage = this.stages.find(s => s.code === code);
    if (!stage) return;

    this.renderPlotsGallery(stage.plots);
    this.renderTablesList(stage.tables);
    this.renderFilesList(stage);
  },

  renderPlotsGallery(plots) {
    const container = document.getElementById("plots-gallery-container");
    if (!container) return;

    if (!plots || plots.length === 0) {
      container.innerHTML = `<div style="grid-column: 1/-1; text-align: center; color: #94a3b8; padding: 40px; background: #ffffff; border: 1px dashed #cbd5e1; border-radius: 8px;">
        No plot images generated yet for this stage.
      </div>`;
      return;
    }

    container.innerHTML = plots.map(p => {
      const runParam = this.selectedRunId ? `&run_id=${encodeURIComponent(this.selectedRunId)}` : "";
      const token = window.SessionsController ? SessionsController.getToken() : null;
      const fileUrl = `/api/explorer/file?path=${encodeURIComponent(p.path)}${runParam}` + (token ? `&token=${encodeURIComponent(token)}` : '');
      const isImg = p.path.endsWith(".png") || p.path.endsWith(".jpg") || p.path.endsWith(".svg");
      return `
        <div class="gallery-item">
          ${isImg ? `
            <img class="gallery-img" src="${fileUrl}" alt="${p.name}" onclick="ExplorerController.openLightbox('${fileUrl}', '${p.name}')" loading="lazy">
          ` : `
            <div style="height: 200px; display:flex; align-items:center; justify-content:center; background:#f1f5f9; font-size:12px; color:#64748b;">
              <span>PDF Document</span>
            </div>
          `}
          <div class="gallery-meta">
            <span class="gallery-title" title="${p.name}">${p.name}</span>
            <a class="btn btn-secondary" style="padding: 2px 8px; font-size: 11px;" href="${fileUrl}" target="_blank" download="${p.name}">Download</a>
          </div>
        </div>
      `;
    }).join("");
  },

  openLightbox(url, title) {
    const modal = document.getElementById("lightbox-modal");
    const img = document.getElementById("lightbox-img");
    const caption = document.getElementById("lightbox-caption");
    if (modal && img) {
      img.src = url;
      if (caption) caption.textContent = title;
      modal.classList.add("active");
    }
  },

  renderTablesList(tables) {
    const select = document.getElementById("table-file-select");
    if (!select) return;

    if (!tables || tables.length === 0) {
      select.innerHTML = `<option value="">No CSV tables available</option>`;
      const tableBody = document.getElementById("dynamic-table-tbody");
      if (tableBody) tableBody.innerHTML = `<tr><td colspan="6" style="text-align:center; color:#94a3b8; padding: 20px;">No tables in this stage.</td></tr>`;
      return;
    }

    select.innerHTML = tables.map(t => `<option value="${t.path}">${t.name}</option>`).join("");
    select.onchange = (e) => this.loadTableData(e.target.value, 1);
    this.loadTableData(tables[0].path, 1);
  },

  async loadTableData(filePath, page = 1, search = "") {
    if (!filePath) return;
    this.currentTableFile = filePath;
    this.tablePage = page;

    try {
      const runParam = this.selectedRunId ? `&run_id=${encodeURIComponent(this.selectedRunId)}` : "";
      const url = `/api/explorer/table?path=${encodeURIComponent(filePath)}&page=${page}&page_size=20${search ? `&search=${encodeURIComponent(search)}` : ''}${runParam}`;
      const res = await fetch(url + (url.includes("?") ? "&" : "?") + "t=" + new Date().getTime());
      if (res.ok) {
        const data = await res.json();
        this.renderTableData(data);
      }
    } catch (e) {
      console.error("Failed to load table:", e);
    }
  },

  renderTableData(data) {
    const thead = document.getElementById("dynamic-table-thead");
    const tbody = document.getElementById("dynamic-table-tbody");
    const info = document.getElementById("table-pagination-info");
    const prevBtn = document.getElementById("table-prev-page-btn");
    const nextBtn = document.getElementById("table-next-page-btn");

    if (thead) {
      thead.innerHTML = `<tr>${data.headers.map(h => `<th>${h}</th>`).join("")}</tr>`;
    }
    if (tbody) {
      tbody.innerHTML = data.rows.map(r => `<tr>${r.map(c => `<td>${c}</td>`).join("")}</tr>`).join("");
    }
    if (info) {
      info.textContent = `Showing page ${data.page} of ${data.total_pages} (${data.total_rows.toLocaleString()} total rows)`;
    }
    if (prevBtn) {
      prevBtn.disabled = data.page <= 1;
      prevBtn.onclick = () => this.loadTableData(this.currentTableFile, data.page - 1);
    }
    if (nextBtn) {
      nextBtn.disabled = data.page >= data.total_pages;
      nextBtn.onclick = () => this.loadTableData(this.currentTableFile, data.page + 1);
    }
  },

  renderFilesList(stage) {
    const tbody = document.getElementById("manifest-files-tbody");
    if (!tbody) return;

    const allFiles = [...(stage.plots || []), ...(stage.tables || []), ...(stage.objects || [])];
    if (allFiles.length === 0) {
      tbody.innerHTML = `<tr><td colspan="4" style="text-align: center; color:#94a3b8; padding: 20px;">No files generated.</td></tr>`;
      return;
    }

    tbody.innerHTML = allFiles.map(f => {
      const runParam = this.selectedRunId ? `&run_id=${encodeURIComponent(this.selectedRunId)}` : "";
      const token = window.SessionsController ? SessionsController.getToken() : null;
      const fileUrl = `/api/explorer/file?path=${encodeURIComponent(f.path)}${runParam}` + (token ? `&token=${encodeURIComponent(token)}` : '');
      const kb = Math.round(f.size / 1024);
      return `
        <tr>
          <td><strong>${f.name}</strong></td>
          <td style="font-family:monospace; font-size:11px; color:#64748b;">${f.path}</td>
          <td>${kb.toLocaleString()} KB</td>
          <td>
            <a class="btn btn-secondary" style="padding: 2px 8px; font-size: 11px;" href="${fileUrl}" download="${f.name}">Download</a>
          </td>
        </tr>
      `;
    }).join("");
  },

  // Interactive Plotly UMAP with Lasso Selection and Multi-Feature Coloring
  async initPlotlyUMAP(runId = null) {
    const plotDiv = document.getElementById("plotly-umap-container");
    if (!plotDiv || typeof Plotly === "undefined") return;

    try {
      const targetRun = runId || this.selectedRunId;
      const token = (typeof SessionsController !== 'undefined') ? SessionsController.getToken() : null;
      let url = "/api/explorer/umap_data?";
      if (targetRun) url += "run_id=" + encodeURIComponent(targetRun) + "&";
      if (token) url += "token=" + encodeURIComponent(token);

      const res = await fetch(url + (url.includes("?") ? "&" : "?") + "t=" + new Date().getTime());
      if (!res.ok) return;
      const data = await res.json();
      this.umapPoints = data.points || [];
      this.umapMetadata = data.metadata_categories || {};

      // Update badge
      const badge = document.getElementById("umap-dataset-badge");
      if (badge) {
        let curName = targetRun || "Active Run";
        const found = this.availableRuns.find(r => r.id === targetRun);
        if (found) {
          curName = found.name.includes("Reference") ? "FSHD Reference" : found.name;
        }
        badge.textContent = `● ${this.umapPoints.length.toLocaleString()} Cells (${curName})`;
        badge.style.background = "#ecfdf5";
        badge.style.color = "#047857";
        badge.style.borderColor = "#a7f3d0";
      }

      this.renderPlotlyTraces();

      // Setup Lasso Selection Handler
      plotDiv.on('plotly_selected', (eventData) => {
        if (eventData && eventData.points && eventData.points.length > 0) {
          const selected = eventData.points.map(pt => pt.customdata).filter(Boolean);
          this.selectedCellIds = Array.from(new Set(selected));
          this.updateLassoBreakdown(this.selectedCellIds);
        } else {
          this.selectedCellIds = [];
          this.updateLassoBreakdown([]);
        }
      });

    } catch (e) {
      console.error("Plotly render error:", e);
    }
  },

  renderPlotlyTraces() {
    const plotDiv = document.getElementById("plotly-umap-container");
    if (!plotDiv || typeof Plotly === "undefined") return;
    if (this.umapPoints.length === 0) {
      plotDiv.innerHTML = `<div style="display: flex; height: 100%; align-items: center; justify-content: center; color: #94a3b8; font-size: 14px;">No cell coordinates found for this dataset.</div>`;
      return;
    }

    const colorBy = document.getElementById("umap-color-by") ? document.getElementById("umap-color-by").value : "cell_type";
    const sizeSlider = document.getElementById("umap-point-size");
    const pointSize = sizeSlider ? parseInt(sizeSlider.value) : 4;

    // Distinct biological palettes
    const paletteCellTypes = {
      "Differentiating myocytes (MYOG-MYH3-high)": "#10b981", // Emerald
      "DUX4-activated cells": "#ef4444",                     // Red / Crimson
      "Fibro-adipogenic progenitors (FAPs)": "#f59e0b",       // Amber
      "Intermediate differentiating myoblasts (MYOD1-high)": "#06b6d4", // Cyan
      "Mature myofibers (sarcomere-gene-high)": "#8b5cf6",     // Purple
      "Newly-formed myotubes (MYH3-extreme)": "#ec4899",      // Pink
      "Proliferating fibroblast-like-stromal cells": "#f97316",// Orange
      "Satellite cells (quiescent-activating, MYF5-high)": "#3b82f6", // Blue
      "Stromal cells (activated-stress-associated)": "#64748b" // Slate
    };

    const paletteConditions = {
      "CTRL": "#2563eb",   // Blue
      "FSHD1": "#dc2626",  // Crimson
      "FSHD2": "#d97706"   // Dark Amber
    };

    const paletteSamples = {
      "CTRL_rep1": "#3b82f6", "CTRL_rep2": "#60a5fa",
      "FSHD1_rep1": "#ef4444", "FSHD1_rep2": "#f87171",
      "FSHD2_rep1": "#f59e0b", "FSHD2_rep2": "#fbbf24"
    };

    const standardColorPalette = [
      "#2563eb", "#dc2626", "#10b981", "#f59e0b", "#8b5cf6",
      "#ec4899", "#06b6d4", "#f97316", "#64748b", "#14b8a6",
      "#84cc16", "#a855f7", "#e11d48", "#0284c7", "#ca8a04",
      "#4338ca", "#059669", "#d97706", "#7c3aed", "#db2777"
    ];

    let traces = [];

    if (colorBy === "dux4_score" || colorBy === "myogenesis_score") {
      // Continuous numerical coloring
      const isDux4 = colorBy === "dux4_score";
      const scoreKey = isDux4 ? "custom_panel_score" : "myogenesis_score";
      const fallbackKey = isDux4 ? "dux4_score" : "myogenesis_score";
      const colorScale = isDux4 ? "Viridis" : "Plasma";
      const title = isDux4 ? "Biomarker Panel Score" : "Pathway / Differentiation Score";

      const x = [];
      const y = [];
      const text = [];
      const ids = [];
      const scores = [];

      this.umapPoints.forEach(p => {
        x.push(p.x);
        y.push(p.y);
        ids.push(p.id);
        const sc = p[scoreKey] !== undefined ? p[scoreKey] : (p[fallbackKey] || 0.0);
        scores.push(sc);
        text.push(`<b>Cell:</b> ${p.id}<br><b>Type:</b> ${p.cell_type}<br><b>Cond:</b> ${p.condition}<br><b>${title}:</b> ${sc}`);
      });

      traces.push({
        x: x,
        y: y,
        text: text,
        customdata: ids,
        mode: "markers",
        type: "scattergl",
        hoverinfo: "text",
        marker: {
          size: pointSize,
          color: scores,
          colorscale: colorScale,
          showscale: true,
          colorbar: {
            title: { text: isDux4 ? "Panel Score" : "Path Score", font: { size: 11 } },
            len: 0.8,
            thickness: 14
          },
          opacity: 0.85
        }
      });

    } else if (colorBy === "dux4_affected") {
      // Binary affected vs negative
      const highGroup = { x: [], y: [], text: [], ids: [] };
      const negGroup = { x: [], y: [], text: [], ids: [] };

      this.umapPoints.forEach(p => {
        const isAff = p.custom_biomarker_affected !== undefined ? p.custom_biomarker_affected : p.dux4_affected;
        const hover = `<b>Cell:</b> ${p.id}<br><b>Type:</b> ${p.cell_type}<br><b>Cond:</b> ${p.condition}<br><b>Biomarker Active:</b> ${isAff ? 'TRUE' : 'FALSE'}`;
        if (isAff) {
          highGroup.x.push(p.x);
          highGroup.y.push(p.y);
          highGroup.text.push(hover);
          highGroup.ids.push(p.id);
        } else {
          negGroup.x.push(p.x);
          negGroup.y.push(p.y);
          negGroup.text.push(hover);
          negGroup.ids.push(p.id);
        }
      });

      traces.push({
        x: negGroup.x,
        y: negGroup.y,
        text: negGroup.text,
        customdata: negGroup.ids,
        mode: "markers",
        type: "scattergl",
        name: "Biomarker Low / Baseline",
        hoverinfo: "text",
        marker: { size: pointSize, color: "#94a3b8", opacity: 0.4 }
      });

      traces.push({
        x: highGroup.x,
        y: highGroup.y,
        text: highGroup.text,
        customdata: highGroup.ids,
        mode: "markers",
        type: "scattergl",
        name: "Biomarker Active / High",
        hoverinfo: "text",
        marker: { size: pointSize + 2, color: "#ef4444", opacity: 0.95 }
      });

    } else {
      // Categorical grouping (cell_type, condition, sample_id, cluster)
      const groups = {};
      this.umapPoints.forEach(p => {
        const cat = p[colorBy] || "Unknown";
        if (!groups[cat]) groups[cat] = { x: [], y: [], text: [], ids: [] };
        groups[cat].x.push(p.x);
        groups[cat].y.push(p.y);
        groups[cat].text.push(
          `<b>Cell:</b> ${p.id}<br><b>Type:</b> ${p.cell_type}<br><b>Condition:</b> ${p.condition}<br><b>Sample:</b> ${p.sample_id}<br><b>Cluster:</b> ${p.cluster}`
        );
        groups[cat].ids.push(p.id);
      });

      const categories = Object.keys(groups);
      // Sort categories sensibly
      if (colorBy === "cluster") {
        categories.sort((a, b) => {
          const numA = parseInt(a.replace(/\D/g, '')) || 0;
          const numB = parseInt(b.replace(/\D/g, '')) || 0;
          return numA - numB;
        });
      } else {
        categories.sort();
      }

      traces = categories.map((cat, idx) => {
        let color = null;
        if (colorBy === "cell_type" && paletteCellTypes[cat]) color = paletteCellTypes[cat];
        else if (colorBy === "condition" && paletteConditions[cat]) color = paletteConditions[cat];
        else if (colorBy === "sample_id" && paletteSamples[cat]) color = paletteSamples[cat];

        if (!color) {
          const upperCat = String(cat).toUpperCase();
          if (upperCat === "CTRL" || upperCat === "CONTROL" || upperCat === "HEALTHY") {
            color = "#2563eb";
          } else if (upperCat === "TREATED" || upperCat === "DISEASE" || upperCat === "TUMOR") {
            color = "#dc2626";
          } else {
            color = standardColorPalette[idx % standardColorPalette.length];
          }
        }

        const markerConfig = { size: pointSize, opacity: 0.85, color: color };

        return {
          x: groups[cat].x,
          y: groups[cat].y,
          text: groups[cat].text,
          customdata: groups[cat].ids,
          mode: "markers",
          type: "scattergl",
          name: cat,
          hoverinfo: "text",
          marker: markerConfig
        };
      });
    }

    const layout = {
      title: {
        text: `UMAP Harmony Single-Cell Embedding (${this.umapPoints.length.toLocaleString()} Cells)`,
        font: { size: 14, color: "#1e293b", family: "system-ui, -apple-system, sans-serif" }
      },
      dragmode: "lasso",
      hovermode: "closest",
      margin: { l: 40, r: 20, t: 40, b: 40 },
      plot_bgcolor: "#fafbfc",
      paper_bgcolor: "#ffffff",
      legend: {
        font: { size: 10, color: "#334155" },
        orientation: "v",
        itemsizing: "constant"
      },
      xaxis: {
        title: { text: "UMAP 1", font: { size: 12, color: "#64748b" } },
        gridcolor: "#f1f5f9",
        zeroline: false
      },
      yaxis: {
        title: { text: "UMAP 2", font: { size: 12, color: "#64748b" } },
        gridcolor: "#f1f5f9",
        zeroline: false
      }
    };

    const config = {
      responsive: true,
      displayModeBar: true,
      displaylogo: false,
      modeBarButtonsToAdd: ['lasso2d', 'select2d']
    };

    Plotly.react(plotDiv, traces, layout, config);
  },

  updateLassoBreakdown(selectedIds) {
    const countEl = document.getElementById("lasso-selected-count");
    const cardEl = document.getElementById("lasso-breakdown-card");
    const contentEl = document.getElementById("lasso-breakdown-content");
    const saveBtn = document.getElementById("save-lasso-group-btn");

    if (!selectedIds || selectedIds.length === 0) {
      if (countEl) countEl.textContent = "0 cells selected";
      if (cardEl) cardEl.style.display = "none";
      if (saveBtn) saveBtn.disabled = true;
      return;
    }

    const totalSelected = selectedIds.length;
    const totalAll = this.umapPoints.length;
    const pct = ((totalSelected / totalAll) * 100).toFixed(1);

    if (countEl) countEl.textContent = `${totalSelected.toLocaleString()} cells selected (${pct}%)`;
    if (saveBtn) saveBtn.disabled = false;

    // Fast index lookup
    const idSet = new Set(selectedIds);
    const condCounts = {};
    const ctCounts = {};

    this.umapPoints.forEach(p => {
      if (idSet.has(p.id)) {
        condCounts[p.condition] = (condCounts[p.condition] || 0) + 1;
        ctCounts[p.cell_type] = (ctCounts[p.cell_type] || 0) + 1;
      }
    });

    const condHtml = Object.entries(condCounts)
      .map(([k, v]) => `<strong>${k}:</strong> ${v} (${((v/totalSelected)*100).toFixed(0)}%)`)
      .join(" &nbsp;|&nbsp; ");

    const topCellTypes = Object.entries(ctCounts)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 4)
      .map(([k, v]) => `<li>${k}: ${v} (${((v/totalSelected)*100).toFixed(0)}%)</li>`)
      .join("");

    if (contentEl) {
      contentEl.innerHTML = `
        <div style="margin-bottom: 6px;">${condHtml}</div>
        <div style="font-weight: 600; margin-bottom: 2px;">Predominant Cell Types:</div>
        <ul style="margin: 0; padding-left: 16px;">${topCellTypes}</ul>
      `;
    }
    if (cardEl) cardEl.style.display = "block";
  },

  refreshUMAPPlot() {
    const plotDiv = document.getElementById("plotly-umap-container");
    if (plotDiv && typeof Plotly !== "undefined") {
      Plotly.Plots.resize(plotDiv);
    }
  },

  async saveLassoGroup() {
    if (this.selectedCellIds.length === 0) {
      alert("Please select cells using the Lasso or Box tool first.");
      return;
    }

    const nameInput = document.getElementById("lasso-group-name");
    const descInput = document.getElementById("lasso-group-desc");
    const groupName = nameInput ? nameInput.value.trim() : "";
    if (!groupName) {
      alert("Please enter a group name for the selected cells.");
      return;
    }

    try {
      const token = (typeof SessionsController !== 'undefined') ? SessionsController.getToken() : null;
      const res = await fetch("/api/explorer/lasso_group", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          group_name: groupName,
          description: descInput ? descInput.value.trim() : "",
          token: token,
          cell_ids: this.selectedCellIds
        })
      });

      if (res.ok) {
        const data = await res.json();
        alert(`Success! ${data.message}\nFile saved: ${data.file_path}`);
        if (nameInput) nameInput.value = "";
        if (descInput) descInput.value = "";
        this.loadSavedLassoGroups();
      } else {
        const err = await res.json();
        alert("Error saving group: " + JSON.stringify(err));
      }
    } catch (e) {
      alert("Network error: " + e.message);
    }
  }
};

window.ExplorerController = ExplorerController;
