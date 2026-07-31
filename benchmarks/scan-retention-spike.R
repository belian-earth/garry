# Workstream B characterisation (design/tail-phase-plan.md): what is
# the ~6.5 GB a compute daemon RETAINS after running scan chunks, and
# what gives it back?
#
#   E1a  same kernel, repeated runs      -> plateau (reusable pool)?
#   E1b  distinct kernels, sequentially  -> step growth (accumulation)?
#   E2   evict .daemon_cache + gc        -> R-side / executable share
#   E3   malloc_trim(0) on the daemon    -> glibc-arena share
#   E5   fresh daemon                    -> the true floor
#
# Workload mirrors the SI tail: kalman_llt (robust LLT, f64) scan_over
# a 13-slice (t, y, x) pair of stacks, ~1 Mpx chunks, 1 compute daemon.
#
# Run: systemd-run --user --scope -p MemoryMax=24G \
#        Rscript benchmarks/scan-retention-spike.R

library(garry)

OUT <- Sys.getenv("SPIKE_OUT",
                  file.path(tempdir(), "scan-retention"))
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)

nx <- 4096L; ny <- 2048L; nt <- 13L
f <- file.path(OUT, "base.tif")
if (!file.exists(f)) {
  d <- gdalraster::create("GTiff", f, nx, ny, 1, "Float32",
                          return_obj = TRUE)
  d$setGeoTransform(c(0, 10, 0, ny * 10, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  set.seed(7)
  for (y0 in seq(0L, ny - 1L, by = 256L)) {
    h <- min(256L, ny - y0)
    d$write(1, 0, y0, nx, h, runif(nx * h, 1, 10))
  }
  d$close()
}

build_scan <- function(hyp, output) {
  g <- graph_new()
  ys <- lazy_stack(lapply(1:nt, function(i)
    lazy_source(f, graph = g) * (1 + 0.02 * i)), along = "t")
  rs <- lazy_stack(lapply(1:nt, function(i)
    lazy_source(f, graph = g) * 0 + 1), along = "t")
  scan_over(list(ys, rs),
            kalman_llt(hyp[[1L]], hyp[[2L]], hyp[[3L]], output = output,
                       robust_iters = 1L, out_dtype = "f64"),
            over = "t")
}

comp_pid <- function() vapply(
  mirai::everywhere(Sys.getpid(), .compute = "garry_compute"),
  function(m) m[], integer(1))[[1L]]

anon_mb <- function(pid) {
  s <- tryCatch(readLines(sprintf("/proc/%d/status", pid), warn = FALSE),
                error = function(e) character(0))
  ln <- grep("^RssAnon:", s, value = TRUE)
  if (!length(ln)) return(NA_real_)
  as.numeric(strsplit(trimws(sub("^RssAnon:", "", ln)), "\\s+")[[1L]][[1L]]) / 1024
}

options(garry.chunk_target_px = 1e6,
        garry.task_log = file.path(OUT, "tasklog.csv"))

garry_daemons(2, 1, gdal_config = FALSE)
pid <- comp_pid()
t0 <- Sys.time()
mark <- function(label) cat(sprintf(
  "[%6.0fs] %-40s comp anon %7.0f MB\n",
  as.numeric(Sys.time() - t0, units = "secs"), label, anon_mb(pid)))

# 0.5 s background tracer for the within-run curve
tr <- file.path(OUT, "tracer.sh")
writeLines(c(
  "#!/bin/sh",
  "PID=$1",
  "while kill -0 $PID 2>/dev/null; do",
  "  A=$(awk '/^RssAnon/{print $2}' /proc/$PID/status 2>/dev/null)",
  "  echo \"$(date +%s.%N),$A\"",
  "  sleep 0.5",
  "done"), tr)
Sys.chmod(tr, "0755")
system2(tr, as.character(pid), wait = FALSE,
        stdout = file.path(OUT, "anon-trace.csv"))

mark("baseline (fresh pools)")

# -- E1a: same kernel, twice ------------------------------------------------
p1 <- collect(build_scan(list(0.1, 0.05, 1), "mean"), plan_only = TRUE)
invisible(execute_plan_mirai(p1)); mark("E1a run 1 (mean kernel, ~8 chunks)")
invisible(execute_plan_mirai(p1)); mark("E1a run 2 (same kernel)")

# -- E1b: five more distinct kernels ---------------------------------------
variants <- list(list(0.1, 0.05, 1), list(0.2, 0.05, 1), list(0.1, 0.1, 1))
for (i in seq_along(variants)) for (outp in c("mean", "sd")) {
  if (i == 1L && outp == "mean") next
  p <- collect(build_scan(variants[[i]], outp), plan_only = TRUE)
  invisible(execute_plan_mirai(p))
  mark(sprintf("E1b + kernel %s / hyp %d", outp, i))
}

# -- E2: evict the jit cache + gc ------------------------------------------
invisible(lapply(mirai::everywhere({
  e <- garry:::.daemon_cache
  rm(list = ls(e), envir = e)
  gc()
}, .compute = "garry_compute"), function(m) m[]))
Sys.sleep(2); mark("E2 after .daemon_cache eviction + gc")

# -- E3: malloc_trim(0) -----------------------------------------------------
trim_ok <- tryCatch({
  invisible(lapply(mirai::everywhere({
    Rcpp::cppFunction("void mtrim() { malloc_trim(0); }",
                      includes = "#include <malloc.h>")
    mtrim()
  }, .compute = "garry_compute"), function(m) m[]))
  TRUE
}, error = function(e) { cat("E3 unavailable:", conditionMessage(e), "\n"); FALSE })
if (trim_ok) { Sys.sleep(2); mark("E3 after malloc_trim(0)") }

# -- post-trim rerun: does the pool re-grow to the same plateau? -----------
invisible(execute_plan_mirai(p1)); mark("rerun same kernel after E2+E3")

# -- E5: the floor ----------------------------------------------------------
garry_daemons(0, 0, gdal_config = FALSE)
garry_daemons(2, 1, gdal_config = FALSE)
pid <- comp_pid()
mark("E5 fresh daemon (floor)")
garry_daemons(0, 0, gdal_config = FALSE)

cat("\ntrace:", file.path(OUT, "anon-trace.csv"),
    "\ntasklog:", file.path(OUT, "tasklog.csv"), "\n")
