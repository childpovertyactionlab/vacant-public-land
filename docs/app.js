// Vacant Public Land — Mapbox GL JS + native PMTiles.
// Mapbox GL renders the CPAL mapbox:// style; parcels come from per-vintage
// PMTiles vector sources (native v3 support). Vintages are data-driven from
// vintage_stats.json.

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

const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-");
const fmt = (n) => (n || 0).toLocaleString();
const dollar = (v) => (v === null || v === "" || v === undefined || isNaN(+v)) ? "—" : "$" + Math.round(+v).toLocaleString();

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

// Bounding box [minLng, minLat, maxLng, maxLat] of a GeoJSON FeatureCollection.
function bbox(geo) {
  let a = 180, b = 90, c = -180, d = -90;
  const walk = (co) => {
    if (typeof co[0] === "number") { a = Math.min(a, co[0]); b = Math.min(b, co[1]); c = Math.max(c, co[0]); d = Math.max(d, co[1]); }
    else co.forEach(walk);
  };
  geo.features.forEach((f) => walk(f.geometry.coordinates));
  return [a, b, c, d];
}

function popupHTML(p, lngLat) {
  const owner = LABEL[p.OWNERSHIP_GROUP] || p.OWNERSHIP_GROUP || "Public owner";
  const color = COLOR[p.OWNERSHIP_GROUP] || "#008097";
  const addr = (p.address && String(p.address).trim()) ? p.address : "";
  const loc = addr ? addr + (p.zip ? ", " + p.zip : "") : "Address not listed";
  // Address links to Google Street View at the clicked point.
  const sv = `https://www.google.com/maps/@?api=1&map_action=pano&viewpoint=${lngLat.lat},${lngLat.lng}`;
  const locHtml = addr ? `<a href="${sv}" target="_blank" rel="noopener">${loc}</a>` : loc;
  // Account links to the DCAD account detail page.
  const acct = p.ACCOUNT_NUM
    ? `<a href="https://www.dallascad.org/AcctDetail.aspx?ID=${encodeURIComponent(p.ACCOUNT_NUM)}" target="_blank" rel="noopener">${p.ACCOUNT_NUM}</a>`
    : "—";
  const row = (k, v) => `<dt>${k}</dt><dd>${v}</dd>`;
  return `<div class="pp">
    <div class="pp-owner"><span class="pp-dot" style="background:${color}"></span>${owner}</div>
    <div class="pp-addr">${locHtml}</div>
    <dl class="pp-grid">
      ${row("Land value", dollar(p.land_val))}
      ${row("Prev. market", dollar(p.prev_val))}
      ${row("SPTD", p.sptd || "—")}
      ${row("Account", acct)}
    </dl>
  </div>`;
}

let STATS = {};
let YEARS = [];
let currentYear = null;

async function main() {
  STATS = await (await fetch("vintage_stats.json")).json();
  YEARS = Object.keys(STATS).sort();
  currentYear = YEARS[YEARS.length - 1];

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
  map.addControl(new mapboxgl.NavigationControl({ showCompass: false }), "top-right");
  map.addControl(new mapboxgl.ScaleControl({ unit: "imperial" }), "bottom-left");
  map.on("error", (e) => console.error("map error:", e && e.error ? e.error : e));

  const popup = new mapboxgl.Popup({ closeButton: false, maxWidth: "300px", offset: 8 });
  let hover = { id: null };

  map.on("load", () => {
    // Spotlight: fade everything outside the City of Dallas, with a crisp edge.
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

    // One PMTiles vector source per vintage (native v3) + a fill layer per group.
    YEARS.forEach((year) => {
      const srcId = "src-" + year;
      const pmUrl = new URL("public-vacant-land_" + year + ".pmtiles", location.href).href;
      map.addSource(srcId, { type: "vector", url: pmUrl, promoteId: "GIS_PARCEL_ID" });

      GROUPS.forEach((g) => {
        const layerId = year + "__" + slug(g.name);
        map.addLayer({
          id: layerId, type: "fill", source: srcId, "source-layer": "parcels",
          layout: { visibility: year === currentYear ? "visible" : "none" },
          paint: {
            "fill-color": g.color,
            "fill-opacity": ["case", ["boolean", ["feature-state", "hover"], false], 0.9, 0.55],
          },
          filter: ["==", ["get", "OWNERSHIP_GROUP"], g.name],
        });
        // Thin outline for definition at high zoom.
        map.addLayer({
          id: layerId + "__line", type: "line", source: srcId, "source-layer": "parcels",
          layout: { visibility: year === currentYear ? "visible" : "none" },
          minzoom: 13,
          paint: { "line-color": g.color, "line-width": 0.6, "line-opacity": 0.9 },
          filter: ["==", ["get", "OWNERSHIP_GROUP"], g.name],
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
  });

  buildPicker(map);
  buildLegend();
  renderCards(currentYear);
}

function setVintage(map, year) {
  currentYear = year;
  YEARS.forEach((y) => GROUPS.forEach((g) => {
    const vis = y === year ? "visible" : "none";
    const base = y + "__" + slug(g.name);
    if (map.getLayer(base)) map.setLayoutProperty(base, "visibility", vis);
    if (map.getLayer(base + "__line")) map.setLayoutProperty(base + "__line", "visibility", vis);
  }));
  renderCards(year);
}

function buildPicker(map) {
  const el = document.getElementById("vintage-picker");
  el.innerHTML = "";
  YEARS.forEach((year) => {
    const label = document.createElement("label");
    label.className = "vintage-option";
    const input = document.createElement("input");
    input.type = "radio"; input.name = "vintage"; input.value = year;
    input.checked = year === currentYear;
    input.addEventListener("change", () => setVintage(map, year));
    label.appendChild(input);
    label.appendChild(document.createTextNode(" " + year));
    el.appendChild(label);
  });
}

function buildLegend() {
  document.getElementById("legend").innerHTML = GROUPS.map((g) =>
    `<span class="legend-item"><span class="swatch" style="background:${g.color}"></span>${g.label}</span>`
  ).join("");
}

function renderCards(year) {
  const s = STATS[year] || { total: 0, by_group: {} };
  document.getElementById("total").textContent = fmt(s.total);
  document.getElementById("vintage-label").textContent = year;
  document.getElementById("counts").innerHTML = GROUPS.map((g) =>
    `<div class="count-row"><b class="count-num" style="border-color:${g.color}">${fmt(s.by_group[g.name])}</b>` +
    ` listed as <span style="color:${g.color}">${g.label}</span></div>`
  ).join("");
}

main().catch((err) => {
  console.error(err);
  document.getElementById("map").innerHTML =
    "<div class='map-error'>Map failed to load — see console. " + err + "</div>";
});
