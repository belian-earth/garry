# Memory admission control. The configured budgets (ram_budget_mb x
# compute pool, read_budget_mb) are caps, not entitlements: execution
# fits them inside a fraction of what is ACTUALLY available, re-read
# during the drain. Availability must respect this process's cgroup, not
# just host MemAvailable -- inside a container / systemd scope / SLURM
# step the host figure is meaningless and budgeting on it overcommits
# straight into a cgroup OOM kill.

test_that("available RAM accounts for a cgroup limit when one applies", {
  skip_on_os(c("windows", "mac", "solaris"))
  skip_if_not(file.exists("/proc/meminfo"))
  host <- .garry_ram_avail_mb()
  expect_true(is.na(host) || host > 0)

  cg <- .garry_cgroup_avail_mb()
  if (is.na(cg)) {
    # No (or unlimited) cgroup: availability is just the host figure.
    succeed()
  } else {
    # Under a limit, the reported figure can never exceed the headroom.
    expect_lte(host, cg + 1e-6)
  }
})

test_that("cgroup headroom is NA when unlimited or unreadable", {
  skip_on_os(c("windows", "mac", "solaris"))
  # Whatever this process sits in, the helper must return a number or NA
  # and never error -- it runs on every distributed execution.
  v <- .garry_cgroup_avail_mb()
  expect_true(is.na(v) || (is.numeric(v) && v >= 0))
})

test_that("the exec_ram_fraction option is registered and sane", {
  f <- garry_opt("exec_ram_fraction")
  expect_true(is.numeric(f), f > 0, f <= 1)
})

test_that("a distributed run still completes with a tiny memory fraction", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("mirai")
  skip_if_not_installed("mori")
  skip_on_cran()
  # Squeezing the fraction to ~0 drives every gate to its floor (one
  # compute task, one read window at a time). That must serialise, not
  # deadlock, and must not change the answer.
  f <- fixture_gradient_f32()
  g <- graph_new()
  out <- reduce_over(lazy_stack(lapply(1:4, function(i)
    lazy_source(f, graph = g) * i), along = "t"), "sum", "t", nan_rm = TRUE)
  mem <- collect(out, distributed = FALSE)

  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  old <- options(garry.exec_ram_fraction = 1e-6,
                 garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)
  got <- suppressMessages(collect(out, distributed = TRUE))
  expect_equal(got, mem, tolerance = 1e-6)
})
