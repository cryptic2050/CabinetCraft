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
    { id: 'templates', label: 'TEMPLATES', phase: 0 },
    { id: 'runs', label: 'RUNS', phase: 0 },
    { id: 'parameters', label: 'PARAMETERS', phase: 0 },
    { id: 'materials', label: 'MATERIALS', phase: 0 },
    { id: 'hardware', label: 'HARDWARE', phase: 0 },
    { id: 'parts', label: 'PARTS', phase: 0 },
    { id: 'nesting', label: 'NESTING', phase: 0 },
    { id: 'labels', label: 'LABELS', phase: 0 },
    { id: 'reports', label: 'REPORTS', phase: 0 },
    { id: 'cnc', label: 'CNC', phase: 0 },
    { id: 'assembly', label: 'ASSEMBLY', phase: 0 },
    { id: 'costs', label: 'COSTS', phase: 0 },
    { id: 'settings', label: 'SETTINGS', phase: 0 }
  ];
  const S = {
    boot: null, tab: 'cabinets', unit: load('cc_unit', 'mm'),
    type: 'base_cabinet', params: null, editing: null, preview: null, cabinets: [], search: '', timer: null, busy: false,
    partsMode: 'project', projectRows: null, partsSearch: '', partsCabinet: '', partsMaterial: '', sort: { key: 'part_id', dir: 1 },
    cutting: null, hw: null,
    tpls: null, tplSel: null, tplText: '', tplResult: null, mats: null, matSel: null, adv: null, advOpen: false, cnc: null, cncCheck: null, cncPrev: null, cncFace: 'a', cncMat: '', cncSheet: 0, nest: null, nestMat: 0, nestSheet: 0, nestSel: null, health: null, labels: null, lookup: null
  };
  function load(k, d) { try { return localStorage.getItem(k) || d; } catch (e) { return d; } }
  function save(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* storage may be blocked */ } }

  // Parameter schema for a cabinet type: user templates have their own, built-in types share one.
  const schemaFor = (type) => (S.boot.schemas && S.boot.schemas[type]) || S.boot.schema;
  function setLibrary(lib, schemas) {
    S.boot.library = lib; S.boot.schemas = schemas; S.boot.defaults = {};
    lib.forEach((e) => { S.boot.defaults[e.type] = Object.assign({}, e.resolved); }); // resolved on the server: schema < company standards < the type's own defaults
  }
  function refreshLibrary() { return rpc('library_state').then((l) => { S.boot.standards = l.standards; setLibrary(l.library, l.schemas); if (S.tab === 'cabinets') render(); }).catch(() => {}); }

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
    return rpc('preview', [S.type, S.params, S.editing ? S.editing.label : null, S.editing ? S.editing.id : null]).then((p) => { S.preview = p; paintResults(); }).catch(showError);
  }
  function applyUpdate(mode) {
    return rpc('update', [S.editing.id, S.params, mode || null]).then((p) => {
      if (p.needs_confirmation) { S.preview = p; showOverrideWarning(p.affected); paintResults(); return; }
      clearOverrideWarning(); S.preview = p; if (p.cabinet) S.editing = p.cabinet; paintResults(); if (S.advOpen && p.updated) loadAdvanced();
    }).catch(showError);
  }
  function clearOverrideWarning() { const el = $('#ovr_warn'); if (el) el.innerHTML = ''; }
  function showOverrideWarning(list) {
    const el = $('#ovr_warn'); if (!el) return;
    const lines = list.map((a) => a.orphaned ? `<li><b>${esc(a.part_id)}</b> has a manual override but would no longer exist.</li>`
      : `<li><b>${esc(a.part_id)}</b> ${esc(a.field)} is manually set to <b>${fmt(a.override)}</b>; the automatic value would change ${fmt(a.auto_old)} &rarr; ${fmt(a.auto_new)} ${S.unit}.</li>`).join('');
    el.innerHTML = `<div class="card" style="border-color:var(--warn)"><h3>This change affects manual overrides</h3><ul style="margin:6px 0 10px 16px;padding:0">${lines}</ul>
      <div class="row"><button class="primary" id="ow_keep">Keep my overrides</button><button class="ghost" id="ow_reset">Reset them to AUTO</button><button class="ghost" id="ow_cancel">Cancel the change</button></div>
      <p class="mute" style="margin-top:8px">Nothing has been changed in the model yet.</p></div>`;
    $('#ow_keep').onclick = () => applyUpdate('keep');
    $('#ow_reset').onclick = () => applyUpdate('reset');
    $('#ow_cancel').onclick = () => { S.params = Object.assign({}, S.editing.params); clearOverrideWarning(); render(); runPreview(); };
  }
  // ---- Advanced parts (manual overrides) -------------------------------------------------------
  function loadAdvanced() { if (!S.editing) return; rpc('advanced_parts', [S.editing.id]).then((a) => { S.adv = a; paintAdvanced(); }).catch(showError); }
  function paintAdvanced() {
    const el = $('#advbody'); if (!el || !S.adv) return; const a = S.adv;
    const num = (f) => (f.value == null ? '' : toDisp(f.value));
    const card = (p) => {
      const f = p.fields; const manual = p.status !== 'AUTO'; const ed = f.edges.value;
      const inp = (k, label, unit) => `<div class="field"><label>${label}</label><input type="number" step="any" data-ov="${k}" placeholder="${toDisp(f[k].auto)}" value="${num(f[k])}"></div>`;
      const off = (k, label) => `<div class="field"><label>${label}</label><input type="number" step="any" data-ov="${k}" placeholder="0" value="${f[k].value == null ? '' : toDisp(f[k].value)}"></div>`;
      const edgeCells = p.edge_faces.map((face) => `<div class="field"><label>${face}</label><input type="number" step="any" min="0" max="5" data-edge="${face}" ${ed ? '' : 'disabled'} value="${(ed ? (ed[face] || 0) : (f.edges.auto[face] || 0))}"></div>`).join('');
      return `<details class="partcard" data-key="${esc(p.key)}" ${manual ? 'open' : ''}><summary>${esc(p.name)} <span class="mono mute">${esc(p.part_id)}</span> <span class="badge ${manual ? 'warnb' : 'plan'}">${p.status}</span></summary>
        <div class="fields">${inp('length', `Length (${S.unit})`)}${inp('width', `Width (${S.unit})`)}${inp('thickness', `Thickness (${S.unit})`)}
        <div class="field"><label>Material</label><select data-ov="material"><option value="">Auto (${esc((a.materials.find((m) => m.id === f.material.auto) || {}).name || f.material.auto)})</option>${a.materials.map((m) => `<option value="${esc(m.id)}" ${m.id === f.material.value ? 'selected' : ''}>${esc(m.name)}</option>`).join('')}</select></div>
        ${off('offset_x', `Move X (${S.unit})`)}${off('offset_y', `Move Y (${S.unit})`)}${off('offset_z', `Move Z (${S.unit})`)}</div>
        <div class="field" style="padding:0 12px"><label><input type="checkbox" data-edges-on ${ed ? 'checked' : ''}> Override edge banding (mm per edge; 0 = none)</label></div>
        <div class="fields" style="grid-template-columns:repeat(4,1fr)">${edgeCells}</div>
        <div class="row" style="padding:0 12px 12px"><button class="primary" data-apply>Apply</button><button class="ghost" data-reset ${manual ? '' : 'disabled'}>Reset to AUTO</button><span class="mute">Blank = AUTO (grey = automatic value)</span></div></details>`;
    };
    el.innerHTML = `${a.orphans.length ? `<ul class="issues"><li class="warning"><b>IGNORED</b> overrides for parts that no longer exist: ${esc(a.orphans.join(', '))}</li></ul>` : ''}
      ${a.issues.length ? `<ul class="issues">${a.issues.map((i) => `<li class="${i.severity}">${esc(i.message)}</li>`).join('')}</ul>` : ''}
      <div class="row" style="margin-bottom:8px"><span class="mute">${a.parts.filter((p) => p.status !== 'AUTO').length} of ${a.parts.length} parts manually overridden</span><button class="ghost" id="adv_resetall">Reset all to AUTO</button></div>
      ${a.parts.map(card).join('')}<p class="mute">Overrides stay when you change the cabinet's size; you are asked before a change would alter one. Hardware counts, labels, nesting and machining follow the overridden parts. Dimensions are along the part's own length/width/thickness axes.</p>`;
    el.querySelectorAll('details.partcard').forEach((d) => {
      const key = d.dataset.key;
      d.querySelector('[data-edges-on]').onchange = (e) => d.querySelectorAll('[data-edge]').forEach((i) => (i.disabled = !e.target.checked));
      d.querySelector('[data-apply]').onclick = () => {
        const fields = {};
        d.querySelectorAll('[data-ov]').forEach((i) => { const k = i.dataset.ov; fields[k] = i.value === '' ? '' : (k === 'material' ? i.value : fromDisp(i.value)); });
        if (d.querySelector('[data-edges-on]').checked) { const e = {}; d.querySelectorAll('[data-edge]').forEach((i) => (e[i.dataset.edge] = i.value === '' ? 0 : parseFloat(i.value))); fields.edges = e; } else fields.edges = null;
        rpc('set_override', [S.editing.id, key, fields]).then((r) => { S.adv = r; S.editing = r.cabinet; paintAdvanced(); runPreview(); toast('Saved'); }).catch(showError);
      };
      d.querySelector('[data-reset]').onclick = () => rpc('reset_overrides', [S.editing.id, key]).then((r) => { S.adv = r; S.editing = r.cabinet; paintAdvanced(); runPreview(); toast('Reset to AUTO'); }).catch(showError);
    });
    $('#adv_resetall').onclick = () => rpc('reset_overrides', [S.editing.id]).then((r) => { S.adv = r; S.editing = r.cabinet; paintAdvanced(); runPreview(); toast('All parts reset to AUTO'); }).catch(showError);
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
    else if (S.tab === 'materials') { v.innerHTML = '<p class="mute">Loading...</p>'; loadMaterials(); }
    else if (S.tab === 'parts') { v.innerHTML = partsShell(); bindParts(); loadParts(); }
    else if (S.tab === 'templates') { v.innerHTML = '<p class="mute">Loading...</p>'; loadTemplates(); }
    else if (S.tab === 'cnc') { v.innerHTML = '<p class="mute">Loading...</p>'; loadCnc(); }
    else if (S.tab === 'nesting') { v.innerHTML = '<p class="mute">Loading...</p>'; loadNesting(); }
    else if (S.tab === 'labels') { v.innerHTML = '<p class="mute">Loading...</p>'; loadLabels(); }
    else if (S.tab === 'reports') { v.innerHTML = '<p class="mute">Loading...</p>'; loadReports(); }
    else if (S.tab === 'runs') { paintRuns(); }
    else if (S.tab === 'assembly') { v.innerHTML = '<p class="mute">Loading...</p>'; loadAssembly(); }
    else if (S.tab === 'costs') { v.innerHTML = '<p class="mute">Loading...</p>'; loadCosts(); }
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
      `<div class="card"><h3>${esc(e.name)}<span class="badge impl">${e.user === 'template' ? 'TEMPLATE' : e.user === 'preset' ? 'SAVED' : 'IMPLEMENTED'}</span></h3><p>${esc(e.description)}</p>
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
    schemaFor(S.type).forEach((f) => (groups[f.group] = groups[f.group] || []).push(f));
    const title = S.editing ? `Editing ${esc(S.editing.label)} <span class="mute">v${S.editing.version}</span>` : 'New cabinet';
    const body = Object.entries(groups).map(([g, fields]) =>
      `<details open><summary>${esc(g)}</summary><div class="fields">${fields.map(fieldHtml).join('')}</div></details>`).join('');
    const lib = S.boot.library.find((e) => e.type === S.type);
    const canSave = !(lib && lib.user === 'template'); // templates are edited in TEMPLATES; everything else can be saved as a preset
    const action = (S.editing
      ? `<span class="mute">Changes apply to the model as you type.</span> <button class="ghost" id="newcab">New cabinet</button>`
      : `<button class="primary" id="create" ${S.busy ? 'disabled' : ''}>CREATE</button>`) + (canSave ? ' <button class="ghost" id="saveas">Save as template...</button>' : '') + (S.editing && lib && lib.user !== 'template' && Object.keys((S.boot.standards || {}).values || {}).length ? ' <button class="ghost" id="applystd">Apply company standards</button>' : '');
    return `<h2>${title}</h2><div class="row" style="margin-bottom:10px">${action}</div>
      <div id="ovr_warn"></div><div id="issues"></div>${body}<h2>CALCULATED</h2><div id="calc"></div>
      ${S.editing ? `<h2>ADVANCED PARTS</h2><details id="adv" ${S.advOpen ? 'open' : ''}><summary>MANUAL OVERRIDES (AUTO unless changed)</summary><div id="advbody" style="padding:10px 12px"><p class="mute">Loading...</p></div></details>` : ''}`;
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
        const f = schemaFor(S.type).find((x) => x.key === el.dataset.key);
        S.params[f.key] = f.type === 'enum' ? el.value : f.type === 'int' ? parseFloat(el.value) : fromDisp(el.value);
        schedule();
      };
    });
    const as = $('#applystd'); if (as) as.onclick = () => { Object.assign(S.params, S.boot.standards.values); render(); schedule(); toast('Company standards applied to this cabinet'); };
    const sa = $('#saveas'); if (sa) sa.onclick = () => {
      const name = prompt('Name for the new cabinet template'); if (!name) return;
      const cat = prompt('Category (e.g. BASE CABINETS, WARDROBES, CUSTOM)', (S.boot.library.find((e) => e.type === S.type) || {}).category || 'CUSTOM'); if (cat === null) return;
      rpc('save_preset', [name, cat, '', S.editing ? S.editing.type : S.type, S.params]).then((st) => { setLibrary(st.library, st.schemas); toast('Saved - it is now in the CABINETS library'); }).catch(showError);
    };
    const adv = $('#adv'); if (adv) { adv.ontoggle = () => { S.advOpen = adv.open; if (adv.open) loadAdvanced(); }; if (adv.open) loadAdvanced(); }
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
    if (calc && p.derived && p.derived.length) {
      calc.innerHTML = `<div class="card"><table>${p.derived.map((d) => `<tr><td>${esc(d.label)}</td><td class="num">${fmt(d.value)} ${S.unit}</td></tr>`).join('')}</table></div>`;
    } else if (calc && p.values && p.values.internal_width != null) {
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
    ['thickness', 'THK', 1], ['qty', 'QTY', 1], ['material', 'MATERIAL'], ['grain', 'GRAIN'], ['edge_text', 'EDGE BANDING'], ['hardware', 'HARDWARE'], ['status', 'STATUS']];

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
      ${rows.map((r) => `<tr>${PART_COLS.map(([k, , num]) => `<td class="${num ? 'num' : ''}">${num && k !== 'qty' ? fmt(r[k]) : k === 'grain' ? GRAIN[r[k]] : k === 'status' ? `<span class="badge ${r[k] === 'AUTO' ? 'plan' : 'warnb'}">${esc(r[k])}</span>` : esc(r[k])}</td>`).join('')}</tr>`).join('')}</tbody></table></div>
      <p class="mute">${rows.length} of ${all.length} parts. Dimensions in ${S.unit}; length is the longer side and band thickness is not deducted.</p>`;
    t.querySelectorAll('[data-sort]').forEach((th) => (th.onclick = () => { S.sort = { key: th.dataset.sort, dir: S.sort.key === th.dataset.sort ? -S.sort.dir : 1 }; paintParts(); }));
    $('#pexport').innerHTML = S.partsMode === 'project' ? exportButtons('parts') : '<p class="mute">Exports cover all cabinets in the model: switch to "All cabinets".</p>';
    bindExports();
  }

  function exportButtons(kind, formats) {
    const f = formats || [['pdf', 'PDF'], ['csv', 'CSV'], ['excel_csv', 'Excel CSV'], ['json', 'JSON']];
    return `<div class="row" style="margin:8px 0"><span class="mute">Export:</span>${f.map(([fmt_, l]) => `<button class="ghost" data-export="${kind}" data-format="${fmt_}">${l}</button>`).join('')}</div>`;
  }
  function bindExports() {
    document.querySelectorAll('[data-export]').forEach((b) => (b.onclick = () => {
      rpc('export', [b.dataset.export, b.dataset.format]).then((r) => toast(r.cancelled ? 'Export cancelled' : r.count > 1 ? `Saved ${r.count} files, e.g. ${r.paths[0]}` : 'Saved ' + r.path)).catch(showError);
    }));
  }

  // ---- Reports (cutting list) ----------------------------------------------------
  function loadReports() { rpc('cutting_list').then((c) => { S.cutting = c; paintReports(); }).catch(showError); }
  function paintReports() {
    const c = S.cutting; const v = $('#view'); if (S.tab !== 'reports' || !c) return;
    if (!c.part_count) { v.innerHTML = '<h2>CUTTING LIST</h2><div class="card"><h3>Nothing to report</h3><p>No cabinets in the model yet.</p></div>'; return; }
    const mats = c.materials.map((m) => `<div class="card"><h3>${esc(m.material)}</h3>
      <p>${m.part_count} parts &middot; ${m.area_m2} m&sup2; &middot; sheet ${fmt(m.sheet_length)} x ${fmt(m.sheet_width)} ${S.unit} &middot; about <b>${m.estimated_sheets}</b> sheet${m.estimated_sheets === 1 ? '' : 's'} (estimate, ${m.waste_pct}% waste)${m.estimated_cost != null ? ` &middot; <b>${m.estimated_cost}</b> at ${m.price}/sheet` : ''}</p>
      <table><thead><tr><th>PART</th><th>LENGTH</th><th>WIDTH</th><th>QTY</th><th>GRAIN</th><th>EDGES</th><th>CABINETS</th></tr></thead><tbody>
      ${m.groups.map((g) => `<tr><td>${esc(g.name)}</td><td class="num">${fmt(g.length)}</td><td class="num">${fmt(g.width)}</td><td class="num"><b>${g.qty}</b></td><td>${GRAIN[g.grain]}</td><td>${esc(g.edge_text)}</td><td class="mute">${esc(g.cabinets)}</td></tr>`).join('')}</tbody></table></div>`).join('');
    const bands = c.edge_banding.length ? `<div class="card"><table>${c.edge_banding.map((b) => `<tr><td>${b.thickness} mm band</td><td class="num">${b.length_m} m</td></tr>`).join('')}</table></div>` : '<p class="mute">No edge banding.</p>';
    const hw = c.hardware.length ? `<div class="card"><table>${c.hardware.map((h) => `<tr><td>${esc(h.name)}</td><td class="mute">${esc(h.category)}</td><td class="num">${h.qty}</td></tr>`).join('')}</table></div>` : '';
    v.innerHTML = `<h2>CUTTING LIST - ${c.cabinet_count} cabinet${c.cabinet_count === 1 ? '' : 's'}, ${c.part_count} parts</h2>${mats}<h2>EDGE BANDING</h2>${bands}<h2>HARDWARE</h2>${hw}
      <p class="mute">${esc(c.estimate_note)} Dimensions in ${S.unit}. PDFs always use millimetres.</p>
      <h2>EXPORT</h2>${exportButtons('cutting_list')}<div class="row"><span class="mute">Hardware list:</span>
      <button class="ghost" data-export="hardware" data-format="csv">CSV</button><button class="ghost" data-export="hardware" data-format="excel_csv">Excel CSV</button></div>
      <div class="row" style="margin-top:8px"><span class="mute">Whole project:</span><button class="ghost" data-export="project" data-format="json">JSON backup</button></div>
      `;
    bindExports();
  }

  // ---- Nesting ----------------------------------------------------------------------
  function loadNesting(settings) {
    const args = settings ? [settings] : [];
    return rpc('nest', args).then((n) => { S.nest = n; if (S.nestMat >= n.materials.length) S.nestMat = 0; paintNesting(); }).catch((e) => { showError(e); if (!S.nest) paintNesting(); });
  }
  const hue = (s) => { let h = 0; for (const c of String(s)) h = (h * 31 + c.charCodeAt(0)) % 360; return h; };

  function paintNesting() {
    const v = $('#view'); if (S.tab !== 'nesting') return;
    const n = S.nest;
    const st = n ? n.settings : { kerf: 4, trim: 10, spacing: 0 };
    const form = `<div class="card"><div class="fields">
      <div class="field"><label>Kerf (${S.unit})</label><input type="number" step="any" id="n_kerf" value="${toDisp(st.kerf)}"></div>
      <div class="field"><label>Edge trim (${S.unit})</label><input type="number" step="any" id="n_trim" value="${toDisp(st.trim)}"></div>
      <div class="field"><label>Extra spacing (${S.unit})</label><input type="number" step="any" id="n_spacing" value="${toDisp(st.spacing)}"></div>
      <div class="field"><label>Sheet size override (${S.unit}) L x W</label><div class="row"><input type="number" id="n_sl" placeholder="material default" value="${st.sheet_length ? toDisp(st.sheet_length) : ''}" style="width:48%"><input type="number" id="n_sw" value="${st.sheet_width ? toDisp(st.sheet_width) : ''}" style="width:48%"></div></div></div>
      <div class="row" style="padding:0 12px 12px"><button class="primary" id="n_run">NEST MATERIAL</button><button class="ghost" id="n_unlock">Unlock all parts</button></div></div>`;
    if (!n || !n.materials.length) { v.innerHTML = `<h2>NESTING</h2>${form}<div class="card"><h3>Nothing to nest</h3><p>No cabinets in the model yet.</p></div>`; bindNestForm(); return; }
    const t = n.totals; const m = n.materials[S.nestMat]; const sh = m.sheets[Math.min(S.nestSheet, m.sheets.length - 1)];
    const stat = (k, val) => `<div class="card" style="flex:1;min-width:110px;text-align:center"><div class="mute" style="font-size:10px">${k}</div><div style="font-size:18px;font-weight:700">${val}</div></div>`;
    const m2 = (mm2) => (mm2 / 1e6).toFixed(2) + ' m&sup2;';
    const tabs = n.materials.map((x, i) => `<button class="ghost ${i === S.nestMat ? 'on' : ''}" data-mat="${i}">${esc(x.material)} (${x.total_sheets})</button>`).join('');
    const sheetTabs = m.sheets.map((x, i) => `<button class="ghost ${sh && i === sh.index ? 'on' : ''}" data-sheet="${i}">Sheet ${i + 1} &middot; ${x.utilization}%</button>`).join('');
    v.innerHTML = `<h2>NESTING</h2>${form}
      <div class="row" style="gap:8px;margin-bottom:6px">${stat('TOTAL SHEETS', t.total_sheets)}${stat('TOTAL AREA', m2(t.total_area))}${stat('USED AREA', m2(t.used_area))}${stat('WASTE AREA', m2(t.waste_area))}${stat('UTILIZATION', t.utilization + ' %')}</div>
      <p class="mute">${esc(m.algorithm)}. Grain runs along the sheet length${m.grain_free ? '; this material has no grain, so parts may rotate' : ''}.</p>
      <div class="row" style="margin:8px 0">${tabs}</div>
      ${m.unplaced.length ? `<ul class="issues">${m.unplaced.map((u) => `<li class="error"><b>DOES NOT FIT</b> ${esc(u.part_id)} (${fmt(u.length)} x ${fmt(u.width)} ${S.unit}) on a ${fmt(m.sheet_length)} x ${fmt(m.sheet_width)} sheet</li>`).join('')}</ul>` : ''}
      ${m.released_locks.length ? `<ul class="issues">${m.released_locks.map((u) => `<li class="warning"><b>LOCK RELEASED</b> ${esc(u.part_id)}: ${esc(u.reason)}</li>`).join('')}</ul>` : ''}
      ${sh ? `<div class="row" style="margin:8px 0">${sheetTabs}</div><div class="card" style="padding:6px">${sheetSvg(m, sh)}</div><div id="ninfo"></div>${cutList(sh)}
        <p class="mute">Sheet ${fmt(m.sheet_length)} x ${fmt(m.sheet_width)} ${S.unit}, trim ${fmt(m.trim)}, kerf ${fmt(m.kerf)}. Used ${m2(sh.used_area)}, waste ${m2(sh.waste_area)}. Drag a part to move and lock it; click it for options.</p>` : '<p class="mute">No parts placed.</p>'}
      <h2>EXPORT</h2>${exportButtons('nesting')}`;
    bindNestForm(); bindNestSheet(m, sh); bindExports();
    v.querySelectorAll('[data-mat]').forEach((b) => (b.onclick = () => { S.nestMat = +b.dataset.mat; S.nestSheet = 0; S.nestSel = null; paintNesting(); }));
    v.querySelectorAll('[data-sheet]').forEach((b) => (b.onclick = () => { S.nestSheet = +b.dataset.sheet; S.nestSel = null; paintNesting(); }));
  }
  function bindNestForm() {
    const run = $('#n_run'); if (!run) return;
    run.onclick = () => {
      const g = (id) => $(id).value;
      const o = { kerf: fromDisp(g('#n_kerf')), trim: fromDisp(g('#n_trim')), spacing: fromDisp(g('#n_spacing')) };
      if (g('#n_sl')) o.sheet_length = fromDisp(g('#n_sl')); if (g('#n_sw')) o.sheet_width = fromDisp(g('#n_sw'));
      loadNesting(o);
    };
    $('#n_unlock').onclick = () => rpc('nest_unlock_all').then((n) => { S.nest = n; paintNesting(); toast('All parts unlocked'); }).catch(showError);
  }
  function sheetSvg(m, sh) {
    const SL = m.sheet_length; const SW = m.sheet_width; const fs = Math.max(SL / 95, 14);
    const parts = sh.placements.map((p) => {
      const y = SW - p.y - p.h; const label = esc(p.part_id) + (p.locked ? ' \u{1F512}' : '');
      const need = fs * 0.62 * p.part_id.length + fs; // approx. text length in sheet mm
      let txt = '';
      if (p.w > need && p.h > fs * 2.6) {
        txt = `<text x="${p.x + fs / 2}" y="${y + fs * 1.1}" font-size="${fs}" fill="#fff">${label}</text><text x="${p.x + fs / 2}" y="${y + fs * 2.2}" font-size="${fs * 0.85}" fill="#ddd">${fmt(p.w)} x ${fmt(p.h)}</text>`;
      } else if (p.h > need && p.w > fs * 2.6) { // tall and narrow: write along the part
        txt = `<text transform="translate(${p.x + fs * 1.1} ${y + p.h - fs / 2}) rotate(-90)" font-size="${fs}" fill="#fff">${label}</text>`;
      }
      return `<g class="np ${S.nestSel === p.uid ? 'sel' : ''}" data-uid="${esc(p.uid)}" data-x="${p.x}" data-y="${p.y}" data-w="${p.w}" data-h="${p.h}" data-rot="${p.rotated}">
        <rect x="${p.x}" y="${y}" width="${p.w}" height="${p.h}" fill="hsl(${hue(p.cabinet_label)} 45% 38%)" stroke="${p.locked ? '#f0a030' : '#0b0c0e'}" stroke-width="${p.locked ? fs / 4 : fs / 8}"/>${txt}</g>`;
    }).join('');
    return `<svg id="nsvg" viewBox="0 0 ${SL} ${SW}" style="width:100%;height:auto;display:block;touch-action:none"><rect width="${SL}" height="${SW}" fill="#2a2418"/>
      <rect x="${m.trim}" y="${m.trim}" width="${SL - 2 * m.trim}" height="${SW - 2 * m.trim}" fill="#1c1f25" stroke="#6b7480" stroke-dasharray="${fs} ${fs / 2}" stroke-width="${fs / 8}"/>${parts}</svg>`;
  }
  function cutList(sh) {
    const c = sh.cut_sequence;
    if (!c.ok) return `<div class="card"><h3>Cut sequence</h3><p class="mute">${esc(c.reason)}.</p></div>`;
    const steps = c.steps.map((x) => x.type === 'part' ? `<tr><td class="num">${x.step}</td><td colspan="2">&rarr; <b>${esc(x.part_id)}</b></td></tr>` :
      `<tr><td class="num">${x.step}</td><td>${x.axis === 'horizontal' ? 'Cut along length at Y' : 'Cut across at X'} = ${fmt(x.position)} ${S.unit}</td><td class="mute">${fmt(x.from)} to ${fmt(x.to)}</td></tr>`).join('');
    return `<details><summary>CUT SEQUENCE (${c.steps.length} steps)</summary><div class="card" style="margin:0;border:0"><table><tbody>${steps}</tbody></table><p class="mute">Positions measured from the sheet's bottom-left corner. Edge trim is cut first.</p></div></details>`;
  }
  function bindNestSheet(m, sh) {
    const svg = $('#nsvg'); if (!svg || !sh) return;
    const toMM = (ev) => { const pt = svg.createSVGPoint(); pt.x = ev.clientX; pt.y = ev.clientY; return pt.matrixTransform(svg.getScreenCTM().inverse()); };
    svg.querySelectorAll('.np').forEach((g) => {
      g.style.cursor = 'grab';
      g.addEventListener('pointerdown', (ev) => {
        ev.preventDefault(); const start = toMM(ev); const x0 = +g.dataset.x; const y0 = +g.dataset.y; const h = +g.dataset.h; let moved = false;
        S.nestSel = g.dataset.uid; showNestInfo(m, sh);
        const rect = g.querySelector('rect'); g.setPointerCapture(ev.pointerId);
        const mv = (e) => { const p = toMM(e); const dx = p.x - start.x; const dy = p.y - start.y; if (Math.abs(dx) + Math.abs(dy) > 4) moved = true; g.setAttribute('transform', `translate(${dx} ${dy})`); };
        const up = (e) => {
          g.removeEventListener('pointermove', mv); g.removeEventListener('pointerup', up);
          const p = toMM(e); if (!moved) { g.removeAttribute('transform'); return; }
          const nx = Math.round(x0 + (p.x - start.x)); const ny = Math.round(y0 - (p.y - start.y));
          rpc('nest_lock', [m.material, g.dataset.uid, sh.index, nx, ny, g.dataset.rot === 'true']).then((r) => {
            if (r.ok === false) { toast(r.error); g.removeAttribute('transform'); return; }
            S.nest = r; toast('Moved and locked'); paintNesting();
          }).catch((er) => { toast(er.message); g.removeAttribute('transform'); });
          void h; void rect;
        };
        g.addEventListener('pointermove', mv); g.addEventListener('pointerup', up);
      });
    });
    showNestInfo(m, sh);
  }
  function showNestInfo(m, sh) {
    const el = $('#ninfo'); if (!el) return; const p = sh.placements.find((x) => x.uid === S.nestSel);
    document.querySelectorAll('.np').forEach((g) => g.classList.toggle('sel', g.dataset.uid === S.nestSel));
    if (!p) { el.innerHTML = ''; return; }
    el.innerHTML = `<div class="card"><h3>${esc(p.part_id)} <span class="mute">${esc(p.name)}</span></h3><p>${fmt(p.w)} x ${fmt(p.h)} ${S.unit} at (${fmt(p.x)}, ${fmt(p.y)}) ${p.rotated ? '&middot; rotated' : ''} ${p.locked ? '&middot; <b>locked</b>' : ''}</p>
      <div class="row">${p.locked ? '<button class="ghost" id="n_ul">Unlock</button>' : '<button class="ghost" id="n_lk">Lock here</button>'}
      <button class="ghost" id="n_rot">Rotate 90&deg;</button><span class="mute">Move to sheet</span><input type="number" id="n_to" min="1" max="${m.sheets.length + 1}" value="${sh.index + 1}" style="width:60px"><button class="ghost" id="n_mv">Go</button></div></div>`;
    const after = (r) => { if (r.ok === false) { toast(r.error); return; } S.nest = r; paintNesting(); };
    const lock = (sheet, rot) => rpc('nest_lock', [m.material, p.uid, sheet, p.x, p.y, rot]).then(after).catch(showError);
    if ($('#n_ul')) $('#n_ul').onclick = () => rpc('nest_unlock', [p.uid]).then(after).catch(showError);
    if ($('#n_lk')) $('#n_lk').onclick = () => rpc('nest_lock_current', [p.uid]).then(after).catch(showError);
    $('#n_rot').onclick = () => lock(sh.index, !p.rotated);
    $('#n_mv').onclick = () => lock(Math.max(0, parseInt($('#n_to').value, 10) - 1), p.rotated);
  }

  // ---- Labels ------------------------------------------------------------------------------
  function loadLabels() { rpc('labels').then((l) => { S.labels = l; paintLabels(); }).catch(showError); }
  function paintLabels() {
    const v = $('#view'); if (S.tab !== 'labels' || !S.labels) return; const L = S.labels.labels;
    const shown = L.slice(0, 48);
    const cards = shown.map((l) => `<div class="lbl"><div class="lt"><div class="mute" style="font-size:9px">${esc(l.project)}</div><b>${esc(l.cabinet)} &middot; ${esc(l.part)}</b>
      <div class="mono">${esc(l.part_id)}</div><div><b>${esc(l.dimensions)}</b> mm &times;${l.qty}</div><div>${esc(l.material)}</div><div class="mute">${esc(l.grain)} &middot; ${esc(l.edge_banding)}</div></div><div class="lq">${l.qr_svg}</div></div>`).join('');
    v.innerHTML = `<h2>LABELS - ${esc(S.labels.project)}</h2>
      ${L.length ? `<div class="row" style="margin-bottom:8px">${exportButtons('labels', [['pdf', 'PDF (21 per A4 sheet)'], ['html', 'HTML'], ['csv', 'CSV'], ['excel_csv', 'Excel CSV'], ['json', 'JSON']])}</div>
      <p class="mute">${L.length} labels, one per part, each with a unique QR code. The PDF is laid out for 63.5 x 38.1 mm labels, 21 per A4 sheet; the HTML version is for other sizes.</p>` : '<div class="card"><h3>No parts</h3><p>Create a cabinet first.</p></div>'}
      <h2>IDENTIFY A PART</h2><div class="card"><div class="row"><input id="lk_code" placeholder="Paste or scan a QR code..." style="flex:1;background:var(--panel2);color:var(--text);border:1px solid var(--line);border-radius:6px;padding:7px"><button class="primary" id="lk_go">Find</button></div><div id="lk_out"></div>
      <p class="mute">A barcode scanner or phone scanner returns text like CC1|&hellip;|side_left. Pasting it here finds the part in the model.</p></div>
      ${L.length ? `<h2>PREVIEW</h2><div class="lblgrid">${cards}</div>${L.length > shown.length ? `<p class="mute">Showing ${shown.length} of ${L.length}; exports contain all.</p>` : ''}` : ''}
      <p class="mute">QR codes carry only a part identifier. Part drawings, assembly steps and production status behind a scan are planned.</p>`;
    bindExports();
    $('#lk_go').onclick = () => rpc('lookup_part', [$('#lk_code').value]).then((r) => {
      const out = $('#lk_out');
      if (!r.ok) { out.innerHTML = `<ul class="issues"><li class="error">${esc(r.error)}</li></ul>`; return; }
      const p = r.part;
      out.innerHTML = `<div class="card" style="margin-top:8px"><h3>${esc(p.part_id)} <span class="mute">${esc(p.name)}</span></h3><p>${fmt(p.length)} x ${fmt(p.width)} x ${fmt(p.thickness)} ${S.unit} &middot; ${esc(p.material)} &middot; grain ${esc(GRAIN[p.grain])}<br>Edges: ${esc(p.edge_text)}<br>Hardware: ${esc(p.hardware)}<br>Position: ${esc(p.position)}</p>
        <button class="ghost" id="lk_sel">Select in SketchUp</button></div>`;
      $('#lk_sel').onclick = () => rpc('select_target', [r.cabinet.id, p.key]).catch(showError);
    }).catch(showError);
  }

  // ---- CNC ---------------------------------------------------------------------------------------
  function loadCnc() {
    rpc('nest').then((n) => { S.nest = n; return Promise.all([rpc('machining_state'), rpc('cnc_check', [S.cncFace])]); }).then(([st, chk]) => { S.cnc = st; S.cncCheck = chk; return loadCncPreview(); }).catch(showError);
  }
  function loadCncPreview() {
    return rpc('cnc_preview', [S.cncMat, S.cncSheet]).then((p) => { S.cncPrev = p; paintCnc(); }).catch((e) => { S.cncPrev = null; paintCnc(); showError(e); });
  }
  const label = (k) => k.replace(/_/g, ' ');
  const SET_GROUPS = [['Shelf pins', 'shelf_pin'], ['Hinges', 'hinge'], ['Handles', 'handle'], ['Runners', 'runner'], ['Cam / bolt', 'cam'], ['Bolt hole', 'bolt'], ['Dowel', 'dowel'], ['Confirmat', 'confirmat'], ['Joints', 'joint']];
  const cncCall = (method, args, msg) => rpc(method, args).then((st) => { S.cnc = st; toast(msg || 'Saved'); return rpc('cnc_check', [S.cncFace]); }).then((c) => { S.cncCheck = c; return loadCncPreview(); }).catch(showError);

  function paintCnc() {
    const v = $('#view'); if (S.tab !== 'cnc' || !S.cnc) return; const st = S.cnc; const sm = st.summary; const chk = S.cncCheck;
    const machine = st.machines.find((m) => m.id === st.active) || st.machines[0]; const builtIn = machine.id === 'default_router';
    const kinds = Object.entries(sm.by_kind).map(([k, n]) => `<tr><td>${esc(label(k))}</td><td class="num">${n}</td></tr>`).join('');
    const issueList = (list) => list.length ? `<ul class="issues">${list.map((i) => `<li class="${i.severity}"><b>${SEV[i.severity][0]}</b> ${esc(i.message)}</li>`).join('')}</ul>` : '';
    const sel = (id, opts, cur) => `<select id="${id}">${opts.map(([val, l]) => `<option value="${esc(val)}" ${val === cur ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select>`;
    const f = (k, l, type = 'number') => `<div class="field"><label>${l}</label><input id="m_${k}" type="${type}" step="any" value="${esc(machine[k])}" ${builtIn ? 'disabled' : ''}></div>`;
    const chkb = (k, l) => `<div class="field"><label><input id="m_${k}" type="checkbox" ${machine[k] ? 'checked' : ''} ${builtIn ? 'disabled' : ''}> ${l}</label></div>`;
    const tools = machine.tools.map((t, i) => `<tr><td><input type="number" data-tool="number" data-i="${i}" value="${t.number}" style="width:60px" ${builtIn ? 'disabled' : ''}></td>
      <td><select data-tool="kind" data-i="${i}" ${builtIn ? 'disabled' : ''}><option ${t.kind === 'router' ? 'selected' : ''}>router</option><option ${t.kind === 'drill' ? 'selected' : ''}>drill</option></select></td>
      <td><input type="number" step="any" data-tool="diameter" data-i="${i}" value="${t.diameter}" style="width:80px" ${builtIn ? 'disabled' : ''}> mm</td><td>${builtIn ? '' : `<button class="ghost" data-rmtool="${i}">&times;</button>`}</td></tr>`).join('');
    const cp = st.custom_posts; const post = cp.find((p) => p.id === S.cncPost) || cp[0];
    const tpl = post ? post.templates : st.default_templates;
    const settings = SET_GROUPS.map(([title, prefix]) => {
      const keys = Object.keys(st.settings).filter((k) => k.startsWith(prefix)); if (!keys.length) return '';
      return `<details><summary>${title.toUpperCase()}</summary><div class="fields">${keys.map((k) => `<div class="field"><label>${esc(label(k))}</label><input type="number" step="any" data-set="${k}" value="${st.settings[k]}"></div>`).join('')}</div></details>`;
    }).join('');
    const pats = st.patterns.map((p) => `<tr><td>${esc(p.name)}</td><td class="mute">${esc(p.role)}, face ${p.side.toUpperCase()}, ${p.holes.length} hole${p.holes.length === 1 ? '' : 's'}</td><td class="num"><button class="ghost" data-delpat="${esc(p.id)}">Delete</button></td></tr>`).join('');
    const prev = S.cncPrev;
    const mats = (S.nest && S.nest.materials) ? S.nest.materials.map((m) => m.material) : [];
    v.innerHTML = `<h2>MACHINING DATA</h2><div class="card"><p><b>${sm.total}</b> operations: ${sm.face} vertical (router-capable), ${sm.edge} horizontal edge bores (need a boring head or manual drilling).</p>
      <table>${kinds}</table></div>${issueList(st.issues)}
      <h2>CHECK &amp; EXPORT</h2><div class="card"><div class="row" style="margin-bottom:8px"><span class="mute">Program for</span>
      ${sel('c_face', [['a', 'Face A up (drills + cuts parts out)'], ['b', 'Face B up (underside drilling only)']], S.cncFace)}</div>
      <span class="status ${chk.errors ? 'err' : chk.warnings ? 'warn' : 'ok'}">${chk.errors ? chk.errors + ' ERROR' + (chk.errors > 1 ? 'S' : '') : chk.warnings ? chk.warnings + ' WARNING' + (chk.warnings > 1 ? 'S' : '') : 'READY'}</span>
      ${issueList(chk.issues)}
      <div class="row" style="margin:10px 0"><button class="primary" data-export="${S.cncFace === 'a' ? 'gcode' : 'gcode_b'}" data-format="nc" ${chk.exportable ? '' : 'disabled'}>G-CODE</button>
      <button class="ghost" data-export="dxf" data-format="dxf">DXF</button><button class="ghost" data-export="svg" data-format="svg">SVG</button>
      <button class="ghost" data-export="machining" data-format="csv">Machining CSV</button><button class="ghost" data-export="machining" data-format="json">JSON</button></div>
      <p class="mute"><b>Generated G-code is not verified on any machine.</b> Simulate and dry-run it first. No tabs or hold-downs are generated; horizontal bores are excluded. One file is written per nested sheet. DXF face-B holes are shown at their top-view positions (not mirrored).</p></div>
      ${prev ? `<div class="row" style="margin-bottom:6px">${sel('c_mat', mats.map((m) => [m, m]), prev.material)}<span class="mute">Sheet</span><input type="number" id="c_sheet" min="1" max="${prev.sheets}" value="${prev.sheet + 1}" style="width:60px"></div>
      <div class="card" style="padding:6px">${prev.svg}</div><p class="mute">${prev.holes} holes on this sheet: red = face A, blue dashed = face B. Orange dashes: the router path.</p>` : ''}
      <h2>MACHINE &amp; POST-PROCESSOR</h2><div class="card"><div class="row" style="margin-bottom:8px">${sel('m_pick', st.machines.map((m) => [m.id, m.name]), st.active)}
      <button class="ghost" id="m_del" ${builtIn ? 'disabled' : ''}>Delete</button></div>
      <div class="fields">${f('name', 'Name', 'text')}<div class="field"><label>Post-processor</label>${sel('m_post', st.posts.map((p) => [p.id, p.name]), machine.post).replace('<select', builtIn ? '<select disabled' : '<select')}</div>
      <div class="field"><label>Units</label>${sel('m_units', [['mm', 'mm'], ['in', 'inches']], machine.units).replace('<select', builtIn ? '<select disabled' : '<select')}</div>
      <div class="field"><label>Origin</label>${sel('m_origin', ['bottom_left', 'bottom_right', 'top_left', 'top_right'].map((o) => [o, label(o)]), machine.origin).replace('<select', builtIn ? '<select disabled' : '<select')}</div>
      <div class="field"><label>Z zero</label>${sel('m_z_zero', [['material_top', 'Top of material'], ['spoilboard', 'Spoilboard']], machine.z_zero).replace('<select', builtIn ? '<select disabled' : '<select')}</div>
      ${f('spindle_rpm', 'Spindle rpm')}${f('feed_cut', 'Cutting feed (mm/min)')}${f('feed_plunge', 'Plunge feed')}${f('feed_drill', 'Drilling feed')}${f('safe_z', 'Safe height above material')}${f('pass_depth', 'Max depth per pass')}${f('cut_extra', 'Cut below material')}${f('decimals', 'Decimals')}
      ${chkb('canned_cycles', 'Canned drilling cycles (G81)')}${chkb('line_numbers', 'Line numbers')}</div>
      <table><thead><tr><th>TOOL</th><th>TYPE</th><th>DIAMETER</th><th></th></tr></thead><tbody>${tools}</tbody></table>
      <div class="row" style="margin-top:8px">${builtIn ? '' : '<button class="ghost" id="m_addtool">Add tool</button><button class="primary" id="m_save">Save machine</button>'}<button class="ghost" id="m_copy">${builtIn ? 'Save as new machine' : 'Save as copy'}</button></div>
      <p class="mute">The router tool diameter must not exceed the nesting kerf: otherwise parts cannot be cut apart (checked above). Each hole diameter needs a matching drill tool.</p></div>
      <details><summary>CUSTOM POST-PROCESSOR (TEXT TEMPLATES)</summary><div class="card" style="margin:0;border:0">
      <div class="row" style="margin-bottom:8px">${sel('p_pick', [['', '- new -'], ...cp.map((p) => [p.id, p.name])], post ? post.id : '')}<input id="p_name" placeholder="Name" value="${esc(post ? post.name : '')}"><input id="p_ext" placeholder="ext" value="${esc(post ? post.extension : 'nc')}" style="width:60px"></div>
      ${st.template_keys.map((k) => `<div class="field"><label>${k}</label><textarea data-tpl="${k}" rows="${Math.min(4, (tpl[k] || '').split('\n').length + 1)}" style="width:100%;background:var(--panel2);color:var(--text);border:1px solid var(--line);border-radius:6px;font-family:ui-monospace,monospace">${esc(tpl[k] || '')}</textarea></div>`).join('')}
      <div class="row"><button class="primary" id="p_save">Save post</button><button class="ghost" id="p_del" ${post ? '' : 'disabled'}>Delete</button></div>
      <p class="mute">Placeholders: ${st.placeholders.map((p) => '{' + p + '}').join(' ')}. Assign a custom post to a machine above.</p></div></details>
      <h2>DRILLING SYSTEM</h2>${settings}<p class="mute">Millimetres. Defaults follow a common 32 mm system: confirm them against your own hardware. Lamello / mortise joints and undermount runners have no machining pattern yet.</p>
      <h2>CUSTOM DRILLING PATTERNS</h2><div class="card">${st.patterns.length ? `<table>${pats}</table>` : '<p class="mute">None yet.</p>'}
      <div class="fields" style="padding:10px 0"><div class="field"><label>Name</label><input id="pt_name"></div><div class="field"><label>Applies to</label>${sel('pt_role', st.roles.map((r) => [r, label(r)]), 'shelf')}</div>
      <div class="field"><label>Face</label>${sel('pt_side', [['a', 'A (top)'], ['b', 'B (bottom)']], 'a')}</div>
      <div class="field" style="grid-column:1/3"><label>Holes: one per line as x, y, diameter, depth (mm from the part's min corner; x along its length)</label><textarea id="pt_holes" rows="3" style="width:100%;background:var(--panel2);color:var(--text);border:1px solid var(--line);border-radius:6px;font-family:ui-monospace,monospace"></textarea></div></div>
      <button class="primary" id="pt_add">Add pattern</button></div>`;
    bindExports();
    $('#c_face').onchange = (e) => { S.cncFace = e.target.value; loadCnc(); };
    if ($('#c_mat')) $('#c_mat').onchange = (e) => { S.cncMat = e.target.value; S.cncSheet = 0; loadCncPreview(); };
    if ($('#c_sheet')) $('#c_sheet').onchange = (e) => { S.cncSheet = Math.max(0, parseInt(e.target.value, 10) - 1); loadCncPreview(); };
    $('#m_pick').onchange = (e) => cncCall('select_machine', [e.target.value], 'Machine selected');
    if (!builtIn) $('#m_del').onclick = () => cncCall('delete_machine', [machine.id], 'Deleted');
    const readMachine = (id) => {
      const g = (k) => $('#m_' + k); const o = { id, tools: [] };
      ['name', 'spindle_rpm', 'feed_cut', 'feed_plunge', 'feed_drill', 'safe_z', 'pass_depth', 'cut_extra', 'decimals'].forEach((k) => (o[k] = g(k).value));
      ['post', 'units', 'origin', 'z_zero'].forEach((k) => (o[k] = g(k).value)); o.canned_cycles = g('canned_cycles').checked; o.line_numbers = g('line_numbers').checked;
      document.querySelectorAll('[data-tool][data-i]').forEach((el) => { const i = +el.dataset.i; o.tools[i] = o.tools[i] || {}; o.tools[i][el.dataset.tool] = el.value; });
      return o;
    };
    if (!builtIn) {
      $('#m_save').onclick = () => cncCall('save_machine', [readMachine(machine.id)]);
      $('#m_addtool').onclick = () => { machine.tools.push({ number: Math.max(0, ...machine.tools.map((t) => +t.number)) + 1, kind: 'drill', diameter: 5 }); paintCnc(); };
      document.querySelectorAll('[data-rmtool]').forEach((b) => (b.onclick = () => { machine.tools.splice(+b.dataset.rmtool, 1); paintCnc(); }));
    }
    $('#m_copy').onclick = () => { const o = readMachine(''); o.name = builtIn ? prompt('Name for the new machine', machine.name + ' (copy)') : machine.name + ' (copy)'; if (!o.name) return; if (builtIn) { o.tools = machine.tools.map((t) => ({ ...t })); } cncCall('save_machine', [o], 'Machine saved'); };
    $('#p_pick').onchange = (e) => { S.cncPost = e.target.value; paintCnc(); };
    $('#p_save').onclick = () => { const t = {}; document.querySelectorAll('[data-tpl]').forEach((el) => (t[el.dataset.tpl] = el.value)); cncCall('save_post', [post ? post.id : '', $('#p_name').value, t, $('#p_ext').value]); };
    $('#p_del').onclick = () => post && cncCall('delete_post', [post.id], 'Deleted');
    v.querySelectorAll('[data-set]').forEach((i) => (i.onchange = () => cncCall('set_machining_setting', [i.dataset.set, i.value])));
    v.querySelectorAll('[data-delpat]').forEach((b) => (b.onclick = () => cncCall('delete_pattern', [b.dataset.delpat], 'Deleted')));
    $('#pt_add').onclick = () => {
      const holes = $('#pt_holes').value.split('\n').map((l) => l.trim()).filter(Boolean).map((l) => { const [x, y, dia, depth] = l.split(/[ ,;]+/); return { x, y, dia, depth }; });
      cncCall('add_pattern', [$('#pt_name').value, $('#pt_role').value, $('#pt_side').value, holes], 'Pattern added');
    };
  }

  // ---- Hardware --------------------------------------------------------------------
  function loadHardware() { rpc('hardware_state').then(setHw).catch(showError); }
  function setHw(h) { S.hw = h; S.boot.schema = h.schema; refreshLibrary(); if (S.tab === 'hardware') paintHardware(); }
  function hwCall(method, args) { return rpc(method, args).then((h) => { setHw(h); toast('Saved'); }).catch(showError); }
  function paintHardware() {
    const h = S.hw; const v = $('#view');
    const lib = Object.entries(h.categories).map(([cat, label]) => {
      const items = h.library.filter((i) => i.category === cat); if (!items.length) return '';
      return `<h2>${esc(label.toUpperCase())}</h2><div class="card"><table>${items.map((i) => `<tr><td>${esc(i.name)}${i.custom ? ' <span class="badge impl">CUSTOM</span>' : ''}</td>
        <td class="mute"><input type="number" step="any" min="0" placeholder="unit price" data-price="${esc(i.id)}" value="${i.price != null ? i.price : ''}" style="width:100px"> ${esc(i.supplier || '')}</td><td class="num">${i.custom ? `<button class="ghost" data-del="${esc(i.id)}">Delete</button>` : ''}</td></tr>`).join('')}</table></div>`;
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
      <p class="mute">Custom hinges, runners, connectors, handles and legs appear in the PARAMETERS dropdowns. Unit prices (editable in the LIBRARY below) feed the COSTS tab. Locks have no automatic placement yet.</p>
      <h2>LIBRARY</h2>${lib}`;
    v.querySelectorAll('[data-del]').forEach((b) => (b.onclick = () => hwCall('delete_hardware', [b.dataset.del])));
    v.querySelectorAll('[data-price]').forEach((i) => (i.onchange = () => hwCall('set_hardware_price', [i.dataset.price, i.value])));
    v.querySelectorAll('[data-set]').forEach((i) => (i.onchange = () => hwCall('set_hardware_setting', [i.dataset.set, i.value])));
    $('#hw_add').onclick = () => hwCall('add_hardware', [$('#hw_name').value, $('#hw_cat').value, $('#hw_price').value, $('#hw_sup').value]);
    const readRules = () => h.hinge_rules.map((r, i) => ({
      min_height: i === 0 ? 0 : fromDisp(v.querySelector(`[data-rule=min_height][data-i="${i}"]`).value), count: parseInt(v.querySelector(`[data-rule=count][data-i="${i}"]`).value, 10) }));
    $('#saverules').onclick = () => hwCall('set_hinge_rules', [readRules()]);
    $('#addrule').onclick = () => { const r = readRules(); r.push({ min_height: (r[r.length - 1].min_height || 0) + 300, count: r[r.length - 1].count + 1 }); S.hw.hinge_rules = r; paintHardware(); };
    v.querySelectorAll('[data-rmrule]').forEach((b) => (b.onclick = () => { const r = readRules(); r.splice(+b.dataset.rmrule, 1); S.hw.hinge_rules = r; paintHardware(); }));
  }




  // ---- Runs (Smart Space fill) -------------------------------------------------------------------------
  function runState() {
    if (!S.run) S.run = { length: 2400, items: [{ type: 'base_single_door', fixed: false, width: '', min: 300, max: 900 }, { type: 'base_drawer_3', fixed: false, width: '', min: 300, max: 900 }, { type: 'base_double_door', fixed: false, width: '', min: 300, max: 900 }], plan: null };
    return S.run;
  }
  function runPayload() {
    const r = runState();
    return [r.length, r.items.map((i) => ({ type: i.type, fixed: i.fixed, width: i.fixed && i.width !== '' ? i.width : null, min: i.min, max: i.max }))];
  }
  function paintRuns() {
    const v = $('#view'); const r = runState();
    const types = S.boot.library;
    const rows = r.items.map((it, n) => `<tr><td class="num">${n + 1}</td>
      <td><select data-rf="type" data-n="${n}">${types.map((e) => `<option value="${esc(e.type)}" ${e.type === it.type ? 'selected' : ''}>${esc(e.name)}</option>`).join('')}</select></td>
      <td><label><input type="checkbox" data-rf="fixed" data-n="${n}" ${it.fixed ? 'checked' : ''}> fixed</label></td>
      <td><input type="number" step="any" data-rf="width" data-n="${n}" value="${it.width === '' ? '' : toDisp(it.width)}" placeholder="auto" ${it.fixed ? '' : 'disabled'} style="width:80px"></td>
      <td><input type="number" step="any" data-rf="min" data-n="${n}" value="${toDisp(it.min)}" ${it.fixed ? 'disabled' : ''} style="width:70px"></td>
      <td><input type="number" step="any" data-rf="max" data-n="${n}" value="${toDisp(it.max)}" ${it.fixed ? 'disabled' : ''} style="width:70px"></td>
      <td><button class="ghost" data-rdel="${n}">&times;</button></td></tr>`).join('');
    v.innerHTML = `<h2>RUNS</h2><p class="mute">A run fills a wall with cabinets side by side. Fixed cabinets keep their width; the others share the rest equally within their min/max. Creating a run adds ordinary cabinets (one undo step) to the right of the existing ones; it is a creation tool, the cabinets are not linked afterwards. Lengths are in ${S.unit}.</p>
      <div class="card"><div class="row"><label class="mute">Wall length (${S.unit})</label><input type="number" step="any" id="run_len" value="${toDisp(r.length)}" style="width:110px"></div>
      <table style="margin-top:8px"><tr><th>#</th><th>Cabinet</th><th></th><th>Width</th><th>Min</th><th>Max</th><th></th></tr>${rows}</table>
      <div class="row" style="margin-top:8px"><button class="ghost" id="run_add">Add cabinet</button><button class="ghost" id="run_plan">Calculate</button><button class="primary" id="run_create">Create run in model</button></div></div>
      <div id="run_result"></div>`;
    bindRuns(); paintRunPlan();
  }
  function paintRunPlan() {
    const el = $('#run_result'); const r = runState(); const p = r.plan; if (!el || !p) return;
    const total = Math.max(p.used + p.leftover, 1);
    const bar = p.widths.length ? `<div style="display:flex;height:34px;border:1px solid var(--line,#444);margin:8px 0">${p.items.map((i, n) => `<div title="${esc(i.type)}" style="flex:${p.widths[n]};background:${n % 2 ? '#8a6a4a' : '#a98458'};color:#fff;font-size:11px;display:flex;align-items:center;justify-content:center;border-right:1px solid #222;overflow:hidden">${fmt(p.widths[n])}</div>`).join('')}${p.leftover > 0 ? `<div style="flex:${p.leftover};background:repeating-linear-gradient(45deg,#333,#333 6px,#222 6px,#222 12px);color:#fff;font-size:11px;display:flex;align-items:center;justify-content:center">gap ${fmt(p.leftover)}</div>` : ''}</div>` : '';
    el.innerHTML = `<div class="card"><h3>Plan ${p.ok ? '<span class="badge impl">FITS</span>' : '<span class="badge warnb">DOES NOT FIT</span>'}</h3>${bar}
      <p>Total ${fmt(total)} ${S.unit}${p.leftover > 0 ? ` &middot; <b>${fmt(p.leftover)} ${S.unit} of the wall is empty</b>` : ''}${p.shortfall > 0 ? ` &middot; <b>${fmt(p.shortfall)} ${S.unit} too long</b>` : ''}</p>
      ${p.issues.length ? `<ul class="issues">${p.issues.map((m) => `<li class="warning">${esc(m)}</li>`).join('')}</ul>` : ''}</div>`;
  }
  function readRun() {
    const r = runState();
    r.length = fromDispUnit($('#run_len').value);
    document.querySelectorAll('[data-rf]').forEach((i) => {
      const it = r.items[+i.dataset.n]; const k = i.dataset.rf;
      it[k] = k === 'type' ? i.value : k === 'fixed' ? i.checked : (i.value === '' ? '' : fromDispUnit(i.value));
    });
  }
  function fromDispUnit(x) { return fromDisp(x); }
  function bindRuns() {
    const re = (keep) => { readRun(); if (!keep) runState().plan = null; };
    document.querySelectorAll('[data-rf]').forEach((i) => (i.onchange = () => { re(); paintRuns(); }));
    $('#run_len').onchange = () => { re(); };
    $('#run_add').onclick = () => { re(); runState().items.push({ type: 'base_cabinet', fixed: false, width: '', min: 300, max: 900 }); paintRuns(); };
    document.querySelectorAll('[data-rdel]').forEach((b) => (b.onclick = () => { re(); runState().items.splice(+b.dataset.rdel, 1); paintRuns(); }));
    $('#run_plan').onclick = () => { re(true); rpc('plan_run', runPayload()).then((p) => { runState().plan = p; paintRunPlan(); }).catch(showError); };
    $('#run_create').onclick = () => { re(true); rpc('create_run', runPayload()).then((res) => { runState().plan = res.plan; paintRunPlan(); refreshList(); toast(`Created ${res.created.length} cabinets`); }).catch(showError); };
  }

  // ---- Assembly ---------------------------------------------------------------------------------------
  function loadAssembly(amount) {
    rpc('list').then((l) => {
      S.asmCabs = l.cabinets || [];
      if (!S.asmCabs.length) { S.asm = null; paintAssembly(); return null; }
      if (!S.asmId || !S.asmCabs.some((c) => c.id === S.asmId)) S.asmId = S.asmCabs[0].id;
      return rpc('assembly_state', [S.asmId, amount == null ? null : amount]).then((a) => { S.asm = a; paintAssembly(); });
    }).catch(showError);
  }
  function paintAssembly() {
    const v = $('#view'); if (S.tab !== 'assembly') return;
    if (!S.asmCabs || !S.asmCabs.length) { v.innerHTML = '<h2>ASSEMBLY</h2><p class="mute">Create cabinets first.</p>'; return; }
    const a = S.asm;
    const sel = `<select id="as_cab">${S.asmCabs.map((c) => `<option value="${esc(c.id)}" ${c.id === S.asmId ? 'selected' : ''}>${esc(c.label)} ${esc(c.type)}</option>`).join('')}</select>`;
    if (!a || !a.ok) { v.innerHTML = `<h2>ASSEMBLY</h2><div class="row">${sel}</div><ul class="issues">${((a && a.issues) || []).map((i) => `<li class="error">${esc(i.message)}</li>`).join('')}</ul>`; bindAssembly(); return; }
    const parts = a.parts.map((p) => `<tr><td class="num">${p.seq}</td><td class="mono">${esc(p.part_id)}</td><td>${esc(p.name)}</td><td class="num">${esc(p.size)}</td><td>${esc(p.material)}</td></tr>`).join('');
    const steps = a.steps.map((s) => `<li><b>${esc(s.title)}</b><br>${esc(s.text)}${s.parts.length ? `<br><span class="mute">Parts: ${esc(s.parts.join(', '))}</span>` : ''}${s.hardware.length ? `<br><span class="mute">Hardware: ${s.hardware.map((h) => h.qty + ' x ' + esc(h.name)).join(', ')}</span>` : ''}</li>`).join('');
    v.innerHTML = `<h2>ASSEMBLY ${a.exploded_in_model ? '<span class="badge warnb">EXPLODED IN MODEL</span>' : ''}</h2>
      <div class="row">${sel}<label class="mute">Explode distance (mm)</label><input type="number" id="as_amt" min="0" max="2000" step="10" value="${a.amount}" style="width:90px">
      <button class="ghost" id="as_preview">Preview</button><button class="primary" id="as_explode">Explode in model</button><button class="ghost" id="as_assemble" ${a.exploded_in_model ? '' : 'disabled'}>Assemble in model</button></div>
      <p class="mute">Explode moves this cabinet's parts apart in SketchUp (one undo step, fully reversible). While exploded, the cabinet is not checked for overlaps with its neighbours.</p>
      <div class="row" style="align-items:flex-start;flex-wrap:wrap"><div class="card" style="flex:1;min-width:280px"><h3>Assembled</h3>${a.svg_assembled}</div><div class="card" style="flex:1;min-width:280px"><h3>Exploded</h3>${a.svg_exploded}</div></div>
      <h2>PARTS</h2><div class="card"><table><tr><th>No</th><th>Part ID</th><th>Part</th><th>Size (mm)</th><th>Material</th></tr>${parts}</table></div>
      <h2>STEPS</h2><div class="card"><ol style="margin:0 0 0 18px;padding:0">${steps}</ol></div>
      ${exportButtons('assembly', [['pdf', 'PDF (all cabinets)']])}
      <p class="mute">Steps follow a standard carcass-first order from the part roles; they are not a manufacturer-verified procedure. Custom-template parts with unknown roles are listed in a generic step. The drawings are an oblique projection with approximate depth ordering.</p>`;
    bindAssembly(); bindExports();
  }
  function bindAssembly() {
    const sel = $('#as_cab'); if (!sel) return;
    sel.onchange = () => { S.asmId = sel.value; loadAssembly(); };
    if (!$('#as_amt')) return;
    const amt = () => $('#as_amt').value;
    $('#as_preview').onclick = () => loadAssembly(amt());
    $('#as_explode').onclick = () => rpc('explode_cabinet', [S.asmId, amt()]).then((r) => { S.asm = r; paintAssembly(); toast('Exploded in the model'); }).catch(showError);
    $('#as_assemble').onclick = () => rpc('assemble_cabinet', [S.asmId]).then((r) => { S.asm = r; paintAssembly(); toast('Assembled'); }).catch(showError);
  }

  // ---- Costs ---------------------------------------------------------------------------------------
  function loadCosts() { rpc('cost_state').then((c) => { S.costs = c; paintCosts(); }).catch(showError); }
  function paintCosts() {
    const v = $('#view'); const c = S.costs; if (S.tab !== 'costs' || !c) return;
    const st = c.settings; const e = c.estimate; const cur = esc(st.currency);
    const m = (n) => (n == null ? '' : Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }));
    const num = (k, label, hint) => `<div class="field"><label>${label}</label><input type="number" step="any" min="0" data-cs="${k}" value="${st[k]}">${hint ? `<span class="mute">${hint}</span>` : ''}</div>`;
    const edgeInputs = ['default'].concat(c.edge_thicknesses).map((t) => `<div class="field"><label>Edge band ${t === 'default' ? '(any other thickness)' : t + ' mm'} per metre</label><input type="number" step="any" min="0" data-edge="${t === 'default' ? 'default' : t}" value="${st.edge_prices[t === 'default' ? 'default' : parseFloat(t).toFixed(1)] ?? ''}"></div>`).join('');
    const form = `<h2>COST SETTINGS</h2><div class="card"><div class="fields">
      <div class="field"><label>Calculate costs for this project</label><select data-cs="enabled"><option value="true" ${st.enabled ? 'selected' : ''}>On</option><option value="false" ${st.enabled ? '' : 'selected'}>Off</option></select></div>
      <div class="field"><label>Currency symbol</label><input data-cs="currency" maxlength="3" value="${esc(st.currency)}"></div>
      <div class="field"><label>Material cost based on</label><select data-cs="material_basis"><option value="nesting" ${st.material_basis === 'nesting' ? 'selected' : ''}>Nested sheets (what you buy)</option><option value="area" ${st.material_basis === 'area' ? 'selected' : ''}>Part area + waste</option></select></div>
      ${num('waste_pct', 'Waste % (area basis only)')}${edgeInputs}${num('edge_waste_pct', 'Edge band waste %')}
      ${num('cnc_per_sheet', 'CNC cost per sheet')}${num('cnc_per_hole', 'CNC cost per drilled hole')}
      ${num('labour_rate', 'Labour rate per hour')}${num('labour_hours_per_cabinet', 'Labour hours per cabinet')}${num('labour_minutes_per_part', 'Labour minutes per part')}
      ${num('installation_per_cabinet', 'Installation per cabinet')}${num('transport', 'Transport (whole project)', 'shared by cabinet volume')}${num('margin_pct', 'Profit margin % of selling price', 'must be under 95')}</div>
      <div class="row" style="padding:0 12px 12px"><button class="primary" id="cs_save">Save &amp; calculate</button></div>
      <p class="mute">Settings are stored in this model. Material prices are set in MATERIALS, hardware unit prices in HARDWARE. Anything without a price is listed as a warning rather than counted as free.</p></div>`;
    if (!e.enabled) { v.innerHTML = `<h2>COSTS <span class="badge warnb">OFF</span></h2>${form}`; bindCosts(); return; }
    if (!c.cabinet_count) { v.innerHTML = `<h2>COSTS</h2><p class="mute">Create cabinets first.</p>${form}`; bindCosts(); return; }
    const rows = (arr, cols) => `<table><tr>${cols.map((x) => `<th>${x[0]}</th>`).join('')}</tr>${arr.map((r) => `<tr>${cols.map((x) => `<td class="${x[2] || ''}">${x[1](r)}</td>`).join('')}</tr>`).join('')}</table>`;
    const n = 'num';
    const mats = rows(e.materials, [['Material', (r) => esc(r.material)], ['Sheets', (r) => r.sheets, n], ['Unit price', (r) => m(r.unit_price), n], ['Basis', (r) => esc(r.basis)], ['Cost', (r) => m(r.cost), n]]);
    const edges = e.edge_banding.length ? rows(e.edge_banding, [['Thickness', (r) => r.thickness + ' mm'], ['Metres', (r) => r.metres, n], ['With waste', (r) => r.metres_with_waste, n], ['Per metre', (r) => m(r.price_per_m), n], ['Cost', (r) => m(r.cost), n]]) : '<p class="mute">No edge banding.</p>';
    const hw = e.hardware.length ? rows(e.hardware, [['Item', (r) => esc(r.name)], ['Qty', (r) => r.qty, n], ['Unit price', (r) => (r.unit_price == null ? '-' : m(r.unit_price)), n], ['Cost', (r) => m(r.cost), n]]) : '<p class="mute">No hardware.</p>';
    const per = rows(e.per_cabinet, [['Cabinet', (r) => esc(r.label)], ['Materials', (r) => m(r.material), n], ['Edge', (r) => m(r.edge_banding), n], ['Hardware', (r) => m(r.hardware), n], ['CNC', (r) => m(r.cnc), n],
      ['Labour', (r) => m(r.labour), n], ['Install', (r) => m(r.installation), n], ['Transport', (r) => m(r.transport), n], ['Cost', (r) => m(r.cost), n], ['Price', (r) => m(r.price), n]]);
    const warn = e.warnings.length ? `<ul class="issues">${e.warnings.map((w) => `<li class="warning">${esc(w)}</li>`).join('')}</ul>` : '';
    const line = (l, val, b) => `<tr><td>${b ? '<b>' + l + '</b>' : l}</td><td class="num">${b ? '<b>' + cur + ' ' + m(val) + '</b>' : cur + ' ' + m(val)}</td></tr>`;
    const sum = `<div class="card"><table>${line('Materials', e.materials_total)}${line('Edge banding', e.edge_total)}${line('Hardware', e.hardware_total)}${line('CNC', e.cnc.cost)}${line(`Labour (${e.labour.hours} h)`, e.labour.cost)}
      ${line('Installation', e.installation)}${line('Transport', e.transport)}${line('Total cost', e.total_cost, true)}${line(`Profit (${st.margin_pct}% of price)`, e.profit)}${line('Selling price', e.selling_price, true)}</table></div>`;
    v.innerHTML = `<h2>COSTS</h2>${warn}${sum}<h2>EXPORT</h2>${exportButtons('costing')}<div class="row"><span class="mute">Client quote (selling prices only, no costs or margin):</span><button class="ghost" data-export="quote" data-format="pdf">Quote PDF</button></div>
      <h2>PER CABINET</h2><div class="card">${per}</div><h2>MATERIALS</h2><div class="card">${mats}</div><h2>EDGE BANDING</h2><div class="card">${edges}</div><h2>HARDWARE</h2><div class="card">${hw}</div>${form}
      <p class="mute">An estimate, not a quote you can rely on blindly: it uses your prices and the nesting heuristic (not proven optimal). Check the figures before sending them to a client.</p>`;
    bindExports(); bindCosts();
  }
  function bindCosts() {
    const b = $('#cs_save'); if (!b) return;
    b.onclick = () => {
      const raw = { edge_prices: {} };
      document.querySelectorAll('[data-cs]').forEach((i) => { const k = i.dataset.cs; raw[k] = k === 'enabled' ? i.value === 'true' : (['currency', 'material_basis'].includes(k) ? i.value : i.value === '' ? 0 : parseFloat(i.value)); });
      document.querySelectorAll('[data-edge]').forEach((i) => { if (i.value !== '') raw.edge_prices[i.dataset.edge] = parseFloat(i.value); });
      rpc('save_cost_settings', [raw]).then((r) => { S.costs = r; paintCosts(); toast('Saved'); }).catch(showError);
    };
  }

  // ---- Templates (custom parametric cabinets) ---------------------------------------------------------
  function loadTemplates() { rpc('templates_state').then((t) => { S.tpls = t; paintTemplates(); }).catch(showError); }
  function paintTemplates() {
    const v = $('#view'); const t = S.tpls; if (S.tab !== 'templates' || !t) return;
    const sel = t.templates.find((x) => x.id === S.tplSel);
    const text = S.tplText || (sel ? sel.json : '');
    const rows = t.templates.map((x) => `<tr class="clickable ${x.id === S.tplSel ? 'sel' : ''}" data-tpl="${esc(x.id)}"><td>${esc(x.name)} <span class="badge impl">TEMPLATE</span></td><td class="mute">${esc(x.category)}</td><td class="num">${x.parameters} params, ${x.panels} panels</td><td class="mute">${esc(x.used_by.join(', '))}</td></tr>`).join('');
    const presets = t.presets.map((x) => `<tr><td>${esc(x.name)} <span class="badge plan">SAVED</span></td><td class="mute">${esc(x.category)}</td><td class="mute">${esc(x.description || '')}</td><td class="num"><button class="ghost" data-delpreset="${esc(x.id)}">Delete</button></td></tr>`).join('');
    const res = S.tplResult;
    const result = !res ? '' : res.ok === false ? `<ul class="issues">${res.errors.map((e) => `<li class="error">${esc(e)}</li>`).join('')}</ul>` :
      `<div class="card"><h3>${esc(res.name)} builds ${res.panels.length} parts with its default values</h3>${(res.issues || []).length ? `<ul class="issues">${res.issues.map((i) => `<li class="${i.severity}">${esc(i.message)}</li>`).join('')}</ul>` : ''}
      ${res.derived.length ? `<table>${res.derived.map((d) => `<tr><td>${esc(d.label)}</td><td class="num">${fmt(d.value)} ${S.unit}</td></tr>`).join('')}</table>` : ''}
      <table style="margin-top:8px"><thead><tr><th>PART</th><th>LENGTH</th><th>WIDTH</th><th>THK</th><th>MATERIAL</th></tr></thead><tbody>${res.panels.map((p) => `<tr><td>${esc(p.name)}</td><td class="num">${fmt(p.length)}</td><td class="num">${fmt(p.width)}</td><td class="num">${fmt(p.thickness)}</td><td>${esc(p.material)}</td></tr>`).join('')}</tbody></table>
      ${res.hardware.length ? `<p class="mute">Hardware: ${res.hardware.map((h) => h.qty + ' x ' + esc(h.name)).join(', ')}</p>` : ''}</div>`;
    v.innerHTML = `<h2>TEMPLATES</h2><div class="card">${t.templates.length ? `<table>${rows}</table>` : '<p class="mute">No templates yet. Load an example below, or write your own.</p>'}
      ${t.presets.length ? `<h3 style="margin-top:12px">Saved from cabinets</h3><table>${presets}</table>` : ''}</div>
      <h2>${sel ? 'EDIT: ' + esc(sel.name.toUpperCase()) : 'NEW TEMPLATE'}</h2><div class="card">
      <div class="row" style="margin-bottom:8px"><button class="ghost" id="tp_new">New (blank)</button>
      <select id="tp_ex"><option value="">Load an example...</option>${Object.entries(t.examples).map(([k, e]) => `<option value="${k}">${esc(e.name)}</option>`).join('')}</select>
      ${sel ? '<button class="ghost" id="tp_del">Delete template</button>' : ''}</div>
      <textarea id="tp_json" rows="18" spellcheck="false" style="width:100%;background:var(--panel2);color:var(--text);border:1px solid var(--line);border-radius:6px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px;padding:8px">${esc(text)}</textarea>
      <div class="row" style="margin-top:8px"><button class="ghost" id="tp_check">Validate &amp; preview</button><button class="primary" id="tp_save">${sel ? 'Save changes' : 'Save as new template'}</button>${t.examples && !sel ? '<button class="ghost" id="tp_install">Install an example as-is</button>' : ''}</div></div>
      ${result}
      <details><summary>FORMAT HELP</summary><div class="card" style="margin:0;border:0"><p>A template is JSON: <b>parameters</b> (what the user enters), <b>derived</b> (named formulas), <b>constraints</b> (rules that must hold), <b>panels</b> (parts with formulas for size and position) and <b>hardware</b> (items with quantity formulas).</p>
      <p>Axes: x = width, y = depth (front to back), z = height. A panel's <code>size</code> is its extent along x, y, z and <code>origin</code> its minimum corner. A panel with <code>repeat</code> is made N times with <code>i</code> (0, 1, ...) and <code>n</code> available; <code>if</code> includes it only when the formula is non-zero. A material parameter <code>m</code> also gives <code>m_t</code>, its thickness.</p>
      <p>Formulas: numbers, parameter / derived names, <code>+ - * / %</code>, comparisons, <code>&amp;&amp; || !</code>, and <code>${t.functions.join(', ')}</code>. Roles: ${t.roles.join(', ')}. Parameter types: ${t.param_types.join(', ')}.</p>
      <p class="mute">Templates have no drilling data: CNC output excludes them (a warning says so).</p></div></details>
      <p class="mute">Saved templates appear in CABINETS straight away. They are also stored inside this model, so it opens correctly on another machine.</p>`;
    v.querySelectorAll('tr[data-tpl]').forEach((r) => (r.onclick = () => { S.tplSel = r.dataset.tpl; S.tplText = ''; S.tplResult = null; paintTemplates(); }));
    $('#tp_json').oninput = (e) => (S.tplText = e.target.value);
    $('#tp_new').onclick = () => { S.tplSel = null; S.tplText = '{\n  "name": "My cabinet",\n  "category": "CUSTOM",\n  "parameters": [],\n  "panels": []\n}'; S.tplResult = null; paintTemplates(); };
    $('#tp_ex').onchange = (e) => { if (!e.target.value) return; S.tplSel = null; S.tplText = t.examples[e.target.value].json; S.tplResult = null; paintTemplates(); };
    $('#tp_check').onclick = () => rpc('validate_template', [$('#tp_json').value]).then((r) => { S.tplResult = r; S.tplText = $('#tp_json').value; paintTemplates(); }).catch(showError);
    $('#tp_save').onclick = () => rpc('save_template', [$('#tp_json').value, sel ? sel.id : '']).then((r) => {
      if (r.ok === false) { S.tplResult = r; S.tplText = $('#tp_json').value; paintTemplates(); return; }
      S.tpls = r; S.tplSel = r.saved_id; S.tplText = ''; S.tplResult = null; setLibrary(r.library, r.schemas); paintTemplates(); toast('Template saved - see CABINETS');
    }).catch(showError);
    if ($('#tp_del')) $('#tp_del').onclick = () => rpc('delete_template', [sel.id]).then((r) => { S.tpls = r; S.tplSel = null; S.tplText = ''; setLibrary(r.library, r.schemas); paintTemplates(); toast('Deleted'); }).catch(showError);
    if ($('#tp_install')) $('#tp_install').onclick = () => { const k = $('#tp_ex').value; if (!k) { toast('Choose an example first'); return; } rpc('install_example', [k]).then((r) => { S.tpls = r; S.tplSel = r.saved_id; setLibrary(r.library, r.schemas); paintTemplates(); toast('Example installed'); }).catch(showError); };
    v.querySelectorAll('[data-delpreset]').forEach((b) => (b.onclick = () => rpc('delete_preset', [b.dataset.delpreset]).then((r) => { S.tpls = r; setLibrary(r.library, r.schemas); paintTemplates(); toast('Deleted'); }).catch(showError)));
  }

  // ---- Materials (editable) ----------------------------------------------------------------
  function loadMaterials() { rpc('materials_state').then(setMats).catch(showError); }
  function setMats(m) { S.mats = m; S.boot.schema = m.schema; refreshLibrary(); if (S.tab === 'materials') paintMaterials(); }
  function paintMaterials() {
    const v = $('#view'); const m = S.mats; if (S.tab !== 'materials' || !m) return;
    const sel = m.materials.find((x) => x.id === S.matSel) || null; const isNew = !sel; const builtIn = sel && !sel.custom;
    const rows = m.materials.map((x) => `<tr class="clickable ${x.id === S.matSel ? 'sel' : ''}" data-mat="${esc(x.id)}"><td><span class="swatch" style="background:${esc(x.color)}"></span>${esc(x.name)}${x.custom ? ' <span class="badge impl">CUSTOM</span>' : m.overridden.includes(x.id) ? ' <span class="badge plan">EDITED</span>' : ''}</td>
      <td class="num">${fmt(x.thickness)}</td><td>${fmt(x.sheet_length)} x ${fmt(x.sheet_width)}</td><td>${GRAIN_SHEET[x.grain]}</td><td class="num">${x.price != null ? x.price : '-'}</td><td>${esc(x.supplier || '')}</td>
      <td class="num">${x.waste_allowance != null ? x.waste_allowance + '%' : 'default'}</td><td>${esc(x.edge_options.join(', '))}</td><td class="mute">${esc(x.used_by.join(', '))}</td></tr>`).join('');
    const d = sel || { name: '', thickness: 18, role: 'carcass', grain: 'length', sheet_length: 2440, sheet_width: 1220, price: '', supplier: '', waste_allowance: '', color: '#d9c7a5', texture: '', edge_options: [0.4, 1, 2] };
    const dis = (cond) => (cond ? 'disabled' : '');
    v.innerHTML = `<h2>MATERIALS</h2><div class="card"><table><thead><tr><th>NAME</th><th>THK</th><th>SHEET</th><th>GRAIN</th><th>PRICE</th><th>SUPPLIER</th><th>WASTE</th><th>EDGE BAND</th><th>USED BY</th></tr></thead><tbody>${rows}</tbody></table></div>
      <h2>${isNew ? 'NEW MATERIAL' : esc(d.name.toUpperCase())}</h2><div class="card"><div class="fields">
      <div class="field"><label>Name</label><input id="mt_name" value="${esc(d.name)}" ${dis(builtIn)}></div>
      <div class="field"><label>Thickness (${S.unit})</label><input id="mt_thk" type="number" step="any" value="${toDisp(d.thickness)}" ${dis(builtIn)}></div>
      <div class="field"><label>Used for</label><select id="mt_role" ${dis(builtIn)}><option value="carcass" ${d.role === 'carcass' ? 'selected' : ''}>Carcass, fronts, drawer boxes</option><option value="back" ${d.role === 'back' ? 'selected' : ''}>Back panels</option></select></div>
      <div class="field"><label>Grain</label><select id="mt_grain">${m.grains.map((g) => `<option value="${g}" ${g === d.grain ? 'selected' : ''}>${GRAIN_SHEET[g]}</option>`).join('')}</select></div>
      <div class="field"><label>Sheet length (${S.unit})</label><input id="mt_sl" type="number" step="any" value="${toDisp(d.sheet_length)}"></div>
      <div class="field"><label>Sheet width (${S.unit})</label><input id="mt_sw" type="number" step="any" value="${toDisp(d.sheet_width)}"></div>
      <div class="field"><label>Price per sheet</label><input id="mt_price" type="number" step="any" min="0" value="${d.price == null ? '' : d.price}"></div>
      <div class="field"><label>Supplier</label><input id="mt_sup" value="${esc(d.supplier || '')}"></div>
      <div class="field"><label>Waste allowance (%)</label><input id="mt_waste" type="number" step="any" min="0" placeholder="default 10" value="${d.waste_allowance == null ? '' : d.waste_allowance}"></div>
      <div class="field"><label>Colour</label><input id="mt_color" type="color" value="${esc(d.color)}" style="height:34px;padding:2px"></div>
      <div class="field"><label>Texture image path (optional)</label><input id="mt_tex" value="${esc(d.texture || '')}"></div>
      <div class="field"><label>Edge-band thicknesses (mm, comma separated)</label><input id="mt_edge" value="${esc(d.edge_options.join(', '))}"></div></div>
      <div class="row" style="padding:0 12px 12px"><button class="primary" id="mt_save">${isNew ? 'Add material' : 'Save changes'}</button>
      <button class="ghost" id="mt_new">New material</button>
      ${sel && sel.custom ? '<button class="ghost" id="mt_del">Delete</button>' : ''}${builtIn && m.overridden.includes(sel.id) ? '<button class="ghost" id="mt_reset">Reset to defaults</button>' : ''}</div></div>
      <p class="mute">Built-in materials keep their name and thickness; the other fields can be changed. Changing a custom material's thickness regenerates only the cabinets that use it. Custom materials are also stored inside this model, so it opens correctly elsewhere. Sheet grain: along length (X) or width (Y) of the sheet.</p>`;
    v.querySelectorAll('tr[data-mat]').forEach((r) => (r.onclick = () => { S.matSel = r.dataset.mat; paintMaterials(); }));
    const after = (res) => { setMats(res); if (res.saved_id) S.matSel = res.saved_id; paintMaterials(); toast(res.regenerated ? `Saved - ${res.regenerated} cabinet${res.regenerated === 1 ? '' : 's'} regenerated` : 'Saved'); };
    $('#mt_new').onclick = () => { S.matSel = null; paintMaterials(); };
    $('#mt_save').onclick = () => rpc('save_material', [{
      id: sel ? sel.id : '', name: $('#mt_name').value, thickness: fromDisp($('#mt_thk').value), role: $('#mt_role').value, grain: $('#mt_grain').value,
      sheet_length: fromDisp($('#mt_sl').value), sheet_width: fromDisp($('#mt_sw').value), price: $('#mt_price').value, supplier: $('#mt_sup').value,
      waste_allowance: $('#mt_waste').value, color: $('#mt_color').value, texture: $('#mt_tex').value, edge_options: $('#mt_edge').value }]).then(after).catch(showError);
    if ($('#mt_del')) $('#mt_del').onclick = () => rpc('delete_material', [sel.id]).then((r) => { S.matSel = null; setMats(r); toast('Deleted'); }).catch(showError);
    if ($('#mt_reset')) $('#mt_reset').onclick = () => rpc('reset_material', [sel.id]).then(after).catch(showError);
  }
  const GRAIN_SHEET = { length: 'along sheet length', width: 'along sheet width', none: 'none' };

  function projectView() {
    const rows = S.cabinets.map((c) => `<tr class="clickable ${S.editing && S.editing.id === c.id ? 'sel' : ''}" data-id="${esc(c.id)}"><td>${esc(c.label)}</td><td class="num">${fmt(c.params.width)} x ${fmt(c.params.height)} x ${fmt(c.params.depth)}</td><td>v${c.version}</td></tr>`).join('');
    return `<h2>PROJECT</h2><div class="card"><div class="field"><label for="pname">Project name (printed on labels)</label><input id="pname" value="${esc(S.projName || '')}"></div>
      <h3 style="margin-top:12px">${S.cabinets.length} cabinet${S.cabinets.length === 1 ? '' : 's'} in this model</h3>
      ${S.cabinets.length ? `<table><thead><tr><th>CABINET</th><th>W x H x D (${S.unit})</th><th>REV</th></tr></thead><tbody>${rows}</tbody></table>` : '<p class="mute">No cabinets yet.</p>'}
      <p class="mute">Click a row to select and zoom. Only top-level groups are scanned.</p></div>
      <h2>PRE-PRODUCTION CHECK</h2><div id="health"><p class="mute">Checking...</p></div>`;
  }
  function bindProject() {
    document.querySelectorAll('tr[data-id]').forEach((r) => (r.onclick = () => rpc('select', [r.dataset.id]).catch(showError)));
    rpc('project_state').then((p) => { S.projName = p.name; const i = $('#pname'); if (i) { i.value = p.name; i.onchange = () => rpc('set_project_name', [i.value]).then((q) => { S.projName = q.name; toast('Saved'); }).catch(showError); } }).catch(() => {});
    runHealth();
  }
  function runHealth() {
    rpc('validate').then((v) => { S.health = v; paintHealth(); }).catch(showError);
  }
  const SEV = { error: ['ERROR', 'err'], warning: ['WARNING', 'warn'] };
  function paintHealth() {
    const el = $('#health'); const v = S.health; if (!el || !v) return;
    const sm = v.summary; const label = { valid: 'ALL CHECKS PASSED', warning: `${sm.warnings} WARNING${sm.warnings === 1 ? '' : 'S'}`, error: `${sm.errors} ERROR${sm.errors === 1 ? '' : 'S'}, ${sm.warnings} WARNING${sm.warnings === 1 ? '' : 'S'}` }[sm.status];
    const cls = { valid: 'ok', warning: 'warn', error: 'err' }[sm.status];
    const items = v.issues.map((i, n) => `<li class="${i.severity} ${i.cabinet_id || i.entity_id ? 'pick' : ''}" data-n="${n}"><b>${SEV[i.severity][0]}</b> ${i.cabinet_label ? esc(i.cabinet_label) + (i.part_id ? ' / ' + esc(i.part_id) : '') + ': ' : ''}${esc(i.message)}</li>`).join('');
    el.innerHTML = `<div class="row" style="margin-bottom:8px"><span class="status ${cls}">${label}</span><button class="ghost" id="recheck">Re-check</button></div>
      <ul class="issues">${items}</ul><p class="mute">Click an item to select it in SketchUp (a part opens its cabinet for editing). Not checked yet: ${esc(v.not_checked.join('; '))}.</p>`;
    $('#recheck').onclick = runHealth;
    el.querySelectorAll('li.pick').forEach((li) => (li.onclick = () => { const i = v.issues[+li.dataset.n]; rpc('select_target', [i.cabinet_id, i.part_key, i.entity_id]).catch(showError); }));
    const h = $('#status'); if (S.tab === 'project') { /* header keeps showing the cabinet being edited */ }
  }

  function settingsView() {
    return `<h2>SETTINGS</h2><div class="card"><div class="field"><label for="unit">Display units</label>
      <select id="unit">${Object.keys(UNIT_MM).map((u) => `<option ${u === S.unit ? 'selected' : ''}>${u}</option>`).join('')}</select>
      <div class="note">Model data is always stored in millimetres; this changes only what you see and type.</div></div></div>
      <h2>MANUFACTURING STANDARDS</h2><div id="stdbox"><p class="mute">Loading...</p></div>`;
  }
  function bindSettings() {
    $('#unit').onchange = (e) => { S.unit = e.target.value; save('cc_unit', S.unit); render(); };
    rpc('standards_state').then((st) => { S.std = st; paintStandards(); }).catch(showError);
  }
  function paintStandards() {
    const el = $('#stdbox'); const st = S.std; if (!el || !st) return; const set = st.standards.values;
    const field = (f) => {
      const on = Object.prototype.hasOwnProperty.call(set, f.key); const cur = on ? set[f.key] : f.default;
      let input;
      if (f.type === 'enum') input = `<select data-std="${f.key}" ${on ? '' : 'disabled'}>${f.options.map((o) => `<option value="${esc(o.value)}" ${o.value === String(cur) ? 'selected' : ''}>${esc(o.label)}</option>`).join('')}</select>`;
      else input = `<input type="number" step="any" data-std="${f.key}" ${on ? '' : 'disabled'} value="${f.type === 'length' ? toDisp(cur) : cur}">`;
      return `<div class="field"><label><input type="checkbox" data-stdon="${f.key}" ${on ? 'checked' : ''}> ${esc(f.label)}${f.type === 'length' ? ` (${S.unit})` : ''}</label>${input}</div>`;
    };
    const groups = {}; st.fields.forEach((f) => (groups[f.group] = groups[f.group] || []).push(f));
    el.innerHTML = `<div class="card"><div class="field"><label>Company name</label><input id="std_name" value="${esc(st.standards.name)}"></div>
      <p class="mute">Tick a setting to make it your standard. Every NEW cabinet starts with these values (cabinet size, door / drawer / shelf counts are design choices and are not standardised). Existing cabinets are not changed.</p></div>
      ${Object.entries(groups).map(([g, fs]) => `<details open><summary>${esc(g)}</summary><div class="fields">${fs.map(field).join('')}</div></details>`).join('')}
      <div class="row" style="margin:10px 0"><button class="primary" id="std_save">Save standards</button><button class="ghost" id="std_reset">Reset to factory defaults</button></div>
      <p class="mute">Hinge spacing, connector spacing, shelf pins and handle positions are placement rules: see HARDWARE. Hinge inset now ${st.hardware_settings.hinge_inset} mm, connector spacing ${st.hardware_settings.connector_spacing} mm.</p>`;
    el.querySelectorAll('[data-stdon]').forEach((c) => (c.onchange = () => { el.querySelector(`[data-std="${c.dataset.stdon}"]`).disabled = !c.checked; }));
    const apply = (r) => { S.std = r; setLibrary(r.library, r.schemas); S.boot.standards = r.standards; paintStandards(); toast('Standards saved - new cabinets use them'); };
    $('#std_save').onclick = () => {
      const values = {};
      el.querySelectorAll('[data-stdon]').forEach((c) => {
        if (!c.checked) return; const f = st.fields.find((x) => x.key === c.dataset.stdon); const i = el.querySelector(`[data-std="${f.key}"]`);
        values[f.key] = f.type === 'length' ? fromDisp(i.value) : f.type === 'enum' ? i.value : parseFloat(i.value);
      });
      rpc('save_standards', [$('#std_name').value, values]).then(apply).catch(showError);
    };
    $('#std_reset').onclick = () => rpc('reset_standards').then((r) => { apply(r); toast('Factory defaults restored'); }).catch(showError);
  }

  // ---- Boot -----------------------------------------------------------------
  function start() {
    rpc('bootstrap').then((b) => {
      S.boot = b;
      S.boot.standards = b.standards; setLibrary(b.library, b.schemas || {});
      S.params = Object.assign({}, S.boot.defaults[S.type]); S.cabinets = b.cabinets;
      if (b.selected) loadCabinet(b.selected); else render();
    }).catch((e) => { $('#view').innerHTML = `<div class="card"><h3>Cannot connect</h3><p>${esc(e.message)}</p></div>`; });
  }
  document.addEventListener('DOMContentLoaded', start);
})();
