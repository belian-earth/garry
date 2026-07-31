# General warp-on-read executor (.gd_spec / .execute_gd_general): the single
# path for any warp-on-read-eligible plan. It warps every GTI source and
# compiles the WHOLE reachable IR into one jit, so derived bands, band math,
# focal, and nested reduce -> map -> reduce all run fused -- and byte-identically
# to the general scheduler (execute_plan_mirai), for any shape .cd_spec (the
# composite fast path) does not match.

skip_if_not_installed("anvl")
skip_if_not_installed("mirai")

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

.gg_equal <- function(x) {
  p <- plan_lazy(x)
  gsp <- .gd_spec(p)
  expect_false(is.null(gsp))                          # takes the general path
  expect_true(is.null(.cd_spec(p)))                   # NOT the composite fast path
  gen   <- .execute_gd_general(p, gsp)
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
  .gg_equal(focal(cs$A, radius = 1L, fn = function(sh) Reduce(`+`, sh) / length(sh)))
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
