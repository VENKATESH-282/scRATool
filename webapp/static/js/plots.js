/* plots.js — Dynamic plot loading and rendering */

// Map tab name → API step key → result subdir
const TAB_STEP_MAP = {
  'qc':           ['qc',          '02_qc'],
  'normalization':['integration', '03_clustering'],
  'dimred':       ['integration', '03_clustering'],
  'clustering':   ['integration', '03_clustering'],
  'annotation':   ['annotation',  '04_annotation'],
  'de':           ['de',          '05_de'],
  'enrichment':   ['enrichment',  '12_enrichment'],
  'featureplots': ['exploration', '06_exploration'],
  'trajectory':   ['trajectory',  '07_trajectory'],
  'cellchat':     ['cellchat',    '09_cellchat'],
  'nichenet':     ['nichenet',    '10_nichenet'],
  'copykat':      ['copykat',     '11_copykat'],
};

// Plot grid IDs per tab
const GRID_IDS = {
  'qc':           'qcPlotGrid',
  'normalization':'normPlotGrid',
  'dimred':       'dimredPlotGrid',
  'clustering':   'clusterPlotGrid',
  'annotation':   'annotPlotGrid',
  'de':           'dePlotGrid',
  'enrichment':   'enrichPlotGrid',
  'featureplots': 'featPlotGrid',
  'trajectory':   'trajPlotGrid',
  'cellchat':     'cellchatPlotGrid',
  'nichenet':     'nichenetPlotGrid',
  'copykat':      'copykatPlotGrid',
};

const Plots = {
  cache: {},          // step → {plots, csvs, ts}
  CACHE_TTL: 15000,   // 15s

  async loadForTab(tab) {
    const mapping = TAB_STEP_MAP[tab];
    if (!mapping) return;
    const [step] = mapping;
    const gridId = GRID_IDS[tab];
    if (!gridId) return;

    // Use cache if fresh
    const cached = this.cache[step];
    if (cached && Date.now() - cached.ts < this.CACHE_TTL) {
      this._render(gridId, cached.plots, step, tab);
      return;
    }

    const grid = document.getElementById(gridId);
    if (grid) grid.innerHTML = `
      <div class="empty-state" style="display:flex; flex-direction:column; align-items:center; justify-content:center; gap: 1rem;">
        <video src="/static/img/loading_animation.mp4" autoplay loop muted playsinline style="width: 150px; border-radius: 8px; box-shadow: 0 4px 15px rgba(0,0,0,0.1);"></video>
        <span>Loading your plots...</span>
      </div>
    `;

    try {
      const runDir = document.getElementById('activeRunDropdown')?.value || 'results';
      const res = await fetch(`/api/plots/${step}?run_dir=${runDir}`);
      const data = await res.json();
      this.cache[step] = { plots: data.plots, csvs: data.csvs, ts: Date.now() };
      this._render(gridId, data.plots, step, tab);

      // Render tables if this tab has one
      if (tab === 'qc')         this._loadTable('qc', 'qcTable');
      if (tab === 'clustering') this._loadTable('integration', 'clusterTable');
      if (tab === 'de')         this._loadTable('de', 'deTable');
      if (tab === 'enrichment') this._loadTable('enrichment', 'enrichTable');
    } catch (e) {
      if (grid) grid.innerHTML = `<div class="empty-state">⚠ Error loading plots: ${e.message}</div>`;
    }
  },

  _render(gridId, plots, step, tab) {
    const grid = document.getElementById(gridId);
    if (!grid) return;
    
    // Filter plots based on tab if they share the same step API
    let filteredPlots = plots;
    if (step === 'integration') {
      if (tab === 'normalization') {
        filteredPlots = plots.filter(p => p.includes('integration_comparison'));
      } else if (tab === 'dimred') {
        filteredPlots = plots.filter(p => p.includes('dimred') || p.includes('pca') || p.includes('variable'));
      } else if (tab === 'clustering') {
        filteredPlots = plots.filter(p => p.includes('clustering'));
      }
    }

    if (!filteredPlots || filteredPlots.length === 0) {
      grid.innerHTML = '<div class="empty-state">No plots found for this section. Run the pipeline to generate results.</div>';
      return;
    }
    grid.innerHTML = '';

    if (step === 'qc') {
      const dropdown = document.getElementById('qcSampleDropdown');
      if (dropdown) {
        const samples = new Set();
        plots.forEach(relPath => {
          const parts = relPath.split('/');
          if (parts.length >= 3) samples.add(parts[1]);
        });
        
        const currentVal = dropdown.value;
        dropdown.innerHTML = '<option value="">All Samples</option>';
        Array.from(samples).sort().forEach(s => {
          const opt = document.createElement('option');
          opt.value = s;
          opt.textContent = s;
          dropdown.appendChild(opt);
        });
        if (samples.has(currentVal)) dropdown.value = currentVal;
        
        dropdown.onchange = () => {
          const selected = dropdown.value;
          Array.from(grid.children).forEach(card => {
            if (!selected) {
              card.style.display = '';
            } else {
              if (card.dataset.sample === selected) card.style.display = '';
              else card.style.display = 'none';
            }
          });
          
          // Also filter table rows if they exist
          const qcTable = document.getElementById('qcTable');
          if (qcTable) {
            qcTable.querySelectorAll('tbody tr').forEach(row => {
              if (!selected) {
                row.style.display = '';
              } else {
                if (row.dataset.sample === selected) row.style.display = '';
                else row.style.display = 'none';
              }
            });
          }
        };
      }
    }

    // Group plots by sample (or "Global" if no sample dir)
    const groups = {};
    filteredPlots.forEach(relPath => {
      const parts = relPath.split('/');
      let groupName = "Global / Integrated";
      if (step === 'qc' && parts.length >= 3) {
        groupName = parts[1];
      } else if (step === 'annotation' && parts.length >= 3) {
        groupName = parts[1];
      }
      if (!groups[groupName]) groups[groupName] = [];
      groups[groupName].push(relPath);
    });

    Object.keys(groups).sort().forEach(groupName => {
      if (groupName !== "Global / Integrated") {
        const header = document.createElement('div');
        header.style.gridColumn = "1 / -1";
        header.style.padding = "1rem 0 0.2rem 0";
        header.style.borderBottom = "1px solid var(--border)";
        header.style.marginBottom = "0.5rem";
        header.style.fontWeight = "600";
        header.style.color = "var(--accent)";
        header.style.fontSize = "1.1rem";
        header.textContent = `Sample: ${groupName}`;
        header.dataset.sample = groupName; // for filtering
        grid.appendChild(header);
      }

      groups[groupName].forEach(relPath => {
        const card = document.createElement('div');
        card.className = 'plot-card';
        const label = relPath.split('/').pop().replace(/_/g, ' ').replace('.png', '');
        if (groupName !== "Global / Integrated") {
          card.dataset.sample = groupName;
        }
        card.innerHTML = `
          <img src="/results/${relPath}?run_dir=${document.getElementById('activeRunDropdown')?.value || 'results'}" alt="${label}" loading="lazy"
               onerror="this.parentElement.style.display='none'">
          <div class="plot-card-label" title="${relPath}">${label}</div>
        `;
        card.querySelector('img').addEventListener('click', (e) => {
          openLightbox(e.target.src);
        });
        grid.appendChild(card);
      });
    });

    // trigger initial filter if a sample was already selected
    if (step === 'qc') {
      const dropdown = document.getElementById('qcSampleDropdown');
      if (dropdown && dropdown.value) {
        dropdown.onchange();
      }
    }
  },

  async _loadTable(step, tableId) {
    const el = document.getElementById(tableId);
    if (!el) return;
    try {
      const runDir = document.getElementById('activeRunDropdown')?.value || 'results';
      const res = await fetch(`/api/results/${step}/table?run_dir=${runDir}`);
      const tables = await res.json();
      const keys = Object.keys(tables);
      if (!keys.length) { el.innerHTML = '<div class="empty-state">No CSV results found.</div>'; return; }
      let html = '';
      keys.forEach(name => {
        const rows = tables[name];
        if (!rows.length) return;
        const cols = Object.keys(rows[0]);
        html += `<div style="margin-bottom:1rem"><div style="font-size:0.75rem;color:var(--text-muted);margin-bottom:0.4rem">${name}</div>`;
        html += '<table class="data-table"><thead><tr>';
        cols.forEach(c => { html += `<th>${c}</th>`; });
        html += '</tr></thead><tbody>';
        rows.slice(0, 100).forEach(row => {
          const sampleId = row['sample_id'] || row['sample'] || row['Sample'] || '';
          html += `<tr data-sample="${sampleId}">`;
          cols.forEach(c => { html += `<td>${row[c] ?? ''}</td>`; });
          html += '</tr>';
        });
        html += '</tbody></table></div>';
      });
      el.innerHTML = html || '<div class="empty-state">No data.</div>';
      
      // If we are loading the QC table, apply the currently selected sample filter
      if (tableId === 'qcTable') {
        const dropdown = document.getElementById('qcSampleDropdown');
        if (dropdown && dropdown.value) {
          dropdown.onchange();
        }
      }
    } catch (e) {
      el.innerHTML = `<div class="empty-state">⚠ ${e.message}</div>`;
    }
  }
};

/* Lightbox */
function openLightbox(src) {
  document.getElementById('lightboxImg').src = src;
  document.getElementById('lightbox').classList.add('open');
}
document.addEventListener('DOMContentLoaded', () => {
  document.getElementById('lightboxClose').addEventListener('click', () => {
    document.getElementById('lightbox').classList.remove('open');
  });
  document.getElementById('lightbox').addEventListener('click', (e) => {
    if (e.target === e.currentTarget)
      document.getElementById('lightbox').classList.remove('open');
  });
});
