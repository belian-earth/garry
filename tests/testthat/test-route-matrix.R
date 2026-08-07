# Route matrix: canonical plans swept through every offline execution
# route, in memory and written to path, all asserted equal AND asserted
# to have run the route they were forced onto (garry_last_route()).
# Catches silent route flips: collect() picks cd_spec -> gd_decompose ->
# scheduler silently, and a plan changing route is exactly the
# regression class an equivalence suite must observe to catch.

skip_if(!requireNamespace("garry", quietly = TRUE),
        "garry not installed for daemons")

# The four collect()-reachable cases; the fast path resolves to
# composite_direct / gd_reduce / scheduler depending on plan shape, so
# the caller names the expected route.
.rm_cases <- function(fast_route) list(
  single = list(opts = list(), distributed = FALSE, route = "single"),
  scheduler_rules = list(
    opts = list(garry.placement = "rules", garry.composite_direct = FALSE),
    distributed = TRUE, route = "scheduler"),
  scheduler_cost = list(
    opts = list(garry.placement = "cost", garry.composite_direct = FALSE),
    distributed = TRUE, route = "scheduler"),
  fast = list(opts = list(), distributed = TRUE, route = fast_route)
)

.rm_read_back <- function(path, nb) {
  cube <- gdal_read_window(path, seq_len(nb), 0L, 0L, 60L, 40L,
                           nodata = -9999)
  if (length(dim(cube)) == 3L) aperm(cube, c(2L, 3L, 1L)) else cube
}

# Sweep one plan through every case x {in-memory, written}; every cell
# must match the single-threaded in-memory result.
.rm_sweep <- function(x, fast_route, tol = 1e-6) {
  base <- NULL
  for (nm in names(.rm_cases(fast_route))) {
    cs <- .rm_cases(fast_route)[[nm]]
    old <- if (length(cs$opts)) do.call(options, cs$opts)
    mem <- collect(x, distributed = cs$distributed)
    expect_identical(garry_last_route(), cs$route)
    path <- tempfile(fileext = ".tif")
    write_tif(x, path, nodata = -9999, distributed = cs$distributed)
    expect_identical(garry_last_route(), cs$route)
    nb <- if (is.null(dim(mem))) 1L
          else if (length(dim(mem)) == 3L) dim(mem)[[3L]] else 1L
    fil <- .rm_read_back(path, nb)
    unlink(path)
    if (!is.null(old)) options(old)
    if (is.null(base)) base <- mem else .gg_close(mem, base, tol)
    .gg_close(fil, base, tol)
  }
}

test_that("a masked composite is identical on every route", {
  local_pools(2, 2)
  .rm_sweep(.gg_masked_composite(), fast_route = "composite_direct")
})

test_that("a derived band (map over reduces) is identical on every route", {
  local_pools(2, 2)
  gA <- .gg_gti(list(s1 = .gg_val(0),   s2 = .gg_val(10)))
  gB <- .gg_gti(list(s1 = .gg_val(100), s2 = .gg_val(50)))
  g <- graph_new()
  A <- reduce_over(lazy_stack(list(.gg_slice(gA, "s1", g),
                                   .gg_slice(gA, "s2", g))), "median", "t")
  B <- reduce_over(lazy_stack(list(.gg_slice(gB, "s1", g),
                                   .gg_slice(gB, "s2", g))), "median", "t")
  .rm_sweep((A - B) / (A + B), fast_route = "gd_reduce", tol = 1e-5)
})

test_that("a scan plan is identical on every route (fast path = scheduler)", {
  local_pools(2, 2)
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
  .rm_sweep(sc, fast_route = "scheduler")
})
