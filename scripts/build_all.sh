#!/usr/bin/env bash
# Build every loaded vintage end to end: warehouse join -> PMTiles -> stats.
#
#   scripts/build_all.sh              # builds 2023 2024 2025 (currently loaded)
#   scripts/build_all.sh 2024 2025    # a subset
#
# Add 2026 here once the platform team loads the 2026 certified roll + PARCEL2026.
# Prereqs: warehouse access (DATABRICKS_* in .env), data/owner_crosswalk_pubDallas.csv
# (from the reviewer), data/mask_water_parks.gpkg (scripts/build_mask.R), tippecanoe.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -gt 0 ]; then YEARS=("$@"); else YEARS=(2023 2024 2025); fi
JOIN="scripts/Join Cleaned Owners to Parcel Accounts.R"

for Y in "${YEARS[@]}"; do
  echo "=== vintage ${Y}: join (warehouse -> data/public-vacant-land_${Y}.geojson) ==="
  Rscript "$JOIN" "$Y"
  echo "=== vintage ${Y}: tile -> docs/public-vacant-land_${Y}.pmtiles ==="
  scripts/tile.sh "$Y"
done

echo "=== stats + boundary -> docs/ ==="
Rscript scripts/build_stats.R
echo "done. Preview over HTTP: npx serve docs"
