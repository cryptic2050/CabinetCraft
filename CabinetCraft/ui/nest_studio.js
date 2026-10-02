(function () {
  'use strict';

  // ---- Bridge to Ruby (same protocol as the main dashboard) ---------------------------------------------------------
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
  CC.onSelection = function () {};

  const $ = (s) => document.querySelector(s);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const num = (v, d) => (+v).toFixed(d == null ? 0 : d);
  const m2 = (mm2) => (mm2 / 1e6).toFixed(2);

  const S = { nest: null, filter: null, side: 'list', tab: 'scheme', cur: null, sel: null, showName: true, showDim: true, error: null };

  // ---- Data helpers -------------------------------------------------------------------------------------------------
  // Every sheet of every material, numbered #1.. in material order (like the layout scheme list).
  function sheets() {
    const out = []; let n = 0;
    if (!S.nest) return out;
    S.nest.materials.forEach((m, mi) => m.sheets.forEach((sh, si) => { out.push({ mi, si, m, sh, num: ++n }); }));
    return out;
  }
  const visible = () => sheets().filter((x) => S.filter == null || x.mi === S.filter);
  function current() {
    const all = visible(); if (!all.length) return null;
    return all.find((x) => S.cur && x.mi === S.cur.mi && x.si === S.cur.si) || all[0];
  }
  const toast = (msg) => { const t = $('#toast'); t.textContent = msg; t.hidden = false; clearTimeout(toast.t); toast.t = setTimeout(() => (t.hidden = true), 2600); };
  const fail = (e) => toast(e && e.message ? e.message : String(e));

  // ---- Toolbar ------------------------------------------------------------------------------------------------------
  const ICON = {
    start: '<path d="M7 5l12 7-12 7z"/>', refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.6M20 4v7h-7"/>', clean: '<path d="M14 3l7 7M3 21l6-2 9-9-4-4-9 9z"/>',
    dxf: '<path d="M6 3h8l4 4v14H6zM14 3v4h4M9 13h6M9 17h6"/>', cnc: '<circle cx="12" cy="12" r="3"/><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M18.4 5.6l-2.1 2.1M7.7 16.3l-2.1 2.1"/>',
    pdf: '<path d="M7 9V3h10v6M7 17H4v-7h16v7h-3M7 14h10v7H7z"/>', labels: '<path d="M3 12l9-9h8v8l-9 9zM16 8h.01"/>', csv: '<path d="M4 5h16v14H4zM4 10h16M4 15h16M10 5v14"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 0 0-.1-1.2l2-1.5-2-3.4-2.3.9a7 7 0 0 0-2-1.2L14 3h-4l-.6 2.6a7 7 0 0 0-2 1.2l-2.3-.9-2 3.4 2 1.5A7 7 0 0 0 5 12a7 7 0 0 0 .1 1.2l-2 1.5 2 3.4 2.3-.9a7 7 0 0 0 2 1.2L10 21h4l.6-2.6a7 7 0 0 0 2-1.2l2.3.9 2-3.4-2-1.5c.1-.4.1-.8.1-1.2z"/>'
  };
  const tb = (id, icon, label, cls, title) => `<button class="tb ${cls || ''}" data-act="${id}" title="${esc(title || label)}"><svg viewBox="0 0 24 24">${ICON[icon]}</svg>${label}</button>`;
  function paintBar() {
    $('#bar').innerHTML = `<div class="brand"><div style="display:flex;align-items:center"><span class="logo">N</span><b>NEST STUDIO</b></div><span>CabinetCraft Pro &middot; sheet nesting</span></div>
      ${tb('start', 'start', 'Start', 'go', 'Run the nesting with the current settings')}${tb('refresh', 'refresh', 'Refresh', '', 'Re-read the model and nest again')}${tb('clean', 'clean', 'Clean up', 'warn', 'Free every locked part and nest again')}
      <span class="sep"></span>
      ${tb('dxf', 'dxf', 'Export DXF', '', 'One DXF per nested sheet')}${tb('cnc', 'cnc', 'Export CNC', '', 'G-code per sheet (check the CNC tab first)')}${tb('pdf', 'pdf', 'Export Saw', '', 'PDF of the sheets with the cut sequences')}${tb('labels', 'labels', 'Labels', '', 'Part labels with QR codes (PDF)')}${tb('csv', 'csv', 'Export CSV', '', 'Placement table')}
      <span class="spacer"></span>${tb('settings', 'gear', 'Settings', '', 'Kerf, trim, spacing, offcuts, sheet size')}`;
    document.querySelectorAll('[data-act]').forEach((b) => (b.onclick = () => act(b.dataset.act)));
  }

  function act(a) {
    if (a === 'start' || a === 'refresh') return load(true);
    if (a === 'clean') return rpc('nest_unlock_all').then((n) => { S.nest = n; paint(); toast('All parts freed'); }).catch(fail);
    if (a === 'settings') return settingsModal();
    const map = { dxf: ['dxf', 'dxf'], cnc: ['gcode', 'nc'], pdf: ['nesting', 'pdf'], labels: ['labels', 'pdf'], csv: ['nesting', 'csv'] }[a];
    if (map) rpc('export', map).then((r) => toast(r.cancelled ? 'Export cancelled' : r.ok === false ? (r.error || 'Export failed') : r.count > 1 ? `Saved ${r.count} files, e.g. ${r.paths[0]}` : 'Saved ' + r.path)).catch(fail);
  }

  // ---- Left panel ---------------------------------------------------------------------------------------------------
  function thumb(x) {
    const { m, sh } = x; const SL = m.sheet_length; const SW = m.sheet_width;
    const parts = sh.placements.map((p) => `<rect x="${p.x}" y="${SW - p.y - p.h}" width="${p.w}" height="${p.h}" fill="#1f5a64" stroke="#0e2a30" stroke-width="${SL / 400}"/>`).join('');
    const off = (sh.offcuts || []).map((o) => `<rect x="${o.x}" y="${SW - o.y - o.h}" width="${o.w}" height="${o.h}" fill="#d2691e"/>`).join('');
    return `<svg viewBox="0 0 ${SL} ${SW}" preserveAspectRatio="xMidYMid meet"><rect width="${SL}" height="${SW}" fill="#2a2d30"/>${off}${parts}</svg>`;
  }
  function paintSide() {
    const side = $('#side'); const cur = current();
    const tabs = `<div class="tabs"><button data-side="list" class="${S.side === 'list' ? 'on' : ''}">Layout scheme list</button><button data-side="info" class="${S.side === 'info' ? 'on' : ''}">Information</button></div>`;
    let body = '';
    if (S.side === 'list') {
      let last = null;
      body = visible().map((x) => {
        const head = x.mi !== last ? `<div class="mat" title="${esc(x.m.material)}">${esc(x.m.material)}</div>` : '';
        last = x.mi;
        return `${head}<div class="card ${cur && cur.mi === x.mi && cur.si === x.si ? 'on' : ''}" data-mi="${x.mi}" data-si="${x.si}">${thumb(x)}<span class="badge">#${x.num}</span>
          <div class="cap"><span>${num(x.m.sheet_length)}&times;${num(x.m.sheet_width)}</span><span>Rate:${num(x.sh.utilization, 2)}%</span><span>Count:1</span></div></div>`;
      }).join('') || '<div class="empty">No sheets</div>';
    } else {
      body = infoPanel(cur);
    }
    side.innerHTML = `${tabs}<div class="scroll">${body}</div>`;
    side.querySelectorAll('[data-side]').forEach((b) => (b.onclick = () => { S.side = b.dataset.side; paintSide(); }));
    side.querySelectorAll('.card').forEach((c) => (c.onclick = () => { S.cur = { mi: +c.dataset.mi, si: +c.dataset.si }; S.sel = null; S.tab = 'scheme'; paint(); }));
  }
  function infoPanel(cur) {
    if (!cur) return '<div class="empty">Nothing nested yet</div>';
    const { m, sh } = cur;
    const rows = sh.placements.slice().sort((a, b) => a.part_id.localeCompare(b.part_id, undefined, { numeric: true })).map((p) =>
      `<tr data-uid="${esc(p.uid)}"><td>${esc(p.part_id)}${p.locked ? ' &#128274;' : ''}</td><td class="n">${num(p.w)}&times;${num(p.h)}</td></tr>`).join('');
    return `<div class="info"><div style="color:var(--gold);font-weight:600;margin-bottom:4px">Sheet #${cur.num}</div>
      <div style="color:var(--mute);margin-bottom:8px">${esc(m.material)}<br>${num(m.sheet_length)} &times; ${num(m.sheet_width)} mm &middot; ${sh.placements.length} parts &middot; ${num(sh.utilization, 2)}%</div>
      <table class="tbl"><thead><tr><th>Part</th><th class="n">mm</th></tr></thead><tbody>${rows}</tbody></table></div>`;
  }

  // ---- Main area ----------------------------------------------------------------------------------------------------
  function paintMain() {
    const main = $('#main'); const cur = current();
    const tab = (id, l) => `<button class="t ${S.tab === id ? 'on' : ''}" data-tab="${id}">${l}</button>`;
    const chip = (id, l, on, title) => `<button class="chip ${on ? 'on' : ''}" data-chip="${id}" title="${esc(title || '')}">${l}</button>`;
    main.innerHTML = `<div id="mtabs">${tab('scheme', 'Layout Scheme')}${tab('boards', 'Boards')}${tab('materials', 'Materials')}
      <span class="grp">${chip('lock', 'Lock', false, 'Lock every part on this sheet where it is')}${chip('free', 'Free', false, 'Release every locked part on this sheet')}</span>
      <span class="grp">${chip('showall', 'Show all', S.showName && S.showDim)}${chip('hideall', 'Hide all', !S.showName && !S.showDim)}${chip('name', 'Name', S.showName)}${chip('dims', 'Dims', S.showDim)}</span></div>
      <div id="stage"></div><div class="sel-info" id="selinfo"></div>`;
    main.querySelectorAll('[data-tab]').forEach((b) => (b.onclick = () => { S.tab = b.dataset.tab; paintMain(); }));
    main.querySelectorAll('[data-chip]').forEach((b) => (b.onclick = () => chip_(b.dataset.chip)));
    if (S.tab === 'scheme') paintScheme(cur); else if (S.tab === 'boards') paintBoards(); else paintMaterials();
    paintSel();
  }
  function chip_(id) {
    if (id === 'showall') { S.showName = S.showDim = true; } else if (id === 'hideall') { S.showName = S.showDim = false; }
    else if (id === 'name') S.showName = !S.showName; else if (id === 'dims') S.showDim = !S.showDim;
    else { lockSheet(id === 'lock'); return; }
    paintMain();
  }
  function lockSheet(lock) {
    const cur = current(); if (!cur) return;
    const uids = cur.sh.placements.filter((p) => (lock ? !p.locked : p.locked)).map((p) => p.uid);
    if (!uids.length) { toast(lock ? 'Everything on this sheet is already locked' : 'Nothing is locked on this sheet'); return; }
    uids.reduce((chain, uid) => chain.then(() => rpc(lock ? 'nest_lock_current' : 'nest_unlock', [uid]).then((n) => { S.nest = n; })), Promise.resolve())
      .then(() => { paint(); toast(`${lock ? 'Locked' : 'Freed'} ${uids.length} part${uids.length === 1 ? '' : 's'}`); }).catch(fail);
  }

  function legend() {
    if (!S.nest) return '';
    const total = S.nest.materials.reduce((a, m) => a + m.total_sheets, 0);
    const items = S.nest.materials.map((m, i) => `<label data-f="${i}" class="${S.filter === i ? 'on' : ''}"><span class="dot"></span>${esc(m.material)} [${m.total_sheets}]</label>`).join('');
    return `<div class="legend"><h4>Materials</h4><label data-f="all" class="${S.filter == null ? 'on' : ''}"><span class="dot"></span>All materials [${total}]</label>${items}</div>`;
  }
  function bindLegend() {
    document.querySelectorAll('.legend [data-f]').forEach((l) => (l.onclick = () => {
      S.filter = l.dataset.f === 'all' ? null : +l.dataset.f; S.cur = null; S.sel = null; paint();
    }));
  }

  function ruler(SL, SW) {
    const step = SL > 4000 ? 1000 : 500; const t = Math.max(SL, SW) / 120; let s = '';
    for (let x = 0; x <= SL; x += step / 5) { const major = x % step === 0; s += `<line x1="${x}" y1="${-t * (major ? 2.4 : 1.2)}" x2="${x}" y2="0" stroke="#777" stroke-width="${t / 6}"/>`; if (major) s += `<text x="${x}" y="${-t * 3.2}" font-size="${t * 2}" fill="#999" text-anchor="middle">${x}</text>`; }
    for (let y = 0; y <= SW; y += step / 5) { const major = y % step === 0; const yy = SW - y; s += `<line x1="${-t * (major ? 2.4 : 1.2)}" y1="${yy}" x2="0" y2="${yy}" stroke="#777" stroke-width="${t / 6}"/>`; if (major) s += `<text x="${-t * 3.2}" y="${yy + t}" font-size="${t * 2}" fill="#999" text-anchor="end">${y}</text>`; }
    return s;
  }

  function paintScheme(cur) {
    const stage = $('#stage');
    if (S.error) { stage.innerHTML = `${legend()}<div class="empty">${esc(S.error)}</div>`; bindLegend(); return; }
    if (!cur) { stage.innerHTML = `${legend()}<div class="empty">${S.nest ? 'Nothing to nest: there are no cabinets in the model yet.' : 'Loading...'}</div>`; bindLegend(); return; }
    const { m, sh } = cur; const SL = m.sheet_length; const SW = m.sheet_width; const fs = Math.max(SL / 95, 14); const pad = SL * 0.1;
    const parts = sh.placements.map((p) => {
      const y = SW - p.y - p.h; const sel = S.sel === p.uid;
      const lines = [];
      if (S.showName) lines.push(p.part_id + (p.locked ? ' \u{1F512}' : ''));
      if (S.showDim) lines.push(`${num(p.w)}×${num(p.h)}`);
      let txt = '';
      if (lines.length) {
        const need = fs * 0.62 * Math.max(...lines.map((l) => l.length)) + fs;
        if (p.w > need && p.h > fs * (lines.length * 1.2 + 1)) txt = lines.map((l, i) => `<text x="${p.x + fs / 2}" y="${y + fs * (1.2 + i * 1.15)}" font-size="${fs}" fill="${i ? '#bfe8d0' : '#fff'}" pointer-events="none">${esc(l)}</text>`).join('');
        else if (p.h > need && p.w > fs * (lines.length * 1.2 + 0.5)) txt = lines.map((l, i) => `<text transform="translate(${p.x + fs * (1.2 + i * 1.15)} ${y + p.h - fs / 2}) rotate(-90)" font-size="${fs}" fill="${i ? '#bfe8d0' : '#fff'}" pointer-events="none">${esc(l)}</text>`).join('');
      }
      return `<g class="part ${sel ? 'sel' : ''}" data-uid="${esc(p.uid)}" data-x="${p.x}" data-y="${p.y}" data-w="${p.w}" data-h="${p.h}" data-rot="${p.rotated}">
        <rect class="pf" x="${p.x}" y="${y}" width="${p.w}" height="${p.h}" fill="var(--teal)" stroke="${sel ? '#ffd54a' : p.locked ? '#e8a62a' : '#8de08f'}" stroke-width="${fs / (sel || p.locked ? 4 : 7)}" ${sel || p.locked ? '' : `stroke-dasharray="${fs * 1.1} ${fs * 0.6}"`}/>${txt}</g>`;
    }).join('');
    const off = (sh.offcuts || []).map((o) => `<rect x="${o.x}" y="${SW - o.y - o.h}" width="${o.w}" height="${o.h}" fill="var(--off)" pointer-events="none"/>`).join('');
    const label = `${m.material} | ${num(SL)}×${num(SW)} | #${cur.num} | ${num(sh.utilization, 2)}%`;
    stage.innerHTML = `${legend()}<svg class="sheet" id="ssvg" viewBox="${-pad} ${-pad * 2.1} ${SL + pad * 2} ${SW + pad * 2.85}" preserveAspectRatio="xMidYMid meet">
      <g>${ruler(SL, SW)}</g>
      <rect x="0" y="${-fs * 2.4}" width="${Math.min(SL, fs * 0.85 * label.length + fs * 2)}" height="${fs * 2.4}" fill="var(--gold)"/><text x="${fs * 0.6}" y="${-fs * 0.7}" font-size="${fs * 1.3}" fill="#222">${esc(label)}</text>
      <rect x="0" y="0" width="${SL}" height="${SW}" fill="#2a2d30" stroke="#d9d9d9" stroke-width="${fs / 7}"/>
      <rect x="${m.trim}" y="${m.trim}" width="${SL - 2 * m.trim}" height="${SW - 2 * m.trim}" fill="none" stroke="#555" stroke-width="${fs / 10}" stroke-dasharray="${fs} ${fs / 2}"/>
      ${off}${parts}</svg>`;
    bindLegend(); bindDrag(m, sh);
  }

  // Click selects a part; dragging moves it and locks it there (the server checks the move is legal).
  function bindDrag(m, sh) {
    const svg = $('#ssvg'); if (!svg) return;
    svg.querySelectorAll('.part').forEach((g) => {
      g.onpointerdown = (e) => {
        if (e.button !== 0) return;
        e.preventDefault(); g.setPointerCapture(e.pointerId);
        const inv = svg.getScreenCTM().inverse();
        const pt = (ev) => { const p = svg.createSVGPoint(); p.x = ev.clientX; p.y = ev.clientY; return p.matrixTransform(inv); };
        const start = pt(e); let moved = false;
        const move = (ev) => { const c = pt(ev); const dx = c.x - start.x; const dy = c.y - start.y; if (Math.abs(dx) + Math.abs(dy) > m.sheet_length / 300) moved = true; if (moved) g.setAttribute('transform', `translate(${dx} ${dy})`); };
        const up = (ev) => {
          g.onpointermove = null; g.onpointerup = null;
          const c = pt(ev); const dx = c.x - start.x; const dy = c.y - start.y; const uid = g.dataset.uid;
          if (!moved) { S.sel = S.sel === uid ? null : uid; paintMain(); return; }
          const x = Math.round(+g.dataset.x + dx); const y = Math.round(+g.dataset.y - dy);
          rpc('nest_lock', [m.material, uid, sh.index, x, y, g.dataset.rot === 'true']).then((r) => {
            if (r.ok === false) { toast(r.error || 'That position is not allowed'); paint(); } else { S.nest = r; S.sel = uid; paint(); toast('Part moved and locked'); }
          }).catch((err) => { fail(err); paint(); });
        };
        g.onpointermove = move; g.onpointerup = up;
      };
    });
  }

  function paintSel() {
    const el = $('#selinfo'); const cur = current(); if (!el) return;
    const p = cur && cur.sh.placements.find((x) => x.uid === S.sel);
    if (S.tab !== 'scheme' || !cur) { el.style.display = 'none'; return; }
    el.style.display = '';
    if (!p) { el.innerHTML = `<span style="color:var(--mute)">Click a part to select it, drag to move it (it is locked where you drop it).</span>`; return; }
    el.innerHTML = `<b>${esc(p.part_id)}</b><span>${esc(p.name)}</span><span>${num(p.w)}&times;${num(p.h)} mm${p.rotated ? ' (rotated)' : ''}</span>
      ${p.locked ? '<button class="btn" id="sUnlock">Unlock</button>' : '<button class="btn" id="sLock">Lock here</button>'}
      ${cur.m.grain_free ? '<button class="btn" id="sRot">Rotate 90&deg;</button>' : '<span style="color:var(--mute)">grain: cannot rotate</span>'}`;
    const call = (method, args, msg) => rpc(method, args).then((r) => { if (r.ok === false) { toast(r.error); return; } S.nest = r; paint(); toast(msg); }).catch(fail);
    if ($('#sLock')) $('#sLock').onclick = () => call('nest_lock_current', [p.uid], 'Part locked');
    if ($('#sUnlock')) $('#sUnlock').onclick = () => call('nest_unlock', [p.uid], 'Part freed');
    if ($('#sRot')) $('#sRot').onclick = () => call('nest_lock', [cur.m.material, p.uid, cur.sh.index, p.x, p.y, !p.rotated], 'Part rotated and locked');
  }

  function paintBoards() {
    const stage = $('#stage'); if (!S.nest) { stage.innerHTML = '<div class="empty">Loading...</div>'; return; }
    const t = S.nest.totals;
    const kpi = (k, v, bad) => `<div class="kpi ${bad ? 'bad' : ''}"><small>${k}</small><b>${v}</b></div>`;
    const unplaced = S.nest.materials.reduce((a, m) => a + m.unplaced.length, 0);
    const rows = sheets().map((x) => `<tr class="row" data-mi="${x.mi}" data-si="${x.si}" style="cursor:pointer"><td>#${x.num}</td><td>${esc(x.m.material)}</td><td class="n">${num(x.m.sheet_length)} &times; ${num(x.m.sheet_width)}</td><td class="n">${x.sh.placements.length}</td><td class="n">${m2(x.sh.used_area)}</td><td class="n">${m2(x.sh.waste_area)}</td><td class="n">${num(x.sh.utilization, 2)}%</td></tr>`).join('');
    stage.innerHTML = `<div class="info">${legend().replace('class="legend"', 'class="legend" style="position:static;margin-bottom:10px"')}<div class="kpis">${kpi('SHEETS', t.total_sheets)}${kpi('BOARD AREA m²', m2(t.total_area))}${kpi('USED m²', m2(t.used_area))}${kpi('WASTE m²', m2(t.waste_area))}${kpi('UTILISATION', num(t.utilization, 1) + '%')}${kpi('DOES NOT FIT', unplaced, unplaced)}</div>
      <table class="tbl"><thead><tr><th>#</th><th>Material</th><th class="n">Board (mm)</th><th class="n">Parts</th><th class="n">Used m&sup2;</th><th class="n">Waste m&sup2;</th><th class="n">Rate</th></tr></thead><tbody>${rows}</tbody></table></div>`;
    bindLegend();
    stage.querySelectorAll('tr.row').forEach((r) => (r.onclick = () => { S.cur = { mi: +r.dataset.mi, si: +r.dataset.si }; S.tab = 'scheme'; paint(); }));
  }

  function paintMaterials() {
    const stage = $('#stage'); if (!S.nest) { stage.innerHTML = '<div class="empty">Loading...</div>'; return; }
    const rows = S.nest.materials.map((m, i) => {
      const parts = m.sheets.reduce((a, s) => a + s.placements.length, 0);
      const used = m.sheets.reduce((a, s) => a + s.used_area, 0); const area = m.sheets.length * m.sheet_length * m.sheet_width;
      return `<tr class="row" data-f="${i}" style="cursor:pointer"><td>${esc(m.material)}</td><td class="n">${num(m.sheet_length)} &times; ${num(m.sheet_width)}</td><td class="n">${m.total_sheets}</td><td class="n">${parts}</td><td class="n">${area ? num(used * 100 / area, 1) : 0}%</td>
        <td>${m.grain_free ? 'no grain: parts may rotate' : 'grain along ' + (m.grain_axis || 'length')}</td><td class="n">${m.unplaced.length ? `<b style="color:var(--red)">${m.unplaced.length}</b>` : '0'}</td></tr>`;
    }).join('');
    stage.innerHTML = `<div class="info"><table class="tbl"><thead><tr><th>Material</th><th class="n">Board (mm)</th><th class="n">Sheets</th><th class="n">Parts</th><th class="n">Rate</th><th>Grain</th><th class="n">Unplaced</th></tr></thead><tbody>${rows}</tbody></table>
      <p style="color:var(--mute)">Click a material to show only its sheets. Prices and thickness are edited in the MATERIALS tab of the main CabinetCraft window.</p></div>`;
    stage.querySelectorAll('tr.row').forEach((r) => (r.onclick = () => { S.filter = +r.dataset.f; S.cur = null; S.tab = 'scheme'; paint(); }));
  }

  function paintFoot() {
    const n = S.nest; if (!n) { $('#foot').innerHTML = '<span>Loading...</span>'; return; }
    const t = n.totals; const un = n.materials.reduce((a, m) => a + m.unplaced.length, 0); const locked = n.materials.reduce((a, m) => a + m.sheets.reduce((b, s) => b + s.placements.filter((p) => p.locked).length, 0), 0);
    $('#foot').innerHTML = `<span>Total: <b>${t.total_sheets}</b> sheet${t.total_sheets === 1 ? '' : 's'}</span><span>Utilisation <b>${num(t.utilization, 1)}%</b></span><span>Offcuts <b>${t.offcut_count}</b></span><span>Locked <b>${locked}</b></span>
      <span class="${un ? 'bad' : 'ok'}">${un ? un + ' part(s) do not fit' : 'All parts placed'}</span><span style="margin-left:auto">Heuristic nesting, not proven optimal &middot; mm</span>`;
  }

  function paint() { paintSide(); paintMain(); paintFoot(); }

  // ---- Settings -----------------------------------------------------------------------------------------------------
  function settingsModal() {
    const st = (S.nest && S.nest.settings) || { kerf: 4, trim: 10, spacing: 0 };
    const f = (id, label, v, ph) => `<div class="f"><label for="${id}">${label}</label><input id="${id}" type="number" step="any" value="${v == null ? '' : v}" placeholder="${ph || ''}"></div>`;
    const md = $('#modal');
    md.innerHTML = `<div class="box"><h3>Nesting settings</h3>${f('s_kerf', 'Kerf (saw / router cut) mm', st.kerf)}${f('s_trim', 'Sheet edge trim mm', st.trim)}${f('s_sp', 'Extra spacing mm', st.spacing)}${f('s_off', 'Smallest reusable offcut mm', st.min_offcut == null ? 150 : st.min_offcut)}
      ${f('s_sl', 'Sheet length override mm', st.sheet_length, 'material default')}${f('s_sw', 'Sheet width override mm', st.sheet_width, 'material default')}
      <div class="f" style="justify-content:flex-end;margin-top:12px"><button class="btn" id="s_cancel">Cancel</button><button class="btn pri" id="s_ok">Apply and nest</button></div></div>`;
    md.hidden = false;
    $('#s_cancel').onclick = () => (md.hidden = true);
    $('#s_ok').onclick = () => {
      const g = (id) => $(id).value; const o = { kerf: +g('#s_kerf'), trim: +g('#s_trim'), spacing: +g('#s_sp'), min_offcut: +g('#s_off') };
      if (g('#s_sl')) o.sheet_length = +g('#s_sl'); if (g('#s_sw')) o.sheet_width = +g('#s_sw');
      md.hidden = true; load(false, o);
    };
  }

  // ---- Loading ------------------------------------------------------------------------------------------------------
  function load(force, settings) {
    S.error = null;
    const args = settings ? [settings] : [];
    return rpc('nest', args).then((n) => { S.nest = n; if (S.filter != null && S.filter >= n.materials.length) S.filter = null; paint(); if (force) toast('Nested: ' + n.totals.total_sheets + ' sheet(s)'); })
      .catch((e) => { S.error = e.message; paint(); });
  }
  CC.reload = () => load(false);

  paintBar(); paint(); load(false);
})();
