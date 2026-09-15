#!/usr/bin/env bash
# Build every loaded vintage end to end: warehouse join -> PMTiles -> stats.
#
#   scripts/build_all.sh              # builds 2023 2024 2025 2026 (currently loaded)
#   scripts/build_all.sh 2024 2025    # a subset
#
# Add 2026 here once the platform team loads the 2026 certified roll + PARCEL2026.
# Prereqs: warehouse access (DATABRICKS_* in .env), data/owner_name_rules.csv (the
# owner -> ownership-group crosswalk), tippecanoe. The water/parks mask
# (scripts/build_mask.R) is optional; set VPL_SKIP_MASK=1 to build without it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Load .env so the warehouse credentials in the documented setup actually reach
# Rscript. Variables already exported in the shell take precedence.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

if [ "$#" -gt 0 ]; then YEARS=("$@"); else YEARS=(2023 2024 2025 2026); fi
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
