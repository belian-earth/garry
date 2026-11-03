# lazy_dataset() pointed at a Zarr store's root: GDAL lists the store's
# arrays and places each one, garry keeps those whose extent overlaps the
# grid and reads them as it reads an explicit list of them. Gates: which
# arrays a grid keeps (one zone, across a zone boundary, across the
# equator, overlapping arrays, none), cells identical to the explicit list,
# Zarr v2 and v3 with and without consolidated metadata, nested groups, a
# store of one array, and classed errors that say what to do.

# The source paths a dataset reads, in the order its nodes hold them.
.ds_paths <- function(ds) {
  g <- ds@graph
  nodes <- lapply(graph_ids(g), function(i) graph_get(g, i))
  src <- Filter(function(n) S7::S7_inherits(n, SourceNode), nodes)
  unique(lapply(src, function(n) n@path))[[1L]]
}

# A year of a dataset as one (y, x, band) array.
.year <- function(ds, y = "2022") collect(time_sel(ds, y), distributed = FALSE)

.ref <- function(fx, g, t, b) {
  v <- fx$vals[[g]][t, b, , ] * 1.0
  v[v == -128] <- NaN
  v
}

g_one <- function() {
  grid_spec("EPSG:32632", c(500050, 4599850, 500250, 4599950), res = 10)
}
g_two <- function() {
  grid_spec("EPSG:32632", c(500000, 4599800, 500600, 4600000), res = 10)
}
g_eq <- function() {
  grid_spec("EPSG:32632", c(500000, -100, 500300, 100), res = 10)
}
g_ov <- function() {
  grid_spec("EPSG:32631", c(400000, 2999800, 400400, 3000000), res = 10)
}
g_off <- function() grid_spec("EPSG:4326", c(100, 10, 101, 11), res = 0.01)

test_that("a store's root is told from an array in it and gets what GDAL needs", {
  root <- .zarr_store_root
  want <- 'ZARR:"/vsicurl/https://h/s.zarr"'
  expect_identical(root("https://h/s.zarr"), want)
  expect_identical(root("https://h/s.zarr/"), want)
  expect_identical(root('ZARR:"https://h/s.zarr"'), want)
  expect_identical(root("/vsicurl/https://h/s.zarr"), want)
  expect_identical(root("/data/s.zarr"), 'ZARR:"/data/s.zarr"')
  expect_identical(root("/data/S.ZARR"), 'ZARR:"/data/S.ZARR"')
  expect_identical(root('ZARR:"/data/store"'), 'ZARR:"/data/store"')
  expect_null(root('ZARR:"/data/s.zarr":/utm11/embeddings'))
  expect_null(root("/data/a.tif"))
  expect_null(root("GTI:/data/s.zarr"))
  expect_null(root(c("/data/a.zarr", "/data/b.zarr")))
  expect_identical(
    .zarr_group_path('ZARR:"/vsicurl/https://h/s.zarr":/utm11/embeddings'),
    'ZARR:"/vsicurl/https://h/s.zarr/utm11":/embeddings'
  )
  expect_identical(
    .zarr_group_path('ZARR:"/s.zarr":/n/f/a'),
    'ZARR:"/s.zarr/n/f":/a'
  )
  expect_identical(.zarr_group_path('ZARR:"/s.zarr":/a'), 'ZARR:"/s.zarr":/a')
})

test_that("GDAL lists a store's arrays, in path order, each opened from its group", {
  for (fmt in c("ZARR_V3", "ZARR_V2")) {
    for (cons in c(TRUE, FALSE)) {
      fx <- fixture_zarr_store(fmt, cons)
      found <- gdal_zarr_arrays(.zarr_store_root(fx$store))
      a <- found$arrays
      expect_setequal(found$names, c("emb", "lut"))
      expect_identical(
        a$array,
        sort(c(paste0("/", names(fx$paths), "/emb"), "/other/lut"))
      )
      expect_identical(
        a$path[a$array == "/nest/far/emb"],
        sprintf('ZARR:"%s/nest/far":/emb', fx$store)
      )
      expect_identical(a$crs[a$name == "lut"], "")
      expect_true(all(nzchar(a$crs[a$name == "emb"])))
      # the array's own group places it as the store's root does
      for (g in names(fx$paths)) {
        row <- a[a$array == paste0("/", g, "/emb"), ]
        geo <- .gdal_georef(fx$paths[[g]])
        expect_identical(row$crs, geo$crs)
        expect_identical(
          unname(unlist(row[c("xmin", "ymin", "xmax", "ymax")])),
          geo$extent
        )
      }
      expect_identical(
        gdal_zarr_arrays(.zarr_store_root(fx$store), "lut")$arrays$array,
        "/other/lut"
      )
    }
  }
})

test_that("a grid keeps the arrays whose extents it overlaps", {
  fx <- fixture_zarr_store()
  keeps <- function(grid) {
    expect_message(
      ds <- lazy_dataset(fx$store, grid),
      "Reading [0-9]+ of the 7"
    )
    sub('^ZARR:".*/([^/"]+)":/emb$', "\\1", .ds_paths(ds))
  }
  expect_identical(keeps(g_one()), "utm32")
  expect_identical(keeps(g_two()), c("utm32", "utm33"))
  # a north and a south UTM CRS meet at the equator
  expect_identical(keeps(g_eq()), c("eqn", "eqs"))
  expect_identical(keeps(g_ov()), c("ova", "ovb"))
  # a nested group's array is found as any other
  far <- grid_spec("EPSG:32632", c(200000, 4999900, 200100, 5000000), res = 10)
  expect_identical(keeps(far), "far")
  expect_message(
    lazy_dataset(fx$store, g_two()),
    '"/utm32/emb" and "/utm33/emb"',
    fixed = TRUE
  )
})

test_that("a store reads the cells of the explicit list of its arrays", {
  for (fmt in c("ZARR_V3", "ZARR_V2")) {
    for (cons in c(TRUE, FALSE)) {
      fx <- fixture_zarr_store(fmt, cons)
      cases <- list(
        list(g_one(), "utm32"),
        list(g_two(), c("utm32", "utm33")),
        list(g_eq(), c("eqn", "eqs")),
        list(g_ov(), c("ova", "ovb"))
      )
      for (k in cases) {
        got <- .year(suppressMessages(lazy_dataset(fx$store, k[[1L]])))
        want <- .year(lazy_dataset(unname(fx$paths[k[[2L]]]), k[[1L]]))
        expect_identical(got, want)
      }
    }
  }
  fx <- fixture_zarr_store()
  got <- .year(suppressMessages(lazy_dataset(fx$store, g_one())))
  expect_equal(unname(got[,, 2]), .ref(fx, "utm32", 2, 2)[6:15, 6:25])
})

test_that("where arrays overlap, the later one in path order wins where it holds data", {
  fx <- fixture_zarr_store()
  got <- .year(suppressMessages(lazy_dataset(fx$store, g_ov())))
  a <- .ref(fx, "ova", 2, 1)
  b <- .ref(fx, "ovb", 2, 1)
  # /ovb/emb covers columns 11 to 40, /ova/emb columns 1 to 30
  expect_equal(unname(got[, 1:10, 1]), a[, 1:10])
  want <- b[, 1:20]
  want[1, 1] <- a[1, 11] # ovb's nodata pixel shows ova beneath
  expect_equal(unname(got[, 11:30, 1]), want)
  expect_equal(unname(got[, 31:40, 1]), b[, 21:30])
  # the explicit list in the other order lets ova win instead
  rev <- .year(lazy_dataset(unname(fx$paths[c("ovb", "ova")]), g_ov()))
  expect_equal(unname(rev[, 11:30, 1]), a[, 11:30])
})

test_that("a store of one array reads as that array, whatever its form", {
  store <- fixture_zarr_root("a")
  ref <- collect(
    lazy_dataset(sprintf('ZARR:"%s":/a', store))$b1,
    distributed = FALSE
  )
  v <- outer(1:20, 1:30, function(y, x) 10 + x %% 7 + y %% 3)
  expect_equal(unname(ref), v, ignore_attr = TRUE)
  for (src in list(store, paste0(store, "/"), sprintf('ZARR:"%s"', store))) {
    expect_no_message(ds <- lazy_dataset(src))
    expect_identical(collect(ds$b1, distributed = FALSE), ref)
  }
  expect_error(
    lazy_dataset(store, array = "a"),
    class = "garry_source_error",
    regexp = "single array"
  )
})

test_that("without a grid a store must hold one georeferenced array", {
  fx <- fixture_zarr_store()
  expect_error(
    lazy_dataset(fx$store),
    class = "garry_source_error",
    regexp = "holds 7 .*emb.* arrays, in 4 CRSs"
  )
  # a group of one georeferenced array and a table
  src <- file.path(withr::local_tempdir(), "one.vrt")
  writeLines(
    paste0(
      '<VRTDataset><Group name="/"><Group name="g">',
      '<Dimension name="y" size="2" type="HORIZONTAL_Y" indexingVariable="y"/>',
      '<Dimension name="x" size="3" type="HORIZONTAL_X" indexingVariable="x"/>',
      '<Array name="y"><DataType>Float64</DataType><DimensionRef ref="y"/><NoDataValue>NaN</NoDataValue>',
      '<RegularlySpacedValues start="15" increment="-10"/></Array>',
      '<Array name="x"><DataType>Float64</DataType><DimensionRef ref="x"/><NoDataValue>NaN</NoDataValue>',
      '<RegularlySpacedValues start="5" increment="10"/></Array>',
      '<Array name="v"><DataType>Int16</DataType><DimensionRef ref="y"/><DimensionRef ref="x"/>',
      '<SRS dataAxisToSRSAxisMapping="2,1">EPSG:32632</SRS><NoDataValue>-1</NoDataValue>',
      "<InlineValues>1 2 3 4 5 6</InlineValues></Array>",
      '<Array name="t"><DataType>Int16</DataType><DimensionRef ref="y"/><DimensionRef ref="x"/>',
      "<NoDataValue>-1</NoDataValue><InlineValues>7 8 9 10 11 12</InlineValues></Array>",
      "</Group></Group></VRTDataset>"
    ),
    src
  )
  store <- sub("vrt$", "zarr", src)
  gdalraster::mdim_translate(
    src,
    store,
    output_format = "Zarr",
    creation_options = "FORMAT=ZARR_V3",
    quiet = TRUE
  )
  ds <- lazy_dataset(store)
  expect_identical(.ds_paths(ds), sprintf('ZARR:"%s/g":/v', store))
  expect_equal(
    unname(collect(ds$b1, distributed = FALSE)),
    matrix(c(1, 4, 2, 5, 3, 6), 2),
    ignore_attr = TRUE
  )
})

test_that("store errors are classed and say what to do", {
  fx <- fixture_zarr_store()
  expect_error(
    lazy_dataset(fx$store, g_off()),
    class = "garry_source_error",
    regexp = "None of the 7 .*emb.* arrays of .*ZARR_V3-TRUE.zarr.* overlaps the grid"
  )
  cnd <- tryCatch(lazy_dataset(fx$store, g_off()), error = identity)
  expect_match(
    conditionMessage(cnd),
    "100, 10, 101, 11 (xmin, ymin, xmax, ymax) in EPSG:4326",
    fixed = TRUE
  )
  expect_error(
    lazy_dataset(fx$store, g_one(), array = "nope"),
    class = "garry_source_error",
    regexp = "no array named .*nope.*named .*emb.* and .*lut"
  )
  expect_error(
    lazy_dataset(fx$store, g_one(), array = "lut"),
    class = "garry_source_error",
    regexp = "none of the arrays .* on a map"
  )
  expect_error(
    lazy_dataset(fx$paths[["utm32"]], g_one(), array = "emb"),
    class = "garry_source_error",
    regexp = "not a store's root"
  )
  expect_error(
    lazy_dataset(fx$store, g_one(), array = c("a", "b")),
    class = "garry_source_error",
    regexp = "one array name"
  )
  two <- fixture_zarr_root(c("a", "b"))
  expect_error(
    lazy_dataset(two, g_one()),
    class = "garry_source_error",
    regexp = "arrays of 2 names: .*a.* and .*b.*\\n.*array = \"a\""
  )
  got <- suppressMessages(lazy_dataset(two, g_one(), array = "b"))
  expect_identical(.ds_paths(got), sprintf('ZARR:"%s":/b', two))
  expect_error(
    lazy_dataset(data.frame(asset = "x"), g_one(), assets = "x", array = "emb"),
    class = "garry_source_error",
    regexp = "STAC items have none"
  )
  # a store GDAL cannot open fails as a read, naming it
  gone <- file.path(withr::local_tempdir(), "gone.zarr")
  expect_error(
    .gdal_hushed(lazy_dataset(gone, g_one()), "gone.zarr"),
    class = "garry_read_error",
    regexp = "could not open .*gone.zarr.* as a Zarr store"
  )
})

test_that("a remote store's listing is kept for the session, a local one's is not", {
  fx <- fixture_zarr_store()
  root <- .zarr_store_root(fx$store)
  open <- .gdal_open
  n <- 0L
  testthat::local_mocked_bindings(.gdal_open = function(...) {
    n <<- n + 1L
    open(...)
  })
  a <- gdal_zarr_arrays(root)
  first <- n
  expect_identical(gdal_zarr_arrays(root), a)
  expect_identical(n, 2L * first)
  memo <- .gdal_cache$zarr_stores
  rm(list = ls(memo, all.names = TRUE), envir = memo)
  withr::defer(rm(list = ls(memo, all.names = TRUE), envir = memo))
  testthat::local_mocked_bindings(.gdal_is_remote = function(path) TRUE)
  n <- 0L
  expect_identical(gdal_zarr_arrays(root), a)
  expect_identical(n, first)
  expect_identical(gdal_zarr_arrays(root), a)
  expect_identical(n, first)
  expect_length(ls(memo, all.names = TRUE), 1L)
})

test_that("a grid meets the UTM zones whose extents hold it", {
  # every OlmoEarth zone array: 983,040 m wide from easting 0, northings
  # -9,175,040 to 9,502,720 in its northern UTM CRS
  zones <- sprintf("EPSG:326%02d", 1:60)
  meets <- function(crs, bb) {
    g <- grid_spec(crs, bb, res = 10)
    unname(which(vapply(
      zones,
      function(z) .gdal_grid_meets(g, c(0, -9175040, 983040, 9502720), z),
      NA
    )))
  }
  expect_identical(
    meets("EPSG:32611", c(417280, 5834240, 445440, 5870080)),
    10:12
  )
  expect_identical(
    meets("EPSG:27700", c(528900, 172400, 548900, 182400)),
    30:31
  )
  expect_identical(
    meets("EPSG:32756", c(320000, 6240000, 340000, 6260000)),
    55:56
  )
  # across the antimeridian
  expect_identical(
    meets("EPSG:32601", c(150000, -1960000, 220000, -1900000)),
    c(1L, 60L)
  )
  # the arrays stop short of the pole
  expect_identical(
    meets("EPSG:3031", c(-100000, -100000, 100000, 100000)),
    integer(0)
  )
  # bounds across the antimeridian in a geographic CRS wrap
  g <- grid_spec("EPSG:32601", c(150000, -1960000, 220000, -1900000), res = 10)
  expect_true(.gdal_grid_meets(g, c(179, -18, 180, -17), "EPSG:4326"))
  expect_true(.gdal_grid_meets(g, c(-180, -18, -179, -17), "EPSG:4326"))
  expect_false(.gdal_grid_meets(g, c(0, -18, 1, -17), "EPSG:4326"))
})

# A skip here ends the file, so this block stays last.
local({
  skip_on_cran()
  local_pools(2, 1, gdal_config = TRUE)

  test_that("pooled reads of a store's arrays match the single-process read", {
    fx <- fixture_zarr_store()
    ds <- suppressMessages(lazy_dataset(fx$store, g_two()))
    yr <- time_sel(ds, "2021")
    got <- collect(yr, distributed = TRUE)
    expect_equal(got, collect(yr, distributed = FALSE), tolerance = 0)
    expect_equal(unname(got[, 1:30, 3]), .ref(fx, "utm32", 1, 3))
  })
})
