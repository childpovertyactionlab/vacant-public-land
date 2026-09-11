# One-off: adapt the existing 2023 output to the refreshed pipeline's format so
# the 2023 vintage can be tiled + shown WITHOUT the warehouse or the owner
# crosswalk. Preserves the published 2023 result as-is (same mask, same owners);
# it reprojects to EPSG:4326 and keeps the fields the front end needs. The popup
# is built (and styled) in the browser from these fields, not baked in here.
#
#   Rscript scripts/prep_2023.R   ->  data/public-vacant-land_2023.geojson
#   then: scripts/tile.sh 2023     ->  docs/public-vacant-land_2023.pmtiles

library(sf)
library(dplyr)

src <- "data/Public Land in the City of Dallas.geojson"   # original 2023 output (EPSG:2276)
out <- "data/public-vacant-land_2023.geojson"

d <- st_read(src, quiet = TRUE) |>
  # Keep only what the map uses: OWNERSHIP_GROUP drives layers + counts,
  # GIS_PARCEL_ID is the feature id (hover), the rest feed the popup. Numbers stay
  # numeric so the browser can format them. Drops ~75 unused DCAD columns.
  transmute(
    GIS_PARCEL_ID,
    OWNERSHIP_GROUP,
    ACCOUNT_NUM,
    address   = trimws(paste(STREET_NUM, FULL_STREET_NAME)),
    city      = PROPERTY_CITY,
    zip       = substr(as.character(PROPERTY_ZIPCODE), 1, 5),
    sptd      = SPTD_CODE,
    land_val  = as.numeric(LAND_VAL),
    prev_val  = as.numeric(PREV_MKT_VAL)
  ) |>
  st_transform(4326)

st_write(d, out, delete_dsn = TRUE)
message("Wrote ", nrow(d), " parcels (2023) -> ", out)
