#!/usr/bin/env bash
# Build every loaded vintage end to end: warehouse join -> PMTiles -> stats.
#
#   scripts/build_all.sh              # builds 2023 2024 2025 2026 (currently loaded)
#   scripts/build_all.sh 2024 2025    # a subset
#
# Prereqs: warehouse access (DATABRICKS_* in .env), data/owner_rules.csv (the
# owner-name pattern -> ownership-group crosswalk), and tippecanoe on PATH.
#
# The water/parks mask is NOT applied by default; set VPL_SKIP_MASK=0 to opt in.
# See the mask note in README.md before doing so.
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
