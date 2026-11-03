# A write builds in a hidden temporary directory beside its target and moves
# into place when the whole run has succeeded (.collect_write()). So a plan may
# read its own target and gets the old values, and a failed run leaves every
# target as it was. The values below are plain R: `.wa_m` and arithmetic on it.

.wa_m <- matrix(as.numeric(1:24), 4L, 6L)
.wa_grid <- grid_spec("EPSG:3857", extent = c(0, 0, 60, 40), dims = c(x = 6L, y = 4L),
                      dtype = "f32")
.wa_dates <- c("2024-01-05", "2024-01-20")

# A GeoTIFF at `p` holding `m`, through GDAL alone.
.wa_tif <- function(p, m = .wa_m, type = "Float32") {
  ds <- gdalraster::create("GTiff", p, ncol(m), nrow(m), 1L, type, return_obj = TRUE)
  ds$setGeoTransform(c(0, 10, 0, 10 * nrow(m), 0, -10))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  ds$write(1L, 0L, 0L, ncol(m), nrow(m), as.numeric(t(m)))
  ds$close()
  p
}

# With a declared grid nothing opens the source until a read does.
.wa_gone <- function() {
  lazy_source(file.path(tempdir(), "garry-no-such-file.tif"), grid = .wa_grid,
              block_dim = c(6L, 4L))
}

# Everything under `dir`, hidden or not, by content. A temporary directory left
# behind shows here, as does a target that changed.
.wa_held <- function(dir) {
  tools::md5sum(list.files(dir, recursive = TRUE, all.files = TRUE, include.dirs = TRUE,
                           no.. = TRUE, full.names = TRUE))
}

# `code` must fail, as `...` says, and leave `dir` as it was.
.wa_keeps <- function(dir, code, ..., info = NULL) {
  held <- .wa_held(dir)
  expect_error(code, ...)
  expect_identical(.wa_held(dir), held, info = info)
}

# A dataset of two slices.
.wa_dataset <- function(first, second) {
  as_dataset(list(B = stats::setNames(list(first, second), .wa_dates)))
}

# Chunk `at` of the write in `code` fails on the host, as on a full disk.
# Returns what `dir` held at that moment.
.wa_chunk_fails <- function(at, dir, code) {
  real <- garry:::.exec_write_chunk
  landed <- 0L
  seen <- character(0)
  testthat::local_mocked_bindings(
    .exec_write_chunk = function(...) {
      landed <<- landed + 1L
      if (landed == at) {
        seen <<- list.files(dir, all.files = TRUE, no.. = TRUE)
        stop("disk full")
      }
      real(...)
    },
    .package = "garry"
  )
  held <- .wa_held(dir)
  expect_error(code, "disk full")
  expect_identical(.wa_held(dir), held)
  seen
}

# The materialise() forms, each over what `one` and `two` read, with the stems
# of the files each writes.
.wa_mat_forms <- function(one, two) {
  list(
    raster = list(x = one, stems = "m"),
    list = list(x = list(a = one, b = two), stems = c("m-a", "m-b")),
    slices = list(x = .wa_dataset(one, two), stems = paste0("m-", .wa_dates))
  )
}

# `back`, as materialise() returned it, plus one.
.wa_plus_one <- function(back) {
  if (S7::S7_inherits(back)) back + 1L else lapply(back, function(r) r + 1L)
}

local({
  local_pools(2, 1)

  test_that("a plan reads its own target on every write route", {
    dir <- withr::local_tempdir()
    p <- file.path(dir, "x.tif")
    for (leg in list(.host, .comp)) {
      .wa_tif(p)
      x <- lazy_source(p) + 1
      .on_leg(leg, x, expect_identical(write_tif(x, p, distributed = leg$distributed), p))
      .expect_cells(.read_cube(p), .wa_m + 1, info = leg$route)
    }
    for (leg in list(.read_host, .read_pool)) {
      .wa_tif(p)
      x <- lazy_source(p)
      .on_leg(leg, x, expect_identical(write_tif(x, p, distributed = leg$distributed), p))
      .expect_cells(.read_cube(p), .wa_m, info = leg$route)
    }
    expect_identical(list.files(dir, all.files = TRUE, no.. = TRUE), "x.tif")
    # the pools read the new file on the next run, not a handle on the old one
    .expect_cells(unclass(collect(lazy_source(p) * 2, distributed = TRUE)), .wa_m * 2)
  })

  test_that("a fused kernel reads its own target", {
    skip_on_os("mac")
    dir <- withr::local_tempdir()
    p <- .wa_tif(file.path(dir, "x.tif"))
    x <- lazy_source(p) + 1
    .on_leg(.fused, x, write_tif(x, p, distributed = TRUE))
    .expect_cells(.read_cube(p), .wa_m + 1)
  })

  test_that("the fast routes read their own target and keep it on a failed write", {
    tile <- function(gti) garry:::.gti_meta(gti)$entries$location[[1L]]
    g <- graph_new()
    gti <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
    x <- reduce_over(lazy_stack(list(.gg_slice(gti, "s1", g), .gg_slice(gti, "s2", g))),
                     "median", "t") * 2
    .on_leg(.leg("gd_reduce"), x, write_tif(x, tile(gti), distributed = TRUE))
    .expect_cells(.read_cube(tile(gti)), .gg_val(5) * 2)
    # these routes write on the host, once the run has its result
    held <- tools::md5sum(tile(gti))
    local({
      local_mocked_bindings(gdal_write_window = function(...) stop("disk full"), .package = "garry")
      expect_error(write_tif(x, tile(gti), distributed = TRUE), "disk full")
    })
    expect_identical(garry_last_route(), "gd_reduce")
    expect_identical(tools::md5sum(tile(gti)), held)

    qa <- matrix(0, 40, 60)
    qa[10:20, 10:30] <- 2
    g <- graph_new()
    v <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
    q <- .gg_gti(list(s1 = qa, s2 = matrix(0, 40, 60)))
    sl <- function(gti) list(s1 = .gg_slice(gti, "s1", g), s2 = .gg_slice(gti, "s2", g))
    ds <- as_dataset(list(V = sl(v), Q = sl(q)), mask_asset = "Q")
    x <- stack_bands(reduce_over(apply_mask(ds, where = c(2)), "median", "t", nan_rm = TRUE))
    .on_leg(.leg("composite_direct"), x, write_tif(x, tile(v), distributed = TRUE))
    want <- .gg_val(5)
    want[10:20, 10:30] <- .gg_val(10)[10:20, 10:30]
    .expect_cells(.read_cube(tile(v)), want)
    held <- tools::md5sum(tile(v))
    local({
      local_mocked_bindings(gdal_write_window = function(...) stop("disk full"), .package = "garry")
      expect_error(write_tif(x, tile(v), distributed = TRUE), "disk full")
    })
    expect_identical(garry_last_route(), "composite_direct")
    expect_identical(tools::md5sum(tile(v)), held)
  })

  test_that("the sinks of a list read each other's old files", {
    for (d in c(FALSE, TRUE)) {
      dir <- withr::local_tempdir()
      a <- .wa_tif(file.path(dir, "a.tif"), .wa_m)
      b <- .wa_tif(file.path(dir, "b.tif"), .wa_m * 2)
      x <- list(a = lazy_source(b) + 1, b = lazy_source(a) + 1)
      expect_identical(write_tif(x, dir, distributed = d), c(a = a, b = b))
      .expect_cells(.read_cube(a), .wa_m * 2 + 1, info = d)
      .expect_cells(.read_cube(b), .wa_m + 1, info = d)
      expect_identical(list.files(dir, all.files = TRUE, no.. = TRUE), c("a.tif", "b.tif"))
    }
  })

  test_that("a grouped write reads its own targets", {
    for (d in c(FALSE, TRUE)) {
      dir <- withr::local_tempdir()
      p <- file.path(dir, paste0("c-", .wa_dates, ".tif"))
      .wa_tif(p[[1L]], .wa_m)
      .wa_tif(p[[2L]], .wa_m * 2)
      ds <- .wa_dataset(lazy_source(p[[1L]]) + 1, lazy_source(p[[2L]]) + 1)
      got <- write_tif(group_by_time(ds, "day"), file.path(dir, "c-{group}.tif"), distributed = d)
      expect_identical(got, stats::setNames(p, .wa_dates))
      .expect_cells(.read_cube(p[[1L]]), .wa_m + 1, info = d)
      .expect_cells(.read_cube(p[[2L]]), .wa_m * 2 + 1, info = d)
    }
  })

  test_that("a COG reads its own target and lands whole", {
    for (d in c(FALSE, TRUE)) {
      dir <- withr::local_tempdir()
      p <- .wa_tif(file.path(dir, "x.tif"))
      expect_identical(write_tif(lazy_source(p) + 1, p, cog = TRUE, distributed = d), p)
      ds <- methods::new(gdalraster::GDALRaster, p)
      expect_identical(ds$getMetadataItem(0, "LAYOUT", "IMAGE_STRUCTURE"), "COG")
      ds$close()
      .expect_cells(.read_cube(p), .wa_m + 1, info = d)
      expect_identical(list.files(dir, all.files = TRUE, no.. = TRUE), "x.tif")
    }
  })

  test_that("materialise reads the checkpoint it replaces, in each form", {
    for (type in c("Float32", "Int16")) {
      src <- lazy_source(.wa_tif(tempfile(fileext = ".tif"), type = type))
      forms <- .wa_mat_forms(src + 1L, src * 2L)
      ext <- if (type == "Float32") ".vrt" else ".tif"
      for (d in c(FALSE, TRUE)) {
        for (form in names(forms)) {
          info <- paste(type, form, d)
          dir <- withr::local_tempdir()
          back <- materialise(forms[[form]]$x, dir, name = "m", distributed = FALSE)
          again <- materialise(.wa_plus_one(back), dir, name = "m", overwrite = TRUE,
                               distributed = d)
          files <- file.path(dir, paste0(forms[[form]]$stems, ext))
          .expect_cells(.read_cube(files[[1L]]), .wa_m + 2, info = info)
          if (length(files) > 1L) {
            .expect_cells(.read_cube(files[[2L]]), .wa_m * 2 + 1, info = info)
          }
          if (form == "raster") {
            .expect_cells(unclass(collect(again, distributed = d)), .wa_m + 2, info = info)
          }
          expect_length(list.files(dir, pattern = "garry-write", all.files = TRUE), 0L)
        }
      }
    }
  })

  test_that("a failed run leaves every target on every route", {
    withr::local_options(garry.read_retry = 0L, garry.placement = "rules")
    good <- lazy_source(.wa_tif(tempfile(fileext = ".tif")))
    bad <- .wa_gone()
    groups <- group_by_time(.wa_dataset(good + 1, bad + 1), "day")
    runs <- list(
      read = function(dir, d) write_tif(bad, file.path(dir, "a.tif"), distributed = d),
      compute = function(dir, d) write_tif(bad + 1, file.path(dir, "a.tif"), distributed = d),
      cog = function(dir, d) write_tif(bad + 1, file.path(dir, "a.tif"), cog = TRUE, distributed = d),
      list = function(dir, d) write_tif(list(a = good + 1, b = bad + 1), dir, distributed = d),
      grouped = function(dir, d) write_tif(groups, file.path(dir, "a-{group}.tif"), distributed = d)
    )
    for (nm in names(runs)) {
      for (d in c(FALSE, TRUE)) {
        dir <- withr::local_tempdir()
        .wa_keeps(dir, runs[[nm]](dir, d), class = "garry_read_error", info = paste(nm, d))
        expect_length(list.files(dir, all.files = TRUE, no.. = TRUE), 0L)
        .wa_tif(file.path(dir, "a.tif"))
        .wa_tif(file.path(dir, "b.tif"))
        for (dt in .wa_dates) .wa_tif(file.path(dir, paste0("a-", dt, ".tif")))
        .wa_keeps(dir, runs[[nm]](dir, d), class = "garry_read_error", info = paste(nm, d))
      }
    }
  })

  test_that("a failed materialise keeps the checkpoint it would replace", {
    withr::local_options(garry.read_retry = 0L, garry.placement = "rules")
    for (type in c("Float32", "Int16")) {
      dtype <- c(Float32 = "f32", Int16 = "i16")[[type]]
      good <- lazy_source(.wa_tif(tempfile(fileext = ".tif"), type = type))
      bad <- lazy_source(file.path(tempdir(), "garry-no-such-file.tif"),
                         grid = garry:::.grid_retype(.wa_grid, dtype), block_dim = c(6L, 4L))
      fine <- .wa_mat_forms(good + 1L, good * 2L)
      fails <- .wa_mat_forms(good + 1L, bad + 1L)
      fails$raster$x <- bad + 1L
      for (form in names(fails)) {
        for (d in c(FALSE, TRUE)) {
          info <- paste(type, form, d)
          dir <- withr::local_tempdir()
          .wa_keeps(dir, materialise(fails[[form]]$x, dir, name = "m", distributed = d),
                    class = "garry_read_error", info = info)
          materialise(fine[[form]]$x, dir, name = "m", distributed = FALSE)
          .wa_keeps(dir,
                    materialise(fails[[form]]$x, dir, name = "m", overwrite = TRUE, distributed = d),
                    class = "garry_read_error", info = info)
        }
      }
    }
  })

  test_that("a failure late in a list leaves the sinks finished before it", {
    one <- lazy_source(.wa_tif(tempfile(fileext = ".tif")))
    x <- list(a = one + 1, b = one * 2)
    dir <- withr::local_tempdir()
    .wa_tif(file.path(dir, "a.tif"), .wa_m * 3)
    # the last chunk of the last sink, on the host
    .wa_chunk_fails(2L, dir, write_tif(x, dir, distributed = FALSE))
    # the second of two translates, the last step of a COG write
    real <- gdal_translate_file
    n <- 0L
    local_mocked_bindings(gdal_translate_file = function(...) {
      n <<- n + 1L
      if (n == 2L) stop("disk full")
      real(...)
    })
    for (d in c(FALSE, TRUE)) {
      n <- 0L
      .wa_keeps(dir, write_tif(x, dir, cog = TRUE, distributed = d), "disk full", info = d)
      expect_identical(n, 2L)
    }
  })

  test_that("a raw cube moves as a pair and reads from anywhere", {
    src <- .wa_tif(tempfile(fileext = ".tif"))
    elsewhere <- withr::local_tempdir()
    for (d in c(FALSE, TRUE)) {
      dir <- withr::local_tempdir()
      back <- materialise(lazy_source(src) + 1, dir, name = "m", distributed = FALSE)
      again <- materialise(back + 1, dir, name = "m", overwrite = TRUE, distributed = d)
      vrt <- file.path(dir, "m.vrt")
      expect_false(any(grepl("garry-write", readLines(vrt), fixed = TRUE)), info = d)
      expect_true(any(grepl(">m.bin<", readLines(vrt), fixed = TRUE)), info = d)
      withr::with_dir(elsewhere, {
        .expect_cells(.read_cube(vrt), .wa_m + 2, info = d)
        .expect_cells(unclass(collect(again, distributed = FALSE)), .wa_m + 2, info = d)
        .expect_cells(unclass(collect(again, distributed = TRUE)), .wa_m + 2, info = d)
      })
    }
  })

  test_that("a relative target lands relative to the session, not its daemons", {
    src <- .wa_tif(tempfile(fileext = ".tif"))
    withr::local_dir(withr::local_tempdir())
    x <- lazy_source(src) + 1
    expect_identical(write_tif(x, "rel.tif", distributed = TRUE), "rel.tif")
    .expect_cells(.read_cube("rel.tif"), .wa_m + 1)
    write_tif(x, "./dot.tif", cog = TRUE, distributed = TRUE)
    .expect_cells(.read_cube("./dot.tif"), .wa_m + 1)
    expect_setequal(list.files(all.files = TRUE, no.. = TRUE), c("rel.tif", "dot.tif"))
  })

  test_that("a sidecar moves with its target and an old one goes", {
    dir <- withr::local_tempdir()
    p <- .wa_tif(file.path(dir, "x.tif"))
    # a baseline GeoTIFF keeps band descriptions in an .aux.xml, and the world
    # file is its own request
    write_tif(lazy_source(p) + 1, p, creation_options = c("PROFILE=BASELINE", "TFW=YES"),
              band_names = "red", distributed = TRUE)
    expect_setequal(list.files(dir, all.files = TRUE, no.. = TRUE),
                    c("x.tif", "x.tif.aux.xml", "x.tfw"))
    .expect_cells(.read_cube(p), .wa_m + 1)
    ds <- methods::new(gdalraster::GDALRaster, p)
    expect_identical(ds$getDescription(1L), "red")
    ds$close()
    # overviews built on the old file would serve its pixels under the new one
    ovr <- .wa_tif(file.path(dir, "y.tif"))
    ds <- methods::new(gdalraster::GDALRaster, ovr, TRUE)
    ds$buildOverviews("NEAREST", 2L, 0L)
    ds$close()
    writeLines("<PAMDataset/>", paste0(ovr, ".aux.xml"))
    expect_true(file.exists(paste0(ovr, ".ovr")))
    write_tif(lazy_source(ovr) + 1, ovr, cog = TRUE, distributed = FALSE)
    expect_false(file.exists(paste0(ovr, ".ovr")))
    expect_false(file.exists(paste0(ovr, ".aux.xml")))
  })

  test_that("a failed move is reported, and names what it left", {
    dir <- withr::local_tempdir()
    a <- .wa_tif(file.path(dir, "a.tif"))
    b <- .wa_tif(file.path(dir, "b.tif"))
    keep <- tools::md5sum(b)
    real <- gdal_place
    local_mocked_bindings(gdal_place = function(from, to) {
      if (basename(to) == "b.tif") "no room for it" else real(from, to)
    })
    src <- lazy_source(.wa_tif(tempfile(fileext = ".tif")))
    err <- expect_error(write_tif(list(a = src + 1, b = src * 2), dir, distributed = TRUE),
                        class = "garry_write_error")
    said <- cli::ansi_strip(conditionMessage(err))
    expect_match(said, "no room for it", fixed = TRUE)
    expect_match(said, "Already in place:.*a\\.tif")
    expect_match(said, "Still as they were:.*b\\.tif")
    .expect_cells(.read_cube(a), .wa_m + 1)
    expect_identical(tools::md5sum(b), keep)
    expect_identical(list.files(dir, all.files = TRUE, no.. = TRUE), c("a.tif", "b.tif"))
  })

  test_that("a raw cube's .bin moves before its .vrt, target by target", {
    dir <- withr::local_tempdir()
    src <- lazy_source(.wa_tif(tempfile(fileext = ".tif")))
    real <- gdal_place
    moved <- character(0)
    local_mocked_bindings(gdal_place = function(from, to) {
      moved <<- c(moved, basename(to))
      real(from, to)
    })
    materialise(list(a = src + 1, b = src * 2), dir, name = "m", distributed = TRUE)
    expect_identical(moved, c("m-a.bin", "m-a.vrt", "m-b.bin", "m-b.vrt"))
  })

  test_that("a /vsi target builds on disk and is copied at the end", {
    vsi <- "/vsimem/garry-atomic"
    withr::defer(gdalraster::vsi_rmdir(vsi, recursive = TRUE))
    p <- file.path(vsi, "x.tif")
    x <- lazy_source(.wa_tif(tempfile(fileext = ".tif"))) + 1
    read <- function(p) unclass(collect(lazy_source(p), distributed = FALSE))
    for (cog in c(FALSE, TRUE)) {
      for (d in c(FALSE, TRUE)) {
        gdalraster::vsi_unlink(p)
        expect_identical(write_tif(x, p, cog = cog, distributed = d), p)
        .expect_cells(read(p), .wa_m + 1, info = paste(cog, d))
      }
    }
    expect_identical(unclass(gdalraster::vsi_read_dir(vsi)), "x.tif")
    # a failed run leaves it, and a missing one stays missing
    withr::local_options(garry.read_retry = 0L)
    for (d in c(FALSE, TRUE)) {
      expect_error(write_tif(.wa_gone() + 1, p, distributed = d), class = "garry_read_error")
      .expect_cells(read(p), .wa_m + 1, info = d)
      gone <- file.path(vsi, "y.tif")
      expect_error(write_tif(.wa_gone() + 1, gone, distributed = d), class = "garry_read_error")
      expect_false(gdalraster::vsi_stat(gone))
    }
    # a copy that fails is a failed write
    expect_error(write_tif(x, "/vsicurl/http://127.0.0.1:9/a.tif", distributed = FALSE),
                 class = "garry_write_error")
  })

  test_that("a mosaic over a target reads the new file on every process", {
    dir <- withr::local_tempdir()
    other <- lazy_source(.wa_tif(tempfile(fileext = ".tif"), .wa_m * 3))
    n <- 0L
    # each process reads through the VRT, so it holds the tile open, and a run
    # on either route replaces the tile
    for (reader in c(FALSE, TRUE)) {
      for (writer in c(FALSE, TRUE)) {
        info <- paste(reader, writer)
        n <- n + 1L
        tile <- .wa_tif(file.path(dir, paste0("t", n, ".tif")))
        vrt <- file.path(dir, paste0("t", n, ".vrt"))
        gdal_mosaic_vrt(vrt, tile)
        .expect_cells(unclass(collect(lazy_source(vrt), distributed = reader)), .wa_m, info = info)
        write_tif(other * 1, tile, distributed = writer)
        .expect_cells(unclass(collect(lazy_source(vrt), distributed = reader)), .wa_m * 3, info = info)
        # and through its own mosaic
        write_tif(lazy_source(vrt) + 1, tile, distributed = reader)
        .expect_cells(unclass(collect(lazy_source(vrt), distributed = reader)), .wa_m * 3 + 1, info = info)
      }
    }
    read <- function(gti, s, d) unclass(collect(.gg_slice(gti, s, graph_new()), distributed = d))
    for (d in c(FALSE, TRUE)) {
      gti <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
      tile <- garry:::.gti_meta(gti)$entries$location[[1L]]
      info <- paste("route", d)
      .expect_cells(read(gti, "s1", TRUE), .gg_val(0), info = info)
      write_tif(lazy_source(.wa_tif(tempfile(fileext = ".tif"), .gg_val(100))) * 1, tile, distributed = d)
      .expect_cells(read(gti, "s1", TRUE), .gg_val(100), info = info)
      write_tif(.gg_slice(gti, "s1", graph_new()) + 1, tile, distributed = TRUE)
      .expect_cells(read(gti, "s1", TRUE), .gg_val(101), info = info)
    }
  })

  test_that("a write that replaces nothing leaves the read handles", {
    dir <- withr::local_tempdir()
    x <- lazy_source(.wa_tif(tempfile(fileext = ".tif"))) + 1
    told <- 0L
    local_mocked_bindings(.gdal_handles_release = function(paths) told <<- told + 1L)
    p <- file.path(dir, "x.tif")
    write_tif(x, p, distributed = TRUE)
    expect_identical(told, 0L)
    write_tif(x, p, distributed = TRUE)
    expect_identical(told, 1L)
  })

  test_that("a target at the filesystem's name limit can be a COG", {
    skip_on_os("windows") # the path limit comes first
    dir <- withr::local_tempdir()
    p <- file.path(dir, paste0(strrep("n", 251L), ".tif"))
    skip_if_not(file.create(p), "this filesystem has a shorter limit")
    # big enough for overviews, whose temporary files extend the name
    m <- matrix(as.numeric(seq_len(1024L)), 1024L, 1024L)
    x <- lazy_source(.wa_tif(tempfile(fileext = ".tif"), m)) + 1
    for (d in c(FALSE, TRUE)) {
      expect_identical(write_tif(x, p, cog = TRUE, distributed = d), p)
      .expect_cells(.read_cube(p), m + 1, info = paste("route", d))
    }
    ds <- methods::new(gdalraster::GDALRaster, p)
    withr::defer(ds$close())
    expect_gt(ds$getOverviewCount(1L), 0L)
  })

  test_that("a pair that moved by half is named as mixed", {
    # each file on its label's line, however long this run's temp path is
    withr::local_options(cli.width = 1000L)
    dir <- withr::local_tempdir()
    src <- lazy_source(.wa_tif(tempfile(fileext = ".tif")))
    x <- list(a = src + 1, b = src * 2, c = src * 3)
    materialise(x, dir, name = "m", distributed = FALSE)
    real <- gdal_place
    local_mocked_bindings(gdal_place = function(from, to) {
      if (basename(to) == "m-b.vrt") "no room for it" else real(from, to)
    })
    err <- expect_error(materialise(x, dir, name = "m", overwrite = TRUE, distributed = TRUE),
                        class = "garry_write_error")
    said <- cli::ansi_strip(conditionMessage(err))
    expect_match(said, "Already in place:[^\n]*m-a\\.vrt")
    expect_match(said, "mixed[^\n]*write these again[^\n]*m-b\\.vrt")
    expect_match(said, "Still as they were:[^\n]*m-c\\.vrt")
  })

  test_that("a write touches nothing but its targets", {
    dir <- withr::local_tempdir()
    writeLines("theirs", file.path(dir, "foreign.txt"))
    writeLines("theirs", file.path(dir, ".hidden"))
    writeLines("theirs", file.path(dir, "x.bin"))
    # what a killed session leaves is another session's until someone deletes it
    left <- file.path(dir, ".garry-write-left")
    dir.create(left)
    writeLines("partial", file.path(left, "x.tif"))
    held <- .wa_held(dir)
    src <- lazy_source(.wa_tif(tempfile(fileext = ".tif")))
    x <- src + 1
    # the file builds under its own name in a hidden directory of the target's
    seen <- .wa_chunk_fails(1L, dir, write_tif(x, file.path(dir, "x.tif"), distributed = FALSE))
    expect_length(setdiff(seen, c(basename(names(held)), "x.tif")), 1L)
    expect_match(setdiff(seen, basename(names(held))), "^\\.garry-write-")
    write_tif(x, file.path(dir, "x.tif"), distributed = TRUE)
    after <- .wa_held(dir)
    expect_identical(after[names(held)], held)
    expect_identical(setdiff(names(after), names(held)), file.path(dir, "x.tif"))
  })

  test_that("returned paths are the final ones, in every form", {
    dir <- withr::local_tempdir()
    src <- lazy_source(.wa_tif(tempfile(fileext = ".tif")))
    p <- file.path(dir, c("a.tif", "b.tif"))
    for (d in c(FALSE, TRUE)) {
      for (cog in c(FALSE, TRUE)) {
        x <- list(a = src + 1, b = src * 2)
        expect_identical(write_tif(x, dir, cog = cog, distributed = d), c(a = p[[1L]], b = p[[2L]]))
        expect_identical(write_tif(x, c(b = p[[1L]], a = p[[2L]]), cog = cog, distributed = d),
                         c(a = p[[2L]], b = p[[1L]]))
        expect_identical(write_tif(x["a"], dir, cog = cog, distributed = d), c(a = p[[1L]]))
        groups <- group_by_time(.wa_dataset(src + 1, src * 2), "day")
        expect_identical(write_tif(groups, file.path(dir, "{group}", "c.tif"), cog = cog, distributed = d),
                         stats::setNames(file.path(dir, .wa_dates, "c.tif"), .wa_dates))
        expect_true(all(file.exists(file.path(dir, .wa_dates, "c.tif"))))
      }
    }
  })
})

# Call number `at` of `name` fails on the daemons of `prof`, and only that one.
.wa_call_fails <- function(name, prof, at) {
  garry:::.garry_abi_check(prof) # the guard would refuse the mock below
  mirai::everywhere({
    ns <- asNamespace("garry")
    unlockBinding(name, ns)
    .wa_real <<- get(name, envir = ns)
    .wa_n <<- 0L
    assign(name, function(...) {
      .wa_n <<- .wa_n + 1L
      if (.wa_n == at) stop("disk full")
      .wa_real(...)
    }, envir = ns)
  }, name = name, at = at, .compute = prof)
}

local({
  local_pools(1, 1)

  test_that("the writer's last write failing leaves the sinks written before it", {
    withr::local_options(garry.placement = "rules")
    one <- lazy_source(.wa_tif(tempfile(fileext = ".tif")))
    x <- list(a = one + 1, b = one * 2)
    dir <- withr::local_tempdir()
    .wa_tif(file.path(dir, "a.tif"), .wa_m * 3)
    .wa_call_fails(".daemon_write_chunk", "garry_write", 2L)
    .wa_keeps(dir, write_tif(x, dir, distributed = TRUE), "disk full")
  })
})

test_that("a target's missing directories appear only with it", {
  dir <- withr::local_tempdir()
  one <- lazy_source(.wa_tif(tempfile(fileext = ".tif")))
  groups <- group_by_time(.wa_dataset(one + 1, one * 2), "day")
  .wa_chunk_fails(2L, dir, write_tif(groups, file.path(dir, "out", "{group}", "c.tif"), distributed = FALSE))
  expect_length(list.files(dir, all.files = TRUE, no.. = TRUE), 0L)
  .wa_chunk_fails(1L, dir, materialise(one + 1, file.path(dir, "new", "cube"), distributed = FALSE))
  expect_length(list.files(dir, all.files = TRUE, no.. = TRUE), 0L)
  p <- file.path(dir, "a", "b", "x.tif")
  expect_identical(write_tif(one + 1, p, distributed = FALSE), p)
  .expect_cells(.read_cube(p), .wa_m + 1)
})

test_that("a directory at a target is refused before the run", {
  dir <- withr::local_tempdir()
  ran <- FALSE
  x <- lazy_source(.wa_tif(tempfile(fileext = ".tif"))) + 1
  local_mocked_bindings(.collect_run = function(...) ran <<- TRUE)
  expect_error(write_tif(x, dir, distributed = FALSE), "directory", class = "garry_write_error")
  dir.create(file.path(dir, "a.tif"))
  expect_error(write_tif(list(a = x, b = x), dir, distributed = FALSE), "directory",
               class = "garry_write_error")
  expect_false(ran)
})

test_that("an unwritable directory fails before the run, and says where", {
  skip_on_os("windows") # no read-only directories
  skip_if(Sys.info()[["effective_user"]] == "root", "root writes anywhere")
  dir <- withr::local_tempdir()
  Sys.chmod(dir, "555")
  withr::defer(Sys.chmod(dir, "755"))
  x <- lazy_source(.wa_tif(tempfile(fileext = ".tif"))) + 1
  ran <- FALSE
  local_mocked_bindings(.collect_run = function(...) ran <<- TRUE)
  err <- expect_error(write_tif(x, file.path(dir, "x.tif"), distributed = FALSE),
                      "temporary directory", class = "garry_write_error")
  expect_false(ran)
  said <- cli::ansi_strip(conditionMessage(err))
  expect_no_match(said, "garry-write", fixed = TRUE)
  expect_match(said, basename(dir), fixed = TRUE)
  expect_match(said, "ermission", fixed = TRUE)
})

# The daemons start in `started`, and the session then moves on.
local({
  started <- withr::local_tempdir()
  withr::local_dir(started)
  local_pools(2, 1)

  test_that("a relative source is the session's file, wherever the daemons started", {
    # what a daemon would find under the same names
    decoy <- lazy_source(.wa_tif(file.path(started, "s.tif"), .wa_m * 100))
    materialise(decoy, file.path(started, "cube"), name = "n", distributed = FALSE)
    withr::local_dir(withr::local_tempdir())
    .wa_tif("s.tif")
    x <- lazy_source("s.tif")
    .expect_cells(unclass(collect(x + 1, distributed = TRUE)), .wa_m + 1)
    write_tif(x + 1, "s.tif", distributed = TRUE)
    .expect_cells(.read_cube("s.tif"), .wa_m + 1)
    # a checkpoint reopens the file it wrote, on the pool and wherever the session goes
    back <- materialise(lazy_source("s.tif") * 2, "cube", name = "n", distributed = TRUE)
    .expect_cells(unclass(collect(back, distributed = TRUE)), (.wa_m + 1) * 2)
    withr::local_dir(started)
    .expect_cells(unclass(collect(back, distributed = TRUE)), (.wa_m + 1) * 2)
    .expect_cells(unclass(collect(back, distributed = FALSE)), (.wa_m + 1) * 2)
  })

  test_that("a relative path behind a driver prefix is the session's too", {
    gti <- .gg_gti(list(s1 = .gg_val(0)))
    withr::local_dir(withr::local_tempdir())
    file.copy(paste0(gti, c("", ".meta.rds")), paste0("i.gti.fgb", c("", ".meta.rds")))
    x <- .gg_slice("i.gti.fgb", "s1", graph_new())
    .expect_cells(unclass(collect(x, distributed = TRUE)), .gg_val(0))
    expect_identical(.gdal_absolute('ZARR:"s.zarr":/a'), paste0('ZARR:"', getwd(), '/s.zarr":/a'))
    for (p in c('ZARR:"/vsicurl/https://x/s.zarr":/a', "/vsimem/x.tif", "https://x/y.tif", "/a/b.tif", "~/x.tif")) {
      expect_identical(.gdal_absolute(p), p)
    }
  })

  test_that("a relative target of any write route reads back through a daemon", {
    withr::local_dir(withr::local_tempdir())
    src <- lazy_source(.wa_tif(tempfile(fileext = ".tif")))
    back <- materialise(list(a = src + 1, b = src * 2), "cube", name = "m", distributed = TRUE)
    .expect_cells(unclass(collect(back$a, distributed = TRUE)), .wa_m + 1)
    .expect_cells(unclass(collect(back$b, distributed = TRUE)), .wa_m * 2)
    ds <- materialise(.wa_dataset(src + 1, src * 2), "cube", name = "d", distributed = TRUE)
    .expect_cells(unclass(collect(ds@bands$B[[1L]], distributed = TRUE)), .wa_m + 1)
    .expect_cells(unclass(collect(ds@bands$B[[2L]], distributed = TRUE)), .wa_m * 2)
  })
})

local({
  local_pools(1, 1)

  test_that("a failure on the writer names the target, not its temporary path", {
    withr::local_options(garry.placement = "rules")
    garry:::.garry_abi_check("garry_write")
    mirai::everywhere({
      ns <- asNamespace("garry")
      unlockBinding(".gdal_close_failure", ns)
      assign(".gdal_close_failure", function(ds, path) {
        ds$close()
        "no room left"
      }, envir = ns)
    }, .compute = "garry_write")
    dir <- withr::local_tempdir()
    p <- file.path(dir, "x.tif")
    x <- lazy_source(.wa_tif(tempfile(fileext = ".tif"))) + 1
    err <- expect_error(write_tif(x, p, distributed = TRUE), class = "garry_write_error")
    said <- cli::ansi_strip(conditionMessage(err))
    expect_match(said, "no room left", fixed = TRUE)
    expect_match(said, "x.tif", fixed = TRUE)
    expect_no_match(said, "garry-write", fixed = TRUE)
  })
})

test_that("what can never be a target is refused before the run", {
  withr::local_dir(withr::local_tempdir())
  .wa_tif("f.tif")
  dir.create("keep")
  .wa_tif("keep/x.tif")
  src <- .wa_tif(tempfile(fileext = ".tif"))
  x <- lazy_source(src) + 1
  held <- .wa_held(".")
  ran <- FALSE
  local_mocked_bindings(.collect_run = function(...) ran <<- TRUE)
  refused <- function(code, why) {
    err <- expect_error(code, class = "garry_write_error")
    expect_match(cli::ansi_strip(conditionMessage(err)), why, fixed = TRUE)
    expect_false(ran)
    expect_identical(.wa_held("."), held)
  }
  # a URL would land in local directories named after its scheme
  refused(write_tif(x, "s3://bucket/key.tif", distributed = FALSE), "/vsis3/")
  refused(materialise(x, "gs://bucket", distributed = FALSE), "URL")
  refused(stage_raw_cube(src, "s3://bucket/key.vrt"), "URL")
  # a file on the way to a target
  refused(write_tif(x, "f.tif/x.tif", distributed = FALSE), "not a directory")
  refused(write_tif(x, "f.tif/more/x.tif", distributed = FALSE), "not a directory")
  refused(materialise(x, "f.tif", name = "m", distributed = FALSE), "not a directory")
  # a `.` or `..` below a directory that does not exist; Windows resolves these
  # as text, so there they name a place that can be written
  skip_on_os("windows")
  refused(write_tif(x, "keep/nope/../x.tif", distributed = FALSE), "not a directory")
  refused(write_tif(x, "nope/../y.tif", distributed = FALSE), "not a directory")
  refused(write_tif(x, "nope/./y.tif", distributed = FALSE), "not a directory")
})

test_that("a `..` through directories that exist still writes", {
  withr::local_dir(withr::local_tempdir())
  dir.create("a")
  dir.create("b")
  x <- lazy_source(.wa_tif(tempfile(fileext = ".tif"))) + 1
  expect_identical(write_tif(x, "a/../b/c/x.tif", distributed = FALSE), "a/../b/c/x.tif")
  .expect_cells(.read_cube("b/c/x.tif"), .wa_m + 1)
})

test_that("a /vsi path is told from a local one that starts the same way", {
  expect_true(all(.gdal_is_vsi(c("/vsimem/x.tif", "/vsis3/b/k.tif", "/vsizip/a.zip/x.tif"))))
  expect_false(any(.gdal_is_vsi(c("/vsidata/x.tif", "/vsi-old/x.tif", "/vsimem", "vsimem/x.tif", "x.tif"))))
})

test_that("two sinks with one target are refused before the run", {
  withr::local_dir(withr::local_tempdir())
  dir.create("out")
  src <- lazy_source(.wa_tif(tempfile(fileext = ".tif")))
  x <- list(a = src + 1, b = src + 2)
  ran <- FALSE
  local_mocked_bindings(.collect_run = function(...) ran <<- TRUE)
  refused <- function(code, who) {
    err <- expect_error(code, "same file", class = "garry_write_error")
    expect_match(cli::ansi_strip(conditionMessage(err)), who)
    expect_false(ran)
  }
  refused(write_tif(x, c(a = "same.tif", b = "same.tif"), distributed = FALSE), "a.*and.*b")
  refused(write_tif(x, c(a = "same.tif", b = "./same.tif"), distributed = FALSE), "a.*and.*b")
  if (.Platform$OS.type == "unix") {
    file.symlink(file.path(getwd(), "out"), "link")
    refused(write_tif(x, c(a = "out/same.tif", b = "link/same.tif"), distributed = FALSE), "a.*and.*b")
  }
  refused(write_tif(stats::setNames(x, c("a", "a")), "out", distributed = FALSE), "a.*and.*a")
  groups <- group_by_time(.wa_dataset(src + 1, src + 2), "day")
  names(groups@groups) <- c("a/b", "a b")
  refused(write_tif(groups, "g-{group}.tif", distributed = FALSE), "a/b.*and.*a b")
})

test_that("materialise refuses a /vsi target that exists", {
  vsi <- "/vsimem/garry-atomic-exists"
  withr::defer(gdalraster::vsi_rmdir(vsi, recursive = TRUE))
  src <- lazy_source(.wa_tif(tempfile(fileext = ".tif")))
  read <- function(back) unclass(collect(back, distributed = FALSE))
  first <- materialise(src + 1, vsi, name = "m", distributed = FALSE)
  expect_error(materialise(src + 2, vsi, name = "m", distributed = FALSE), "already exists")
  .expect_cells(read(first), .wa_m + 1)
  .expect_cells(read(materialise(src + 2, vsi, name = "m", overwrite = TRUE, distributed = FALSE)), .wa_m + 2)
})

test_that("a read goes to the new file past a handle a user holds open", {
  skip_on_os("windows") # a file held open cannot be renamed over
  p <- .wa_tif(tempfile(fileext = ".tif"))
  ds <- methods::new(gdalraster::GDALRaster, p, read_only = TRUE)
  withr::defer(ds$close())
  write_tif(lazy_source(.wa_tif(tempfile(fileext = ".tif"))) + 1, p, distributed = FALSE)
  .expect_cells(unclass(collect(lazy_source(p), distributed = FALSE)), .wa_m + 1)
})

test_that("a run that left a target unbuilt moves nothing", {
  dir <- withr::local_tempdir()
  src <- lazy_source(.wa_tif(tempfile(fileext = ".tif")))
  local_mocked_bindings(.collect_run = function(x, plan_only, path, ...) .wa_tif(path[["a"]]))
  err <- expect_error(write_tif(list(a = src + 1, b = src * 2), dir, distributed = FALSE),
                      "without building", class = "garry_write_error")
  expect_match(cli::ansi_strip(conditionMessage(err)), "b.tif", fixed = TRUE)
  expect_length(list.files(dir, all.files = TRUE, no.. = TRUE), 0L)
})

test_that("a built file moves with the target it extends by name", {
  w <- c("/t/x.tif", "/t/a.b.tif", "/t/m.vrt")
  files <- c("/t/x.tif.aux.xml", "/t/x.tfw", "/t/x.tif", "/t/a.b.tif.ovr", "/t/m.bin", "/t/other",
             "/t/a.b.tif", "/t/m.vrt")
  expect_identical(.write_owner(files, w), c(1L, 1L, 1L, 2L, 3L, NA, 2L, 3L))
})

test_that("the moves cost each target the same, however many there are", {
  n <- 6000L
  dir <- withr::local_tempdir()
  targets <- stats::setNames(file.path(dir, paste0("s", seq_len(n), ".tif")), seq_len(n))
  stage <- .write_stage(targets)
  dir.create(stage$dirs[[1L]])
  withr::defer(unlink(stage$dirs, recursive = TRUE))
  file.create(stage$work)
  moved <- 0L
  local_mocked_bindings(
    gdal_place = function(from, to) {
      moved <<- moved + 1L
      NULL
    },
    gdal_remove = function(paths) NULL
  )
  took <- system.time(.write_publish(stage, targets))[["elapsed"]]
  expect_identical(moved, n)
  expect_lt(took, 2) # 9 s when each move scans every file
})

test_that("a stage of a raw cube follows the rule of every write", {
  dir <- withr::local_tempdir()
  vrt <- file.path(dir, "m.vrt")
  src <- .wa_tif(tempfile(fileext = ".tif"))
  expect_identical(stage_raw_cube(src, vrt), vrt)
  .expect_cells(.read_cube(vrt), .wa_m)
  expect_setequal(list.files(dir, all.files = TRUE, no.. = TRUE), c("m.bin", "m.vrt"))
  # onto itself, which opened the .bin for writing under its own read
  expect_identical(stage_raw_cube(vrt, vrt), vrt)
  .expect_cells(.read_cube(vrt), .wa_m)
  # a failure partway through keeps the cube
  held <- .wa_held(dir)
  local_mocked_bindings(gdal_read_window = function(...) stop("disk full"))
  expect_error(stage_raw_cube(src, vrt), "disk full")
  expect_identical(.wa_held(dir), held)
})

test_that("a failure names the target, not its temporary path", {
  dir <- withr::local_tempdir()
  p <- file.path(dir, "x.tif")
  x <- lazy_source(.wa_tif(tempfile(fileext = ".tif"))) + 1
  says <- function(code) {
    err <- expect_error(code, class = "garry_write_error")
    said <- cli::ansi_strip(conditionMessage(err))
    expect_no_match(said, "garry-write", fixed = TRUE)
    said
  }
  local({
    local_mocked_bindings(.gdal_close_failure = function(ds, path) {
      ds$close()
      "no room left"
    })
    expect_match(says(write_tif(x, p, distributed = FALSE)), "x.tif", fixed = TRUE)
  })
  local({
    local_mocked_bindings(gdal_translate_file = function(src, dst, cl) stop("no room at ", dst))
    expect_match(says(write_tif(x, p, cog = TRUE, distributed = FALSE)), "no room at", fixed = TRUE)
  })
  # a failed rename gives the reason, not the two paths
  from <- file.path(dir, "no-such")
  expect_no_match(gdal_place(from, file.path(dir, "b")), "no-such", fixed = TRUE)
})

test_that("an interrupt waits for the moves", {
  skip_on_os("windows") # pskill ends the process there
  dir <- withr::local_tempdir()
  src <- lazy_source(.wa_tif(tempfile(fileext = ".tif")))
  real <- gdal_place
  n <- 0L
  local_mocked_bindings(gdal_place = function(from, to) {
    why <- real(from, to)
    n <<- n + 1L
    if (n == 1L) {
      tools::pskill(Sys.getpid(), tools::SIGINT)
      for (k in seq_len(1e6)) NULL # R looks for interrupts as it loops
    }
    why
  })
  end <- tryCatch(
    {
      write_tif(list(a = src + 1, b = src * 2), dir, distributed = FALSE)
      for (k in seq_len(1e6)) NULL
      "no interrupt"
    },
    interrupt = function(e) "interrupted"
  )
  expect_identical(end, "interrupted")
  .expect_cells(.read_cube(file.path(dir, "a.tif")), .wa_m + 1)
  .expect_cells(.read_cube(file.path(dir, "b.tif")), .wa_m * 2)
})

test_that("a symlink at a target is replaced, not followed", {
  skip_on_os("windows")
  dir <- withr::local_tempdir()
  real <- .wa_tif(file.path(dir, "real.tif"), .wa_m * 3)
  link <- file.path(dir, "link.tif")
  file.symlink(real, link)
  write_tif(lazy_source(.wa_tif(tempfile(fileext = ".tif"))) + 1, link, distributed = FALSE)
  expect_identical(Sys.readlink(link), "")
  .expect_cells(.read_cube(link), .wa_m + 1)
  .expect_cells(.read_cube(real), .wa_m * 3)
})
