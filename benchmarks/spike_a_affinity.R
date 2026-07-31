# Spike A: does per-daemon CPU affinity bound the XLA CPU client's
# thread pool? XLA sizes its eigen pool via tsl::port::MaxParallelism()
# (NumSchedulableCPUs), which respects sched_setaffinity; the client
# inits lazily on first g_jit. Two conditions, fresh daemons each:
#   uncapped  - no affinity, expect ~all-cores thread pool
#   capped    - taskset -cp <k cpus> before any jit, expect ~k pool
# Reports per-daemon: Threads, Cpus_allowed_list, VmRSS after one jit.
suppressMessages(library(mirai))

daemon_probe <- function() {
  suppressMessages(library(garry))
  t0 <- Sys.time()
  jf <- garry:::g_jit(function(ins) {
    x <- ins[[1L]]
    x * 2 + 1
  })
  up <- garry:::g_upload(matrix(runif(512 * 512), 512), "f32")
  invisible(garry:::g_download(jf(list(up))[[1L]]))
  jit_s <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  st <- readLines(sprintf("/proc/%d/status", Sys.getpid()))
  pick <- function(k) sub(paste0(k, ":\\s*"), "", grep(paste0("^", k, ":"), st, value = TRUE))
  list(pid = Sys.getpid(),
       threads = pick("Threads"),
       cpus = pick("Cpus_allowed_list"),
       rss_kb = pick("VmRSS"),
       jit_s = round(jit_s, 2))
}

run_cond <- function(n, k = NULL) {
  daemons(n)
  on.exit(daemons(0L), add = TRUE)
  pids <- vapply(everywhere(Sys.getpid()), function(m) m[], integer(1))
  if (!is.null(k)) {
    cores <- parallel::detectCores()
    for (i in seq_along(pids)) {
      lo <- ((i - 1L) * k) %% cores
      lst <- paste(seq(lo, lo + k - 1L) %% cores, collapse = ",")
      system2("taskset", c("-a", "-cp", lst, pids[[i]]), stdout = FALSE)
    }
  }
  res <- lapply(everywhere(daemon_probe(), daemon_probe = daemon_probe),
                function(m) m[])
  for (r in res)
    cat(sprintf("  pid %-7s threads %-4s cpus %-12s rss %-12s jit %ss\n",
                r$pid, r$threads, r$cpus, r$rss_kb, r$jit_s))
  invisible(res)
}

cat("== uncapped (4 readers, no affinity) ==\n")
run_cond(4L)
cat("== capped (4 readers, k=2 disjoint) ==\n")
run_cond(4L, k = 2L)
cat("== capped (8 readers, k=2 disjoint) ==\n")
run_cond(8L, k = 2L)
