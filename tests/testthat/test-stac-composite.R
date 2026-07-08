# Decision D18 lock (discovery half): items rectangularise into the
# source table; filters and slicing act on the table; the table becomes
# the GTI index; lazy_stac_stack composes offline. Fabricated items over
# local tiles keep the gate deterministic; live-network smoke is
# env-gated (GARRY_RUN_NETWORK=1).

skip_if_not_installed("anvl")

# Fabricate a doc_items-shaped list over the three local stack fixtures
# (two tiles per date: west/east half of the 50x40 EPSG:3857 grid).
.fake_items <- function() {
  paths <- vapply(1:3, function(i) {
    file.path(tempdir(), sprintf("garry-fixture-t%d.tif", i))
  }, character(1))
  # Ensure fixtures exist (created by test-stack.R helpers if run first).
  if (!all(file.exists(paths))) {
    for (i in 1:3) {
      f <- paths[[i]]
      if (file.exists(f)) next
      ds <- gdalraster::create("GTiff", f, 50, 40, 1, "Float32",
                               return_obj = TRUE)
      ds$setGeoTransform(c(0, 10, 0, 400, 0, -10))
      ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
      set.seed(100 + i)
      m <- matrix(runif(50 * 40), 40, 50) + i
      if (i == 2) m[5:8, 10:12] <- NaN
      ds$write(1, 0, 0, 50, 40, as.numeric(t(m)))
      ds$close()
    }
  }
  b <- gdalraster::transform_bounds(c(0, 0, 500, 400), "EPSG:3857",
                                    "EPSG:4326")
  dates <- c("2023-01-05T01:00:00Z", "2023-01-15T01:00:00Z",
             "2023-02-05T01:00:00Z")
  feats <- lapply(1:3, function(i) {
    list(
      id = sprintf("item-%d", i),
      bbox = as.list(b),
      properties = list(datetime = dates[[i]],
                        `eo:cloud_cover` = c(5, 60, 12)[[i]]),
      assets = list(B1 = list(href = paths[[i]]))
    )
  })
  list(features = feats)
}

test_that("stac_sources rectangularises items", {
  src <- stac_sources(.fake_items())
  expect_identical(nrow(src), 3L)
  expect_identical(src$asset, rep("B1", 3))
  expect_true(all(file.exists(src$location)))
  expect_identical(src$cloud_cover, c(5, 60, 12))
  expect_false(is.unsorted(src$datetime))
})

test_that("table filters: cloud cover, duplicates, slices", {
  src <- stac_sources(.fake_items())
  expect_identical(nrow(stac_filter_cloud(src, 50)), 2L)

  dup <- rbind(src, src[1, ])
  expect_identical(nrow(stac_drop_duplicates(dup)), 3L)

  sl <- stac_time_slices(src, "day")
  expect_identical(sl$slice,
                   c("2023-01-05", "2023-01-15", "2023-02-05"))
  expect_identical(unique(stac_time_slices(src, "month")$slice),
                   c("2023-01", "2023-02"))
})

test_that("solar_day groups by local overpass date (gap 8)", {
  base <- stac_sources(.fake_items())[rep(1L, 3L), , drop = FALSE]

  # HLS-at-144E shape: a late-UTC overpass belongs to the NEXT local
  # day; an early-UTC one to the same day. 144.3E -> +9.62 h.
  base$datetime <- c("2023-06-15T00:16:42.336Z",   # 09:54 local solar
                     "2023-06-15T14:21:00Z",       # 23:59 local solar
                     "2023-06-15T14:24:00Z")       # 00:02 NEXT local day
  sl <- stac_time_slices(base, "solar_day", lon = 144.3)
  expect_identical(sl$slice, c("2023-06-15", "2023-06-15", "2023-06-16"))
  # UTC "day" puts all three in one slice: the difference solar_day fixes.
  expect_identical(unique(stac_time_slices(base, "day")$slice),
                   "2023-06-15")

  # Antimeridian scene (179E, +11.93 h): one overpass, two UTC dates,
  # ONE solar day.
  base$datetime <- c("2023-06-15T23:58:00Z", "2023-06-16T00:02:00Z",
                     "2023-06-16T00:05:00Z")
  sl <- stac_time_slices(base, "solar_day", lon = 179)
  expect_identical(unique(sl$slice), "2023-06-16")
  expect_identical(length(unique(stac_time_slices(base, "day")$slice)), 2L)

  # Default lon: circular mean of footprint centres straddling the
  # antimeridian must land near 180, not 0.
  base$xmin <- c(178.5, 178.5, -180); base$xmax <- c(180, 180, -178.5)
  sl <- stac_time_slices(base, "solar_day")
  expect_identical(unique(sl$slice), "2023-06-16")

  # Offset datetimes (explicit +00:00) parse too.
  base$datetime <- rep("2023-06-15T10:00:00+00:00", 3L)
  expect_identical(unique(stac_time_slices(base, "solar_day",
                                           lon = 0)$slice),
                   "2023-06-15")

  expect_error(stac_time_slices(base, "solar_day", lon = NaN))
})

test_that("http hrefs gain the vsicurl prefix", {
  it <- .fake_items()
  it$features[[1]]$assets$B1$href <- "https://example.com/x.tif"
  src <- stac_sources(it)
  expect_identical(src$location[[1]], "/vsicurl/https://example.com/x.tif")
})

test_that("lazy_stac_stack composes a median through GTI slices", {
  src <- stac_sources(.fake_items())
  grid <- gdal_grid_spec(src$location[[1]])$grid   # native 3857 grid

  st <- lazy_stac_stack(src, grid, asset = "B1")
  expect_identical(st$slices,
                   c("2023-01-05", "2023-01-15", "2023-02-05"))
  expect_identical(unname(st$stack@grid@dims[["t"]]), 3L)

  old <- options(garry.chunk_target_px = 300)
  on.exit(options(old))
  med <- collect(reduce_over(st$stack, "median", "t", nan_rm = TRUE))

  layers <- lapply(src$location, function(f)
    gdal_read_window(f, 1L, 0L, 0L, 50L, 40L))
  arr <- g_stack(layers)
  want <- apply(arr, c(2, 3), function(v) {
    m <- median(v, na.rm = TRUE); if (is.na(m)) NaN else m
  })
  expect_identical(is.nan(med), is.nan(want))
  ok <- !is.nan(want)
  expect_equal(med[ok], want[ok], tolerance = 1e-5)
})

test_that("the full benchmark shape runs: mask -> stack -> median", {
  # vrtility-benchmark miniature: per-slice QA masking (threshold in
  # place of an Fmask decode), median composite, written to GTiff.
  src <- stac_sources(.fake_items())
  grid <- gdal_grid_spec(src$location[[1]])$grid
  st <- lazy_stac_stack(src, grid, asset = "B1")

  masked <- lapply(seq_along(st$slices), function(i) {
    lr <- lazy_source(paste0("GTI:", st$index),
                      graph = graph_new(),
                      open_options = gti_open_options(
                        grid,
                        filter = sprintf("slice = '%s'", st$slices[[i]]),
                        sort_field = "datetime"))
    id <- graph_add(lr@graph, MapNode, parents = lr@node_id,
                    grid = lr@grid,
                    fn = function(x) {
                      frac <- x - g_cast(x, "i32")
                      g_ifelse(frac > 0.9, NaN, x)
                    })
    LazyRaster(graph = lr@graph, node_id = id, grid = lr@grid)
  })
  comp <- reduce_over(lazy_stack(masked), "median", "t", nan_rm = TRUE)
  outfile <- tempfile(fileext = ".tif")
  collect(comp, path = outfile)

  layers <- lapply(src$location, function(f) {
    m <- gdal_read_window(f, 1L, 0L, 0L, 50L, 40L)
    frac <- m - trunc(m)
    m[!is.nan(m) & frac > 0.9] <- NaN
    m
  })
  arr <- g_stack(layers)
  want <- apply(arr, c(2, 3), function(v) {
    md <- median(v, na.rm = TRUE); if (is.na(md)) NaN else md
  })
  got <- gdal_read_window(outfile, 1L, 0L, 0L, 50L, 40L)
  ok <- !is.nan(want)
  expect_equal(got[ok], want[ok], tolerance = 1e-5)
})

test_that("live MPC query smoke (network, env-gated)", {
  skip_if(!nzchar(Sys.getenv("GARRY_RUN_NETWORK")),
          "set GARRY_RUN_NETWORK=1 to run")
  skip_if_not_installed("rstac")

  its <- stac_query(
    bbox = c(144.13, -7.725, 144.2, -7.68),
    stac_source = "https://planetarycomputer.microsoft.com/api/stac/v1/",
    collection = "hls2-s30",
    start_date = "2023-01-01",
    end_date = "2023-01-31")
  src <- stac_sources(its, assets = c("B04", "Fmask"))
  expect_gt(nrow(src), 0L)
  expect_true(all(grepl("^/vsicurl/", src$location)))
  expect_true(all(c("B04", "Fmask") %in% src$asset))
})
