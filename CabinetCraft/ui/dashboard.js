(function () {
  'use strict';

  // ---- Bridge to Ruby -------------------------------------------------------
  const CC = (window.CC = {});
  let seq = 0;
  const pending = {};

  function rpc(method, args) {
    return new Promise((resolve, reject) => {
      const id = ++seq;
      pending[id] = { resolve, reject };
      if (!window.sketchup || !window.sketchup.rpc) { reject(new Error('Not running inside SketchUp')); return; }
      window.sketchup.rpc(JSON.stringify({ id, method, args: args || [] }));
    });
  }
  CC.resolve = function (id, msg) {
    const p = pending[id]; if (!p) return; delete pending[id];
    msg.ok ? p.resolve(msg.result) : p.reject(new Error(msg.error));
  };
  CC.onSelection = function (cab) {
    if (cab) { loadCabinet(cab); } else if (S.editing) { S.editing = null; render(); }
    refreshList();
  };

  // ---- State ----------------------------------------------------------------
  const SECTIONS = [
    { id: 'project', label: 'PROJECT', phase: 0 },
    { id: 'cabinets', label: 'CABINETS', phase: 0 },
    { id: 'parameters', label: 'PARAMETERS', phase: 0 },
    { id: 'materials', label: 'MATERIALS', phase: 0 },
    { id: 'hardware', label: 'HARDWARE', phase: 3, scope: 'Hinge/runner/connector libraries, rule-based placement (hinge count by door height), custom hardware.' },
    { id: 'parts', label: 'PARTS', phase: 0 },
    { id: 'nesting', label: 'NESTING', phase: 4, scope: '2D sheet packing that respects grain, kerf and trim; sheet preview and utilisation. Will be described as a heuristic, not optimal.' },
    { id: 'reports', label: 'REPORTS', phase: 3, scope: 'Cutting list, grouped parts, material totals; CSV / Excel-compatible CSV / PDF / JSON export.' },
    { id: 'cnc', label: 'CNC', phase: 5, scope: 'Machining data (hinge cups, shelf pins, connectors), DXF, and a post-processor framework.' },
    { id: 'settings', label: 'SETTINGS', phase: 0 }
  ];
  const S = {
    boot: null, tab: 'cabinets', unit: load('cc_unit', 'mm'),
    type: 'base_cabinet', params: null, editing: null, preview: null, cabinets: [], search: '', timer: null, busy: false
  };
  function load(k, d) { try { return localStorage.getItem(k) || d; } catch (e) { return d; } }
  function save(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* storage may be blocked */ } }

  // ---- Helpers --------------------------------------------------------------
  const UNIT_MM = { mm: 1, cm: 10, m: 1000, in: 25.4 };
  const UNIT_DP = { mm: 1, cm: 2, m: 4, in: 3 };
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const toDisp = (mm) => +(mm / UNIT_MM[S.unit]).toFixed(UNIT_DP[S.unit]);
  const fromDisp = (v) => parseFloat(v) * UNIT_MM[S.unit];
  const fmt = (mm) => toDisp(mm);
  const $ = (sel) => document.querySelector(sel);
  const GRAIN = { length: 'Along length', width: 'Along width', none: 'None' };

  function toast(msg) {
    const t = $('#toast'); t.textContent = msg; t.hidden = false;
    clearTimeout(toast.t); toast.t = setTimeout(() => (t.hidden = true), 2600);
  }

  // ---- Data flow ------------------------------------------------------------
  function loadCabinet(cab) {
    S.editing = cab; S.type = cab.type; S.params = Object.assign({}, cab.params); S.preview = null;
    if (S.tab === 'cabinets' || S.tab === 'project') S.tab = 'parameters';
    render(); runPreview();
  }
  function refreshList() { rpc('list').then((r) => { S.cabinets = r.cabinets; if (S.tab === 'project') render(); }).catch(() => {}); }

  // Live updates: debounced; edits regenerate only the selected cabinet.
  function schedule() {
    clearTimeout(S.timer);
    S.timer = setTimeout(() => (S.editing ? applyUpdate() : runPreview()), 200);
  }
  function runPreview() {
    return rpc('preview', [S.type, S.params, S.editing ? S.editing.label : null]).then((p) => { S.preview = p; paintResults(); }).catch(showError);
  }
  function applyUpdate() {
    return rpc('update', [S.editing.id, S.params]).then((p) => {
      S.preview = p; if (p.cabinet) S.editing = p.cabinet; paintResults();
    }).catch(showError);
  }
  function doCreate() {
    S.busy = true; render();
    rpc('create', [S.type, S.params]).then((p) => {
      S.busy = false; S.preview = p;
      if (p.created) { S.editing = p.cabinet; toast('Created ' + p.cabinet.label); refreshList(); }
      render();
    }).catch((e) => { S.busy = false; showError(e); render(); });
  }
  function showError(e) { toast(e.message); }

  // ---- Rendering ------------------------------------------------------------
  function render() {
    $('#nav').innerHTML = SECTIONS.map((s) =>
      `<button data-tab="${s.id}" class="${S.tab === s.id ? 'active' : ''}">${s.label}${s.phase ? `<span class="tag">P${s.phase}</span>` : ''}</button>`).join('');
    document.querySelectorAll('#nav button').forEach((b) => (b.onclick = () => { S.tab = b.dataset.tab; if (S.tab === 'project') refreshList(); render(); }));
    const v = $('#view');
    const sec = SECTIONS.find((s) => s.id === S.tab);
    if (sec.phase) v.innerHTML = roadmap(sec);
    else if (S.tab === 'cabinets') { v.innerHTML = cabinetsView(); bindCabinets(); }
    else if (S.tab === 'parameters') { v.innerHTML = parametersView(); bindParameters(); paintResults(); }
    else if (S.tab === 'materials') v.innerHTML = materialsView();
    else if (S.tab === 'parts') v.innerHTML = partsView();
    else if (S.tab === 'project') { v.innerHTML = projectView(); bindProject(); }
    else if (S.tab === 'settings') { v.innerHTML = settingsView(); bindSettings(); }
    paintStatus();
  }

  function roadmap(sec) {
    return `<h2>${sec.label} <span class="badge plan">PLANNED - PHASE ${sec.phase}</span></h2>
      <div class="card"><h3>Not implemented yet</h3><p>${esc(sec.scope)}</p>
      <p class="mute">Nothing on this page is functional in the current version.</p></div>`;
  }

  function cabinetsView() {
    const q = S.search.toLowerCase();
    const impl = S.boot.library.filter((e) => !q || (e.name + e.category).toLowerCase().includes(q)).map((e) =>
      `<div class="card"><h3>${esc(e.name)}<span class="badge impl">IMPLEMENTED</span></h3><p>${esc(e.description)}</p>
       <button class="primary" data-new="${esc(e.type)}">Configure &amp; create</button></div>`).join('');
    const planned = Object.entries(S.boot.planned).map(([cat, names]) => {
      const f = names.filter((n) => !q || (n + cat).toLowerCase().includes(q));
      return f.length ? `<details><summary>${esc(cat)} <span class="badge plan">PLANNED</span></summary>
        <div class="fields" style="grid-template-columns:1fr">${f.map((n) => `<div class="mute">${esc(n)}</div>`).join('')}</div></details>` : '';
    }).join('');
    return `<input type="search" id="search" placeholder="Search library..." value="${esc(S.search)}">
      <h2>AVAILABLE NOW</h2>${impl || '<p class="mute">No match.</p>'}
      <h2>ROADMAP (NOT YET FUNCTIONAL)</h2>${planned}`;
  }
  function bindCabinets() {
    $('#search').oninput = (e) => { S.search = e.target.value; const pos = e.target.selectionStart; render(); const i = $('#search'); i.focus(); i.setSelectionRange(pos, pos); };
    document.querySelectorAll('[data-new]').forEach((b) => (b.onclick = () => {
      S.type = b.dataset.new; S.editing = null; S.preview = null;
      S.params = Object.assign({}, S.boot.defaults[S.type]); S.tab = 'parameters'; render(); runPreview();
    }));
  }

  function parametersView() {
    if (!S.params) return '<div class="card"><h3>No cabinet selected</h3><p>Pick a cabinet type in CABINETS, or select a CabinetCraft cabinet in the model.</p></div>';
    const groups = {};
    S.boot.schema.forEach((f) => (groups[f.group] = groups[f.group] || []).push(f));
    const title = S.editing ? `Editing ${esc(S.editing.label)} <span class="mute">v${S.editing.version}</span>` : 'New cabinet';
    const body = Object.entries(groups).map(([g, fields]) =>
      `<details open><summary>${esc(g)}</summary><div class="fields">${fields.map(fieldHtml).join('')}</div></details>`).join('');
    const action = S.editing
      ? `<span class="mute">Changes apply to the model as you type.</span> <button class="ghost" id="newcab">New cabinet</button>`
      : `<button class="primary" id="create" ${S.busy ? 'disabled' : ''}>CREATE</button>`;
    return `<h2>${title}</h2><div class="row" style="margin-bottom:10px">${action}</div>
      <div id="issues"></div>${body}<h2>CALCULATED</h2><div id="calc"></div>`;
  }
  function fieldHtml(f) {
    const v = S.params[f.key]; const id = 'f_' + f.key;
    let input;
    if (f.type === 'enum') {
      input = `<select id="${id}" data-key="${f.key}">${f.options.map((o) => `<option value="${esc(o.value)}" ${o.value === v ? 'selected' : ''}>${esc(o.label)}</option>`).join('')}</select>`;
    } else if (f.type === 'int') {
      input = `<input id="${id}" data-key="${f.key}" type="number" step="1" min="${f.min}" max="${f.max}" value="${v}">`;
    } else {
      input = `<input id="${id}" data-key="${f.key}" type="number" step="any" value="${toDisp(v)}">`;
    }
    const unit = f.type === 'length' ? ` <span class="mute">(${S.unit})</span>` : '';
    return `<div class="field" data-field="${f.key}"><label for="${id}">${esc(f.label)}${unit}</label>${input}
      ${f.note ? `<div class="note">${esc(f.note)}</div>` : ''}<div class="msg"></div></div>`;
  }
  function bindParameters() {
    document.querySelectorAll('[data-key]').forEach((el) => {
      el.oninput = el.onchange = () => {
        const f = S.boot.schema.find((x) => x.key === el.dataset.key);
        S.params[f.key] = f.type === 'enum' ? el.value : f.type === 'int' ? parseFloat(el.value) : fromDisp(el.value);
        schedule();
      };
    });
    const c = $('#create'); if (c) c.onclick = doCreate;
    const n = $('#newcab'); if (n) n.onclick = () => { S.editing = null; S.preview = null; S.params = Object.assign({}, S.boot.defaults[S.type]); render(); runPreview(); };
  }

  function paintResults() {
    paintStatus();
    const p = S.preview; const issues = $('#issues'); const calc = $('#calc');
    document.querySelectorAll('.field').forEach((f) => { f.classList.remove('bad'); f.querySelector('.msg').textContent = ''; f.querySelector('.msg').className = 'msg'; });
    if (!p) { if (S.tab === 'parts') render(); return; }
    (p.issues || []).forEach((i) => {
      const f = i.key && document.querySelector(`[data-field="${i.key}"]`);
      if (f) { if (i.severity === 'error') f.classList.add('bad'); const m = f.querySelector('.msg'); m.textContent = i.message; m.className = 'msg ' + i.severity; }
    });
    if (issues) issues.innerHTML = (p.issues || []).length ? `<ul class="issues">${p.issues.map((i) => `<li class="${i.severity}">${esc(i.message)}</li>`).join('')}</ul>` : '';
    if (calc && p.values && p.values.internal_width != null) {
      const v = p.values;
      const rows = [['Internal width', v.internal_width], ['Side height', v.side_height], ['Back panel', `${fmt(v.back_width)} x ${fmt(v.back_height)}`]];
      if (v.open_zone) rows.push(['Shelf', v.shelf_count ? `${fmt(v.shelf_width)} x ${fmt(v.shelf_depth)}` : '-'], ['Compartment width', v.compartment_width]);
      if (v.door_widths.length) rows.push(['Doors', `${v.door_widths.map(fmt).join(' + ')} x ${fmt(v.door_height)}`]);
      if (v.drawer_fronts.length) {
        rows.push(['Drawer fronts', v.drawer_fronts.map((f) => fmt(f.height)).join(' / ')],
          ['Drawer box', `${fmt(v.drawer_box_width)} x ${fmt(v.drawer_box_depth)}`]);
      }
      calc.innerHTML = `<div class="card"><table>${rows.map(([k, x]) => `<tr><td>${k}</td><td class="num">${typeof x === 'number' ? fmt(x) : x} ${typeof x === 'number' ? S.unit : ''}</td></tr>`).join('')}</table></div>`;
    }
    if (S.tab === 'parts') $('#view').innerHTML = partsView();
  }
  function paintStatus() {
    const el = $('#status'); const issues = (S.preview && S.preview.issues) || [];
    const err = issues.some((i) => i.severity === 'error'); const warn = issues.some((i) => i.severity === 'warning');
    el.className = 'status ' + (err ? 'err' : warn ? 'warn' : 'ok'); el.textContent = err ? 'ERROR' : warn ? 'WARNING' : 'VALID';
  }

  function partsView() {
    const rows = (S.preview && S.preview.panels) || [];
    if (!rows.length) return '<div class="card"><h3>No parts to show</h3><p>Configure a valid cabinet in PARAMETERS (or select one in the model).</p></div>';
    const title = S.editing ? S.editing.label : 'preview (not yet created)';
    return `<h2>PARTS - ${esc(title)}</h2><div class="card"><table><thead><tr><th>PART ID</th><th>NAME</th><th>LENGTH</th><th>WIDTH</th><th>THK</th><th>MATERIAL</th><th>GRAIN</th><th>QTY</th></tr></thead><tbody>
      ${rows.map((r) => `<tr><td>${esc(r.part_id)}</td><td>${esc(r.name)}</td><td class="num">${fmt(r.length)}</td><td class="num">${fmt(r.width)}</td><td class="num">${fmt(r.thickness)}</td><td>${esc(r.material)}</td><td>${GRAIN[r.grain]}</td><td class="num">${r.qty}</td></tr>`).join('')}
      </tbody></table></div><p class="mute">Dimensions in ${S.unit}. Length is the longer side. This is the selected cabinet only; project-wide parts lists and export arrive in Phase 3.</p>`;
  }

  function materialsView() {
    return `<h2>MATERIALS <span class="badge impl">READ-ONLY</span></h2><div class="card"><table><thead><tr><th>NAME</th><th>THK</th><th>SHEET</th><th>GRAIN</th><th>ROLE</th></tr></thead><tbody>
      ${S.boot.materials.map((m) => `<tr><td><span class="swatch" style="background:${esc(m.color)}"></span>${esc(m.name)}</td><td class="num">${fmt(m.thickness)}</td><td>${fmt(m.sheet_length)} x ${fmt(m.sheet_width)}</td><td>${GRAIN[m.grain]}</td><td>${esc(m.role)}</td></tr>`).join('')}
      </tbody></table></div><p class="mute">Custom materials, prices and suppliers: planned (Phase 2). Dimensions in ${S.unit}.</p>`;
  }

  function projectView() {
    const rows = S.cabinets.map((c) => `<tr class="clickable ${S.editing && S.editing.id === c.id ? 'sel' : ''}" data-id="${esc(c.id)}"><td>${esc(c.label)}</td><td class="num">${fmt(c.params.width)} x ${fmt(c.params.height)} x ${fmt(c.params.depth)}</td><td>v${c.version}</td></tr>`).join('');
    return `<h2>PROJECT</h2><div class="card"><h3>${S.cabinets.length} cabinet${S.cabinets.length === 1 ? '' : 's'} in this model</h3>
      <p>Click a row to select and zoom to it. Saved projects, folders and runs arrive in a later phase; today the SketchUp model is the project.</p>
      ${S.cabinets.length ? `<table><thead><tr><th>CABINET</th><th>W x H x D (${S.unit})</th><th>REV</th></tr></thead><tbody>${rows}</tbody></table>` : '<p class="mute">No cabinets yet.</p>'}</div>
      <p class="mute">Only top-level groups are scanned in this version.</p>`;
  }
  function bindProject() {
    document.querySelectorAll('tr[data-id]').forEach((r) => (r.onclick = () => rpc('select', [r.dataset.id]).catch(showError)));
  }

  function settingsView() {
    return `<h2>SETTINGS</h2><div class="card"><div class="field"><label for="unit">Display units</label>
      <select id="unit">${Object.keys(UNIT_MM).map((u) => `<option ${u === S.unit ? 'selected' : ''}>${u}</option>`).join('')}</select>
      <div class="note">Model data is always stored in millimetres; this changes only what you see and type.</div></div></div>
      <p class="mute">Company manufacturing standards: planned (Phase 6).</p>`;
  }
  function bindSettings() {
    $('#unit').onchange = (e) => { S.unit = e.target.value; save('cc_unit', S.unit); render(); };
  }

  // ---- Boot -----------------------------------------------------------------
  function start() {
    rpc('bootstrap').then((b) => {
      S.boot = b;
      S.boot.defaults = {};
      b.library.forEach((e) => { const d = {}; b.schema.forEach((f) => (d[f.key] = f.default)); S.boot.defaults[e.type] = Object.assign(d, e.defaults); });
      S.params = Object.assign({}, S.boot.defaults[S.type]); S.cabinets = b.cabinets;
      if (b.selected) loadCabinet(b.selected); else render();
    }).catch((e) => { $('#view').innerHTML = `<div class="card"><h3>Cannot connect</h3><p>${esc(e.message)}</p></div>`; });
  }
  document.addEventListener('DOMContentLoaded', start);
})();
