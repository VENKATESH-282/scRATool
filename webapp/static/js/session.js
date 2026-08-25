/* session.js — Session token management */

const Session = {
  token: null,

  init() {
    document.getElementById('btnNewSession').addEventListener('click', () => this.create());
    document.getElementById('btnSaveSession').addEventListener('click', () => this.save());
    document.getElementById('btnLoadSession').addEventListener('click', () => this.promptLoad());
  },

  async create() {
    const res = await fetch('/api/session/new', { method: 'POST' });
    const data = await res.json();
    this.token = data.token;
    this._updateDisplay();
    showToast('New session created: ' + this.token, 'success');
  },

  async save() {
    if (!this.token) { showToast('No active session to save.', 'error'); return; }
    const meta = { token: this.token, timestamp: new Date().toISOString() };
    const res = await fetch('/api/session/save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(meta)
    });
    const data = await res.json();
    if (data.ok) showToast('Session saved: ' + this.token, 'success');
  },

  promptLoad() {
    showModal('Load Session', `
      <p style="color:var(--text-secondary);margin-bottom:1rem">Enter your session token to resume previous analysis.</p>
      <input type="text" id="loadTokenInput" class="select-input" placeholder="e.g. A1B2C3D4" style="text-transform:uppercase">
    `, [{
      label: 'Load',
      primary: true,
      onClick: async () => {
        const token = document.getElementById('loadTokenInput').value.trim().toUpperCase();
        if (!token) return;
        const res = await fetch('/api/session/load', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ token })
        });
        if (res.ok) {
          const data = await res.json();
          this.token = data.token;
          this._updateDisplay();
          closeModal();
          showToast('Session loaded: ' + token, 'success');
        } else {
          showToast('Session not found.', 'error');
        }
      }
    }]);
  },

  _updateDisplay() {
    const el = document.getElementById('sessionToken');
    if (el) el.textContent = this.token || '–––––';
  }
};
