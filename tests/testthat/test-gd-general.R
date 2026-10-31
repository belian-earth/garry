# Warp-on-read plans the composite fast path (.cd_spec) does not match: the
# reduce decomposition (.gd_decompose, .execute_gd_reduce) must agree with the
# general scheduler (execute_plan_mirai) and, byte for byte, with the WHOLE
# reachable IR compiled into one kernel, on derived bands, band math, focal,
# and nested reduce -> map -> reduce.


# GTI fixtures (.gg_grid / .gg_gti / .gg_slice / .gg_val) and the strict
# comparator live in helper-gti.R, shared with the composite-direct and
# route-matrix gates.

# Two two-slice composites (bands A, B) on one shared graph.
.gg_composites <- function() {
  gA <- .gg_gti(list(s1 = .gg_val(0),   s2 = .gg_val(10)))
  gB <- .gg_gti(list(s1 = .gg_val(100), s2 = .gg_val(50)))
  g <- graph_new()
  list(A = reduce_over(lazy_stack(list(.gg_slice(gA, "s1", g),
                                       .gg_slice(gA, "s2", g))), "median", "t"),
       B = reduce_over(lazy_stack(list(.gg_slice(gB, "s1", g),
                                       .gg_slice(gB, "s2", g))), "median", "t"))
}

# The oracle: every source warped, the whole IR replayed in one kernel.
.gg_whole_ir <- function(plan, gspec) {
  ny <- gspec$grid@dims[["y"]]
  nx <- gspec$grid@dims[["x"]]
  tmp <- .gd_tmp()
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  info <- .gd_warp_sources(plan, gspec$grid, tmp, .gd_log_open())
  dev <- .exec_device(gspec$device)
  h <- gspec$halo
  inputs <- lapply(gspec$input_nodes, function(id) {
    a <- g_upload_raw(
      readBin(info[[as.character(id)]]$bin, "raw", n = as.numeric(ny) * nx * 4),
      "f32",
      c(ny, nx),
      device = dev
    )
    n <- graph_get(plan@graph, id)
    if (length(n@scale) == 1L) {
      a <- a * n@scale + n@offset
    }
    if (h > 0L) g_pad(a, h, NaN) else a # radius-cell NaN edge boundary
  })
  res <- g_download(.gd_host_kernel(plan@graph, gspec, dev)(inputs))[[1L]]
  .gd_write_stack(res, gspec$grid, NULL, NULL, NULL, NULL)
}

.gg_equal <- function(x) {
  p <- plan_lazy(x)
  gsp <- .gd_spec(p)
  expect_false(is.null(gsp))                          # takes the general path
  expect_true(is.null(.cd_spec(p)))                   # NOT the composite fast path
  gen   <- .gg_whole_ir(p, gsp)
  sched <- execute_plan_mirai(p)
  ok <- !is.nan(as.numeric(sched))
  expect_equal(as.numeric(gen)[ok], as.numeric(sched)[ok], tolerance = 1e-5)
  # Reduce-decomposition (the general path): compute the leaf temporal reduces
  # via the overlapped per-band pipeline, then run the upper IR on the 2D results
  # -- byte-identical to the whole-grid kernel.
  dc <- .gd_decompose(p)
  expect_false(is.null(dc))
  .gg_identical(.execute_gd_reduce(p, dc), gen)
}

test_that("a derived band (map over reduces) runs warp-on-read == scheduler", {
  local_pools(2, 2)
  cs <- .gg_composites()
  .gg_equal((cs$A - cs$B) / (cs$A + cs$B))            # ndvi shape
})

test_that("nested reduce -> map -> reduce runs warp-on-read == scheduler", {
  local_pools(2, 2)
  cs <- .gg_composites()
  ndvi <- (cs$A - cs$B) / (cs$A + cs$B)
  # a second derived band, then reduce over the band axis of the two
  top <- reduce_over(lazy_stack(list(ndvi, cs$A * 2 - cs$B), along = "band"),
                     "sum", "band")
  .gg_equal(top)
})

test_that("a focal on a composite runs warp-on-read == scheduler", {
  local_pools(2, 2)
  cs <- .gg_composites()
  .gg_equal(focal_map(cs$A, radius = 1L, fn = function(sh) Reduce(`+`, sh) / length(sh)))
})

test_that("collect() routes a derived band through the general path", {
  local_pools(2, 2)
  cs <- .gg_composites()
  ndvi <- (cs$A - cs$B) / (cs$A + cs$B)
  got  <- collect(ndvi, distributed = TRUE)
  want <- collect(ndvi, distributed = FALSE)
  ok <- !is.nan(as.numeric(want))
  expect_equal(as.numeric(got)[ok], as.numeric(want)[ok], tolerance = 1e-5)
})
