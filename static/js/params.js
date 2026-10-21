// Pipeline Parameters Dynamic Form Controller
const ParamsController = {
  schema: null,
  presets: {},
  currentParams: {},

  init() {
    this.bindEvents();
    this.loadSchemaAndPresets();
  },

  bindEvents() {
    const presetSelect = document.getElementById("preset-select");
    if (presetSelect) {
      presetSelect.addEventListener("change", (e) => this.applyPreset(e.target.value));
    }

    const searchInput = document.getElementById("param-search-input");
    if (searchInput) {
      searchInput.addEventListener("input", (e) => this.filterParams(e.target.value));
    }

    const exportBtn = document.getElementById("export-params-btn");
    if (exportBtn) {
      exportBtn.addEventListener("click", () => this.exportParamsJson());
    }

    const resetBtn = document.getElementById("reset-params-btn");
    if (resetBtn) {
      resetBtn.addEventListener("click", () => this.applyPreset("default"));
    }
  },

  async loadSchemaAndPresets() {
    try {
      const token = window.SessionsController ? SessionsController.getToken() : null;
      const paramsUrl = token ? `/api/params?token=${encodeURIComponent(token)}` : null;

      const promises = [
        fetch("/api/params/schema"),
        fetch("/api/params/presets")
      ];
      if (paramsUrl) promises.push(fetch(paramsUrl));

      const results = await Promise.all(promises);
      const schemaRes = results[0];
      const presetsRes = results[1];
      const sessionParamsRes = results[2];

      if (schemaRes.ok) this.schema = await schemaRes.json();
      if (presetsRes.ok) {
        const pData = await presetsRes.json();
        this.presets = pData.presets || {};
        this.renderPresetDropdown();
      }

      if (sessionParamsRes && sessionParamsRes.ok) {
        this.currentParams = await sessionParamsRes.json();
      } else if (this.presets.default) {
        this.currentParams = Object.assign({}, this.presets.default.params);
      }
      this.renderForm();
    } catch (e) {
      console.error("Failed to load schema or presets:", e);
    }
  },

  renderPresetDropdown() {
    const select = document.getElementById("preset-select");
    if (!select) return;

    select.innerHTML = Object.keys(this.presets).map(k => `
      <option value="${k}">${this.presets[k].name}</option>
    `).join("");
  },

  applyPreset(presetKey) {
    if (this.presets[presetKey]) {
      this.currentParams = Object.assign({}, this.presets[presetKey].params);
      this.renderForm();
      const descEl = document.getElementById("preset-description");
      if (descEl) descEl.textContent = this.presets[presetKey].description;
      if (window.RunnerController && typeof RunnerController.renderCurrentConfigPreview === "function") {
        RunnerController.renderCurrentConfigPreview();
      }
    }
  },

  async saveParams(showToast = true) {
    try {
      const token = window.SessionsController ? SessionsController.getToken() : null;
      const url = token ? `/api/params?token=${encodeURIComponent(token)}` : "/api/params";

      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(this.currentParams)
      });

      const data = await res.json();
      if (!res.ok) {
        let msg = "Failed to save parameters";
        if (data && data.detail) {
          if (typeof data.detail === "string") msg = data.detail;
          else if (data.detail.message) {
            msg = data.detail.message;
            if (data.detail.errors && data.detail.errors.length) {
              msg += ":\n" + data.detail.errors.join("\n");
            }
          }
        }
        alert(msg);
        return false;
      }

      const successMsg = "✔ Parameters successfully saved to workspace!";
      if (showToast) {
        if (window.SessionsController && SessionsController.showToast) {
          SessionsController.showToast(successMsg);
        } else {
          alert(successMsg);
        }
      }

      // If RunnerController exists, refresh live config preview immediately
      if (window.RunnerController && typeof RunnerController.renderCurrentConfigPreview === "function") {
        RunnerController.renderCurrentConfigPreview();
      }

      return true;
    } catch (e) {
      console.error("Save params error:", e);
      alert("Error saving parameters: " + e.message);
      return false;
    }
  },

  renderForm() {
    const container = document.getElementById("params-groups-container");
    if (!container || !this.schema) return;

    const definitions = this.schema.definitions || {};
    let html = "";

    for (const [groupKey, group] of Object.entries(definitions)) {
      const title = group.title || groupKey;
      const desc = group.description || "";
      const props = group.properties || {};

      html += `
        <div class="card param-group-card" data-group="${groupKey}">
          <div class="card-header">
            <div>
              <div class="card-title">${title}</div>
              ${desc ? `<div style="font-size: 12px; color: #64748b; margin-top: 2px;">${desc}</div>` : ""}
            </div>
            <div style="display: flex; align-items: center; gap: 8px;">
              ${groupKey === "hpc_cluster_options" ? '<button class="btn btn-secondary btn-sm" onclick="ClusterController.openModal()">🔌 Connect SSH & Pick Location</button>' : ''}
              <span class="status-badge" style="font-size: 11px;">${Object.keys(props).length} params</span>
            </div>
          </div>
          <div class="grid-2 param-grid">
      `;

      for (const [propKey, prop] of Object.entries(props)) {
        const val = this.currentParams[propKey] !== undefined ? this.currentParams[propKey] : prop.default;
        const propTitle = prop.description || propKey;
        const pType = prop.type || "string";

        html += `
          <div class="form-group param-field-item" data-key="${propKey}" data-title="${propTitle}">
            <label class="form-label" style="display: flex; justify-content: space-between;">
              <span><code>${propKey}</code></span>
              <span style="font-size: 11px; color: #94a3b8; font-weight: normal;">${pType}</span>
            </label>
        `;

        if (pType === "boolean") {
          html += `
            <label style="display: flex; align-items: center; gap: 8px; cursor: pointer; padding: 6px 10px; background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 6px; font-weight: 500; font-size: 13px;">
              <input type="checkbox" style="width: 16px; height: 16px; cursor: pointer;" ${val ? "checked" : ""} onchange="ParamsController.updateParam('${propKey}', this.checked)">
              <span>${prop.description || propKey}</span>
            </label>
          `;
        } else if (prop.enum) {
          html += `
            <select class="form-select" onchange="ParamsController.updateParam('${propKey}', this.value)">
              ${prop.enum.map(opt => `<option value="${opt}" ${String(val) === String(opt) ? "selected" : ""}>${opt}</option>`).join("")}
            </select>
          `;
        } else if (pType === "integer" || pType === "number") {
          html += `
            <input type="number" class="form-input" value="${val}"
              ${prop.minimum !== undefined ? `min="${prop.minimum}"` : ""}
              ${prop.maximum !== undefined ? `max="${prop.maximum}"` : ""}
              step="${pType === 'number' ? '0.01' : '1'}"
              onchange="ParamsController.updateParam('${propKey}', ${pType === 'integer' ? 'parseInt(this.value, 10)' : 'parseFloat(this.value)'})">
          `;
        } else {
          html += `
            <input type="text" class="form-input" value="${val}"
              onchange="ParamsController.updateParam('${propKey}', this.value)">
          `;
        }

        html += `<div class="form-desc">${propTitle}</div></div>`;
      }

      html += `</div></div>`;
    }

    container.innerHTML = html;
    this.applyExecutionTargetVisibility();
  },

  updateParam(key, value) {
    this.currentParams[key] = value;
    if (key === "execution_target") {
      this.applyExecutionTargetVisibility();
    }
    if (window.RunnerController && typeof RunnerController.renderCurrentConfigPreview === "function") {
      RunnerController.renderCurrentConfigPreview();
    }
  },

  applyExecutionTargetVisibility() {
    const target = this.currentParams["execution_target"] || "local";

    const slurmKeys = ["queue", "account", "cluster_options"];
    const sshKeys = ["ssh_host", "ssh_user", "ssh_port", "remote_work_dir"];

    const isLocal = target === "local";
    const isSlurmLocal = target === "slurm_local";
    const isSshRemote = target === "ssh_remote";

    const localCard = document.querySelector('.param-group-card[data-group="local_system_options"]');
    if (localCard) {
      localCard.style.display = isLocal ? "block" : "none";
    }

    slurmKeys.forEach(k => {
      const el = document.querySelector(`.param-field-item[data-key="${k}"]`);
      if (el) el.style.display = (isSlurmLocal || isSshRemote) ? "block" : "none";
    });

    sshKeys.forEach(k => {
      const el = document.querySelector(`.param-field-item[data-key="${k}"]`);
      if (el) el.style.display = isSshRemote ? "block" : "none";
    });

    const sshBtn = document.querySelector('.param-group-card[data-group="hpc_cluster_options"] button');
    if (sshBtn) {
      sshBtn.style.display = isSshRemote ? "inline-block" : "none";
    }
  },

  filterParams(keyword) {
    const term = keyword.trim().toLowerCase();
    const items = document.querySelectorAll(".param-field-item");
    const groups = document.querySelectorAll(".param-group-card");

    if (!term) {
      items.forEach(it => it.style.display = "block");
      groups.forEach(g => g.style.display = "block");
      return;
    }

    groups.forEach(group => {
      let hasVisible = false;
      const groupItems = group.querySelectorAll(".param-field-item");
      groupItems.forEach(it => {
        const key = it.getAttribute("data-key").toLowerCase();
        const title = it.getAttribute("data-title").toLowerCase();
        if (key.includes(term) || title.includes(term)) {
          it.style.display = "block";
          hasVisible = true;
        } else {
          it.style.display = "none";
        }
      });
      group.style.display = hasVisible ? "block" : "none";
    });
  },

  exportParamsJson() {
    const dataStr = "data:text/json;charset=utf-8," + encodeURIComponent(JSON.stringify(this.currentParams, null, 2));
    const dlAnchor = document.createElement("a");
    dlAnchor.setAttribute("href", dataStr);
    dlAnchor.setAttribute("download", "params.json");
    dlAnchor.click();
  },

  getParams() {
    return Object.assign({}, this.currentParams);
  }
};

window.ParamsController = ParamsController;
