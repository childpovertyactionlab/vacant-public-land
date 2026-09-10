# One-off: adapt the existing 2023 output to the refreshed pipeline's format so
# the 2023 vintage can be tiled + previewed WITHOUT the warehouse or the owner
# crosswalk. Preserves the published 2023 result as-is (same mask, same owners);
# it only reprojects to EPSG:4326 and adds the popup_html property the new front
# end expects.
#
#   Rscript "scripts/prep_2023.R"  ->  data/public-vacant-land_2023.geojson
#   then: scripts/tile.sh 2023      ->  docs/public-vacant-land_2023.pmtiles
#   then: quarto preview index.qmd  (validates the mapgl map + vintage picker)

library(sf)
library(dplyr)
library(scales)

src <- "data/Public Land in the City of Dallas.geojson"   # original 2023 output (EPSG:2276)
out <- "data/public-vacant-land_2023.geojson"

d <- st_read(src, quiet = TRUE) |>
  mutate(popup_html = paste0(
    "<b>Account Number: </b>", ACCOUNT_NUM, "<br>",
    "<b>Owner: </b>", OWNERSHIP_GROUP, "<br>",
    "<b>Address: </b>", STREET_NUM, " ", FULL_STREET_NAME, "<br>",
    "<b>City: </b>", PROPERTY_CITY, "<br>",
    "<b>Zip: </b>", PROPERTY_ZIPCODE, "<br>",
    "<b>Land Value: </b>", scales::dollar(LAND_VAL), "<br>",
    "<b>Previous Market Value: </b>", scales::dollar(PREV_MKT_VAL), "<br>",
    "<b>SPTD Code: </b>", SPTD_CODE
  )) |>
  # Keep only what the front end uses: OWNERSHIP_GROUP drives layers + counts,
  # popup_html carries the rest. Drops ~80 unused DCAD columns from the tiles.
  select(OWNERSHIP_GROUP, popup_html) |>
  st_transform(4326)

st_write(d, out, delete_dsn = TRUE)
message("Wrote ", nrow(d), " parcels (2023) -> ", out)
