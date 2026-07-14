# Stage-merge pass gate: single-consumer compute chains fuse into
# their consumer (mask -> stack -> median -> band stack runs as ONE
# XLA program per chunk, no store round-trips); multi-consumer
# producers and focal stages stay materialised.

skip_if_not_installed("anvl")

# Two bands + one shared QA on a common grid.
.merge_fixtures <- function() {
  mk <- function(name, vals, dtype = "Float32") {
    fp <- file.path(tempdir(), sprintf("garry-sm-%s.tif", name))
    if (file.exists(fp)) return(fp)
    ds <- gdalraster::create("GTiff", fp, 12, 9, 1, dtype,
                             return_obj = TRUE)
    ds$setGeoTransform(c(0, 10, 0, 90, 0, -10))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    ds$write(1, 0, 0, 12, 9, as.numeric(vals))
    ds$close()
    fp
  }
  n <- 12 * 9
  list(b1 = mk("b1", seq_len(n)),
       b2 = mk("b2", seq_len(n) * 10),
       qa = mk("qa", rep(c(0, 2, 0), length.out = n), dtype = "Byte"))
}

.masked_slice <- function(band_path, qa_path, off) {
  lazy_map(lazy_source(band_path) + off, lazy_source(qa_path),
           dtype = "f32", fn = function(x, q) {
             bad <- g_bitand(g_cast(q, "i32"), 2L) > 0
             g_ifelse(bad, NaN, x)
           })
}

test_that("mask -> stack -> median fuses per band; the band-stack join stays a boundary", {
  fx <- .merge_fixtures()
  composite_of <- function(band) {
    masked <- lapply(c(0, 100), function(off)
      .masked_slice(band, fx$qa, off))
    reduce_over(lazy_stack(masked), "median", "t", nan_rm = TRUE)
  }

  # A single composite still fuses completely into one stage.
  p1 <- collect(composite_of(fx$b1), plan_only = TRUE)
  kinds1 <- vapply(p1@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds1 == "compute"), 1L)

  out <- lazy_stack(list(composite_of(fx$b1), composite_of(fx$b2)),
                    along = "band")

  # Fusion never crosses a reduction into a join: each band's
  # mask -> stack -> median fuses to ONE stage, but the medians do not
  # fold into the band stack, so band 1's compute chunks depend only
  # on band 1's (+ QA) reads and overlap band 2's read drain.
  p <- collect(out, plan_only = TRUE)
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds == "compute"), 3L)     # 2 bands + band stack
  expect_identical(sum(kinds == "source_read"), 3L) # b1, b2, qa (dedup)
  sink <- p@stages[[p@sink]]
  expect_identical(length(sink@inputs), 2L)         # the two band stages
  for (sid in sink@inputs) {
    s <- p@stages[[sid]]
    in_kinds <- kinds[s@inputs]
    expect_true(all(in_kinds == "source_read"))     # band + qa only
    expect_identical(length(s@inputs), 2L)
  }

  # Correctness vs base R.
  got <- collect(out)
  b1 <- gdal_read_window(fx$b1, 1L, 0L, 0L, 12L, 9L)
  b2 <- gdal_read_window(fx$b2, 1L, 0L, 0L, 12L, 9L)
  q <- gdal_read_window(fx$qa, 1L, 0L, 0L, 12L, 9L)
  bad <- bitwAnd(as.integer(q), 2L) > 0
  want_of <- function(b) {
    m0 <- ifelse(bad, NaN, b); m1 <- ifelse(bad, NaN, b + 100)
    w <- (m0 + m1) / 2                          # median of two layers
    w[bad] <- NaN
    w
  }
  for (k in 1:2) {
    want <- want_of(list(b1, b2)[[k]])
    slab <- got[, , k]
    expect_identical(is.nan(slab), is.nan(matrix(want, 9, 12)))
    ok <- !is.nan(want)
    expect_equal(slab[matrix(ok, 9, 12)], want[ok], tolerance = 1e-5)
  }
})

test_that("diamond producers fuse once their consumers share a stage", {
  # `shared` feeds two maps inside ONE composite. After the maps fold
  # into the stack+median stage, `shared`'s consumers are ONE stage,
  # so it merges too; the composed closure evaluates each member once,
  # so the value is reused, not recomputed.
  fx <- .merge_fixtures()
  shared <- .masked_slice(fx$b1, fx$qa, 0)
  v1 <- lazy_map(shared, dtype = "f32", fn = function(x) x + 5)
  v2 <- lazy_map(shared, dtype = "f32", fn = function(x) x + 9)
  out <- reduce_over(lazy_stack(list(v1, v2)), "median", "t",
                     nan_rm = TRUE)

  p <- collect(out, plan_only = TRUE)
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds == "compute"), 1L)
  expect_true(shared@node_id %in% p@stages[[p@sink]]@members)

  got <- collect(out)
  expect_identical(dim(got), c(9L, 12L))
  # median of (m + 5, m + 9) = m + 7.
  b1 <- gdal_read_window(fx$b1, 1L, 0L, 0L, 12L, 9L)
  q <- gdal_read_window(fx$qa, 1L, 0L, 0L, 12L, 9L)
  want <- b1 + 7
  want[bitwAnd(as.integer(q), 2L) > 0] <- NaN
  expect_identical(is.nan(got), is.nan(want))
  ok <- !is.nan(want)
  expect_equal(got[ok], want[ok], tolerance = 1e-5)
})

test_that("a reduce feeding a multi-input map stays a stage boundary", {
  # NDVI-like join of two composites: the medians stay materialised
  # (fusing them would make every chunk of the join wait on BOTH
  # subtrees' reads); the join map is its own stage.
  fx <- .merge_fixtures()
  composite_of <- function(band) {
    masked <- lapply(c(0, 100), function(off)
      .masked_slice(band, fx$qa, off))
    reduce_over(lazy_stack(masked), "median", "t", nan_rm = TRUE)
  }
  out <- lazy_map(composite_of(fx$b1), composite_of(fx$b2),
                  dtype = "f32", fn = function(a, b) b - a)
  p <- collect(out, plan_only = TRUE)
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds == "compute"), 3L)

  got <- collect(out)
  b1 <- gdal_read_window(fx$b1, 1L, 0L, 0L, 12L, 9L)
  q <- gdal_read_window(fx$qa, 1L, 0L, 0L, 12L, 9L)
  want <- (b1 * 10 + 50) - (b1 + 50)     # b2 = 10*b1; both + off/2
  want[bitwAnd(as.integer(q), 2L) > 0] <- NaN
  expect_identical(is.nan(got), is.nan(want))
  ok <- !is.nan(want)
  expect_equal(got[ok], want[ok], tolerance = 1e-4)
})

test_that("focal stages do not merge (halo guard) and still execute", {
  fx <- .merge_fixtures()
  layers <- lapply(c(0, 100), function(off) {
    sm <- .masked_slice(fx$b1, fx$qa, off)
    focal(sm, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)
  })
  out <- reduce_over(lazy_stack(layers), "median", "t", nan_rm = TRUE)

  p <- collect(out, plan_only = TRUE)
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  # focal stages keep their own source-fed stages; only the stack+median
  # stage consumes them.
  expect_identical(sum(kinds == "compute"), 3L)
  halos <- vapply(p@stages, function(s) s@halo, integer(1))
  expect_identical(sum(halos[kinds == "compute"] > 0L), 2L)

  got <- collect(out)                # executes without error
  expect_identical(dim(got), c(9L, 12L))
})

test_that("sources with different native blocks share one chunk table", {
  # An Int16 and a Byte source get different GDAL strip heights; the
  # plan-wide chunk dim must tile every stage identically or the fused
  # stage receives differently-shaped input chunks (regression: shapes
  # (223,1259) vs (229,1259) on ragged edges).
  mk <- function(name, dtype, block_y) {
    fp <- tempfile(paste0("garry-blk-", name), fileext = ".tif")
    ds <- gdalraster::create(
      "GTiff", fp, 40, 36, 1, dtype, return_obj = TRUE,
      options = c("TILED=YES", "BLOCKXSIZE=16",
                  sprintf("BLOCKYSIZE=%d", block_y)))
    ds$setGeoTransform(c(0, 10, 0, 360, 0, -10))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    ds$write(1, 0, 0, 40, 36, as.numeric(seq_len(40 * 36)))
    ds$close()
    fp
  }
  f_a <- mk("a", "Int16", 16L)
  f_b <- mk("b", "Byte", 32L)

  masked <- lazy_map(lazy_source(f_a), lazy_source(f_b), dtype = "f32",
                     fn = function(x, q) x + g_cast(q, "f32") * 0)
  out <- reduce_over(lazy_stack(list(masked, masked * 2)), "median", "t",
                     nan_rm = TRUE)

  old <- options(garry.chunk_target_px = 300)   # force several chunks
  on.exit(options(old))
  p <- collect(out, plan_only = TRUE)
  # One shared compute tiling; source tables are integer multiples of
  # it (read-granularity decoupling).
  cdims <- unique(lapply(
    Filter(function(s) s@kind %in% c("compute", "reduce_partial"),
           p@stages),
    function(s) s@chunks@chunk_dim))
  expect_length(cdims, 1L)
  for (s in Filter(function(s) s@kind == "source_read", p@stages))
    expect_identical(unname(s@chunks@chunk_dim %% cdims[[1L]]), c(0L, 0L))

  got <- collect(out)
  m <- gdal_read_window(f_a, 1L, 0L, 0L, 40L, 36L)
  expect_equal(got, m * 1.5, tolerance = 1e-5)   # median(m, 2m)
})

test_that("merged plans run identically under the mirai scheduler", {
  skip_if_not_installed("mirai")
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  fx <- .merge_fixtures()
  composite_of <- function(band) {
    masked <- lapply(c(0, 100), function(off)
      .masked_slice(band, fx$qa, off))
    reduce_over(lazy_stack(masked), "median", "t", nan_rm = TRUE)
  }
  out <- lazy_stack(list(composite_of(fx$b1), composite_of(fx$b2)),
                    along = "band")
  single <- collect(out)

  garry_daemons(2, 2, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  dist <- collect(out, distributed = TRUE)
  expect_identical(is.nan(dist), is.nan(single))
  ok <- !is.nan(single)
  expect_equal(dist[ok], single[ok], tolerance = 0)
})
