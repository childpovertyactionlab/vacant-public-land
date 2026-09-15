// Vacant Public Land — Mapbox GL JS + native PMTiles.
// Mapbox GL renders the CPAL mapbox:// style; parcels come from per-vintage
// PMTiles vector sources (native v3 support). Vintages, size bands and every
// headline figure are data-driven from vintage_stats.json.

const TOKEN = window.CPAL_MAPBOX_TOKEN;
mapboxgl.accessToken = TOKEN;
const STYLE = "mapbox://styles/michaelcpal/clqzkwbw800sw01nv90032l7z";

const GROUPS = [
  { name: "CITY OF DALLAS",           label: "City of Dallas",           color: "#008097" },
  { name: "DALLAS COUNTY",            label: "Dallas County",            color: "#E98816" },
  { name: "DART",                     label: "DART",                     color: "#1E4A4A" },
  { name: "DALLAS COLLEGE",           label: "Dallas College",           color: "#F7314C" },
  { name: "DALLAS ISD",               label: "Dallas ISD",               color: "#EA8B98" },
  { name: "DALLAS HOUSING AUTHORITY", label: "Dallas Housing Authority", color: "#851E2C" },
  { name: "MULTIPLE OWNERS",          label: "Multiple Owners",          color: "#EACA2D" },
];
const LABEL = Object.fromEntries(GROUPS.map((g) => [g.name, g.label]));
const COLOR = Object.fromEntries(GROUPS.map((g) => [g.name, g.color]));

// Single accent for the trend charts. Each chart plots one series, so there is
// no categorical palette here and no legend — the card's label names the metric.
const ACCENT = "#008097";
const SURFACE = "#ffffff";

const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-");
const fmt = (n) => Math.round(n || 0).toLocaleString();
const dollar = (v) => (v === null || v === "" || v === undefined || isNaN(+v)) ? "—" : "$" + Math.round(+v).toLocaleString();
const acresTxt = (a) => (a == null || isNaN(+a)) ? "—" : (+a < 1 ? (+a).toFixed(2) : fmt(a));
const billions = (v) => "$" + (v / 1e9).toFixed(2) + "B";

let STATS = {};      // vintages
let BANDS = [];      // size bands
let YEARS = [];
let currentYear = null;
let activeBands = new Set();
let activeOwners = new Set();
let MAP = null;

// ---------------------------------------------------------------------------
// Geometry helpers

// A world polygon with the city cut out as holes — fills everything OUTSIDE
// Dallas so the city reads as the focus (a "spotlight" mask).
function maskGeo(boundary) {
  const world = [[-180, -85], [180, -85], [180, 85], [-180, 85], [-180, -85]];
  const holes = [];
  boundary.features.forEach((f) => {
    const g = f.geometry;
    if (g.type === "Polygon") holes.push(g.coordinates[0]);
    else if (g.type === "MultiPolygon") g.coordinates.forEach((poly) => holes.push(poly[0]));
  });
  return { type: "Feature", geometry: { type: "Polygon", coordinates: [world, ...holes] } };
}

function bbox(geo) {
  let a = 180, b = 90, c = -180, d = -90;
  const walk = (co) => {
    if (typeof co[0] === "number") { a = Math.min(a, co[0]); b = Math.min(b, co[1]); c = Math.max(c, co[0]); d = Math.max(d, co[1]); }
    else co.forEach(walk);
  };
  geo.features.forEach((f) => walk(f.geometry.coordinates));
  return [a, b, c, d];
}

// ---------------------------------------------------------------------------
// Filtering

// Mapbox filter for the active size bands. An empty selection shows nothing,
// which matches what the count cards will read.
function bandFilter() {
  const on = BANDS.filter((b) => activeBands.has(b.id));
  if (!on.length) return ["==", ["get", "acres"], -1];   // acres >= 0 always, so this matches nothing
  const parts = on.map((b) => (b.max == null || b.max === undefined)
    ? [">=", ["get", "acres"], b.min]
    : ["all", [">=", ["get", "acres"], b.min], ["<", ["get", "acres"], b.max]]);
  return parts.length === 1 ? parts[0] : ["any", ...parts];
}

function layerFilter(groupName) {
  return ["all", ["==", ["get", "OWNERSHIP_GROUP"], groupName], bandFilter()];
}

// Owner filtering rides on layer visibility rather than the filter expression:
// there is already one layer per group, so hiding the layer is both cheaper than
// re-evaluating a predicate per feature and keeps each group's colour attached
// to its own layer.
function layerVisible(year, groupName) {
  return (year === currentYear && activeOwners.has(groupName)) ? "visible" : "none";
}

// Totals are summed from precomputed (group x band) cells rather than counted
// from rendered tiles: vector tiles are clipped per viewport, so counting
// features would undercount at low zoom and drift as the user pans.
function totalsFor(year) {
  const cells = (STATS[year] || {}).cells || {};
  const byGroup = {};
  let parcels = 0, acres = 0, land_val = 0;
  GROUPS.forEach((g) => {
    let p = 0, a = 0, v = 0;
    if (!activeOwners.has(g.name)) { byGroup[g.name] = { parcels: 0, acres: 0, land_val: 0 }; return; }
    BANDS.forEach((b) => {
      if (!activeBands.has(b.id)) return;
      const c = (cells[g.name] || {})[b.id];
      if (!c) return;
      p += c.parcels || 0; a += c.acres || 0; v += c.land_val || 0;
    });
    byGroup[g.name] = { parcels: p, acres: a, land_val: v };
    parcels += p; acres += a; land_val += v;
  });
  return { parcels, acres, land_val, byGroup };
}

// Option counts are cross-filtered: the lot-size options count only owners that
// are currently on, and the owner options count only sizes that are on. That way
// a number next to an option is what you would actually get by ticking it.
function bandParcelCount(year, bandId) {
  const cells = (STATS[year] || {}).cells || {};
  return GROUPS.reduce((n, g) => activeOwners.has(g.name)
    ? n + (((cells[g.name] || {})[bandId] || {}).parcels || 0) : n, 0);
}

function ownerParcelCount(year, groupName) {
  const cells = (STATS[year] || {}).cells || {};
  return BANDS.reduce((n, b) => activeBands.has(b.id)
    ? n + (((cells[groupName] || {})[b.id] || {}).parcels || 0) : n, 0);
}

// ---------------------------------------------------------------------------
// Popup

function popupHTML(p, lngLat) {
  const owner = LABEL[p.OWNERSHIP_GROUP] || p.OWNERSHIP_GROUP || "Public owner";
  const color = COLOR[p.OWNERSHIP_GROUP] || ACCENT;
  const addr = (p.address && String(p.address).trim()) ? p.address : "";
  const loc = addr ? addr + (p.zip ? ", " + p.zip : "") : "Address not listed";
  const sv = `https://www.google.com/maps/@?api=1&map_action=pano&viewpoint=${lngLat.lat},${lngLat.lng}`;
  const locHtml = addr ? `<a href="${sv}" target="_blank" rel="noopener">${loc}</a>` : loc;
  const acct = p.ACCOUNT_NUM
    ? `<a href="https://www.dallascad.org/AcctDetail.aspx?ID=${encodeURIComponent(p.ACCOUNT_NUM)}" target="_blank" rel="noopener">${p.ACCOUNT_NUM}</a>`
    : "—";
  const row = (k, v) => `<dt>${k}</dt><dd>${v}</dd>`;
  return `<div class="pp">
    <div class="pp-owner"><span class="pp-dot" style="background:${color}"></span>${owner}</div>
    <div class="pp-addr">${locHtml}</div>
    <dl class="pp-grid">
      ${row("Lot size", acresTxt(p.acres) + " ac")}
      ${row("Land value", dollar(p.land_val))}
      ${row("Prev. market", dollar(p.prev_val))}
      ${row("SPTD", p.sptd || "—")}
      ${row("Account", acct)}
    </dl>
  </div>`;
}

// ---------------------------------------------------------------------------
// Trend charts — one metric each, so never a second y-scale on one plot.

const METRICS = [
  { key: "parcels",  label: "Parcels",            fmt: fmt,       tick: fmt },
  { key: "acres",    label: "Acres",              fmt: fmt,       tick: fmt },
  { key: "land_val", label: "Assessed land value", fmt: billions, tick: (v) => "$" + (v / 1e9).toFixed(1) + "B" },
];

const W = 300, H = 96, PAD = { t: 10, r: 12, b: 18, l: 46 };

function lineChart(metric, series) {
  const vals = series.map((d) => d.value);
  let lo = Math.min(...vals), hi = Math.max(...vals);
  // These measures move by a couple of percent; a zero baseline would flatten
  // them into a straight line. Pad the observed range instead and keep both
  // axis ticks visible so the reader can see the scale is not zero-based.
  if (lo === hi) { lo -= 1; hi += 1; }
  const pad = (hi - lo) * 0.25;
  lo -= pad; hi += pad;
  const iw = W - PAD.l - PAD.r, ih = H - PAD.t - PAD.b;
  const x = (i) => PAD.l + (series.length === 1 ? iw / 2 : (i / (series.length - 1)) * iw);
  const y = (v) => PAD.t + ih - ((v - lo) / (hi - lo)) * ih;

  const path = series.map((d, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(d.value).toFixed(1)}`).join("");
  const first = series[0], last = series[series.length - 1];

  // Hairline, solid gridlines at the two tick values; no area fill, because the
  // baseline is not zero and a fill would imply magnitude from zero.
  const ticks = [lo + pad, hi - pad];
  const grid = ticks.map((t) =>
    `<line class="grid" x1="${PAD.l}" y1="${y(t).toFixed(1)}" x2="${W - PAD.r}" y2="${y(t).toFixed(1)}"/>`
  ).join("");
  const tickText = ticks.map((t) =>
    `<text class="tick" x="${PAD.l - 6}" y="${(y(t) + 3).toFixed(1)}" text-anchor="end">${metric.tick(t)}</text>`
  ).join("");
  // Emphasis marker tying the charts to the vintage picker: a hairline guide at
  // the selected year, so "2026" in the control and the headline value below
  // clearly refer to the same point on the line.
  const selIdx = series.findIndex((d) => d.year === currentYear);
  const guide = selIdx >= 0
    ? `<line class="grid" x1="${x(selIdx).toFixed(1)}" y1="${PAD.t}" x2="${x(selIdx).toFixed(1)}" y2="${H - PAD.b}"/>`
    : "";

  const xText = series.map((d, i) =>
    (i === 0 || i === series.length - 1)
      ? `<text class="tick" x="${x(i).toFixed(1)}" y="${H - 4}" text-anchor="${i ? "end" : "start"}">${d.year}</text>`
      : ""
  ).join("");

  // Markers: r=4 (>=8px), each with a 2px surface ring, plus a 24px transparent
  // hit area so the point is reliably hoverable and focusable.
  const dots = series.map((d, i) => `
    <circle cx="${x(i).toFixed(1)}" cy="${y(d.value).toFixed(1)}" r="4" fill="${ACCENT}" stroke="${SURFACE}" stroke-width="2"/>
    <circle class="pt-hit" cx="${x(i).toFixed(1)}" cy="${y(d.value).toFixed(1)}" r="12"
            tabindex="0" role="img"
            data-year="${d.year}" data-val="${metric.fmt(d.value)}" data-label="${metric.label}"
            aria-label="${d.year}: ${metric.fmt(d.value)} ${metric.label}"></circle>`).join("");

  // No endpoint label inside the plot: the card's headline value directly above
  // already labels the last point, in larger type. Repeating it here would be a
  // second number saying the same thing, and it would overflow the viewBox.

  return {
    svg: `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${metric.label}, ${first.year} to ${last.year}">
      ${grid}${guide}${tickText}${xText}
      <path d="${path}" fill="none" stroke="${ACCENT}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
      ${dots}
    </svg>`,
    first, last,
  };
}

function renderTrend() {
  const grid = document.getElementById("trend-grid");
  grid.innerHTML = "";
  const byYear = Object.fromEntries(YEARS.map((y) => [y, totalsFor(y)]));

  METRICS.forEach((m) => {
    const series = YEARS.map((y) => ({ year: y, value: byYear[y][m.key] }));
    const { svg, first } = lineChart(m, series);
    const sel = series.find((d) => d.year === currentYear) || series[series.length - 1];
    const diff = sel.value - first.value;
    const pct = first.value ? (diff / first.value) * 100 : 0;
    // Neutral ink, not red/green: a fall in vacant public land could mean lots
    // were put to use or that public land was sold off, and the page should not
    // assert which. The sign carries the direction; status colors stay reserved.
    const sign = diff > 0 ? "+" : (diff < 0 ? "−" : "±");
    const deltaHtml = (sel.year === first.year)
      ? `<span class="neutral">First vintage</span>`
      : `<span class="neutral">${sign}${m.fmt(Math.abs(diff))} (${sign}${Math.abs(pct).toFixed(1)}%)</span> since ${first.year}`;

    const card = document.createElement("div");
    card.className = "tcard";
    card.innerHTML = `
      <div class="tcard-label">${m.label} · ${sel.year}</div>
      <div class="tcard-value">${m.fmt(sel.value)}</div>
      <div class="tcard-delta">${deltaHtml}</div>
      ${svg}`;
    grid.appendChild(card);
  });

  renderTrendTable(byYear);
  wireChartTooltips();
}

function renderTrendTable(byYear) {
  const t = document.getElementById("trend-table");
  t.innerHTML = "";
  const head = t.insertRow();
  ["Vintage", "Parcels", "Acres", "Assessed land value"].forEach((h) => {
    const th = document.createElement("th"); th.scope = "col"; th.textContent = h; head.appendChild(th);
  });
  YEARS.forEach((y) => {
    const r = t.insertRow();
    const th = document.createElement("th"); th.scope = "row"; th.textContent = y; r.appendChild(th);
    [fmt(byYear[y].parcels), fmt(byYear[y].acres), billions(byYear[y].land_val)].forEach((v) => {
      r.insertCell().textContent = v;
    });
  });
}

// Tooltips enhance, never gate: every value here is also in the table view.
let TT = null;
function wireChartTooltips() {
  if (!TT) { TT = document.createElement("div"); TT.className = "tt"; TT.hidden = true; document.body.appendChild(TT); }
  const show = (el) => {
    TT.innerHTML = "";
    const v = document.createElement("div"); v.className = "tt-v"; v.textContent = el.dataset.val;
    const k = document.createElement("div"); k.className = "tt-k";
    k.textContent = `${el.dataset.label} · ${el.dataset.year}`;
    TT.append(v, k);
    const r = el.getBoundingClientRect();
    TT.hidden = false;
    TT.style.left = Math.min(window.innerWidth - TT.offsetWidth - 8, Math.max(8, r.left + r.width / 2 - TT.offsetWidth / 2)) + "px";
    TT.style.top = Math.max(8, r.top - TT.offsetHeight - 8) + "px";
  };
  const hide = () => { if (TT) TT.hidden = true; };
  document.querySelectorAll(".tcard .pt-hit").forEach((el) => {
    el.addEventListener("pointerenter", () => show(el));
    el.addEventListener("pointerleave", hide);
    el.addEventListener("focus", () => show(el));
    el.addEventListener("blur", hide);
  });
}

// ---------------------------------------------------------------------------
// Controls + cards

function renderCards() {
  const t = totalsFor(currentYear);
  document.getElementById("total").textContent = fmt(t.parcels);
  document.getElementById("vintage-label").textContent = currentYear;
  document.getElementById("total-acres").textContent = fmt(t.acres);
  document.getElementById("total-value").textContent = billions(t.land_val);
  // Every group stays listed even when filtered out, dimmed rather than removed:
  // the rows keep their position so the reader is not re-reading a shuffled list,
  // and an excluded group is visibly excluded rather than silently absent.
  document.getElementById("counts").innerHTML = GROUPS.map((g) => {
    const off = activeOwners.has(g.name) ? "" : " is-off";
    return `<div class="count-row${off}"><b class="count-num" style="border-color:${g.color}">${fmt(t.byGroup[g.name].parcels)}</b>` +
      ` listed as <span style="color:${g.color}">${g.label}</span></div>`;
  }).join("");
}

function applyFilter() {
  if (!MAP) return;
  YEARS.forEach((y) => GROUPS.forEach((g) => {
    const base = y + "__" + slug(g.name);
    const vis = layerVisible(y, g.name);
    [base, base + "__line"].forEach((id) => {
      if (!MAP.getLayer(id)) return;
      MAP.setFilter(id, layerFilter(g.name));
      MAP.setLayoutProperty(id, "visibility", vis);
    });
  }));
}

function renderLegend() {
  document.getElementById("legend").innerHTML = GROUPS.map((g) =>
    `<span class="legend-item${activeOwners.has(g.name) ? "" : " is-off"}">` +
    `<span class="swatch" style="background:${g.color}"></span>${g.label}</span>`
  ).join("");
}

function noteText() {
  if (!activeOwners.size || !activeBands.size) return "Nothing selected — the map is empty.";
  const filtered = activeBands.size < BANDS.length || activeOwners.size < GROUPS.length;
  if (!filtered) {
    // State the concentration as measured rather than asserting what the big
    // parcels are: acreage is dominated by a small number of very large tracts,
    // so parcel count and acreage tell different stories.
    const big = BANDS[BANDS.length - 1];
    const all = totalsFor(currentYear);
    const cells = (STATS[currentYear] || {}).cells || {};
    const bigAc = GROUPS.reduce((a, g) => a + (((cells[g.name] || {})[big.id] || {}).acres || 0), 0);
    const bigN = bandParcelCount(currentYear, big.id);
    const share = all.acres ? Math.round((bigAc / all.acres) * 100) : 0;
    return `The ${big.label} band is ${fmt(bigN)} parcels (${Math.round((bigN / all.parcels) * 100)}% of the count) `
      + `but ${share}% of all acreage — filter it out to see the smaller, lot-scale inventory.`;
  }
  const t = totalsFor(currentYear);
  return `Filtered: ${fmt(t.parcels)} parcels · ${fmt(t.acres)} acres · ${billions(t.land_val)}. `
    + `The counts and trend below follow this selection.`;
}

function refresh() {
  applyFilter();
  renderCards();
  renderLegend();
  renderTrend();
  syncDropdowns();
  document.getElementById("size-note").textContent = noteText();
}

// ---------------------------------------------------------------------------
// Dropdown filter controls
//
// A disclosure button plus a panel of checkboxes/radios, rather than a native
// <select multiple> (which is unusable on touch and cannot show per-option
// counts) or a row of chips (which wraps badly once there are three filters).
// The button always states the current selection, so the row reads as a summary
// even when every panel is closed.

const DD = {};   // id -> { el, btn, panel, build, summary }

function closeAllDropdowns(except) {
  Object.values(DD).forEach((d) => {
    if (d === except || d.panel.hidden) return;
    d.panel.hidden = true;
    d.el.dataset.open = "0";
    d.btn.setAttribute("aria-expanded", "false");
  });
}

function makeDropdown(id, build, summary) {
  const el = document.getElementById(id);
  const btn = el.querySelector(".dd-btn");
  const panel = el.querySelector(".dd-panel");
  const d = { el, btn, panel, build, summary };
  DD[id] = d;

  btn.addEventListener("click", (e) => {
    e.stopPropagation();
    const open = panel.hidden;
    closeAllDropdowns(d);
    panel.hidden = !open;
    el.dataset.open = open ? "1" : "0";
    btn.setAttribute("aria-expanded", open ? "true" : "false");
    if (open) { const f = panel.querySelector("input"); if (f) f.focus(); }
  });
  panel.addEventListener("click", (e) => e.stopPropagation());
  el.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !panel.hidden) {
      panel.hidden = true; el.dataset.open = "0";
      btn.setAttribute("aria-expanded", "false"); btn.focus();
    }
  });
  return d;
}

function optRow({ type, name, checked, label, count, color, onChange }) {
  const row = document.createElement("label");
  row.className = "dd-opt";
  row.dataset.on = checked ? "1" : "0";
  const input = document.createElement("input");
  input.type = type; if (name) input.name = name; input.checked = checked;
  input.addEventListener("change", () => onChange(input.checked));
  row.appendChild(input);
  if (color) {
    const sw = document.createElement("span");
    sw.className = "dd-swatch"; sw.style.background = color;
    row.appendChild(sw);
  }
  const l = document.createElement("span");
  l.className = "dd-opt-l"; l.textContent = label;
  row.appendChild(l);
  if (count != null) {
    const n = document.createElement("span");
    n.className = "dd-opt-n"; n.textContent = fmt(count);
    row.appendChild(n);
  }
  return row;
}

function bulkActions(panel, onAll, onNone) {
  const wrap = document.createElement("div");
  wrap.className = "dd-actions";
  const a = document.createElement("button"); a.type = "button"; a.textContent = "Select all";
  a.addEventListener("click", onAll);
  const n = document.createElement("button"); n.type = "button"; n.textContent = "Clear";
  n.addEventListener("click", onNone);
  wrap.append(a, n);
  panel.appendChild(wrap);
}

function buildVintagePanel() {
  const panel = DD["dd-vintage"].panel;
  panel.innerHTML = "";
  YEARS.forEach((y) => panel.appendChild(optRow({
    type: "radio", name: "vintage", checked: y === currentYear, label: y,
    onChange: () => { setVintage(y); closeAllDropdowns(); },
  })));
}

function buildSizePanel() {
  const panel = DD["dd-size"].panel;
  panel.innerHTML = "";
  BANDS.forEach((b) => panel.appendChild(optRow({
    type: "checkbox", checked: activeBands.has(b.id), label: b.label,
    count: bandParcelCount(currentYear, b.id),
    onChange: (on) => { on ? activeBands.add(b.id) : activeBands.delete(b.id); refresh(); },
  })));
  bulkActions(panel,
    () => { activeBands = new Set(BANDS.map((b) => b.id)); refresh(); },
    () => { activeBands = new Set(); refresh(); });
}

function buildOwnerPanel() {
  const panel = DD["dd-owner"].panel;
  panel.innerHTML = "";
  GROUPS.forEach((g) => panel.appendChild(optRow({
    type: "checkbox", checked: activeOwners.has(g.name), label: g.label, color: g.color,
    count: ownerParcelCount(currentYear, g.name),
    onChange: (on) => { on ? activeOwners.add(g.name) : activeOwners.delete(g.name); refresh(); },
  })));
  bulkActions(panel,
    () => { activeOwners = new Set(GROUPS.map((g) => g.name)); refresh(); },
    () => { activeOwners = new Set(); refresh(); });
}

// Summaries name the selection when it is short enough to name, and fall back to
// a count. "All owners" is more useful than listing seven labels.
function summarise(selected, total, one, many, allWord) {
  if (selected.length === total) return allWord;
  if (selected.length === 0) return "None";
  if (selected.length === 1) return one(selected[0]);
  return `${selected.length} of ${total} ${many}`;
}

function syncDropdowns() {
  DD["dd-vintage"].btn.querySelector(".dd-val").textContent = currentYear;

  const bandsOn = BANDS.filter((b) => activeBands.has(b.id));
  DD["dd-size"].btn.querySelector(".dd-val").textContent =
    summarise(bandsOn, BANDS.length, (b) => b.label, "sizes", "All sizes");

  const ownersOn = GROUPS.filter((g) => activeOwners.has(g.name));
  DD["dd-owner"].btn.querySelector(".dd-val").textContent =
    summarise(ownersOn, GROUPS.length, (g) => g.label, "owners", "All owners");

  // Rebuild panels so the cross-filtered counts and checked states stay current.
  buildVintagePanel();
  buildSizePanel();
  buildOwnerPanel();
}

function buildControls() {
  makeDropdown("dd-vintage");
  makeDropdown("dd-size");
  makeDropdown("dd-owner");
  document.addEventListener("click", () => closeAllDropdowns());
  document.getElementById("filters-reset").addEventListener("click", () => {
    activeBands = new Set(BANDS.map((b) => b.id));
    activeOwners = new Set(GROUPS.map((g) => g.name));
    refresh();
  });
}

function setVintage(year) {
  currentYear = year;
  refresh();
}

// ---------------------------------------------------------------------------

async function main() {
  const raw = await (await fetch("vintage_stats.json")).json();
  STATS = raw.vintages;
  BANDS = raw.bands;
  YEARS = Object.keys(STATS).sort();
  currentYear = YEARS[YEARS.length - 1];
  activeBands = new Set(BANDS.map((b) => b.id));
  activeOwners = new Set(GROUPS.map((g) => g.name));

  // Render everything the stats file can drive BEFORE touching Mapbox. The map
  // needs WebGL, which some machines and locked-down browsers do not provide;
  // when it is missing only the map should degrade, not the counts, the filter
  // and the trend charts, which are plain DOM and SVG.
  buildControls();
  refresh();

  try {
    await initMap();
  } catch (err) {
    console.error("map init failed:", err);
    const el = document.getElementById("map");
    el.innerHTML = "";
    const msg = document.createElement("div");
    msg.className = "map-error";
    msg.textContent = "The interactive map could not load in this browser (WebGL unavailable). "
      + "The figures and trend below are unaffected.";
    el.appendChild(msg);
  }
}

async function initMap() {
  const boundaryGeo = await (await fetch("city-of-dallas-boundary.geojson")).json();
  const bb = bbox(boundaryGeo);

  const map = new mapboxgl.Map({
    container: "map",
    style: STYLE,
    bounds: bb,
    fitBoundsOptions: { padding: 24 },
    minZoom: 8,
    maxZoom: 18,
    maxBounds: [[bb[0] - 0.18, bb[1] - 0.14], [bb[2] + 0.18, bb[3] + 0.14]],
  });
  MAP = map;
  map.addControl(new mapboxgl.NavigationControl({ showCompass: false }), "top-right");
  map.addControl(new mapboxgl.ScaleControl({ unit: "imperial" }), "bottom-left");
  map.on("error", (e) => console.error("map error:", e && e.error ? e.error : e));

  const popup = new mapboxgl.Popup({ closeButton: false, maxWidth: "300px", offset: 8 });
  let hover = { id: null };

  map.on("load", () => {
    map.addSource("boundary", { type: "geojson", data: boundaryGeo });
    map.addSource("mask", { type: "geojson", data: maskGeo(boundaryGeo) });
    map.addLayer({
      id: "outside-mask", type: "fill", source: "mask",
      paint: { "fill-color": "#eef1f1", "fill-opacity": 0.72 },
    });
    map.addLayer({
      id: "boundary-line", type: "line", source: "boundary",
      paint: { "line-color": "#008097", "line-width": 1.2, "line-opacity": 0.5 },
    });

    YEARS.forEach((year) => {
      const srcId = "src-" + year;
      const pmUrl = new URL("public-vacant-land_" + year + ".pmtiles", location.href).href;
      map.addSource(srcId, { type: "vector", url: pmUrl, promoteId: "GIS_PARCEL_ID" });

      GROUPS.forEach((g) => {
        const layerId = year + "__" + slug(g.name);
        map.addLayer({
          id: layerId, type: "fill", source: srcId, "source-layer": "parcels",
          layout: { visibility: layerVisible(year, g.name) },
          paint: {
            "fill-color": g.color,
            "fill-opacity": ["case", ["boolean", ["feature-state", "hover"], false], 0.9, 0.55],
          },
          filter: layerFilter(g.name),
        });
        map.addLayer({
          id: layerId + "__line", type: "line", source: srcId, "source-layer": "parcels",
          layout: { visibility: layerVisible(year, g.name) },
          minzoom: 13,
          paint: { "line-color": g.color, "line-width": 0.6, "line-opacity": 0.9 },
          filter: layerFilter(g.name),
        });

        map.on("mousemove", layerId, (e) => {
          map.getCanvas().style.cursor = "pointer";
          if (!e.features.length) return;
          if (hover.id !== null) map.setFeatureState(hover, { hover: false });
          hover = { source: srcId, sourceLayer: "parcels", id: e.features[0].id };
          map.setFeatureState(hover, { hover: true });
        });
        map.on("mouseleave", layerId, () => {
          map.getCanvas().style.cursor = "";
          if (hover.id !== null) map.setFeatureState(hover, { hover: false });
          hover = { id: null };
        });
        map.on("click", layerId, (e) => {
          popup.setLngLat(e.lngLat).setHTML(popupHTML(e.features[0].properties, e.lngLat)).addTo(map);
        });
      });
    });

    // Layer filters are set at creation, but the user may have changed the
    // selection while the style was still loading.
    applyFilter();
  });
}

main().catch((err) => {
  console.error(err);
  const el = document.getElementById("map");
  if (el) {
    el.innerHTML = "";
    const msg = document.createElement("div");
    msg.className = "map-error";
    msg.textContent = "Could not load vintage_stats.json — see console.";
    el.appendChild(msg);
  }
});
