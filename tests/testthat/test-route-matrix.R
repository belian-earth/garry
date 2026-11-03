# Route matrix: canonical plans swept through every offline execution
# route, in memory and written to path, each held to a value from plain R
# and to the route it was forced onto (garry_last_route()). collect() picks
# cd_spec -> gd_decompose -> scheduler silently, and a plan changing route
# is exactly the regression class an equivalence suite must observe.
#
# This file owns "this plan is equal across routes". Other files assert what
# it cannot: route predicates, plan shape, kernel reuse.

# The scheduler, with the fast routes off.
.rm_sched <- function(mode, ...) {
  .leg(opts = list(garry.placement = mode, garry.composite_direct = FALSE, ...))
}

# Every way collect() can run a plan. The default placement is cost, so a plan
# whose own route is the scheduler has no cost row to add.
.rm_legs <- function(route) {
  c(
    list(.host, .rm_sched("rules")),
    if (route != "scheduler") list(.rm_sched("cost")),
    list(.leg(route))
  )
}

# A kernel shipped as a closure rather than a program, the way out the
# error at a failed program names (.program_miss()). Compute daemons on a
# GPU take this wire, so no CPU run reaches it but this leg.
.rm_closure <- .rm_sched("rules", garry.kernel_wire = "closure", garry.stage_merge = "guarded")

# Enough to split the scheduler's rows into chunks. The fast routes tile their
# own jobs.
.rm_px <- 600

# The band stack collect() and write_tif() take a masked composite as.
.rm_composite <- function(...) stack_bands(.gg_masked_composite(...))

# Medians of the two slices of a composite pair, on one shared graph.
.rm_median <- function(g, gti) {
  reduce_over(lazy_stack(list(.gg_slice(gti, "s1", g), .gg_slice(gti, "s2", g))), "median", "t")
}

local({
  # Two compute daemons: the fast routes fan their jobs out over the profiles,
  # and no other file runs them on more than one.
  local_pools(2, 2)

  test_that("a masked composite holds its value on every route", {
    expect_plan(.rm_composite(), .gg_masked_want(), "f32",
                legs = .rm_legs("composite_direct"), px = .rm_px)
  })

  test_that("a UInt16 masked composite holds its value on every route", {
    expect_plan(.rm_composite(type = "UInt16", dtype = "u16"), .gg_masked_want(), "f32",
                legs = c(.rm_legs("composite_direct"), list(.rm_closure)), px = .rm_px)
  })

  test_that("a single band composite runs the whole-grid kernel", {
    x <- .rm_composite(single = TRUE)
    expect_identical(.cd_spec(collect(x, plan_only = TRUE))$n_bands, 1L)
    expect_plan(x, .gg_masked_want(single = TRUE), "f32", legs = list(.leg("composite_direct")))
  })

  test_that("bands with different per-slice fns leave the composite route", {
    gA <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
    gB <- .gg_gti(list(s1 = .gg_val(100), s2 = .gg_val(50)))
    g <- graph_new()
    a <- list(.gg_slice(gA, "s1", g), .gg_slice(gA, "s2", g))
    b <- list(.gg_slice(gB, "s1", g), .gg_slice(gB, "s2", g))
    x <- lazy_stack(
      list(
        d = reduce_over(lazy_stack(Map(`-`, a, b)), "mean", "t"),
        p = reduce_over(lazy_stack(Map(`*`, a, b)), "mean", "t")
      ),
      along = "band"
    )
    expect_null(.cd_spec(collect(x, plan_only = TRUE)))
    products <- (.gg_val(0) * .gg_val(100) + .gg_val(10) * .gg_val(50)) / 2
    want <- array(c(matrix(-70, 40L, 60L), products), c(40L, 60L, 2L))
    expect_plan(x, want, "f32", legs = list(.leg("gd_reduce")))
  })

  test_that("a quantized write leaves the fast routes and stores what they hold", {
    expect_written(.rm_composite(), .gg_masked_want() * 2, "i16",
                   legs = list(.host, .leg("scheduler")), scale = 0.5)
  })

  # Each fast route has its own writer, and only cells no slice holds put a
  # sentinel in it.
  test_that("a cell no slice holds reaches the file as the sentinel", {
    want <- .gg_masked_want(overlap = TRUE)
    expect_true(anyNA(want))
    expect_written(.rm_composite(overlap = TRUE), want, "f32",
                   legs = list(.leg("composite_direct")), nodata = -9999)
    bands <- .gg_masked_composite(overlap = TRUE)
    a <- want[, , 1L]
    b <- want[, , 2L]
    expect_written((bands$V1 - bands$V2) / (bands$V1 + bands$V2), .as_f32((a - b) / (a + b)), "f32",
                   legs = list(.leg("gd_reduce")), nodata = -9999)
  })

  test_that("a derived band (map over reduces) holds its value on every route", {
    gA <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
    gB <- .gg_gti(list(s1 = .gg_val(100), s2 = .gg_val(50)))
    g <- graph_new()
    A <- .rm_median(g, gA)
    B <- .rm_median(g, gB)
    a <- .gg_val(5)
    b <- .gg_val(75)
    expect_plan((A - B) / (A + B), .as_f32((a - b) / (a + b)), "f32",
                legs = .rm_legs("gd_reduce"), px = .rm_px)
  })

  test_that("a scan plan holds its value on every route (no fast route)", {
    gA <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
    g <- graph_new()
    body <- function(xs, margin) {
      g_scan(
        init = 0,
        body = function(carry, v) {
          s <- carry + v
          list(carry = s, out = s)
        },
        xs = xs[[1L]]
      )$out
    }
    sc <- scan_over(lazy_stack(list(.gg_slice(gA, "s1", g) + 1,
                                    .gg_slice(gA, "s2", g) * 2)),
                    body, over = "t")
    first <- .gg_val(0) + 1
    want <- array(c(first, first + .gg_val(10) * 2), c(40L, 60L, 2L))
    expect_plan(sc, want, "f32", legs = .rm_legs("scheduler"), px = .rm_px)
  })
})
