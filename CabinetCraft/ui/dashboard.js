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
    { id: 'hardware', label: 'HARDWARE', phase: 0 },
    { id: 'parts', label: 'PARTS', phase: 0 },
    { id: 'nesting', label: 'NESTING', phase: 4, scope: '2D sheet packing that respects grain, kerf and trim; sheet preview and utilisation. Will be described as a heuristic, not optimal.' },
    { id: 'reports', label: 'REPORTS', phase: 0 },
    { id: 'cnc', label: 'CNC', phase: 5, scope: 'Machining data (hinge cups, shelf pins, connectors), DXF, and a post-processor framework.' },
    { id: 'settings', label: 'SETTINGS', phase: 0 }
  ];
  const S = {
    boot: null, tab: 'cabinets', unit: load('cc_unit', 'mm'),
    type: 'base_cabinet', params: null, editing: null, preview: null, cabinets: [], search: '', timer: null, busy: false,
    partsMode: 'project', projectRows: null, partsSearch: '', partsCabinet: '', partsMaterial: '', sort: { key: 'part_id', dir: 1 },
    cutting: null, hw: null
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
    else if (S.tab === 'parts') { v.innerHTML = partsShell(); bindParts(); loadParts(); }
    else if (S.tab === 'reports') { v.innerHTML = '<p class="mute">Loading...</p>'; loadReports(); }
    else if (S.tab === 'hardware') { v.innerHTML = '<p class="mute">Loading...</p>'; loadHardware(); }
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
    if (!p) { if (S.tab === 'parts') paintParts(); return; }
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
    if (S.tab === 'parts') { if (S.partsMode === 'project') loadParts(); else paintParts(); }
  }
  function paintStatus() {
    const el = $('#status'); const issues = (S.preview && S.preview.issues) || [];
    const err = issues.some((i) => i.severity === 'error'); const warn = issues.some((i) => i.severity === 'warning');
    el.className = 'status ' + (err ? 'err' : warn ? 'warn' : 'ok'); el.textContent = err ? 'ERROR' : warn ? 'WARNING' : 'VALID';
  }

  // ---- Parts (project-wide) -------------------------------------------------
  const PART_COLS = [['part_id', 'PART ID'], ['cabinet_label', 'CABINET'], ['name', 'PART'], ['length', 'LENGTH', 1], ['width', 'WIDTH', 1],
    ['thickness', 'THK', 1], ['qty', 'QTY', 1], ['material', 'MATERIAL'], ['grain', 'GRAIN'], ['edge_text', 'EDGE BANDING'], ['hardware', 'HARDWARE']];

  function partsShell() {
    return `<h2>PARTS</h2><div class="row" style="margin-bottom:8px">
      <button class="ghost ${S.partsMode === 'project' ? 'on' : ''}" id="pm_project">All cabinets</button>
      <button class="ghost ${S.partsMode === 'current' ? 'on' : ''}" id="pm_current">Current cabinet</button></div>
      <div class="row" style="margin-bottom:8px"><input type="search" id="psearch" placeholder="Search parts..." value="${esc(S.partsSearch)}" style="flex:1;margin:0">
      <select id="pcab"></select><select id="pmat"></select></div>
      <div id="ptable"></div><div id="pexport"></div>`;
  }
  function bindParts() {
    $('#pm_project').onclick = () => { S.partsMode = 'project'; render(); };
    $('#pm_current').onclick = () => { S.partsMode = 'current'; render(); };
    $('#psearch').oninput = (e) => { S.partsSearch = e.target.value; paintParts(); };
    $('#pcab').onchange = (e) => { S.partsCabinet = e.target.value; paintParts(); };
    $('#pmat').onchange = (e) => { S.partsMaterial = e.target.value; paintParts(); };
  }
  function loadParts() {
    if (S.partsMode === 'current') { paintParts(); return; }
    rpc('parts_list').then((r) => { S.projectRows = r.rows; paintParts(); }).catch(showError);
  }
  function currentRows() { return ((S.preview && S.preview.panels) || []).map((r) => Object.assign({ cabinet_label: S.editing ? S.editing.label : '(new)' }, r)); }
  function paintParts() {
    const t = $('#ptable'); if (!t) return;
    const all = S.partsMode === 'project' ? (S.projectRows || []) : currentRows();
    const opts = (key) => ['', ...Array.from(new Set(all.map((r) => r[key]))).sort()];
    const fill = (sel, key, cur, label) => { const el = $(sel); el.innerHTML = opts(key).map((o) => `<option value="${esc(o)}" ${o === cur ? 'selected' : ''}>${o ? esc(o) : label}</option>`).join(''); };
    fill('#pcab', 'cabinet_label', S.partsCabinet, 'All cabinets'); fill('#pmat', 'material', S.partsMaterial, 'All materials');
    const q = S.partsSearch.toLowerCase();
    let rows = all.filter((r) => (!S.partsCabinet || r.cabinet_label === S.partsCabinet) && (!S.partsMaterial || r.material === S.partsMaterial) &&
      (!q || PART_COLS.some(([k]) => String(r[k]).toLowerCase().includes(q))));
    const { key, dir } = S.sort;
    rows = rows.slice().sort((a, b) => (a[key] < b[key] ? -dir : a[key] > b[key] ? dir : 0));
    if (!all.length) { t.innerHTML = '<div class="card"><h3>No parts</h3><p>Create a cabinet, or configure one in PARAMETERS.</p></div>'; $('#pexport').innerHTML = ''; return; }
    t.innerHTML = `<div class="card" style="overflow:auto"><table><thead><tr>${PART_COLS.map(([k, h]) => `<th class="sortable" data-sort="${k}">${h}${key === k ? (dir > 0 ? ' &#9650;' : ' &#9660;') : ''}</th>`).join('')}</tr></thead><tbody>
      ${rows.map((r) => `<tr>${PART_COLS.map(([k, , num]) => `<td class="${num ? 'num' : ''}">${num && k !== 'qty' ? fmt(r[k]) : k === 'grain' ? GRAIN[r[k]] : esc(r[k])}</td>`).join('')}</tr>`).join('')}</tbody></table></div>
      <p class="mute">${rows.length} of ${all.length} parts. Dimensions in ${S.unit}; length is the longer side and band thickness is not deducted.</p>`;
    t.querySelectorAll('[data-sort]').forEach((th) => (th.onclick = () => { S.sort = { key: th.dataset.sort, dir: S.sort.key === th.dataset.sort ? -S.sort.dir : 1 }; paintParts(); }));
    $('#pexport').innerHTML = S.partsMode === 'project' ? exportButtons('parts') : '<p class="mute">Exports cover all cabinets in the model: switch to "All cabinets".</p>';
    bindExports();
  }

  function exportButtons(kind) {
    const f = [['csv', 'CSV'], ['excel_csv', 'Excel CSV'], ['json', 'JSON']];
    return `<div class="row" style="margin:8px 0"><span class="mute">Export:</span>${f.map(([fmt_, l]) => `<button class="ghost" data-export="${kind}" data-format="${fmt_}">${l}</button>`).join('')}</div>`;
  }
  function bindExports() {
    document.querySelectorAll('[data-export]').forEach((b) => (b.onclick = () => {
      rpc('export', [b.dataset.export, b.dataset.format]).then((r) => toast(r.cancelled ? 'Export cancelled' : 'Saved ' + r.path)).catch(showError);
    }));
  }

  // ---- Reports (cutting list) ----------------------------------------------------
  function loadReports() { rpc('cutting_list').then((c) => { S.cutting = c; paintReports(); }).catch(showError); }
  function paintReports() {
    const c = S.cutting; const v = $('#view'); if (S.tab !== 'reports' || !c) return;
    if (!c.part_count) { v.innerHTML = '<h2>CUTTING LIST</h2><div class="card"><h3>Nothing to report</h3><p>No cabinets in the model yet.</p></div>'; return; }
    const mats = c.materials.map((m) => `<div class="card"><h3>${esc(m.material)}</h3>
      <p>${m.part_count} parts &middot; ${m.area_m2} m&sup2; &middot; sheet ${fmt(m.sheet_length)} x ${fmt(m.sheet_width)} ${S.unit} &middot; about <b>${m.estimated_sheets}</b> sheet${m.estimated_sheets === 1 ? '' : 's'} (estimate)</p>
      <table><thead><tr><th>PART</th><th>LENGTH</th><th>WIDTH</th><th>QTY</th><th>GRAIN</th><th>EDGES</th><th>CABINETS</th></tr></thead><tbody>
      ${m.groups.map((g) => `<tr><td>${esc(g.name)}</td><td class="num">${fmt(g.length)}</td><td class="num">${fmt(g.width)}</td><td class="num"><b>${g.qty}</b></td><td>${GRAIN[g.grain]}</td><td>${esc(g.edge_text)}</td><td class="mute">${esc(g.cabinets)}</td></tr>`).join('')}</tbody></table></div>`).join('');
    const bands = c.edge_banding.length ? `<div class="card"><table>${c.edge_banding.map((b) => `<tr><td>${b.thickness} mm band</td><td class="num">${b.length_m} m</td></tr>`).join('')}</table></div>` : '<p class="mute">No edge banding.</p>';
    const hw = c.hardware.length ? `<div class="card"><table>${c.hardware.map((h) => `<tr><td>${esc(h.name)}</td><td class="mute">${esc(h.category)}</td><td class="num">${h.qty}</td></tr>`).join('')}</table></div>` : '';
    v.innerHTML = `<h2>CUTTING LIST - ${c.cabinet_count} cabinet${c.cabinet_count === 1 ? '' : 's'}, ${c.part_count} parts</h2>${mats}<h2>EDGE BANDING</h2>${bands}<h2>HARDWARE</h2>${hw}
      <p class="mute">${esc(c.estimate_note)} Dimensions in ${S.unit}.</p>
      <h2>EXPORT</h2>${exportButtons('cutting_list')}<div class="row"><span class="mute">Hardware list:</span>
      <button class="ghost" data-export="hardware" data-format="csv">CSV</button><button class="ghost" data-export="hardware" data-format="excel_csv">Excel CSV</button></div>
      <div class="row" style="margin-top:8px"><span class="mute">Whole project:</span><button class="ghost" data-export="project" data-format="json">JSON backup</button></div>
      <p class="mute">PDF export: planned.</p>`;
    bindExports();
  }

  // ---- Hardware --------------------------------------------------------------------
  function loadHardware() { rpc('hardware_state').then(setHw).catch(showError); }
  function setHw(h) { S.hw = h; S.boot.schema = h.schema; if (S.tab === 'hardware') paintHardware(); }
  function hwCall(method, args) { return rpc(method, args).then((h) => { setHw(h); toast('Saved'); }).catch(showError); }
  function paintHardware() {
    const h = S.hw; const v = $('#view');
    const lib = Object.entries(h.categories).map(([cat, label]) => {
      const items = h.library.filter((i) => i.category === cat); if (!items.length) return '';
      return `<h2>${esc(label.toUpperCase())}</h2><div class="card"><table>${items.map((i) => `<tr><td>${esc(i.name)}${i.custom ? ' <span class="badge impl">CUSTOM</span>' : ''}</td>
        <td class="mute">${i.price != null ? i.price : ''} ${esc(i.supplier || '')}</td><td class="num">${i.custom ? `<button class="ghost" data-del="${esc(i.id)}">Delete</button>` : ''}</td></tr>`).join('')}</table></div>`;
    }).join('');
    const rules = h.hinge_rules.map((r, i) => `<tr><td>door height &ge;</td><td><input type="number" data-rule="min_height" data-i="${i}" value="${toDisp(r.min_height)}" ${i === 0 ? 'disabled' : ''} style="width:90px"> ${S.unit}</td>
      <td>hinges <input type="number" data-rule="count" data-i="${i}" value="${r.count}" min="1" max="10" style="width:60px"></td><td>${i ? `<button class="ghost" data-rmrule="${i}">&times;</button>` : ''}</td></tr>`).join('');
    const SET = [['hinge_inset', 'Hinge inset from door edge (mm)'], ['connector_spacing', 'Connector spacing (mm)'], ['shelf_pins_per_shelf', 'Shelf pins per shelf'],
      ['handle_inset', 'Handle inset from free edge (mm)'], ['handle_top_offset', 'Handle drop from door top (mm)']];
    v.innerHTML = `<h2>HINGE RULES</h2><div class="card"><table>${rules}</table>
      <div class="row" style="margin-top:8px"><button class="ghost" id="addrule">Add rule</button><button class="primary" id="saverules">Save rules</button></div>
      <p class="mute">Hinge count for a door = the last rule whose height is at or below the door's height. Hinge positions and counts update on every cabinet automatically.</p></div>
      <h2>PLACEMENT SETTINGS</h2><div class="card"><div class="fields">${SET.map(([k, l]) => `<div class="field"><label>${l}</label><input type="number" data-set="${k}" value="${h.settings[k]}"></div>`).join('')}</div>
      <p class="mute">Millimetres, not affected by the display unit.</p></div>
      <h2>ADD CUSTOM HARDWARE</h2><div class="card"><div class="fields">
      <div class="field"><label>Name</label><input id="hw_name"></div>
      <div class="field"><label>Category</label><select id="hw_cat">${Object.entries(h.categories).map(([k, l]) => `<option value="${k}">${esc(l)}</option>`).join('')}</select></div>
      <div class="field"><label>Unit price (optional)</label><input id="hw_price" type="number" step="any" min="0"></div>
      <div class="field"><label>Supplier (optional)</label><input id="hw_sup"></div></div>
      <div class="row" style="padding:0 12px 12px"><button class="primary" id="hw_add">Add</button></div></div>
      <p class="mute">Custom hinges, runners, connectors, handles and legs appear in the PARAMETERS dropdowns. Prices are stored but not used until costing (Phase 6). Locks have no automatic placement yet.</p>
      <h2>LIBRARY</h2>${lib}`;
    v.querySelectorAll('[data-del]').forEach((b) => (b.onclick = () => hwCall('delete_hardware', [b.dataset.del])));
    v.querySelectorAll('[data-set]').forEach((i) => (i.onchange = () => hwCall('set_hardware_setting', [i.dataset.set, i.value])));
    $('#hw_add').onclick = () => hwCall('add_hardware', [$('#hw_name').value, $('#hw_cat').value, $('#hw_price').value, $('#hw_sup').value]);
    const readRules = () => h.hinge_rules.map((r, i) => ({
      min_height: i === 0 ? 0 : fromDisp(v.querySelector(`[data-rule=min_height][data-i="${i}"]`).value), count: parseInt(v.querySelector(`[data-rule=count][data-i="${i}"]`).value, 10) }));
    $('#saverules').onclick = () => hwCall('set_hinge_rules', [readRules()]);
    $('#addrule').onclick = () => { const r = readRules(); r.push({ min_height: (r[r.length - 1].min_height || 0) + 300, count: r[r.length - 1].count + 1 }); S.hw.hinge_rules = r; paintHardware(); };
    v.querySelectorAll('[data-rmrule]').forEach((b) => (b.onclick = () => { const r = readRules(); r.splice(+b.dataset.rmrule, 1); S.hw.hinge_rules = r; paintHardware(); }));
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
