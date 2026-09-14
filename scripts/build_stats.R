# Per-vintage counts for the map's header cards -> docs/vintage_stats.json.
# Reads each built data/public-vacant-land_<year>.geojson (only vintages present
# are emitted), counts total + by ownership group. The front end drives its
# vintage picker and cards off this file, so adding 2026 needs no page edit.

library(sf)
library(jsonlite)

groups <- c("CITY OF DALLAS", "DALLAS COUNTY", "DART", "DALLAS COLLEGE",
            "DALLAS ISD", "DALLAS HOUSING AUTHORITY", "MULTIPLE OWNERS")
vintages <- c("2023", "2024", "2025", "2026")   # extend freely; missing files are skipped

stats <- list()
for (y in vintages) {
  f <- sprintf("data/public-vacant-land_%s.geojson", y)
  if (!file.exists(f)) next
  d <- sf::st_read(f, quiet = TRUE) |> sf::st_drop_geometry()
  by_group <- sapply(groups, function(g) sum(d$OWNERSHIP_GROUP == g, na.rm = TRUE))
  stats[[y]] <- list(total = nrow(d), by_group = as.list(by_group))
}
if (!length(stats)) stop("No data/public-vacant-land_<year>.geojson found — build a vintage first.")

dir.create("docs", showWarnings = FALSE)
write_json(stats, "docs/vintage_stats.json", auto_unbox = TRUE, pretty = TRUE)
message("Wrote docs/vintage_stats.json for: ", paste(names(stats), collapse = ", "))

# Reproject the city boundary to WGS84 (EPSG:4326) for the web map. The source
# is in EPSG:6584 (TX North Central, feet); MapLibre needs lon/lat.
bnd <- sf::st_read("data/City of Dallas Boundary.geojson", quiet = TRUE) |> sf::st_transform(4326)
sf::st_write(bnd, "docs/city-of-dallas-boundary.geojson", delete_dsn = TRUE, quiet = TRUE)
message("Wrote docs/city-of-dallas-boundary.geojson (EPSG:4326)")
