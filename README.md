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
  Authority, or MULTIPLE OWNERS) via a hand-curated owner crosswalk keyed on
  account number.

Water and city parks are erased from the result (open-data mask).

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
owner crosswalk CSV at `data/owner_crosswalk_pubDallas.csv`, the water/parks mask
(`scripts/build_mask.R`), and `tippecanoe` on `PATH`.

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

- [ ] Confirm the read path for the R build: warehouse host + warehouse id +
      credential, **or** publish a vacant-land extract to a UC Volume for it to
      read instead (a clean swap, per "Staying current").
- [ ] Confirm catalog/schema against the live metastore
      (`silver_tx_dallas_cad_car.account`,
      `bronze_tx_dallas_cad.parcel_geom_certified`). The join fails loudly on
      schema drift rather than producing a wrong map.
- [ ] Provide the re-curated owner crosswalk CSV (account-keyed; one file covers
      every vintage).
- [ ] Load the 2026 certified roll + PARCEL2026 to unblock the 2026 vintage;
      then add `2026` to `scripts/build_all.sh`.
- [ ] Consider the auto-refresh job (see "Staying current") so later vintages do
      not depend on someone remembering to run the build.
