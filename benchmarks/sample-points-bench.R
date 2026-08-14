# Cost of three routes to the same sampled table, each in a FRESH process
# (no vsicurl cache carry-over, which invalidated the first attempt).
#
#   sample   : garry sample_points (phase 1 -- all chunks compute, no disk)
#   collect  : compute the whole window + extract host-side (status quo)
#   targeted : gdalraster::pixel_extract on the REMOTE COG -- fetches only
#              the tiles holding points, but reads the SOURCE (no graph)
#
# Usage: Rscript sample-bench2.R            (parent)
#        Rscript sample-bench2.R run <method> <n> <clustered>   (internal)
suppressMessages({library(garry); library(gdalraster)})
TILE <- paste0("https://data.source.coop/tge-labs/aef/v1/annual/2021/36S/",
               "xekh5rjs4wg6wb9b4-0000000000-0000000000.tiff")
VSI <- paste0("/vsicurl/", TILE)
BANDS <- c(10L, 11L, 12L)
EXT <- c(520480, 8566400, 582000, 8627920)     # ~61 km, 2048 px at 30 m
NPX <- 2048L

pts_of <- function(n, clustered) {
  set.seed(1)
  if (clustered) {
    x <- stats::runif(n, EXT[1] + 500, EXT[1] + 5500)
    y <- stats::runif(n, EXT[2] + 500, EXT[2] + 5500)
  } else {
    x <- stats::runif(n, EXT[1], EXT[3]); y <- stats::runif(n, EXT[2], EXT[4])
  }
  cbind(x, y)
}

args <- commandArgs(trailingOnly = TRUE)
if (length(args) && args[[1]] == "run") {
  method <- args[[2]]; n <- as.integer(args[[3]])
  clustered <- as.logical(args[[4]])
  xy <- pts_of(n, clustered)
  g <- grid_spec("EPSG:32736", extent = EXT, dims = c(NPX, NPX), dtype = "f32")
  t0 <- proc.time()[["elapsed"]]
  chk <- if (method == "targeted") {
    v <- pixel_extract(VSI, xy, bands = BANDS, interp = "nearest")
    sum(as.matrix(v), na.rm = TRUE)
  } else {
    garry_daemons()
    ds <- lazy_dataset(TILE, g, bands = BANDS)
    v <- if (method == "sample") {
      sample_points(ds, wk::xy(xy[, 1], xy[, 2], crs = "EPSG:32736"))
    } else {
      arr <- collect(ds)                       # then extract host-side
      gt <- g@transform
      cc <- floor((xy[, 1] - gt[1]) / gt[2]) + 1
      rr <- floor((xy[, 2] - gt[4]) / gt[6]) + 1
      ok <- rr >= 1 & rr <= NPX & cc >= 1 & cc <= NPX
      out <- matrix(NA_real_, nrow(xy), 3L)
      for (b in 1:3) out[ok, b] <- arr[, , b][cbind(rr[ok], cc[ok])]
      out
    }
    garry_daemons(0, 0)
    sum(v, na.rm = TRUE)
  }
  cat(sprintf("RUN %s %.2f %.4g\n", method, proc.time()[["elapsed"]] - t0, chk))
  quit(save = "no")
}

# ---- parent -----------------------------------------------------------------
self <- normalizePath(sub("--file=", "", grep("--file=", commandArgs(), value = TRUE)[[1]]))
h <- new(GDALRaster, VSI); sgt <- h$getGeoTransform(); h$close()
tiles <- function(xy) {
  sc <- floor((xy[, 1] - sgt[1]) / sgt[2]); sr <- floor((xy[, 2] - sgt[4]) / sgt[6])
  length(unique(paste(sc %/% 1024, sr %/% 1024)))
}
win_tiles <- {
  cs <- floor((c(EXT[1], EXT[3]) - sgt[1]) / sgt[2]) %/% 1024
  rs <- floor((c(EXT[4], EXT[2]) - sgt[4]) / sgt[6]) %/% 1024
  (diff(range(cs)) + 1) * (diff(range(rs)) + 1)
}
cat(sprintf("window spans %d source tiles per band (1024 px tiles)\n\n", win_tiles))
cat(sprintf("%-22s %-8s %8s %8s %8s\n", "case", "tiles", "sample", "collect", "targeted"))
for (cs in list(list(n = 200L, cl = TRUE), list(n = 200L, cl = FALSE),
                list(n = 5000L, cl = FALSE))) {
  xy <- pts_of(cs$n, cs$cl)
  got <- vapply(c("sample", "collect", "targeted"), function(m) {
    o <- system2("Rscript", c(self, "run", m, cs$n, cs$cl), stdout = TRUE, stderr = FALSE)
    l <- grep("^RUN ", o, value = TRUE)
    if (!length(l)) NA_real_ else as.numeric(strsplit(l, " ")[[1]][[3]])
  }, numeric(1))
  cat(sprintf("n=%-5d %-14s %2d/%-5d %7.1fs %7.1fs %7.1fs\n",
              cs$n, if (cs$cl) "clustered" else "scattered",
              tiles(xy), win_tiles, got[[1]], got[[2]], got[[3]]))
}
