# group_by_time() partitions a dataset's slices into calendar periods so a
# following reduce_over(over = "t") builds one composite per group (a year of
# daily imagery -> twelve monthly composites), materialised by collect() as a
# named list or one file per group.

# One single-band GeoTIFF per date; returns a stac_sources()-shaped table.
.gbt_sources <- function(dates, vals, asset = "V") {
  b <- gdalraster::transform_bounds(c(0, 0, 80, 60), "EPSG:3857", "EPSG:4326")
  do.call(rbind, lapply(seq_along(dates), function(i) {
    f <- file.path(tempdir(), sprintf("gbt-%s-%d.tif", asset, i))
    d <- gdalraster::create("GTiff", f, 8, 6, 1, "Float32", return_obj = TRUE)
    d$setGeoTransform(c(0, 10, 0, 60, 0, -10))
    d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    d$write(1, 0, 0, 8, 6, rep(vals[[i]], 48)); d$close()
    data.frame(item_id = sprintf("%s-i%d", asset, i), asset = asset, location = f,
               datetime = paste0(dates[[i]], "T00:00:00Z"), cloud_cover = 0,
               xmin = b[[1]], ymin = b[[2]], xmax = b[[3]], ymax = b[[4]],
               row.names = NULL)
  }))
}

test_that(".time_group truncates slice names by period", {
  s <- c("2023-01-05", "2023-03-20", "2023-11-02")
  expect_equal(garry:::.time_group(s, "month"), c("2023-01", "2023-03", "2023-11"))
  expect_equal(garry:::.time_group(s, "year"), rep("2023", 3))
  expect_equal(garry:::.time_group(s, "quarter"), c("2023-Q1", "2023-Q1", "2023-Q4"))
})

test_that("group_by_time partitions slices by period", {
  src <- .gbt_sources(c("2023-01-05", "2023-01-20", "2023-02-05", "2023-03-05"),
                      c(1, 2, 3, 4))
  grid <- gdal_grid_spec(src$location[[1L]])$grid
  ds <- lazy_dataset(src, grid, assets = "V")            # granularity "day" -> 4 slices
  expect_length(ds@bands$V, 4L)

  g <- group_by_time(ds, "month")
  expect_true(S7::S7_inherits(g, garry:::LazyDatasetGroups))
  expect_equal(names(g@groups), c("2023-01", "2023-02", "2023-03"))
  expect_length(g@groups[["2023-01"]]@bands$V, 2L)       # Jan has 2 slices
  expect_length(g@groups[["2023-02"]]@bands$V, 1L)

  expect_equal(names(group_by_time(ds, "year")@groups), "2023")
  # a custom mapping: group by day-of-month string
  gc <- group_by_time(ds, function(s) substr(s, 9L, 10L))
  expect_setequal(names(gc@groups), c("05", "20"))
})

test_that("group_by_time |> reduce_over builds one composite per month", {
  skip_if_not_installed("anvl")
  src <- .gbt_sources(
    c("2023-01-05", "2023-01-20", "2023-02-05", "2023-02-20", "2023-03-05", "2023-03-20"),
    c(10, 20, 100, 200, 5, 15))
  grid <- gdal_grid_spec(src$location[[1L]])$grid
  ds <- lazy_dataset(src, grid, assets = "V")

  comps <- ds |> group_by_time("month") |> reduce_over("median", "t")
  expect_true(S7::S7_inherits(comps, garry:::LazyDatasetGroups))

  res <- collect(comps)
  expect_named(res, c("2023-01", "2023-02", "2023-03"))
  expect_equal(unname(res[["2023-01"]][1, 1]), 15,  tolerance = 1e-4)   # median(10, 20)
  expect_equal(unname(res[["2023-02"]][1, 1]), 150, tolerance = 1e-4)   # median(100, 200)
  expect_equal(unname(res[["2023-03"]][1, 1]), 10,  tolerance = 1e-4)   # median(5, 15)
})

test_that("collect writes one file per group via a {group} placeholder", {
  skip_if_not_installed("anvl")
  src <- .gbt_sources(c("2023-01-05", "2023-02-05"), c(1, 2))
  grid <- gdal_grid_spec(src$location[[1L]])$grid
  comps <- lazy_dataset(src, grid, assets = "V") |>
    group_by_time("month") |> reduce_over("median", "t")

  tmpl <- file.path(tempdir(), "comp_{group}.tif")
  out <- collect(comps, path = tmpl, nodata = -9999)
  expect_named(out, c("2023-01", "2023-02"))
  expect_true(all(file.exists(out)))
  expect_match(out[["2023-01"]], "comp_2023-01\\.tif$")
})

test_that("ragged bands: a band absent in a group is dropped from that group", {
  # V spans Jan+Feb; W only Feb. Grouping by month -> Jan has V only, Feb has both.
  v <- .gbt_sources(c("2023-01-05", "2023-02-05"), c(1, 2), asset = "V")
  w <- .gbt_sources(c("2023-02-10"), c(9), asset = "W")
  src <- stac_merge(v, w)
  grid <- gdal_grid_spec(src$location[[1L]])$grid
  g <- lazy_dataset(src, grid, assets = c("V", "W")) |> group_by_time("month")
  expect_equal(names(g@groups[["2023-01"]]@bands), "V")          # W absent in Jan
  expect_setequal(names(g@groups[["2023-02"]]@bands), c("V", "W"))
})
