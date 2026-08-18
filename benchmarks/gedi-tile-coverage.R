# Do real GEDI shots cluster enough for a pushdown / point-mode fetch to pay?
# The number that decides it is TILE COVERAGE: the fraction of a source's
# COG tiles that hold at least one shot. Low coverage -> fetching only those
# tiles wins. High coverage -> you need the data anyway and bulk windowed
# reads win (measured: per-point reads on a remote COG were 2.8x SLOWER for
# scattered points).
suppressMessages({library(sf); library(gdalraster)})

gedi_files <- c(
  bc_b1 = "/home/hugh/.cache/R/ramet47/bc-cohort/gedi/gedi_b1_l2a_2019-04-01_2025-12-31.rds",
  b1    = "/home/hugh/.cache/R/ramet47/gedi/gedi_b1_l2a_2019-04-01_2025-12-31.rds",
  b2    = "/home/hugh/.cache/R/ramet47/gedi/gedi_b2_l2a_2019-04-01_2023-12-31.rds"
)

# an ESD/AEF-style cube: 10 m source, 1024 px COG tiles (the AEF geometry)
report <- function(nm, path) {
  if (!file.exists(path)) return(invisible(NULL))
  g <- readRDS(path)
  xy <- sf::st_coordinates(sf::st_transform(sf::st_geometry(g), 3857))
  # work in the shots' own UTM-ish metric frame: use their bbox at 10 m
  x0 <- min(xy[, 1]); y0 <- min(xy[, 2])
  w <- diff(range(xy[, 1])); h <- diff(range(xy[, 2]))
  for (res in c(10, 30)) {
    for (tile_px in c(512, 1024)) {
      tile_m <- res * tile_px
      tx <- floor((xy[, 1] - x0) / tile_m)
      ty <- floor((xy[, 2] - y0) / tile_m)
      hit <- length(unique(paste(tx, ty)))
      total <- (floor(w / tile_m) + 1) * (floor(h / tile_m) + 1)
      cat(sprintf(
        "%-6s n=%6d  %2d m / %4d px tiles: %5d of %6.0f tiles hit  = %5.1f%%\n",
        nm, nrow(g), res, tile_px, hit, total, 100 * hit / total))
    }
  }
  cat(sprintf("       bbox %.0f x %.0f km\n\n", w / 1000, h / 1000))
}
for (nm in names(gedi_files)) report(nm, gedi_files[[nm]])
