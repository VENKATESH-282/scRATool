/**
 * scRNA-seq General Platform - Results Explorer Controller
 * Interactive Plotly UMAP visualization, lasso selection, result table viewer, and export tools.
 */

const ResultsController = {
  state: {
    projectId: null,
    stages: [],
    selectedStage: null,
    selectedFile: null,
    umapData: null,
    colorBy: null,
    lassoSelection: [],
    tableData: null,
    tablePage: 1,
    tableSearch: ''
  },

  init() {
    const colorBySelect = document.getElementById('umap-color-by');
    if (colorBySelect) {
      colorBySelect.addEventListener('change', (e) => {
        this.onColorByChange(e.target.value);
      });
    }

    const btnSaveLasso = document.getElementById('btn-save-lasso-group');
    if (btnSaveLasso) {
      btnSaveLasso.addEventListener('click', () => {
        this.saveLassoGroup();
      });
    }

    const stageSelect = document.getElementById('results-stage-select');
    if (stageSelect) {
      stageSelect.addEventListener('change', (e) => {
        this.onStageSelect(e.target.value);
      });
    }

    const fileSelect = document.getElementById('results-file-select');
    if (fileSelect) {
      fileSelect.addEventListener('change', (e) => {
        this.state.selectedFile = e.target.value;
        this.loadTable(1, '');
      });
    }

    const searchInput = document.getElementById('table-search-input');
    if (searchInput) {
      let timer = null;
      searchInput.addEventListener('input', (e) => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          this.onTableSearch(e.target.value);
        }, 400);
      });
    }
  },

  loadResults(projectId) {
    this.state.projectId = projectId;
    this.loadStages(projectId);
    this.loadUmap(projectId);
  },

  async loadStages(projectId) {
    const container = document.getElementById('stages-list');
    if (!container) return;

    try {
      const res = await fetch(`/api/results/${projectId}/stages`);
      if (!res.ok) throw new Error("Failed to fetch stages");
      const data = await res.json();
      this.state.stages = data.stages || [];
      this.renderStages(this.state.stages);
    } catch (err) {
      container.innerHTML = `<div class="alert alert-warning">No analysis results found yet. Launch a pipeline run first.</div>`;
    }
  },

  renderStages(stages) {
    const container = document.getElementById('stages-list');
    const stageSelect = document.getElementById('results-stage-select');

    if (!container) return;

    if (!stages || stages.length === 0) {
      container.innerHTML = `<div class="empty-state"><p>No result stages generated yet.</p></div>`;
      if (stageSelect) stageSelect.innerHTML = `<option value="">No stages available</option>`;
      return;
    }

    container.innerHTML = stages.map(s => `
      <div class="card stage-card mb-3" onclick="ResultsController.onStageSelect('${s.name}')">
        <div class="card-body">
          <div class="d-flex justify-content-between align-items-center">
            <h4 class="card-title text-indigo">${s.name}</h4>
            <span class="badge badge-primary">${s.n_tables} Tables, ${s.n_plots} Plots</span>
          </div>
          <div class="stage-chips mt-2">
            ${s.tables.map(t => `<span class="tag tag-secondary">${t}</span>`).join(' ')}
          </div>
        </div>
      </div>
    `).join('');

    if (stageSelect) {
      stageSelect.innerHTML = `<option value="">Select Stage...</option>` +
        stages.map(s => `<option value="${s.name}">${s.name}</option>`).join('');
    }
  },

  onStageSelect(stageName) {
    this.state.selectedStage = stageName;
    const stage = this.state.stages.find(s => s.name === stageName);
    const fileSelect = document.getElementById('results-file-select');

    if (fileSelect && stage) {
      fileSelect.innerHTML = `<option value="">Select Table...</option>` +
        stage.tables.map(t => `<option value="${t}">${t}</option>`).join('');
      if (stage.tables.length > 0) {
        fileSelect.value = stage.tables[0];
        this.state.selectedFile = stage.tables[0];
        this.loadTable(1, '');
      }
    }
  },

  async loadUmap(projectId) {
    const container = document.getElementById('umap-container');
    const colorSelect = document.getElementById('umap-color-by');
    if (!container) return;

    try {
      const res = await fetch(`/api/results/${projectId}/umap`);
      if (!res.ok) throw new Error("Failed to fetch UMAP data");
      const data = await res.json();

      this.state.umapData = data;
      const countSpan = document.getElementById('umap-cell-count');
      if (countSpan) countSpan.textContent = data.total_cells || 0;

      if (colorSelect && data.color_by_options) {
        colorSelect.innerHTML = data.color_by_options.map(opt =>
          `<option value="${opt}">${opt}</option>`
        ).join('');
        this.state.colorBy = data.color_by_options[0] || null;
      }

      if (data.points && data.points.length > 0) {
        this.renderUmap(data.points, this.state.colorBy);
      } else {
        container.innerHTML = `<div class="empty-state p-5 text-center"><p class="text-muted">No UMAP embedding coordinates available for this project yet.</p></div>`;
      }
    } catch (err) {
      container.innerHTML = `<div class="alert alert-error">Error loading UMAP: ${err.message}</div>`;
    }
  },

  renderUmap(points, colorBy) {
    const container = document.getElementById('umap-container');
    if (!container || !window.Plotly) return;

    const xVals = points.map(p => p.x);
    const yVals = points.map(p => p.y);
    const ids = points.map(p => p.id || '');
    const categories = points.map(p => p[colorBy] !== undefined ? String(p[colorBy]) : 'Unknown');

    // Group by category for color legend
    const uniqueCats = Array.from(new Set(categories));
    const traces = uniqueCats.map(cat => {
      const idxs = [];
      categories.forEach((c, i) => { if (c === cat) idxs.push(i); });
      return {
        x: idxs.map(i => xVals[i]),
        y: idxs.map(i => yVals[i]),
        customdata: idxs.map(i => ids[i]),
        name: cat,
        mode: 'markers',
        type: 'scattergl',
        marker: { size: 4, opacity: 0.8 },
        hovertemplate: `<b>%{customdata}</b><br>Group: ${cat}<br>UMAP1: %{x:.2f}<br>UMAP2: %{y:.2f}<extra></extra>`
      };
    });

    const layout = {
      title: { text: `UMAP Visualization (Color by: ${colorBy || 'Cluster'})`, font: { size: 14 } },
      margin: { l: 40, r: 40, t: 40, b: 40 },
      hovermode: 'closest',
      dragmode: 'lasso',
      xaxis: { title: 'UMAP_1', zeroline: false },
      yaxis: { title: 'UMAP_2', zeroline: false },
      legend: { orientation: 'h', y: -0.15 }
    };

    const config = { responsive: true, displayModeBar: true };

    Plotly.newPlot(container, traces, layout, config);

    container.on('plotly_selected', (eventData) => {
      this.onLassoSelect(eventData);
    });
  },

  onColorByChange(colorBy) {
    this.state.colorBy = colorBy;
    if (this.state.umapData && this.state.umapData.points) {
      this.renderUmap(this.state.umapData.points, colorBy);
    }
  },

  onLassoSelect(eventData) {
    if (!eventData || !eventData.points) {
      this.state.lassoSelection = [];
    } else {
      this.state.lassoSelection = eventData.points.map(p => p.customdata).filter(Boolean);
    }
    const countBadge = document.getElementById('lasso-count');
    if (countBadge) {
      countBadge.textContent = this.state.lassoSelection.length;
    }
  },

  async saveLassoGroup() {
    const nameInput = document.getElementById('lasso-group-name');
    const groupName = nameInput ? nameInput.value.trim() : '';

    if (!groupName) {
      if (window.App && window.App.showToast) {
        window.App.showToast("Please enter a group name", "warning");
      }
      return;
    }

    if (!this.state.lassoSelection || this.state.lassoSelection.length === 0) {
      if (window.App && window.App.showToast) {
        window.App.showToast("No cells selected on UMAP. Use the lasso tool to select cells first.", "warning");
      }
      return;
    }

    try {
      const res = await fetch('/api/results/save_group', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          project_id: this.state.projectId,
          group_name: groupName,
          cell_ids: this.state.lassoSelection
        })
      });
      const data = await res.json();
      if (res.ok) {
        if (window.App && window.App.showToast) {
          window.App.showToast(`Saved ${data.saved} cells to export group '${data.group_name}'`, "success");
        }
        if (nameInput) nameInput.value = '';
      } else {
        throw new Error(data.detail || "Failed to save group");
      }
    } catch (err) {
      if (window.App && window.App.showToast) {
        window.App.showToast(`Error: ${err.message}`, "error");
      }
    }
  },

  async loadTable(page = 1, search = '') {
    if (!this.state.projectId || !this.state.selectedStage || !this.state.selectedFile) return;

    this.state.tablePage = page;
    this.state.tableSearch = search;

    const container = document.getElementById('results-table-container');
    if (container) container.innerHTML = `<div class="p-3 text-muted">Loading table data...</div>`;

    try {
      const url = `/api/results/${this.state.projectId}/table?stage=${encodeURIComponent(this.state.selectedStage)}&filename=${encodeURIComponent(this.state.selectedFile)}&page=${page}&page_size=50&search=${encodeURIComponent(search)}`;
      const res = await fetch(url);
      if (!res.ok) throw new Error("Failed to load table");
      const data = await res.json();
      this.state.tableData = data;
      this.renderTable(data);
    } catch (err) {
      if (container) container.innerHTML = `<div class="alert alert-error">Error loading table: ${err.message}</div>`;
    }
  },

  renderTable(data) {
    const container = document.getElementById('results-table-container');
    if (!container) return;

    if (!data.headers || data.headers.length === 0 || !data.rows || data.rows.length === 0) {
      container.innerHTML = `<div class="p-4 text-muted">No rows match query or file is empty.</div>`;
      return;
    }

    const headersHtml = data.headers.map(h => `<th>${h}</th>`).join('');
    const rowsHtml = data.rows.map(r => `
      <tr>
        ${data.headers.map(h => `<td>${r[h] !== undefined ? r[h] : ''}</td>`).join('')}
      </tr>
    `).join('');

    container.innerHTML = `
      <div class="table-responsive">
        <table class="table table-striped table-hover">
          <thead><tr>${headersHtml}</tr></thead>
          <tbody>${rowsHtml}</tbody>
        </table>
      </div>
      <div class="d-flex justify-content-between align-items-center mt-3">
        <span class="text-muted small">Showing page ${data.page} of ${data.total_pages} (${data.total_rows} total rows)</span>
        <div>
          <button class="btn btn-sm btn-outline me-2" ${data.page <= 1 ? 'disabled' : ''} onclick="ResultsController.loadTable(${data.page - 1}, '${this.state.tableSearch}')">Previous</button>
          <button class="btn btn-sm btn-outline" ${data.page >= data.total_pages ? 'disabled' : ''} onclick="ResultsController.loadTable(${data.page + 1}, '${this.state.tableSearch}')">Next</button>
        </div>
      </div>
    `;
  },

  onTableSearch(query) {
    this.loadTable(1, query);
  }
};

document.addEventListener('DOMContentLoaded', () => {
  ResultsController.init();
});
