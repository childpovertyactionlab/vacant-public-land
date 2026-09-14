#!/usr/bin/env bash
# Tile each vintage's parcel GeoJSON (EPSG:4326) into a PMTiles archive served
# from docs/ by GitHub Pages. The layer name is pinned to "parcels" — docs/app.js
# references it as source-layer, so keep them in sync.
#
# Inputs : data/public-vacant-land_<year>.geojson  (written by the join script)
# Outputs: docs/public-vacant-land_<year>.pmtiles
#
# Requires tippecanoe (>= 2.x). Run once per vintage after regenerating its
# GeoJSON (scripts/build_all.sh does this for every loaded year).
set -euo pipefail

# Skip (don't fail the render) if tippecanoe is absent — the map just renders
# without parcel tiles. Install: apt install tippecanoe / brew install tippecanoe.
if ! command -v tippecanoe >/dev/null 2>&1; then
  echo "tippecanoe not found on PATH — skipping tile build (map layers will be empty)."
  exit 0
fi

YEARS=("$@")
if [ ${#YEARS[@]} -eq 0 ]; then
  YEARS=(2023 2024 2025)   # default vintages; add 2026 when its GeoJSON exists
fi

for YEAR in "${YEARS[@]}"; do
  SRC="data/public-vacant-land_${YEAR}.geojson"
  OUT="docs/public-vacant-land_${YEAR}.pmtiles"
  if [ ! -f "$SRC" ]; then
    echo "skip ${YEAR}: ${SRC} missing (run the join script for ${YEAR})"
    continue
  fi
  echo "tiling ${SRC} -> ${OUT}"
  tippecanoe \
    -o "$OUT" --force \
    -l parcels \
    -n "public vacant land ${YEAR}" \
    -zg --extend-zooms-if-still-dropping \
    --no-tile-size-limit \
    --preserve-input-order \
    "$SRC"
done

echo "done. PMTiles written to docs/ (served by Pages via range requests)."
