# A missing cell is NaN wherever a float can hold it, and an error where an
# integer buffer would have to invent a value. Each form below makes cells
# missing a different way, each dtype reads it, and every operation is held
# to a hand-written mask. A value of 0 in a hole is the failure this file
# exists to catch.

# Which cells of a 6 x 4 raster a sentinel marks, by hand.
.mc_mask <- rbind(
  c(FALSE, TRUE, FALSE, FALSE, FALSE, FALSE),
  c(FALSE, FALSE, FALSE, FALSE, TRUE, FALSE),
  c(TRUE, FALSE, FALSE, FALSE, FALSE, FALSE),
  c(FALSE, FALSE, FALSE, TRUE, FALSE, FALSE)
)
.mc_base <- matrix(as.numeric(1:24), 4L, 6L, byrow = TRUE)

.mc_types <- list(
  Byte = list(dtype = "u8", sentinel = 255, cells = .mc_base),
  Int16 = list(dtype = "i16", sentinel = -9999, cells = .mc_base),
  Float32 = list(dtype = "f32", sentinel = -9999, cells = .mc_base + 0.5)
)

.mc_tile <- function(cells, type, ...) {
  fixture_tile(as.numeric(t(cells)), type, nx = ncol(cells), ny = nrow(cells), ...)
}

.mc_hide <- function(m) {
  m[.mc_mask] <- NaN
  m
}

# Each form returns list(x, m, dtype): the raster, its cells with NaN where
# they are missing, and the dtype it declares.
.mc_forms <- list(
  # the file says which value is missing
  sentinel = function(type, tt) {
    cells <- tt$cells
    cells[.mc_mask] <- tt$sentinel
    x <- lazy_source(.mc_tile(cells, type, nodata = tt$sentinel))
    list(x, .mc_hide(tt$cells), "f32")
  },
  # nothing is missing, and an integer stays one
  no_sentinel = function(type, tt) {
    list(lazy_source(.mc_tile(tt$cells, type)), tt$cells, tt$dtype)
  },
  # a given nodata unmasks the file's own, which is data again
  replaced = function(type, tt) {
    cells <- tt$cells
    cells[.mc_mask] <- tt$sentinel
    m <- .mc_hide(tt$cells)
    cells[1L, 1L] <- 0
    m[1L, 1L] <- 0
    list(lazy_source(.mc_tile(cells, type, nodata = 0), nodata = tt$sentinel), m, "f32")
  },
  # no tile reaches the middle two columns
  tile_gap = function(type, tt) {
    left <- .mc_tile(tt$cells[, 1:2], type)
    right <- .mc_tile(tt$cells[, 5:6], type, gt = c(40, 10, 0, 40, 0, -10))
    g <- grid_spec("EPSG:3857", extent = c(0, 0, 60, 40), dims = c(x = 6L, y = 4L),
                   dtype = tt$dtype)
    m <- tt$cells
    m[, 3:4] <- NaN
    list(lazy_source(c(left, right), grid = g), m, tt$dtype)
  },
  # the warp's grid runs past the band
  past_footprint = function(type, tt) {
    x <- lazy_source(.mc_tile(tt$cells[, 1:4], type))
    g <- grid_spec("EPSG:3857", extent = c(0, 0, 60, 40), dims = c(x = 6L, y = 4L))
    m <- tt$cells
    m[, 5:6] <- NaN
    list(align_to(x, g), m, tt$dtype)
  },
  # the sentinel is applied before the affine
  scale = function(type, tt) {
    cells <- tt$cells
    cells[.mc_mask] <- tt$sentinel
    x <- lazy_source(.mc_tile(cells, type, nodata = tt$sentinel, scale = 0.5), scale = TRUE)
    list(x, .mc_hide(tt$cells) * 0.5, "f32")
  },
  # a slice of a tile index: without the filter the later slice wins
  slice = function(type, tt) {
    cells <- function(base) .gg_val(base) + (if (tt$dtype == "f32") 0.5 else 0)
    gti <- .gg_gti(list(s1 = cells(0), s2 = cells(100)), type = type)
    list(.gg_slice(gti, "s1", graph_new(), tt$dtype), cells(0), tt$dtype)
  }
)

# A grid two columns wider than `x`: the cells past `x` are missing.
.mc_wider <- function(x) {
  d <- x@grid@dims
  ext <- grid_bbox(x)
  res <- (ext[[3L]] - ext[[1L]]) / d[["x"]]
  grid_spec(grid_crs(x), extent = c(ext[[1L]], ext[[2L]], ext[[3L]] + 2 * res, ext[[4L]]),
            dims = c(x = d[["x"]] + 2L, y = d[["y"]]))
}

# An integer raster with holes refuses a kernel on `leg`, which is the route
# that said so.
.mc_refuses <- function(x, leg, info) {
  withr::local_options(leg$opts)
  for (plan in list(x + 0, x + 1L)) {
    expect_error(collect(plan, distributed = leg$distributed), class = "garry_nodata_error")
    expect_identical(garry_last_route(), leg$route, info = info)
  }
}

# Everything a raster can go through with cells missing. An integer raster
# with holes shows them to a read and refuses a kernel, and a float one
# carries them. A sentinel stores them; without one an integer file has
# nowhere to put them. `reads` run the plain read, `maps` the kernels.
.mc_ops <- function(x, m, dt, sentinel, info, reads = list(.read_host), maps = list(.host)) {
  float <- startsWith(dt, "f")
  holed <- anyNA(m)
  expect_plan(x, m, dt, legs = reads, file = float || !holed, info = info)
  expect_written(x, m, dt, legs = reads, nodata = sentinel, info = info)
  if (holed && !float) {
    for (leg in maps) {
      .mc_refuses(x, leg, info)
    }
    expect_error(write_tif(x, tempfile(fileext = ".tif"), distributed = FALSE), "nodata")
  } else {
    expect_plan(x + 0, .as_f32(m), "f32", legs = maps, file = FALSE, info = info)
    expect_plan(x + 1L, m + 1, dt, legs = maps, file = FALSE, info = info)
  }
  if (!S7::S7_inherits(graph_get(x@graph, x@node_id), WarpNode)) {
    wide <- align_to(x, .mc_wider(x))
    expect_plan(wide, cbind(m, NaN, NaN), dt, legs = reads, file = float, info = info)
  }
}

for (form in names(.mc_forms)) local({
  build <- .mc_forms[[form]]
  test_that(paste("missing cells:", form), {
    for (type in names(.mc_types)) {
      tt <- .mc_types[[type]]
      row <- build(type, tt)
      .mc_ops(row[[1L]], row[[2L]], row[[3L]], tt$sentinel, paste(form, type))
      # a point read cannot carry the filter, and refuses rather than drop it
      if (form == "slice") {
        expect_error(extract_points(row[[1L]], cbind(5, 395), bands = 1L), "no pixels to read")
      }
    }
  })
})

local({
  local_pools(2, 1)

  test_that("the pools see the same cells missing", {
    for (form in names(.mc_forms)) {
      tt <- .mc_types$Int16
      row <- .mc_forms[[form]]("Int16", tt)
      .mc_ops(row[[1L]], row[[2L]], row[[3L]], tt$sentinel, form,
              reads = list(.read_pool), maps = list(.comp))
    }
  })

  test_that("a scale that needs rounding reaches the store as the host reads it", {
    cells <- .mc_base * 300
    cells[.mc_mask] <- -9999
    x <- lazy_source(.mc_tile(cells, "Int16", nodata = -9999), scale = 2e-4, offset = 0.5) + 0
    want <- .as_f32(.mc_hide(.mc_base * 300) * 2e-4 + 0.5)
    expect_plan(x, want, "f32", legs = list(.host, .comp), file = FALSE)
  })
})
