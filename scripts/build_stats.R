# Per-vintage summary for the map -> docs/vintage_stats.json.
#
# Reads each built data/public-vacant-land_<year>.geojson (only vintages present
# are emitted). The front end drives its vintage picker, count cards, lot-size
# filter and time-series chart off this file, so adding a vintage needs no page
# edit.
#
# Counts are precomputed per (ownership group x size band) rather than derived in
# the browser: vector tiles are clipped and simplified per viewport, so counting
# rendered features would undercount at low zoom and change as the user pans. The
# page sums these cells instead, which is exact and works offline.

library(sf)
library(jsonlite)

groups <- c("CITY OF DALLAS", "DALLAS COUNTY", "DART", "DALLAS COLLEGE",
            "DALLAS ISD", "DALLAS HOUSING AUTHORITY", "MULTIPLE OWNERS")
vintages <- c("2023", "2024", "2025", "2026")   # extend freely; missing files are skipped

# Size bands. Cut points are about what the land could hold, not round numbers:
# under 0.1 ac is remnant strip / alley closure, 0.1-0.5 is house-lot scale,
# 0.5-2 a small site, 2-10 a real development parcel, and 10+ is dominated by
# river corridor and levee land that is large by area but not developable.
bands <- list(
  list(id = "lt01",  label = "Under 0.1 ac",  min = 0,   max = 0.1),
  list(id = "lot",   label = "0.1 - 0.5 ac",  min = 0.1, max = 0.5),
  list(id = "small", label = "0.5 - 2 ac",    min = 0.5, max = 2),
  list(id = "site",  label = "2 - 10 ac",     min = 2,   max = 10),
  list(id = "large", label = "10+ ac",        min = 10,  max = Inf)
)
band_of <- function(acres) {
  out <- rep(NA_character_, length(acres))
  for (b in bands) out[is.na(out) & acres >= b$min & acres < b$max] <- b$id
  out[is.na(out)] <- bands[[length(bands)]]$id   # guard the open upper edge
  out
}

vintage_stats <- list()
for (y in vintages) {
  f <- sprintf("data/public-vacant-land_%s.geojson", y)
  if (!file.exists(f)) next
  d <- sf::st_read(f, quiet = TRUE) |> sf::st_drop_geometry()
  if (!"acres" %in% names(d)) {
    stop(sprintf("%s has no `acres` column - rebuild it with the current join script.", f),
         call. = FALSE)
  }
  d$acres <- as.numeric(d$acres)
  d$band  <- band_of(d$acres)

  cells <- list()
  for (g in groups) {
    per_band <- list()
    for (b in bands) {
      k <- d$OWNERSHIP_GROUP == g & d$band == b$id
      per_band[[b$id]] <- list(
        parcels  = sum(k, na.rm = TRUE),
        acres    = round(sum(d$acres[k], na.rm = TRUE), 1),
        land_val = round(sum(as.numeric(d$land_val)[k], na.rm = TRUE))
      )
    }
    cells[[g]] <- per_band
  }

  vintage_stats[[y]] <- list(
    total = list(
      parcels  = nrow(d),
      acres    = round(sum(d$acres, na.rm = TRUE), 1),
      land_val = round(sum(as.numeric(d$land_val), na.rm = TRUE))
    ),
    cells = cells
  )
}
if (!length(vintage_stats)) {
  stop("No data/public-vacant-land_<year>.geojson found - build a vintage first.")
}

out <- list(
  generated = format(Sys.time(), "%Y-%m-%d"),
  bands     = lapply(bands, function(b) list(
                id = b$id, label = b$label,
                min = b$min, max = if (is.infinite(b$max)) NULL else b$max)),
  groups    = groups,
  vintages  = vintage_stats
)

dir.create("docs", showWarnings = FALSE)
write_json(out, "docs/vintage_stats.json", auto_unbox = TRUE, pretty = TRUE, null = "null")
message("Wrote docs/vintage_stats.json for: ", paste(names(vintage_stats), collapse = ", "))

# Reproject the city boundary to WGS84 (EPSG:4326) for the web map. The source
# is in EPSG:6584 (TX North Central, feet); Mapbox GL needs lon/lat.
bnd <- sf::st_read("data/City of Dallas Boundary.geojson", quiet = TRUE) |> sf::st_transform(4326)
sf::st_write(bnd, "docs/city-of-dallas-boundary.geojson", delete_dsn = TRUE, quiet = TRUE)
message("Wrote docs/city-of-dallas-boundary.geojson (EPSG:4326)")
