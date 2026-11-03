# lazy_dataset() pointed at a Zarr store's root: garry lists the store's
# arrays from its consolidated metadata (else GDAL lists them), takes each
# one's CRS and extent from its zarr-conventions attributes (else GDAL
# gives them), keeps those that overlap the grid and reads them as an
# explicit list of them, GDAL checked against what the store declares.
# Gates: which arrays a grid keeps and in what order, cells identical to
# the explicit list, Zarr v2 and v3, declared and GDAL-placed arrays,
# GDAL's disagreement with a declaration, arrays with no CRS named, a store
# of one array, the remote listing kept, and classed errors that say what
# to do.

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

# fixture_zarr_declared()'s i-th array
.ref_declared <- function(i) {
  v <- outer(1:20, 1:30, function(y, x) i * 100 + y + x)
  v[1L, 1L] <- NaN
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

# three declared groups: g1 and g3 overlap in EPSG:32632, g2 lies elsewhere
at3 <- function(...) {
  utils::modifyList(
    list(
      g1 = list(crs = "EPSG:32632", x0 = 500000, y1 = 4600000),
      g2 = list(crs = "EPSG:32633", x0 = 300000, y1 = 4600000),
      g3 = list(crs = "EPSG:32632", x0 = 500100, y1 = 4600000)
    ),
    list(...)
  )
}

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
})

test_that("consolidated metadata lists a store's arrays and what they declare", {
  wkt <- gdalraster::srs_to_wkt("EPSG:32633")
  pj <- yyjsonr::read_json_str(gdalraster::srs_to_projjson("EPSG:32632"))
  for (format in 2:3) {
    store <- fixture_zarr_declared(
      at3(
        # proj:wkt2 and proj:projjson name a CRS as proj:code does
        g2 = list(attrs = list(`proj:code` = NULL, `proj:wkt2` = wkt)),
        g3 = list(attrs = list(`proj:code` = NULL, `proj:projjson` = pj))
      ),
      on = "array",
      format = format
    )
    a <- gdal_zarr_arrays(.zarr_store_root(store))
    expect_identical(a$array, c("/g1/v", "/g2/v", "/g3/v"))
    expect_identical(a$path[[2L]], .glue('ZARR:"{store}/g2":/v'))
    expect_identical(a$full[[2L]], .glue('ZARR:"{store}":/g2/v'))
    expect_true(all(a$declared))
    expect_identical(a$crs[[1L]], "EPSG:32632")
    expect_true(crs_equal(a$crs[[2L]], "EPSG:32633"))
    expect_true(crs_equal(a$crs[[3L]], "EPSG:32632"))
    expect_identical(
      unlist(a[3L, c("xmin", "ymin", "xmax", "ymax")], use.names = FALSE),
      c(500100, 4599800, 500400, 4600000)
    )
    # GDAL agrees with each declaration, so each reads
    for (i in 1:3) {
      e <- unlist(a[i, c("xmin", "ymin", "xmax", "ymax")], use.names = FALSE)
      g <- grid_spec(a$crs[[i]], e, res = 10)
      got <- suppressMessages(lazy_dataset(store, g, array = "v"))
      expect_true(a$path[[i]] %in% .ds_paths(got))
    }
  }
  # spatial:bbox gives the extent before spatial:transform does
  store <- fixture_zarr_declared(
    at3(g1 = list(attrs = list(`spatial:bbox` = c(1, 2, 3, 4))))
  )
  a <- gdal_zarr_arrays(.zarr_store_root(store))
  expect_identical(
    unlist(a[1L, c("xmin", "ymin", "xmax", "ymax")], use.names = FALSE),
    c(1, 2, 3, 4)
  )
})

test_that("GDAL places the arrays of a store that declares nothing", {
  for (fmt in c("ZARR_V3", "ZARR_V2")) {
    for (cons in c(TRUE, FALSE)) {
      fx <- fixture_zarr_store(fmt, cons)
      a <- gdal_zarr_arrays(.zarr_store_root(fx$store))
      expect_identical(
        a$array,
        sort(c(paste0("/", names(fx$paths), "/emb"), "/other/lut"))
      )
      expect_false(any(a$declared))
      expect_identical(
        a$path[a$array == "/nest/far/emb"],
        .glue('ZARR:"{fx$store}/nest/far":/emb')
      )
      expect_identical(a$crs[a$name == "lut"], "")
      # each from its group, as GDAL places it from the root
      for (g in names(fx$paths)) {
        row <- a[a$array == paste0("/", g, "/emb"), ]
        geo <- .gdal_georef(fx$paths[[g]])
        expect_identical(row$crs, geo$crs)
        expect_identical(
          unlist(row[c("xmin", "ymin", "xmax", "ymax")], use.names = FALSE),
          geo$extent
        )
      }
    }
  }
})

test_that("a grid opens and reads only the arrays it overlaps", {
  store <- fixture_zarr_declared(at3())
  .gdal_handle_reset()
  expect_message(
    ds <- lazy_dataset(store, g_one()),
    'Reading 2 of the 3 "v" arrays of .*"/g1/v" and "/g3/v"'
  )
  want <- .glue('ZARR:"{store}/{c("g1", "g3")}":/v')
  expect_identical(.ds_paths(ds), want)
  expect_setequal(names(.gdal_cache$handles), want)
  # g3 lies over g1 from column 6, so it wins there
  got <- collect(ds$b1, distributed = FALSE)
  expect_equal(unname(got[, 1:5]), .ref_declared(1)[6:15, 6:10])
  expect_equal(unname(got[, 6:20]), .ref_declared(3)[6:15, 1:15])
})

test_that("arrays in the grid's CRS go last, the rest in path order", {
  xy <- gdalraster::transform_xy(
    cbind(500000, 4600000),
    "EPSG:32632",
    "EPSG:32633"
  )
  b0 <- round(xy[1L, ], -1)
  store <- fixture_zarr_declared(list(
    a = list(crs = "EPSG:32632", x0 = 500000, y1 = 4600000),
    b = list(crs = "EPSG:32633", x0 = b0[[1L]], y1 = b0[[2L]])
  ))
  path <- .glue('ZARR:"{store}/{c("a", "b")}":/v')
  ga <- grid_spec("EPSG:32632", c(500000, 4599800, 500300, 4600000), res = 10)
  gb <- grid_spec(
    "EPSG:32633",
    c(b0[[1L]], b0[[2L]] - 200, b0[[1L]] + 300, b0[[2L]]),
    res = 10
  )
  expect_message(
    da <- lazy_dataset(store, ga),
    '"/b/v" and "/a/v"',
    fixed = TRUE
  )
  expect_identical(.ds_paths(da), rev(path))
  got <- collect(da$b1, distributed = FALSE)
  # a's own pixels, but where a holds no data
  expect_equal(unname(got)[-1L], .ref_declared(1)[-1L])
  expect_identical(
    got,
    collect(lazy_dataset(rev(path), ga)$b1, distributed = FALSE)
  )
  db <- suppressMessages(lazy_dataset(store, gb))
  expect_identical(.ds_paths(db), path)
  got <- collect(db$b1, distributed = FALSE)
  expect_equal(unname(got)[-1L], .ref_declared(2)[-1L])
})

test_that("a store reads the cells of the explicit list of its arrays", {
  for (fmt in c("ZARR_V3", "ZARR_V2")) {
    for (cons in c(TRUE, FALSE)) {
      fx <- fixture_zarr_store(fmt, cons)
      # each grid is in EPSG:32632 or 32631: those arrays go last
      cases <- list(
        list(g_one(), "utm32"),
        list(g_two(), c("utm33", "utm32")),
        list(g_eq(), c("eqs", "eqn")),
        list(g_ov(), c("ova", "ovb"))
      )
      for (k in cases) {
        ds <- suppressMessages(lazy_dataset(fx$store, k[[1L]]))
        expect_identical(
          sub('^ZARR:".*/([^/"]+)":/emb$', "\\1", .ds_paths(ds)),
          k[[2L]]
        )
        want <- .year(lazy_dataset(unname(fx$paths[k[[2L]]]), k[[1L]]))
        expect_identical(.year(ds), want)
      }
    }
  }
  fx <- fixture_zarr_store()
  # a nested group's array is found as any other
  far <- grid_spec("EPSG:32632", c(200000, 4999900, 200100, 5000000), res = 10)
  expect_message(lazy_dataset(fx$store, far), '"/nest/far/emb"', fixed = TRUE)
  got <- .year(suppressMessages(lazy_dataset(fx$store, g_one())))
  expect_equal(unname(got[,, 2]), .ref(fx, "utm32", 2, 2)[6:15, 6:25])
})

test_that("in one CRS, the later array in path order wins where it holds data", {
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
})

test_that("GDAL must place a declared array where the store declares it", {
  grid <- g_one()
  # group attributes that only the root consolidates: GDAL takes them up
  # from the store's root, not from the array's group
  for (format in 2:3) {
    store <- fixture_zarr_declared(at3(), per_group = FALSE, format = format)
    cnd <- expect_error(
      lazy_dataset(store, grid),
      class = "garry_source_error",
      regexp = 'GDAL does not place "/g1/v" of .* where the store declares it'
    )
    said <- cli::ansi_strip(conditionMessage(cnd))
    expect_match(
      said,
      "declares EPSG:32632 over 500000, 4599800, 500300, 4600000",
      fixed = TRUE
    )
    expect_match(said, "GDAL gives no CRS", fixed = TRUE)
    full <- .glue('ZARR:"{store}":/g1/v')
    expect_match(said, full, fixed = TRUE)
    expect_match(said, .glue('ZARR:"{store}/g1":/v'), fixed = TRUE)
    # the root form reads it
    got <- collect(lazy_dataset(full, grid)$b1, distributed = FALSE)
    expect_equal(unname(got), .ref_declared(1)[6:15, 6:25], ignore_attr = TRUE)
  }
  # declared on the store's root alone: each array takes its nearest
  # group's declaration, and GDAL places neither form of it
  for (format in 2:3) {
    store <- fixture_zarr_declared(at3()[-2L], on = "root", format = format)
    a <- gdal_zarr_arrays(.zarr_store_root(store))
    expect_true(all(a$declared))
    expect_identical(a$xmax, c(500300, 500300))
    expect_error(
      suppressMessages(lazy_dataset(store, grid)),
      class = "garry_source_error",
      regexp = "GDAL gives no CRS"
    )
  }
  # an extent GDAL does not give
  store <- fixture_zarr_declared(
    at3(
      g1 = list(
        attrs = list(`spatial:bbox` = c(500000, 4599800, 500310, 4600000))
      )
    )
  )
  expect_error(
    suppressMessages(lazy_dataset(store, grid)),
    class = "garry_source_error",
    regexp = "GDAL gives EPSG:32632 over 500000, 4599800, 500300, 4600000"
  )
})

test_that("arrays of the name read that have no CRS or extent are named", {
  store <- fixture_zarr_declared(at3(
    g3 = list(attrs = list(`proj:code` = NULL))
  ))
  expect_message(
    ds <- lazy_dataset(store, g_one()),
    'Reading 1 of the 2 "v" arrays.*1 more "v" array has no CRS or extent.*"/g3/v"'
  )
  expect_identical(.ds_paths(ds), .glue('ZARR:"{store}/g1":/v'))
  expect_error(
    lazy_dataset(store, g_off()),
    class = "garry_source_error",
    regexp = 'None of the 2 "v" arrays.*1 more "v" array has no CRS or extent.*"/g3/v"'
  )
})

test_that("a store of one array reads as that array, whatever its form", {
  ref <- outer(1:20, 1:30, function(y, x) 10 + x %% 7 + y %% 3)
  for (cons in c(TRUE, FALSE)) {
    store <- fixture_zarr_root("a", consolidated = cons)
    for (src in list(store, paste0(store, "/"), .glue('ZARR:"{store}"'))) {
      expect_no_message(ds <- lazy_dataset(src))
      expect_equal(
        unname(collect(ds$b1, distributed = FALSE)),
        ref,
        ignore_attr = TRUE
      )
    }
    # the overlap check holds for one array too
    expect_error(
      lazy_dataset(store, g_off()),
      class = "garry_source_error",
      regexp = "None of the 1 .*array of .* overlaps the grid"
    )
  }
  # listed from consolidated metadata, the array has a name to pick
  expect_no_message(lazy_dataset(fixture_zarr_root("a"), array = "a"))
  expect_error(
    lazy_dataset(fixture_zarr_root("a", consolidated = FALSE), array = "a"),
    class = "garry_source_error",
    regexp = "single array"
  )
})

test_that("without a grid a store must hold one array with a CRS and extent", {
  fx <- fixture_zarr_store()
  expect_error(
    lazy_dataset(fx$store),
    class = "garry_source_error",
    regexp = "holds 7 .*emb.* arrays, in 4 CRSs"
  )
  store <- fixture_zarr_declared(at3()[1L])
  expect_no_message(ds <- lazy_dataset(store))
  expect_identical(.ds_paths(ds), .glue('ZARR:"{store}/g1":/v'))
})

test_that("store errors are classed and say what to do", {
  fx <- fixture_zarr_store()
  cnd <- expect_error(
    lazy_dataset(fx$store, g_off()),
    class = "garry_source_error",
    regexp = "None of the 7 .*emb.* arrays of .*ZARR_V3-TRUE.zarr.* overlaps the grid"
  )
  said <- cli::ansi_strip(conditionMessage(cnd))
  expect_match(
    said,
    "100, 10, 101, 11 (xmin, ymin, xmax, ymax) in EPSG:4326",
    fixed = TRUE
  )
  expect_match(said, "connection strings", fixed = TRUE)
  expect_error(
    lazy_dataset(fx$store, g_one(), array = "nope"),
    class = "garry_source_error",
    regexp = "no array named .*nope.*named .*emb.* and .*lut"
  )
  expect_error(
    lazy_dataset(fx$store, g_one(), array = "lut"),
    class = "garry_source_error",
    regexp = "No array of .* declares a CRS and extent, and GDAL places none: .*/other/lut"
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
    regexp = "under 2 names: .*a.* and .*b.*\\n.*array = \"a\""
  )
  got <- suppressMessages(lazy_dataset(two, g_one(), array = "b"))
  expect_identical(.ds_paths(got), .glue('ZARR:"{two}":/b'))
  # a store's root is read alone
  for (src in list(c(fx$store, two), c(fx$store, fx$paths[["utm32"]]))) {
    expect_error(
      lazy_dataset(src, g_one()),
      class = "garry_source_error",
      regexp = "root of a Zarr store, which is read alone"
    )
  }
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

test_that("a remote store's listing is kept for the session and filtered by name", {
  memo <- .gdal_cache$zarr_stores
  rm(list = ls(memo, all.names = TRUE), envir = memo)
  withr::defer(rm(list = ls(memo, all.names = TRUE), envir = memo))
  read <- .gdal_read_json
  open <- .gdal_georef
  n <- c(read = 0L, open = 0L)
  testthat::local_mocked_bindings(
    .gdal_read_json = function(...) {
      n[["read"]] <<- n[["read"]] + 1L
      read(...)
    },
    .gdal_georef = function(...) {
      n[["open"]] <<- n[["open"]] + 1L
      open(...)
    }
  )
  # local: listed again each time
  root <- .zarr_store_root(fixture_zarr_declared(at3()))
  a <- gdal_zarr_arrays(root)
  expect_identical(gdal_zarr_arrays(root), a)
  expect_identical(n[["read"]], 2L)
  # remote: listed once; GDAL opens the undeclared arrays of the name asked
  # for, each once, whatever `array` asks for later
  testthat::local_mocked_bindings(.gdal_is_remote = function(path) TRUE)
  fx <- fixture_zarr_store()
  root <- .zarr_store_root(fx$store)
  .gdal_handle_reset()
  n[] <- 0L
  expect_error(lazy_dataset(fx$store, g_one(), array = "lut"))
  expect_identical(n, c(read = 1L, open = 1L))
  a <- gdal_zarr_arrays(root)
  expect_identical(n, c(read = 1L, open = 8L))
  suppressMessages(lazy_dataset(fx$store, g_one(), array = "emb"))
  suppressMessages(lazy_dataset(fx$store, g_one()))
  expect_identical(n, c(read = 1L, open = 8L))
  expect_identical(gdal_zarr_arrays(root), a)
  expect_length(ls(memo, all.names = TRUE), 1L)
})

test_that("a grid meets the extents that hold it", {
  # every OlmoEarth zone array: 983,040 m wide from easting 0, northings
  # -9,175,040 to 9,502,720 in its northern UTM CRS
  zones <- .glue("EPSG:326{formatC(1:60, width = 2, flag = '0')}")
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
  # and so do extents given past 180
  w <- grid_spec("EPSG:4326", c(-100, 10, -90, 20), res = 0.1)
  expect_true(.gdal_grid_meets(w, c(0, -90, 360, 90), "EPSG:4326"))
  f <- grid_spec("EPSG:4326", c(-179, -18, -170, -17), res = 0.1)
  expect_true(.gdal_grid_meets(f, c(170, -20, 190, -10), "EPSG:4326"))
  expect_false(.gdal_grid_meets(f, c(0, -20, 10, -10), "EPSG:4326"))
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
