# Vacant Public Land

Interactive map of vacant parcels owned by public entities within the City of
Dallas. A refresh of the 2023 Dallas Media Collaborative map onto current DCAD
appraisal data, with a client-side vintage picker. Source of truth is the
migrated DCAD data on the cpal-data-platform Databricks warehouse, not the
original Dropbox `.gdb`/CSV inputs.

## What "vacant" and "public" mean

- **Vacant** — DCAD SPTD land-use codes C11–C14 (vacant lots) **and**
  `improvement_value = 0` (no taxable structure). Pairing the land-use intent
  with the structure-absence signal drops C11–C14 lots that actually carry a
  building. `improvement_value` is the signal newer CPAL work standardized on
  (the SB 15 "undeveloped" test in zoning-analysis; `has_building` in silver).
- **Public** — the owner maps to one of seven public ownership groups (City of
  Dallas, Dallas County, DART, Dallas College, Dallas ISD, Dallas Housing
  Authority, or MULTIPLE OWNERS) via `data/owner_rules.csv`: ordered regex rules
  matched against the owner name. Names are reduced to an alphanumeric-only key
  first, so DCAD's spacing and punctuation noise ("DALLAS C ITY OF",
  "DALLAS CITY OF ET AL") collapses automatically. Exclusion rules run first, so
  private entities that merely contain a public name (Dallas County Audubon,
  Dallas City Homes Inc) are rejected before the broad prefix rules see them.

  Patterns rather than exact names because DCAD re-truncates owner names every
  vintage: "DALLAS HOUSING ACQUISITION &" covered 83 parcels in 2023 and 7 in
  2026, while "... & DEV CORP" moved the other way. The rules reproduce the
  original 2023 curation exactly (4,203/4,203, zero mismatches) while also
  catching the variants an exact-name crosswalk drops in later vintages. Every
  build prints public-looking owner names that no rule covers, so gaps surface
  instead of silently under-counting.

Water and city parks are **not** currently erased — see the mask note under
"Refresh a vintage".

## How it's built

A **static snapshot per appraisal vintage**, not a live service. Parcels don't
change between builds, so there is no warehouse query per visitor and no API
layer to run:

    warehouse query (R/sf)  →  per-vintage GeoJSON  →  PMTiles (tippecanoe)  →  docs/  →  GitHub Pages

`docs/` is a hand-authored Mapbox GL JS v3 site that reads the `.pmtiles`
archives as vector sources natively (v3.21+, no adapter). The vintage picker and
count cards are data-driven from `docs/vintage_stats.json`, so a new vintage
appears with no page edit.

### Refresh a vintage

    scripts/build_all.sh 2025            # one year, end to end
    scripts/build_all.sh 2023 2024 2025  # several

Per year that runs the warehouse join → tile, then rebuilds the stats and the
city boundary. Preview over HTTP (PMTiles needs HTTP range requests, which
`python -m http.server` does not serve):

    npx serve docs

Prereqs: warehouse access (`DATABRICKS_*` in `.env`; copy `.env.example`), the
owner rules at `data/owner_rules.csv` (committed), and `tippecanoe` on `PATH`.

The water/parks mask is **not** applied. `scripts/build_mask.R` rebuilds one from
City of Dallas open data, but that reconstruction is far broader than the retired
Dropbox mask it replaces — it would erase 12.6% of the parcels the published 2023
map kept (water alone, 2.4%). Builds run with `VPL_SKIP_MASK=1` until the
exclusion is re-specified.

## Staying current

DCAD certifies a new roll each summer; without a trigger the map drifts stale.
The durable fix is to run the refresh where the data lands: a Databricks job
downstream of CAD ingestion materializes the vacant-land extract to a UC Volume
when a new certified vintage arrives, and a light repo step tiles and commits it.
The join script's warehouse read is a single swappable block (see the connect
section of `scripts/Join Cleaned Owners to Parcel Accounts.R`), so pointing it at
a Volume extract instead of the warehouse is a one-block change. Until that
exists, run `build_all.sh <year>` by hand after certification.

## Deploy

A push to `main` triggers `.github/workflows/deploy-pages.yml`, which injects the
publishable (`pk.*`) Mapbox token from the `MAPBOX_TOKEN` repo secret into
`docs/config.js` and deploys `docs/` to Pages. The token is never committed;
`docs/config.js` is gitignored and `docs/config.example.js` is the placeholder.

## Checklist for the data-engineering reviewer

- [x] Read path confirmed: `cpal-public` workspace, SQL warehouse
      `8142ee381e9bef88`, OAuth via the databricks CLI profile. Note
      `odbc::databricks()` does **not** work with the current Databricks ODBC
      driver — the join connects through the driver explicitly.
- [x] Catalog/schema confirmed against the live metastore. Every column the join
      selects exists in `silver.silver_tx_dallas_cad_car.{account, account_owner,
      property_address}` and `bronze.bronze_tx_dallas_cad.parcel_geom_certified`.
      Both owner/address joins need an `appraisal_year` predicate —
      `universal_id` is not year-unique and omitting it fans rows out ~5.7x.
- [ ] Switch GitHub Pages to **Source: GitHub Actions** (currently `legacy`,
      publishing `main:/docs`). Without this the deploy workflow cannot publish,
      and a branch-published site has no `docs/config.js`, so the map loads with
      no Mapbox token.
- [x] Owner crosswalk — no longer needed from the Google Sheet. The sheet's
      content was fully recoverable from the published 2023 output and is now
      expressed as pattern rules in `data/owner_rules.csv`. Review the exclusion
      rules and the TIF-to-City mapping if you want to revisit those calls.
- [x] 2026 is already loaded (`appraisal_year = 2026` in silver, with 2025
      parcel geometry) and is built. `build_all.sh` covers 2023-2026.
- [ ] Consider the auto-refresh job (see "Staying current") so later vintages do
      not depend on someone remembering to run the build.
