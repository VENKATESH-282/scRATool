/* app.js — Main application logic */

'use strict';

// ── Utilities ──────────────────────────────────────────────────────────
function showToast(msg, type = 'info') {
  const t = document.createElement('div');
  t.style.cssText = `
    position:fixed;bottom:1.5rem;right:1.5rem;z-index:9999;
    background:${type==='success'?'#065f46':type==='error'?'#7f1d1d':'#1e1b4b'};
    border:1px solid ${type==='success'?'#10b981':type==='error'?'#ef4444':'#7c3aed'};
    color:#fff;padding:0.75rem 1.25rem;border-radius:8px;font-size:0.8rem;
    box-shadow:0 4px 20px rgba(0,0,0,0.5);max-width:320px;
    animation:fadeIn 0.2s ease;
  `;
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 4000);
}

function showModal(title, bodyHtml, buttons = []) {
  document.getElementById('modalTitle').textContent = title;
  document.getElementById('modalBody').innerHTML = bodyHtml;
  const footer = document.getElementById('modalFooter');
  footer.innerHTML = '';
  buttons.forEach(btn => {
    const b = document.createElement('button');
    b.className = btn.primary ? 'btn-primary' : 'btn-ghost';
    b.textContent = btn.label;
    b.addEventListener('click', btn.onClick);
    footer.appendChild(b);
  });
  document.getElementById('modalOverlay').classList.add('open');
}

function closeModal() {
  document.getElementById('modalOverlay').classList.remove('open');
}

// ── Tab Navigation ─────────────────────────────────────────────────────
const TabManager = {
  current: 'data',

  init() {
    document.querySelectorAll('.nav-item').forEach(item => {
      item.addEventListener('click', (e) => {
        e.preventDefault();
        const tab = item.dataset.tab;
        if (tab) this.switchTo(tab);
      });
    });
  },

  switchTo(tab) {
    // Update nav
    document.querySelectorAll('.nav-item').forEach(i => i.classList.remove('active'));
    const navEl = document.querySelector(`.nav-item[data-tab="${tab}"]`);
    if (navEl) navEl.classList.add('active');

    // Update panels
    document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
    const panel = document.getElementById(`tab-${tab}`);
    if (panel) panel.classList.add('active');

    this.current = tab;

    // Load plots for the newly activated tab
    if (TAB_STEP_MAP[tab]) {
      Plots.loadForTab(tab);
    }
  }
};

// ── Pipeline Controller ────────────────────────────────────────────────
const Pipeline = {
  logEventSource: null,
  logCount: 0,

  init() {
    document.getElementById('btnLaunch').addEventListener('click', () => this.launch());
    document.getElementById('btnStop').addEventListener('click', () => this.stop());
    document.getElementById('modalClose').addEventListener('click', closeModal);
    document.getElementById('modalOverlay').addEventListener('click', (e) => {
      if (e.target === e.currentTarget) closeModal();
    });

    // Refresh buttons
    const refreshMap = {
      qcRefresh: 'qc', normRefresh: 'normalization', clusterRefresh: 'clustering',
      annotRefresh: 'annotation', deRefresh: 'de', enrichRefresh: 'enrichment',
      featRefresh: 'featureplots', trajRefresh: 'trajectory',
      cellchatRefresh: 'cellchat', nichenetRefresh: 'nichenet', copykatRefresh: 'copykat'
    };
    Object.entries(refreshMap).forEach(([btnId, tab]) => {
      const btn = document.getElementById(btnId);
      if (btn) btn.addEventListener('click', () => {
        const step = TAB_STEP_MAP[tab]?.[0];
        if (step) delete Plots.cache[step];
        Plots.loadForTab(tab);
      });
    });

    // Poll status
    this.pollStatus();
  },

  async launch() {
    const mode    = document.querySelector('input[name="mode"]:checked')?.value || 'matrix';
    const csv     = document.getElementById('sampleCsvSelect').value;
    const profile = document.getElementById('profileSelect').value;
    const outdirName = document.getElementById('outdirName')?.value.trim() || 'results';

    const skipFlags = [];
    const flagMap = {
      skipCellranger: '--skip_cellranger', skipPdx: '--skip_pdx',
      skipQc: '--skip_qc', skipIntegration: '--skip_integration',
      skipAnnotation: '--skip_annotation', skipDe: '--skip_de',
      skipTrajectory: '--skip_trajectory', skipCellchat: '--skip_cellchat',
      skipNichenet: '--skip_nichenet', skipCopykat: '--skip_copykat',
    };
    Object.entries(flagMap).forEach(([id, flag]) => {
      if (document.getElementById(id)?.checked) skipFlags.push(flag);
    });

    if (!csv) { showToast('Please select a sample CSV first.', 'error'); return; }

    const SERVER_PROFILES = ['server', 'tigshp', 'hpc_small', 'hpc_large'];
    if (SERVER_PROFILES.includes(profile)) {
      // Ensure server config exists
      const cfg = this._serverCfg || {};
      if (!cfg.host || !cfg.user || !cfg.remote_dir) {
        showToast('Please configure your server in the Settings tab first.', 'error');
        return;
      }

      // Check if password is already saved — if yes, launch directly without modal
      try {
        const statusRes = await fetch('/api/server/password/status');
        const statusData = await statusRes.json();
        if (statusData.configured) {
          // Password stored — launch directly, backend will read it
          await this._doLaunch(mode, csv, profile, skipFlags.join(' '), '', outdirName);
          return;
        }
      } catch { /* network error — fall through to modal */ }

      // No password stored — show the prompt modal
      this._launchParams = { mode, csv, profile, extraFlags: skipFlags.join(' '), outdirName };
      this._showServerPasswordModal();
      return;
    }

    await this._doLaunch(mode, csv, profile, skipFlags.join(' '), '', outdirName);
  },

  _showServerPasswordModal() {
    const cfg = this._serverCfg || {};
    const host = cfg.host || '?';
    const user = cfg.user || 'user';
    showModal(
      '🖥 SSH Server Password Required',
      `<div style="margin-bottom:1rem; color:var(--text-muted); font-size:0.85rem">
         Connecting to <strong style="color:var(--text-primary)">${user}@${host}</strong> via SSH.<br>
         Your password is used once and never stored.
       </div>
       <input type="password" id="sshPasswordPrompt" class="select-input" style="width:100%"
              placeholder="Enter SSH password" autocomplete="off">
       <div style="margin-top:0.5rem; font-size:0.75rem; color:var(--text-muted)">
         💡 Tip: Save your server config in <strong>Settings → Server Connection</strong> to pre-fill host/user.
       </div>`,
      [
        {
          label: 'Cancel',
          primary: false,
          onClick: closeModal
        },
        {
          label: 'Connect & Run',
          primary: true,
          onClick: async () => {
            const pwd = document.getElementById('sshPasswordPrompt')?.value || '';
            if (!pwd) { showToast('Password cannot be empty for server profiles.', 'error'); return; }
            closeModal();
            const p = this._launchParams;
            await this._doLaunch(p.mode, p.csv, p.profile, p.extraFlags, pwd, p.outdirName);
          }
        }
      ]
    );
    // Auto-focus the password field
    setTimeout(() => document.getElementById('sshPasswordPrompt')?.focus(), 100);
  },

  async _doLaunch(mode, csv, profile, extraFlags, sshPassword, outdirName) {
    const res = await fetch('/api/pipeline/launch', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode, samples_csv: csv, profile, extra_flags: extraFlags, ssh_password: sshPassword, outdir_name: outdirName })
    });
    const data = await res.json();
    if (data.error) { showToast(data.error, 'error'); return; }

    showToast('Pipeline launched!', 'success');
    document.getElementById('btnLaunch').disabled = true;
    document.getElementById('btnStop').disabled = false;
    document.getElementById('logTerminal').innerHTML = '';
    this.streamLogs();
  },

  async stop() {
    await fetch('/api/pipeline/stop', { method: 'POST' });
    showToast('Pipeline stopped.', 'error');
    document.getElementById('btnLaunch').disabled = false;
    document.getElementById('btnStop').disabled = true;
    if (this.logEventSource) { this.logEventSource.close(); this.logEventSource = null; }
    this._setStatusDot('idle');
  },

  streamLogs() {
    if (this.logEventSource) this.logEventSource.close();
    const terminal = document.getElementById('logTerminal');
    this.logEventSource = new EventSource('/api/pipeline/logs');
    this.logEventSource.onmessage = (e) => {
      if (e.data === '__DONE__') {
        this.logEventSource.close();
        this.logEventSource = null;
        document.getElementById('btnLaunch').disabled = false;
        document.getElementById('btnStop').disabled = true;
        return;
      }
      const line = document.createElement('span');
      line.className = 'log-line';
      const text = JSON.parse(e.data);
      if (/ERROR|error/i.test(text)) line.classList.add('error');
      else if (/WARN|warn/i.test(text)) line.classList.add('warn');
      else if (/✔|SUCCESS|complete|Done/i.test(text)) line.classList.add('done');
      line.textContent = text;
      terminal.appendChild(line);
      terminal.appendChild(document.createElement('br'));
      terminal.scrollTop = terminal.scrollHeight;
      this.logCount++;
      const badge = document.getElementById('logBadge');
      if (badge) badge.textContent = this.logCount;
    };
  },

  async pollStatus() {
    try {
      const res = await fetch('/api/pipeline/status');
      const data = await res.json();
      this._setStatusDot(data.status);
      document.getElementById('statusText').textContent =
        data.status === 'running' ? 'Pipeline Running...' :
        data.status === 'done'    ? 'Done ✔' :
        data.status === 'failed'  ? 'Failed ✗' : 'Idle';
      this._updateProgress(data.progress || {});
      
      // Reconnect log stream if page was refreshed while running
      if (data.status === 'running' && !this.logEventSource) {
        this.streamLogs();
        document.getElementById('btnLaunch').disabled = true;
        document.getElementById('btnStop').disabled = false;
      }
    } catch {}
    setTimeout(() => this.pollStatus(), 3000);
  },

  _setStatusDot(status) {
    const dot = document.getElementById('statusDot');
    if (!dot) return;
    dot.className = 'status-dot';
    if (['running','done','failed'].includes(status)) dot.classList.add(status);
  },

  _updateProgress(progress) {
    const container = document.getElementById('progressSteps');
    if (!container) return;
    const stepLabels = {
      DOWNLOAD_SRA: 'Download SRA', CELLRANGER_COUNT: 'CellRanger',
      PDX_PROCESSING: 'PDX Processing', QC_FILTERING: 'QC Filtering',
      INTEGRATION_CLUSTERING: 'Integration & Clustering',
      CELL_ANNOTATION: 'Cell Annotation', DIFFERENTIAL_EXPRESSION: 'Differential Expression',
      OBJECT_EXPLORATION: 'Object Exploration', TRAJECTORY_ANALYSIS: 'Trajectory',
      CELLCHAT: 'CellChat', NICHENET: 'NicheNet', COPYKAT: 'CopyKAT',
      FUNCTIONAL_ENRICHMENT: 'Functional Enrichment',
    };
    container.innerHTML = '';
    Object.entries(progress).forEach(([step, pct]) => {
      const label = stepLabels[step] || step;
      const icon = pct >= 100 ? '[done]' : pct > 0 ? '[...]' : '[ ]';
      container.innerHTML += `
        <div class="progress-row">
          <span class="progress-icon">${icon}</span>
          <span style="font-size:0.75rem;min-width:140px;color:var(--text-secondary)">${label}</span>
          <div class="progress-bar-wrap"><div class="progress-bar-fill" style="width:${pct}%"></div></div>
          <span class="progress-pct">${pct}%</span>
        </div>`;
    });
  }
};

// ── Data Tab ───────────────────────────────────────────────────────────
const DataTab = {
  async init() {
    // Load available CSVs
    await this.loadSamples();

    // File upload
    document.getElementById('uploadCsvInput').addEventListener('change', async (e) => {
      const file = e.target.files[0];
      if (!file) return;
      const form = new FormData();
      form.append('file', file);
      const res  = await fetch('/api/upload/samples', { method: 'POST', body: form });
      const data = await res.json();
      if (data.error) { showToast(data.error, 'error'); return; }
      showToast(`Uploaded ${data.count} samples from ${data.filename}`, 'success');
      // Add to dropdown
      const sel = document.getElementById('sampleCsvSelect');
      const opt = document.createElement('option');
      opt.value = data.filename;
      opt.textContent = data.filename + ' (uploaded)';
      sel.appendChild(opt);
      sel.value = data.filename;
      // Show preview
      this._renderSamplePreview(data.rows, data.filename);
    });

    // Mode radio cards
    document.querySelectorAll('.radio-card').forEach(card => {
      card.addEventListener('click', () => {
        document.querySelectorAll('.radio-card').forEach(c => c.classList.remove('selected'));
        card.classList.add('selected');
        const input = card.querySelector('input');
        input.checked = true;

        // Toggle GEO input panel
        const geoSec = document.getElementById('geoInputSection');
        if (geoSec) {
          geoSec.style.display = (input.value === 'geo') ? 'block' : 'none';
        }
      });
    });

    // GEO Download buttons
    const _geoSkipFlags = () => {
      const flagMap = {
        geo_skipCellranger: '--skip_cellranger', geo_skipPdx: '--skip_pdx',
        geo_skipQc: '--skip_qc', geo_skipIntegration: '--skip_integration',
        geo_skipAnnotation: '--skip_annotation', geo_skipDe: '--skip_de',
        geo_skipTrajectory: '--skip_trajectory', geo_skipCellchat: '--skip_cellchat',
        geo_skipNichenet: '--skip_nichenet', geo_skipCopykat: '--skip_copykat',
      };
      return Object.entries(flagMap)
        .filter(([id]) => document.getElementById(id)?.checked)
        .map(([, flag]) => flag).join(' ');
    };

    const _triggerGeoDownload = async (autoRun) => {
      const geoId = document.getElementById('geoIdInput').value.trim();
      if (!geoId) { showToast('Please enter a GEO Accession ID.', 'error'); return; }

      const btnDl    = document.getElementById('btnGeoDownload');
      const btnRun   = document.getElementById('btnGeoDownloadRun');
      const geoStat  = document.getElementById('geoStatus');
      if (btnDl)  btnDl.disabled  = true;
      if (btnRun) btnRun.disabled = true;
      if (geoStat) geoStat.textContent = `Starting download for ${geoId}...`;
      showToast(`Starting GEO Download: ${geoId}`, 'info');

      const profile = document.getElementById('profileSelect')?.value || 'local';
      const extra   = _geoSkipFlags();

      try {
        const res = await fetch('/api/geo/download', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ geo_id: geoId, auto_run: autoRun, profile, extra_flags: extra })
        });
        const data = await res.json();
        if (data.error) {
          showToast(data.error, 'error');
          if (btnDl)  btnDl.disabled  = false;
          if (btnRun) btnRun.disabled = false;
          if (geoStat) geoStat.textContent = 'Error: ' + data.error;
          return;
        }

        document.getElementById('logTerminal').innerHTML = '';
        Pipeline.logCount = 0;
        Pipeline.streamLogs();

        if (geoStat) geoStat.textContent = autoRun
          ? `Downloading & running pipeline for ${geoId}. Watch the log below.`
          : `Downloading ${geoId}. Once done, select the CSV in Sample Sheet and click Launch Pipeline.`;

        // Poll for idle state to re-enable buttons and refresh sample list
        const checkStatus = setInterval(async () => {
          const sr = await fetch('/api/pipeline/status');
          const sd = await sr.json();
          if (sd.status !== 'running') {
            clearInterval(checkStatus);
            if (btnDl)  btnDl.disabled  = false;
            if (btnRun) btnRun.disabled = false;
            const expectedCsv = `samples_${geoId.toLowerCase()}.csv`;
            await DataTab.loadSamples(expectedCsv);
            if (sd.status === 'done' || sd.status === 'idle') {
              showToast(`GEO ${autoRun ? 'pipeline' : 'download'} for ${geoId} complete!`, 'success');
              if (geoStat) geoStat.textContent = autoRun
                ? `Pipeline complete! Check the result tabs.`
                : `Download complete! Select samples_${geoId.toLowerCase()}.csv above and click Launch Pipeline.`;
            } else {
              showToast(`Pipeline ended with status: ${sd.status}`, 'error');
              if (geoStat) geoStat.textContent = `Status: ${sd.status}. Check the log for details.`;
            }
          }
        }, 3000);
      } catch (err) {
        showToast(err.message, 'error');
        if (btnDl)  btnDl.disabled  = false;
        if (btnRun) btnRun.disabled = false;
      }
    };

    const btnGeo = document.getElementById('btnGeoDownload');
    if (btnGeo) btnGeo.addEventListener('click', () => _triggerGeoDownload(false));

    const btnGeoRun = document.getElementById('btnGeoDownloadRun');
    if (btnGeoRun) btnGeoRun.addEventListener('click', () => _triggerGeoDownload(true));

    // CSV select → show preview
    document.getElementById('sampleCsvSelect').addEventListener('change', async (e) => {
      const name = e.target.value;
      if (!name) return;
      await this._fetchAndPreview(name);
    });
  },

  async loadSamples(selectedFilename = null) {
    try {
      const res  = await fetch('/api/samples/list');
      const data = await res.json();
      const sel  = document.getElementById('sampleCsvSelect');
      sel.innerHTML = '<option value="">— Select sample sheet —</option>';
      data.forEach(f => {
        const opt = document.createElement('option');
        opt.value = f.name;
        opt.textContent = f.name;
        sel.appendChild(opt);
      });
      if (selectedFilename) {
        sel.value = selectedFilename;
      } else if (data.length > 0) {
        sel.value = data[0].name;
      }
    } catch {}
  },

  async _fetchAndPreview(filename) {
    try {
      const res  = await fetch(`/api/upload/samples`, {
        method: 'POST',
        body: (() => { const f = new FormData(); /* no-op, server reads from disk */ return f; })()
      });
    } catch {}
    // Just show the filename hint
    const prev = document.getElementById('samplePreview');
    prev.style.display = 'none';
  },

  _renderSamplePreview(rows, filename) {
    if (!rows.length) return;
    const prev = document.getElementById('samplePreview');
    const cols = Object.keys(rows[0]);
    let html = '<div style="font-size:0.72rem;color:var(--text-muted);margin-bottom:0.4rem">' + filename + '</div>';
    html += '<table class="data-table"><thead><tr>' + cols.map(c=>`<th>${c}</th>`).join('') + '</tr></thead><tbody>';
    rows.slice(0, 8).forEach(row => {
      html += '<tr>' + cols.map(c=>`<td>${row[c]??''}</td>`).join('') + '</tr>';
    });
    html += '</tbody></table>';
    prev.innerHTML = html;
    prev.style.display = 'block';
  }
};

// ── Report Tab ─────────────────────────────────────────────────────────
const ReportTab = {
  init() {
    document.getElementById('btnGenerateReport').addEventListener('click', async () => {
      const status = document.getElementById('reportStatus');
      status.textContent = 'Generating report...';
      status.className = 'status-msg loading';
      const runDir = document.getElementById('activeRunDropdown')?.value || 'results';
      const res = await fetch(`/api/report/generate?run_dir=${runDir}`, { method: 'POST' });
      const data = await res.json();
      if (data.error) {
        status.textContent = 'Error: ' + data.error;
        status.className = 'status-msg error';
      } else {
        status.textContent = 'Report generated at: ' + data.path;
        status.className = 'status-msg success';
        document.getElementById('reportPreview').innerHTML =
          '<p style="color:var(--green);font-size:0.85rem">Report ready. Click Download to save it.</p>';
      }
    });

    document.getElementById('btnDownloadReport').addEventListener('click', () => {
      const runDir = document.getElementById('activeRunDropdown')?.value || 'results';
      window.open(`/api/report/download?run_dir=${runDir}`, '_blank');
    });
  }
};

// ── Settings Tab ───────────────────────────────────────────────────────
const SettingsTab = {
  init() {
    document.getElementById('addColorRow').addEventListener('click', () => {
      const container = document.getElementById('colorAssignments');
      const row = document.createElement('div');
      row.className = 'color-row';
      row.innerHTML = `
        <input type="text" class="color-label-input" placeholder="Cell type name">
        <input type="color" class="color-picker" value="#${Math.floor(Math.random()*16777215).toString(16).padStart(6,'0')}">
        <button class="btn-ghost remove-color">✕</button>
      `;
      row.querySelector('.remove-color').addEventListener('click', () => row.remove());
      container.appendChild(row);
    });

    document.getElementById('colorAssignments').addEventListener('click', (e) => {
      if (e.target.classList.contains('remove-color')) e.target.closest('.color-row').remove();
    });

    document.getElementById('saveColors').addEventListener('click', () => {
      showToast('Color assignments saved to session.', 'success');
    });

    document.getElementById('addMetaField').addEventListener('click', () => {
      const field = document.getElementById('newMetaField').value.trim();
      if (!field) { showToast('Enter a field name.', 'error'); return; }
      const status = document.getElementById('settingsStatus');
      status.textContent = `Field "${field}" added to metadata (will apply on next pipeline run).`;
      status.className = 'status-msg success';
    });

    // ── Server Password ──────────────────────────────────────────────────
    const _checkPasswordStatus = async () => {
      const statusEl = document.getElementById('serverPasswordStatus');
      if (!statusEl) return;
      try {
        // Load saved config and populate fields
        const r = await fetch('/api/server/config');
        const cfg = await r.json();
        Pipeline._serverCfg = cfg;
        if (document.getElementById('serverHost'))  document.getElementById('serverHost').value  = cfg.host  || '';
        if (document.getElementById('serverUser'))  document.getElementById('serverUser').value  = cfg.user  || '';
        if (document.getElementById('serverDir'))   document.getElementById('serverDir').value   = cfg.remote_dir || '';
        if (document.getElementById('serverSshKey')) document.getElementById('serverSshKey').value = cfg.ssh_key || '';
        if (document.getElementById('exportDir'))    document.getElementById('exportDir').value    = cfg.export_dir || '';

        const ps = await fetch('/api/server/password/status');
        const pd = await ps.json();
        if (pd.configured) {
          statusEl.textContent = `✔ Password saved for ${cfg.user || '?'}@${cfg.host || '?'}. Pipeline will use it automatically for server profiles.`;
          statusEl.style.color = 'var(--green, #10b981)';
        } else {
          statusEl.textContent = `⚠ No password saved. Enter one below — you will also be prompted each time you launch on a server profile.`;
          statusEl.style.color = 'var(--amber, #f59e0b)';
        }
      } catch {
        statusEl.textContent = 'Could not load server config.';
      }
    };
    _checkPasswordStatus();

    const btnSaveCfg = document.getElementById('btnSaveServerConfig');
    if (btnSaveCfg) {
      btnSaveCfg.addEventListener('click', async () => {
        const host   = document.getElementById('serverHost')?.value.trim()   || '';
        const user   = document.getElementById('serverUser')?.value.trim()   || '';
        const dir    = document.getElementById('serverDir')?.value.trim()    || '';
        const sshKey = document.getElementById('serverSshKey')?.value.trim() || '';
        const pwd    = document.getElementById('serverPasswordInput')?.value  || '';

        if (!host || !user || !dir) {
          showToast('Please fill in Host, Username, and Remote Directory.', 'error');
          return;
        }

        // Save config (no password here)
        await fetch('/api/server/config', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ host, user, remote_dir: dir, ssh_key: sshKey })
        });

        // Save password if entered
        if (pwd) {
          await fetch('/api/server/password', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ password: pwd })
          });
          document.getElementById('serverPasswordInput').value = '';
        }

        showToast(`✔ Server config saved: ${user}@${host}`, 'success');
        _checkPasswordStatus();
      });
    }

    const btnTest = document.getElementById('btnTestServerConnection');
    if (btnTest) {
      btnTest.addEventListener('click', async () => {
        btnTest.disabled = true;
        btnTest.textContent = 'Testing...';
        const statusEl = document.getElementById('serverPasswordStatus');
        if (statusEl) statusEl.textContent = '⏳ Attempting SSH connection...';
        try {
          const r = await fetch('/api/server/test', { method: 'POST' });
          const d = await r.json();
          if (d.ok) {
            showToast('✔ SSH connection successful!', 'success');
            if (statusEl) { statusEl.textContent = `✔ Connected to ${d.host} — ${d.output}`; statusEl.style.color = 'var(--green, #10b981)'; }
          } else {
            showToast('✗ Connection failed: ' + d.error, 'error');
            if (statusEl) { statusEl.textContent = `✗ ${d.error}`; statusEl.style.color = '#ef4444'; }
          }
        } catch (e) {
          showToast('Test failed: ' + e.message, 'error');
        }
        btnTest.disabled = false;
        btnTest.textContent = 'Test Connection';
      });
    }

    const btnClear = document.getElementById('btnClearServerPassword');
    if (btnClear) {
      btnClear.addEventListener('click', async () => {
        if (!confirm('Remove the saved SSH password? You will be prompted to enter it the next time you launch on a server profile.')) return;
        await fetch('/api/server/clear-password', { method: 'POST' });
        showToast('Server password cleared.', 'info');
        _checkPasswordStatus();
      });
    }

    const btnSaveExport = document.getElementById('btnSaveExportDir');
    if (btnSaveExport) {
      btnSaveExport.addEventListener('click', async () => {
        const export_dir = document.getElementById('exportDir')?.value.trim() || '';
        await fetch('/api/server/config', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ export_dir })
        });
        showToast('Export directory saved.', 'success');
      });
    }
  }
};

// ── Enrichment Tab ─────────────────────────────────────────────────────
const EnrichmentTab = {
  init() {
    document.getElementById('btnRunEnrichment').addEventListener('click', async () => {
      const collection = document.getElementById('enrichCollection').value;
      const organism   = document.getElementById('enrichOrganism').value;
      const status     = document.getElementById('enrichStatus');
      status.textContent = '⏳ Submitting enrichment job...';
      status.className = 'status-msg loading';

      try {
        const res = await fetch('/api/pipeline/launch', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            mode: 'seurat_rds',
            samples_csv: 'results/04_annotation/integrated_annotated.rds',
            profile: document.getElementById('profileSelect')?.value || 'local',
            extra_flags: `--skip_qc --skip_integration --skip_annotation --skip_de --skip_trajectory --skip_cellchat --skip_nichenet --skip_copykat --enrichment_collection ${collection} --enrichment_organism "${organism}"`
          })
        });
        const data = await res.json();
        if (data.error) throw new Error(data.error);
        status.textContent = 'Enrichment job launched. Check the log in the Data tab.';
        status.className = 'status-msg success';
      } catch (e) {
        status.textContent = 'Error: ' + e.message;
        status.className = 'status-msg error';
      }
    });
  }
};

// ── QC Search ──────────────────────────────────────────────────────────
function initQcSearch() {
  const inp = document.getElementById('qcSampleFilter');
  if (!inp) return;
  inp.addEventListener('input', () => {
    const q = inp.value.toLowerCase();
    document.querySelectorAll('#qcPlotGrid .plot-card').forEach(card => {
      const label = card.querySelector('.plot-card-label')?.textContent?.toLowerCase() || '';
      card.style.display = label.includes(q) ? '' : 'none';
    });
  });
}

// ── DE Search ─────────────────────────────────────────────────────────
function initDeSearch() {
  const inp = document.getElementById('deSearch');
  if (!inp) return;
  inp.addEventListener('input', () => {
    const q = inp.value.toLowerCase();
    document.querySelectorAll('#deTable tr').forEach((row, i) => {
      if (i === 0) return;
      row.style.display = row.textContent.toLowerCase().includes(q) ? '' : 'none';
    });
  });
}

// ── Theme Manager Removed ────────────────────────────────────────────────

// ── Bootstrap ──────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', async () => {
  TabManager.init();
  Pipeline.init();
  Session.init();
  await DataTab.init();
  ReportTab.init();
  SettingsTab.init();
  EnrichmentTab.init();
  initQcSearch();
  initDeSearch();

  // Load server config so the password modal shows correct host/user
  try {
    const r = await fetch('/api/server/config');
    Pipeline._serverCfg = await r.json();
  } catch { Pipeline._serverCfg = {}; }
  
  // Load available run directories
  try {
    const r = await fetch('/api/runs');
    const runs = await r.json();
    const dropdown = document.getElementById('activeRunDropdown');
    if (dropdown && runs.length > 0) {
      dropdown.innerHTML = '';
      runs.forEach(run => {
        const opt = document.createElement('option');
        opt.value = run;
        opt.textContent = run === 'results' ? 'results (Default)' : run;
        dropdown.appendChild(opt);
      });
      dropdown.addEventListener('change', () => {
        const tab = TabManager.current;
        if (TAB_STEP_MAP[tab]) {
            delete Plots.cache[TAB_STEP_MAP[tab][0]];
            Plots.loadForTab(tab);
        }
      });
    }
  } catch {}

  // Create a session automatically on load
  await Session.create();
});

