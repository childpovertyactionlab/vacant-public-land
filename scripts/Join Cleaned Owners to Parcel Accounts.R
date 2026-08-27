# Build the "public vacant parcels" layer for one appraisal vintage.
#
# 2026 refresh of the original 2023 pipeline. Source of truth is the migrated
# DCAD silver on the cpal-data-platform warehouse — NOT Michael's Dropbox.
#
# Vintage is a single parameter (`year`). Bumping it to 2026 is the only change
# needed once the platform loads the 2026 certified roll + 2026 parcel geometry,
# provided the Databricks schema does not drift; `assert_columns()` below fails
# loudly if it does, rather than silently producing a wrong map.
#
# Output: data/public-vacant-land_<year>.geojson (EPSG:2276), tiled to PMTiles
# for the front end. The file is gitignored (regenerable); rebuild by running
# this script against the warehouse.

library(tidyverse)
library(sf)
library(DBI)
library(odbc)
library(glue)
library(googlesheets4)

# ---- Config -----------------------------------------------------------------
year         <- 2025L                              # target appraisal vintage
parcel_tax_year <- year - 1L                       # newest parcel snapshot (PARCELyyyy -> tax_year-1)
vacant_sptd  <- c("C11", "C12", "C13", "C14")      # DCAD vacant-lot land-use codes
keep_groups  <- c("CITY OF DALLAS", "DART", "DALLAS ISD", "MULTIPLE OWNERS",
                  "DALLAS HOUSING AUTHORITY", "DALLAS COUNTY", "DALLAS COLLEGE")
crs_planar   <- 2276                               # NAD83 TX North Central (US ft)

# Warehouse coordinates. CONFIRM against the live platform: catalogs are
# parameterized dev_* vs prod in cpal-data-platform. The certified roll lives in
# the *_car silver schema; parcel geometry lives in bronze.
catalog        <- Sys.getenv("CPAL_DBX_CATALOG",        "silver")
silver_schema  <- "silver_tx_dallas_cad_car"       # certified silver (current roll = silver_tx_dallas_cad)
bronze_catalog <- Sys.getenv("CPAL_DBX_BRONZE_CATALOG", "bronze")
bronze_schema  <- "bronze_tx_dallas_cad"
parcel_table   <- "parcel_geom_certified"          # cols: Acct, geometry_wkt, tax_year; CRS 2276

crosswalk_sheet <- "1_mMM9Smz4LndqW-fFx0O5VuIAyvIG3oLxvUdtMbv9Ys"
crosswalk_tab   <- "pubDallas"                      # cols: ACCOUNT_NUM, OWNERSHIP_GROUP (re-curate per vintage; see Phase C)

boundary_path <- "data/City of Dallas Boundary.geojson"  # replaces Data.gdb "Dallas_Simple"
mask_path     <- "data/mask_water_parks.gpkg"            # built by scripts/build_mask.R (Phase B)
out_geojson   <- glue("data/public-vacant-land_{year}.geojson")

# ---- Helpers ----------------------------------------------------------------
# Schema contract: stop the build if the warehouse no longer exposes a column we
# depend on. This is what makes the 2026 bump safe — drift fails here, loudly.
assert_columns <- function(df, required, where) {
  missing <- setdiff(required, colnames(df))
  if (length(missing)) {
    stop(glue("Schema drift in {where}: missing column(s) {toString(missing)}. ",
              "Reconcile the query with the current cpal-data-platform schema before shipping."),
         call. = FALSE)
  }
  invisible(df)
}

# ---- Connect ----------------------------------------------------------------
# CPAL standard: Databricks SQL warehouse over ODBC + OAuth (databricks CLI
# profile / env). Alternative if the warehouse is unreachable from R: have a
# Databricks job write the filtered result to a UC Volume as parquet/geojson and
# read that here with arrow/sf instead of the two dbGetQuery() calls below.
con <- DBI::dbConnect(
  odbc::databricks(),
  httpPath = Sys.getenv("CPAL_DBX_HTTP_PATH")      # SQL warehouse HTTP path
)
on.exit(DBI::dbDisconnect(con), add = TRUE)

# ---- 1. Vacant public-candidate accounts ------------------------------------
# One row per vacant account for the vintage, with owner name (for the crosswalk)
# and situs address (for popups). account / account_owner / property_address all
# share universal_id within an appraisal_year partition.
accounts_sql <- glue_sql("
  SELECT a.source_account_id      AS ACCOUNT_NUM,
         a.gis_parcel_id          AS GIS_PARCEL_ID,
         a.sptd_code              AS SPTD_CODE,
         a.land_value             AS LAND_VAL,
         a.prev_market_value      AS PREV_MKT_VAL,
         o.owner_name             AS OWNER_NAME1,
         pa.street_num            AS STREET_NUM,
         pa.full_street_name      AS FULL_STREET_NAME,
         pa.property_city         AS PROPERTY_CITY,
         pa.property_zipcode      AS PROPERTY_ZIPCODE
  FROM {`catalog`}.{`silver_schema`}.account a
  LEFT JOIN {`catalog`}.{`silver_schema`}.account_owner o
    ON a.universal_id = o.universal_id AND o.owner_seq = 1
  LEFT JOIN {`catalog`}.{`silver_schema`}.property_address pa
    ON a.universal_id = pa.universal_id
  WHERE a.appraisal_year = {year}
    AND a.sptd_code IN ({vals*})
", vals = vacant_sptd, .con = con)

vacant <- DBI::dbGetQuery(con, accounts_sql) |>
  assert_columns(c("ACCOUNT_NUM", "GIS_PARCEL_ID", "SPTD_CODE", "LAND_VAL",
                   "PREV_MKT_VAL", "OWNER_NAME1", "STREET_NUM",
                   "FULL_STREET_NAME", "PROPERTY_CITY", "PROPERTY_ZIPCODE"),
                 where = glue("{silver_schema}.account join"))

# ---- 2. Owner crosswalk -> ownership group ----------------------------------
# Hand-curated public-owner labels. Joined on ACCOUNT_NUM (DCAD account numbers
# persist across vintages); Phase C re-curates for owners new/changed since 2023.
cleanOwners <- read_sheet(ss = crosswalk_sheet, sheet = crosswalk_tab) |>
  assert_columns(c("ACCOUNT_NUM", "OWNERSHIP_GROUP"), where = "owner crosswalk")

publicAccounts <- vacant |>
  left_join(cleanOwners, by = "ACCOUNT_NUM") |>
  filter(!is.na(OWNERSHIP_GROUP))

# Parcels carrying >1 distinct ownership group across their accounts -> MULTIPLE OWNERS
multiParcels <- publicAccounts |>
  group_by(GIS_PARCEL_ID) |>
  summarize(groups = n_distinct(OWNERSHIP_GROUP), .groups = "drop") |>
  filter(groups > 1)

publicClean <- publicAccounts |>
  mutate(OWNERSHIP_GROUP = if_else(GIS_PARCEL_ID %in% multiParcels$GIS_PARCEL_ID,
                                   "MULTIPLE OWNERS", OWNERSHIP_GROUP)) |>
  filter(OWNERSHIP_GROUP %in% keep_groups) |>
  distinct(GIS_PARCEL_ID, .keep_all = TRUE)

# ---- 3. Parcel geometry for the kept parcels --------------------------------
# Pull only the geometry we need (append-only certified snapshot for the chosen
# tax_year), keyed Acct == GIS_PARCEL_ID.
ids <- unique(publicClean$GIS_PARCEL_ID)
geom_sql <- glue_sql("
  SELECT Acct AS GIS_PARCEL_ID, geometry_wkt
  FROM {`bronze_catalog`}.{`bronze_schema`}.{`parcel_table`}
  WHERE tax_year = {parcel_tax_year}
    AND Acct IN ({ids*})
", ids = ids, .con = con)

geom_raw <- DBI::dbGetQuery(con, geom_sql) |>
  assert_columns(c("GIS_PARCEL_ID", "geometry_wkt"), where = parcel_table)

parcels <- geom_raw |>
  filter(!is.na(geometry_wkt)) |>
  mutate(geometry = st_as_sfc(geometry_wkt, crs = crs_planar)) |>
  st_as_sf() |>
  select(GIS_PARCEL_ID)

publicParcel <- parcels |>
  inner_join(publicClean, by = "GIS_PARCEL_ID") |>
  distinct(GIS_PARCEL_ID, .keep_all = TRUE)

# ---- 4. Clip to City of Dallas, then subtract the water/parks mask -----------
boundary <- st_read(boundary_path, quiet = TRUE) |> st_transform(crs_planar)
publicDallas <- publicParcel[st_union(boundary), ]        # keep parcels within the city

if (file.exists(mask_path)) {
  mask <- st_read(mask_path, quiet = TRUE) |> st_transform(crs_planar) |> st_union()
  invtParcels <- st_difference(publicDallas, mask)        # erase water + parks
} else {
  warning(glue("Mask {mask_path} not found (run scripts/build_mask.R). ",
               "Writing WITHOUT the water/parks exclusion."))
  invtParcels <- publicDallas
}

# ---- 5. Popup + write (web CRS 4326 for tiling / MapLibre) -------------------
# Precompute one popup_html property so the front end (and the PMTiles) carry a
# ready-to-render popup; mirrors the fields the 2023 map showed.
invtParcels <- invtParcels |>
  mutate(popup_html = paste0(
    "<b>Account Number: </b>", ACCOUNT_NUM, "<br>",
    "<b>Owner: </b>", OWNERSHIP_GROUP, "<br>",
    "<b>Address: </b>", STREET_NUM, " ", FULL_STREET_NAME, "<br>",
    "<b>City: </b>", PROPERTY_CITY, "<br>",
    "<b>Zip: </b>", PROPERTY_ZIPCODE, "<br>",
    "<b>Land Value: </b>", scales::dollar(LAND_VAL), "<br>",
    "<b>Previous Market Value: </b>", scales::dollar(PREV_MKT_VAL), "<br>",
    "<b>SPTD Code: </b>", SPTD_CODE
  ))

# Spatial ops ran in EPSG:2276 (planar); web tiles + MapLibre need EPSG:4326.
web <- st_transform(invtParcels, 4326)
st_write(web, out_geojson, delete_dsn = TRUE)
message(glue("Wrote {nrow(web)} public vacant parcels ({year}) -> {out_geojson}"))
