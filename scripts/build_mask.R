# Rebuild the water + parks exclusion mask from open data.
#
# Replaces the original Dropbox Data.gdb layer "Dallas_MaskLayer_WaterParks",
# which is no longer available. The mask is dissolved to a single geometry and
# subtracted from the public vacant parcels in
# "Join Cleaned Owners to Parcel Accounts.R" via st_difference() — same operation
# the 2023 pipeline used, just with a reproducible, documented source.
#
# Output: data/mask_water_parks.gpkg (EPSG:2276, single dissolved feature).
# Gitignored (regenerable); rebuild by running this script.
#
# SOURCING NOTE (safety): fetch one source at a time. Prefer pre-downloading each
# file with curl from a plain shell and reading the LOCAL copy here, rather than
# fanning out HTTP from R. The *_src values below accept either a local path or a
# single URL. CONFIRM the endpoints against current open-data portals before use.

library(sf)
library(dplyr)
library(glue)

source(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])), "load_env.R"))

# ---- Config -----------------------------------------------------------------
crs_planar <- 2276                                  # match the parcel layer
out_path   <- "data/mask_water_parks.gpkg"
boundary_path <- "data/City of Dallas Boundary.geojson"   # clip extent (+ buffer)
clip_buffer_ft <- 5280                              # 1 mi buffer so edge water/parks still cut

# Water bodies. Options (pick one, document which): USGS NHD waterbodies for the
# Dallas area, or the City/County open-data hydrography layer. CONFIRM URL/path.
water_src <- Sys.getenv("MASK_WATER_SRC", "data/_mask_src/water.geojson")

# Park boundaries. City of Dallas Park & Recreation "Park Boundaries" open-data
# layer (ArcGIS FeatureServer GeoJSON export) or a local download. CONFIRM.
parks_src <- Sys.getenv("MASK_PARKS_SRC", "data/_mask_src/parks.geojson")

# ---- Load + normalize one source at a time ----------------------------------
read_layer <- function(src, label) {
  if (!nzchar(src)) stop(glue("No source configured for {label}"), call. = FALSE)
  message(glue("Reading {label} from {src}"))
  st_read(src, quiet = TRUE) |>
    st_transform(crs_planar) |>
    st_make_valid() |>
    st_geometry()            # geometry only; attributes are irrelevant to a mask
}

water <- read_layer(water_src, "water")
parks <- read_layer(parks_src, "parks")

# ---- Dissolve to a single mask geometry, clipped to the city + buffer --------
boundary <- st_read(boundary_path, quiet = TRUE) |>
  st_transform(crs_planar) |>
  st_union() |>
  st_buffer(clip_buffer_ft)

mask <- c(st_union(water), st_union(parks)) |>
  st_union() |>
  st_intersection(boundary) |>
  st_make_valid()

mask_sf <- st_sf(
  mask_id    = 1L,
  components = "water+parks",
  built_from = glue("water={basename(water_src)}; parks={basename(parks_src)}"),
  crs_epsg   = crs_planar,
  geometry   = st_sfc(mask, crs = crs_planar)
)

# ---- Write + report ----------------------------------------------------------
st_write(mask_sf, out_path, delete_dsn = TRUE)
area_sqmi <- as.numeric(units::set_units(st_area(mask_sf), "mi^2"))
message(glue("Wrote water/parks mask -> {out_path} ({round(area_sqmi, 1)} sq mi excluded)"))
