# shrink_footprint(): NaN spreads by the radius from every nodata
# boundary, including the raster border (boundary = "nodata"), or from
# real nodata only, keeping the full extent (boundary = "keep").

# Oracle: grow the NaN mask of `ref` by `r` (square window); off-raster
# cells count as nodata when `edge_bad`.
.grow_nan <- function(ref, r, edge_bad) {
  bad <- !is.finite(ref)
  n <- nrow(ref); c <- ncol(ref)
  grown <- bad
  for (dy in -r:r) for (dx in -r:r) {
    ys <- seq_len(n) + dy; xs <- seq_len(c) + dx
    in_y <- ys >= 1L & ys <= n; in_x <- xs >= 1L & xs <= c
    g2 <- matrix(edge_bad, n, c)
    g2[in_y, in_x] <- bad[ys[in_y], xs[in_x]]
    grown <- grown | g2
  }
  out <- ref; out[grown] <- NaN
  out
}

.holed <- function() {
  a <- lazy_source(fixture_gradient_f32())
  m <- collect(a, distributed = FALSE)
  thr <- as.numeric(quantile(m, 0.05))
  ref <- m; ref[m <= thr] <- NaN
  list(lz = lazy_map(a, dtype = "f32", fn = function(x) g_ifelse(x <= thr, NaN, x)),
       ref = ref)
}

test_that("shrink_footprint erodes nodata boundaries by the radius", {
  h <- .holed()
  exp <- .grow_nan(h$ref, 1L, edge_bad = TRUE) # off-raster counts as nodata
  out <- collect(shrink_footprint(h$lz, radius = 1L))
  expect_identical(!is.finite(out), !is.finite(exp))
  keep <- is.finite(exp)
  expect_equal(out[keep], exp[keep], tolerance = 1e-6)
})

test_that("shrink_footprint validates radius", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  expect_error(shrink_footprint(a, radius = 0), "positive")
  expect_error(shrink_footprint(a, radius = c(1, 2)), "positive")
})

test_that("boundary = 'keep' erodes real nodata only and keeps the frame", {
  h <- .holed()
  for (r in 1:2) {
    exp <- .grow_nan(h$ref, r, edge_bad = FALSE)
    for (px in c(1e9, 300)) { # one chunk, and halos across chunks
      .with_chunk_px(px, {
        out <- collect(shrink_footprint(h$lz, radius = r, boundary = "keep"),
                       distributed = FALSE)
        expect_identical(is.nan(out), is.nan(exp), info = paste(r, px))
        ok <- !is.nan(exp)
        expect_equal(out[ok], exp[ok], tolerance = 1e-6)
      })
    }
  }
  # no nodata at all: nothing changes, the frame included
  a <- lazy_source(fixture_gradient_f32())
  out <- collect(shrink_footprint(a, radius = 2, boundary = "keep"), distributed = FALSE)
  expect_false(any(is.nan(out)))
})

test_that("boundary = 'keep' matches pooled and applies per dataset slice", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  h <- .holed()
  exp <- .grow_nan(h$ref, 2L, edge_bad = FALSE)
  ds <- as_dataset(list(V = list(s1 = h$lz, s2 = h$lz * 2)))
  out_ds <- shrink_footprint(ds, radius = 2, boundary = "keep")
  local_pools(2, 1)
  got <- collect(shrink_footprint(h$lz, radius = 2, boundary = "keep"))
  expect_identical(is.nan(got), is.nan(exp))
  s2 <- collect(out_ds@bands$V$s2)
  expect_identical(is.nan(s2), is.nan(exp))
})

test_that("boundary = 'keep' refuses rasters with outer dims", {
  a <- lazy_source(fixture_gradient_f32())
  stk <- lazy_stack(list(a, a))
  expect_error(shrink_footprint(stk, radius = 1, boundary = "keep"), "2-D")
  expect_error(shrink_footprint(a, radius = 1, boundary = "edge"), "boundary")
})
