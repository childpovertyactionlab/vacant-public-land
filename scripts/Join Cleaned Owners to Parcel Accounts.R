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
library(jsonlite)

# .env -> environment (shell env still wins). See scripts/load_env.R.
source(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])), "load_env.R"))

# ---- Config -----------------------------------------------------------------
# Vintage from the first CLI arg (Rscript join.R 2024) or the VPL_YEAR env var;
# defaults to 2025. scripts/build_all.sh loops the loaded years this way.
.year_arg    <- commandArgs(trailingOnly = TRUE)
year         <- as.integer(if (length(.year_arg) >= 1L) .year_arg[[1L]] else Sys.getenv("VPL_YEAR", "2025"))
parcel_tax_year <- year - 1L                       # newest parcel snapshot (PARCELyyyy -> tax_year-1)
vacant_sptd  <- c("C11", "C12", "C13", "C14")      # DCAD vacant-lot land-use codes
keep_groups  <- c("CITY OF DALLAS", "DART", "DALLAS ISD", "MULTIPLE OWNERS",
                  "DALLAS HOUSING AUTHORITY", "DALLAS COUNTY", "DALLAS COLLEGE")
crs_planar   <- 2276                               # NAD83 TX North Central (US ft)

# Warehouse coordinates — the CPAL Databricks env contract, same variable names
# the evictions `databricks-api` service uses. CONFIRM catalog/schema against the
# live platform: catalogs are parameterized dev_* vs prod in cpal-data-platform,
# so they are env-overridable (defaults are the current prod locations). The
# certified roll lives in the *_car silver schema; parcel geometry lives in bronze.
catalog        <- Sys.getenv("DATABRICKS_CATALOG",        "silver")
silver_schema  <- Sys.getenv("DATABRICKS_SCHEMA",         "silver_tx_dallas_cad_car")  # certified silver
bronze_catalog <- Sys.getenv("DATABRICKS_BRONZE_CATALOG", "bronze")
bronze_schema  <- Sys.getenv("DATABRICKS_BRONZE_SCHEMA",  "bronze_tx_dallas_cad")
parcel_table   <- "parcel_geom_certified"          # cols: Acct, geometry_wkt, tax_year; CRS 2276

# Owner crosswalk. The live Google Sheet is owned by the reviewer and is not
# accessible to this pipeline, so prefer a committed CSV snapshot (reproducible,
# no Google auth). The reviewer re-curates the crosswalk per vintage and drops it
# here as CSV; the sheet read is only a fallback for someone who has access.
crosswalk_rules <- "data/owner_rules.csv"        # preferred: owner-name PATTERN -> group
crosswalk_csv   <- "data/owner_crosswalk_pubDallas.csv"
crosswalk_sheet <- "1_mMM9Smz4LndqW-fFx0O5VuIAyvIG3oLxvUdtMbv9Ys"
crosswalk_tab   <- "pubDallas"                      # cols: ACCOUNT_NUM, OWNERSHIP_GROUP

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
# CPAL standard: Databricks SQL warehouse over ODBC + OAuth. odbc::databricks()
# reads DATABRICKS_HOST + auth (DATABRICKS_TOKEN / OAuth / CLI profile) from the
# environment; the SQL-warehouse HTTP path is built from DATABRICKS_WAREHOUSE_ID
# (override wholesale with DATABRICKS_HTTP_PATH if DE hands you a full path).
#
# Alternative if the warehouse is unreachable from R (the auto-refresh path in
# the plan): have a Databricks job write the filtered result to a UC Volume as
# parquet/geojson and read that here with arrow/sf instead of the two
# dbGetQuery() calls below — this connect block is the only thing that changes.
.warehouse_id <- Sys.getenv("DATABRICKS_WAREHOUSE_ID")
http_path <- Sys.getenv(
  "DATABRICKS_HTTP_PATH",
  if (nzchar(.warehouse_id)) sprintf("/sql/1.0/warehouses/%s", .warehouse_id) else ""
)
if (!nzchar(http_path)) {
  stop("Set DATABRICKS_WAREHOUSE_ID (or DATABRICKS_HTTP_PATH) — no SQL warehouse to connect to.",
       call. = FALSE)
}
# odbc::databricks() only auto-detects the legacy Simba driver; the current
# Databricks ODBC driver (v2, /Library/databricks/...) is invisible to it and the
# call dies in configure_simba(). Connect through the driver explicitly instead.
driver_path <- Sys.getenv("DATABRICKS_ODBC_DRIVER",
                          "/Library/databricks/databricksodbc/lib/libdatabricksodbc.dylib")
if (!file.exists(driver_path)) {
  stop(glue("Databricks ODBC driver not found at {driver_path}. ",
            "Install it or set DATABRICKS_ODBC_DRIVER."), call. = FALSE)
}
dbx_host  <- sub("^https://", "", Sys.getenv("DATABRICKS_HOST"))
dbx_token <- Sys.getenv("DATABRICKS_TOKEN")
if (!nzchar(dbx_token)) {
  # Preferred path: OAuth from the databricks CLI profile (`databricks auth login`).
  prof <- Sys.getenv("DATABRICKS_CONFIG_PROFILE", "DEFAULT")
  raw <- suppressWarnings(system2("databricks", c("auth", "token", "-p", prof),
                                  stdout = TRUE, stderr = FALSE))
  if (length(raw)) {
    dbx_token <- tryCatch(jsonlite::fromJSON(paste(raw, collapse = ""))$access_token,
                          error = function(e) "")
  }
}
if (!nzchar(dbx_token)) {
  stop("No Databricks credential: set DATABRICKS_TOKEN or run `databricks auth login`.",
       call. = FALSE)
}
con <- DBI::dbConnect(odbc::odbc(), driver = driver_path,
                      Host = dbx_host, Port = 443, HTTPPath = http_path,
                      SSL = 1, ThriftTransport = 2,
                      AuthMech = 11, Auth_Flow = 0, Auth_AccessToken = dbx_token,
                      # The driver defaults string columns to 255 chars, which
                      # silently truncates parcel WKT (up to ~694k chars) into
                      # corrupt geometry. 65535 is the driver maximum; anything
                      # longer is handled by the chunked fetch in section 3.
                      DefaultStringColumnLength = 65535)
on.exit(DBI::dbDisconnect(con), add = TRUE)

# ---- 1. Vacant public-candidate accounts ------------------------------------
# One row per vacant account for the vintage, with owner name (for the crosswalk)
# and situs address (for popups). account / account_owner / property_address all
# share universal_id within an appraisal_year partition.
# Vacancy = SPTD C11-C14 (land-use intent) AND improvement_value = 0 (no taxable
# structure). improvement_value is the modern structure-absence signal newer CPAL
# work uses (has_building in silver; the SB 15 "undeveloped" test in zoning-analysis);
# combining with SPTD drops C11-C14 lots that actually carry a structure.
accounts_sql <- glue_sql("
  SELECT a.source_account_id      AS ACCOUNT_NUM,
         a.gis_parcel_id          AS GIS_PARCEL_ID,
         a.sptd_code              AS SPTD_CODE,
         a.improvement_value      AS IMPR_VAL,
         a.land_value             AS LAND_VAL,
         a.prev_market_value      AS PREV_MKT_VAL,
         o.owner_name             AS OWNER_NAME1,
         pa.street_num            AS STREET_NUM,
         pa.full_street_name      AS FULL_STREET_NAME,
         pa.property_city         AS PROPERTY_CITY,
         pa.property_zipcode      AS PROPERTY_ZIPCODE
  FROM {`catalog`}.{`silver_schema`}.account a
  LEFT JOIN {`catalog`}.{`silver_schema`}.account_owner o
    ON a.universal_id = o.universal_id AND a.appraisal_year = o.appraisal_year AND o.owner_seq = 1
  LEFT JOIN {`catalog`}.{`silver_schema`}.property_address pa
    ON a.universal_id = pa.universal_id AND a.appraisal_year = pa.appraisal_year
  WHERE a.appraisal_year = {year}
    AND a.sptd_code IN ({vals*})
    AND a.improvement_value = 0
", vals = vacant_sptd, .con = con)

vacant <- DBI::dbGetQuery(con, accounts_sql) |>
  assert_columns(c("ACCOUNT_NUM", "GIS_PARCEL_ID", "SPTD_CODE", "IMPR_VAL", "LAND_VAL",
                   "PREV_MKT_VAL", "OWNER_NAME1", "STREET_NUM",
                   "FULL_STREET_NAME", "PROPERTY_CITY", "PROPERTY_ZIPCODE"),
                 where = glue("{silver_schema}.account join"))

# ---- 2. Owner crosswalk -> ownership group ----------------------------------
# Hand-curated public-owner labels, joined on ACCOUNT_NUM (DCAD account numbers
# persist across vintages). Prefer the committed CSV; fall back to the live sheet.
# Owner NAME is the durable key, not ACCOUNT_NUM: an account-keyed snapshot
# silently drops parcels that go vacant or change hands in a later vintage.
#
# Matching is by PATTERN, not exact name, because DCAD re-truncates and misspells
# owner names every vintage — "DALLAS HOUSING ACQUISITION &" was 83 parcels in
# 2023 and 7 in 2026 while "... & DEV CORP" moved the other way, and the city
# appears as "DALLAS CITY OF", "DALLAS CITY  OF", "DALLAS C ITY OF" and
# "DALLAS CITY OF ET AL". Exact-name matching leaked parcels on every refresh.
#
# Names are reduced to an alphanumeric-only key before matching, which collapses
# all whitespace and punctuation noise ("DALLAS C ITY OF" -> "DALLASCITYOF"), and
# rules are applied in priority order, first match wins. Exclusion rules
# (__EXCLUDE__) run first so private entities that merely contain a public name
# (Dallas County Audubon, Dallas City Homes Inc) are rejected before the broad
# prefix rules can claim them.
norm_owner <- function(x) gsub("\\s+", " ", trimws(toupper(x)))
owner_key  <- function(x) gsub("[^A-Z0-9]", "", toupper(x))

classify_owners <- function(names_norm, rules) {
  rules <- rules[order(rules$priority), , drop = FALSE]
  uniq <- unique(names_norm)
  key  <- owner_key(uniq)
  out  <- rep(NA_character_, length(uniq))
  for (i in seq_len(nrow(rules))) {
    todo <- is.na(out)
    if (!any(todo)) break
    hit <- todo & grepl(rules$pattern[[i]], key, perl = TRUE)
    out[hit] <- rules$ownership_group[[i]]
  }
  out[!is.na(out) & out == "__EXCLUDE__"] <- NA_character_
  unname(stats::setNames(out, uniq)[names_norm])
}

publicAccounts <- if (file.exists(crosswalk_rules)) {
  message("Reading owner pattern rules from ", crosswalk_rules)
  rules <- readr::read_csv(crosswalk_rules, show_col_types = FALSE) |>
    assert_columns(c("priority", "pattern", "ownership_group"),
                   where = "owner pattern rules")
  matched <- vacant |>
    mutate(.owner_norm = norm_owner(OWNER_NAME1),
           OWNERSHIP_GROUP = classify_owners(.owner_norm, rules))

  # Surface public-looking owners no rule covers, so the crosswalk can be extended
  # deliberately instead of silently under-counting.
  unmatched <- matched |>
    filter(is.na(OWNERSHIP_GROUP),
           grepl("DALLAS|CITY|COUNTY|DART|ISD|HOUSING|COLLEGE|TRANSIT",
                 .owner_norm)) |>
    count(.owner_norm, sort = TRUE)
  if (nrow(unmatched)) {
    message("Public-looking owner names with NO crosswalk rule (top 15):")
    print(utils::head(as.data.frame(unmatched), 15))
  }

  matched |> select(-.owner_norm) |> filter(!is.na(OWNERSHIP_GROUP))
} else {
  # NOTE the parentheses: R's native pipe binds tighter than `else`, so
  # `if (c) {A} else {B} |> f()` applies f only to the else branch. Without them
  # the schema contract silently skipped the committed-CSV path.
  cleanOwners <- (if (file.exists(crosswalk_csv)) {
    message("Reading account-keyed owner crosswalk from ", crosswalk_csv)
    readr::read_csv(crosswalk_csv, show_col_types = FALSE)
  } else {
    message("No ", crosswalk_csv, " found; reading the live Google Sheet (needs access). ",
            "Ask the reviewer for a re-curated CSV to make the build reproducible.")
    read_sheet(ss = crosswalk_sheet, sheet = crosswalk_tab)
  }) |>
    assert_columns(c("ACCOUNT_NUM", "OWNERSHIP_GROUP"), where = "owner crosswalk")

  vacant |>
    left_join(cleanOwners, by = "ACCOUNT_NUM") |>
    filter(!is.na(OWNERSHIP_GROUP))
}

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

# Parcel WKT routinely exceeds any ODBC string-column ceiling (max seen ~694k
# chars), and an over-long value comes back truncated -> "OGR: Corrupt data".
# Fetch it in fixed-width chunks sized under the driver limit and reassemble in
# R. Chunk count is derived from the actual data so it self-adjusts per vintage.
chunk_len <- 30000L
max_len <- DBI::dbGetQuery(con, glue_sql("
  SELECT COALESCE(MAX(LENGTH(geometry_wkt)), 0) AS max_len
  FROM {`bronze_catalog`}.{`bronze_schema`}.{`parcel_table`}
  WHERE tax_year = {parcel_tax_year}
    AND Acct IN ({ids*})
", ids = ids, .con = con))$max_len
n_chunks <- max(1L, as.integer(ceiling(max_len / chunk_len)))
message(glue("Parcel WKT max length {max_len} chars -> {n_chunks} chunk(s) of {chunk_len}"))

chunk_sql <- paste(
  sprintf("SUBSTRING(geometry_wkt, %d, %d) AS wkt_%02d",
          (seq_len(n_chunks) - 1L) * chunk_len + 1L, chunk_len, seq_len(n_chunks)),
  collapse = ",\n         ")

geom_sql <- glue_sql("
  SELECT Acct AS GIS_PARCEL_ID,
         ", glue::glue_sql_collapse(chunk_sql), "
  FROM {`bronze_catalog`}.{`bronze_schema`}.{`parcel_table`}
  WHERE tax_year = {parcel_tax_year}
    AND Acct IN ({ids*})
", ids = ids, .con = con)

geom_raw <- DBI::dbGetQuery(con, geom_sql) |>
  assert_columns(c("GIS_PARCEL_ID", "wkt_01"), where = parcel_table)

wkt_cols <- grep("^wkt_", names(geom_raw), value = TRUE)
geom_raw$geometry_wkt <- do.call(paste0, c(
  lapply(geom_raw[wkt_cols], function(x) ifelse(is.na(x), "", x)), list(collapse = NULL)))

# Any WKT that still fails to parse is dropped loudly rather than silently.
parsed <- lapply(geom_raw$geometry_wkt, function(w) {
  tryCatch(st_as_sfc(w, crs = crs_planar)[[1]], error = function(e) NULL)
})
bad <- vapply(parsed, is.null, logical(1))
if (any(bad)) {
  warning(glue("Dropped {sum(bad)} parcel(s) with unparseable WKT: ",
               "{toString(utils::head(geom_raw$GIS_PARCEL_ID[bad], 10))}"))
}

parcels <- st_as_sf(
  data.frame(GIS_PARCEL_ID = geom_raw$GIS_PARCEL_ID[!bad], stringsAsFactors = FALSE),
  geometry = st_sfc(parsed[!bad], crs = crs_planar)
)

publicParcel <- parcels |>
  inner_join(publicClean, by = "GIS_PARCEL_ID") |>
  distinct(GIS_PARCEL_ID, .keep_all = TRUE)

# ---- 4. Clip to City of Dallas, then subtract the water/parks mask -----------
boundary <- st_read(boundary_path, quiet = TRUE) |> st_transform(crs_planar)
publicDallas <- publicParcel[st_union(boundary), ]        # keep parcels within the city

# Default is SKIP. The reconstructed water/parks mask is much broader than the
# retired Dropbox layer (it erases 12.6% of the parcels the published 2023 map
# kept), so applying it must be a deliberate opt-in: VPL_SKIP_MASK=0. Defaulting
# the other way silently regenerates a materially different dataset for anyone
# who has run build_mask.R once and whose .env predates this flag.
apply_mask <- identical(tolower(Sys.getenv("VPL_SKIP_MASK", "1")), "0")
if (apply_mask && file.exists(mask_path)) {
  message(glue("VPL_SKIP_MASK=0 — APPLYING the water/parks mask from {mask_path}. ",
               "This erases a materially different set of parcels than the published ",
               "map; see the mask note in README.md."))
  mask <- st_read(mask_path, quiet = TRUE) |> st_transform(crs_planar) |> st_union()
  invtParcels <- st_difference(publicDallas, mask)        # erase water + parks
} else if (!apply_mask) {
  message(glue("Writing WITHOUT the water/parks exclusion (default) ",
               "(mask {ifelse(file.exists(mask_path), 'present but skipped', 'not built')})."))
  invtParcels <- publicDallas
} else {
  warning(glue("Mask {mask_path} not found (run scripts/build_mask.R). ",
               "Writing WITHOUT the water/parks exclusion."))
  invtParcels <- publicDallas
}

# ---- 5. Trim to the map's fields + write (web CRS 4326 for tiling) -----------
# The browser builds and styles the popup from these fields (no baked HTML).
#
# `acres` is computed here, while the layer is still in the planar CRS (2276,
# US survey feet) — area measured on 4326 degrees would be meaningless. Parcel
# count alone is a poor summary of this inventory: lot size spans four orders of
# magnitude, and the front end uses `acres` to let people cut the map to lots of
# a usable size.
invtParcels <- invtParcels |>
  mutate(acres = round(as.numeric(st_area(geometry)) / 43560, 3)) |>
  transmute(
    GIS_PARCEL_ID,
    OWNERSHIP_GROUP,
    ACCOUNT_NUM,
    address  = trimws(paste(STREET_NUM, FULL_STREET_NAME)),
    city     = PROPERTY_CITY,
    zip      = substr(as.character(PROPERTY_ZIPCODE), 1, 5),
    sptd     = SPTD_CODE,
    land_val = as.numeric(LAND_VAL),
    prev_val = as.numeric(PREV_MKT_VAL),
    acres
  )

# Spatial ops ran in EPSG:2276 (planar); web tiles need EPSG:4326.
web <- st_transform(invtParcels, 4326)
st_write(web, out_geojson, delete_dsn = TRUE)
message(glue("Wrote {nrow(web)} public vacant parcels ({year}) -> {out_geojson}"))
