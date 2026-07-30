# Width-1 mirai profile routing spike (deep review 2026-07-31, roadmap
# item 10). Question: can per-daemon width-1 profiles give the
# scheduler DAEMON IDENTITY — routing a task to a chosen daemon — at
# negligible dispatch overhead? If yes, directed dispatch could retire
# the cold-kernel slow start + scan-compile surcharge (warm-daemon
# reuse) and reopen wide compute pools for scan tails.
#
# Run: Rscript benchmarks/width1-routing-spike.R
# Results: design/width1-routing-spike.md

library(mirai)

N <- 8L
N_TASKS <- 2000L

fmt <- function(x) sprintf("%.3f", x)

# -- A. dispatch overhead: one width-N pool vs N width-1 profiles ------------

daemons(N, .compute = "pool")
for (i in seq_len(N)) daemons(1L, .compute = paste0("d", i))
Sys.sleep(1)

bench <- function(label, dispatch) {
  # warm-up round
  invisible(lapply(dispatch(64L), function(m) m[]))
  t0 <- proc.time()[["elapsed"]]
  ms <- dispatch(N_TASKS)
  vals <- vapply(ms, function(m) m[], numeric(1))
  el <- proc.time()[["elapsed"]] - t0
  stopifnot(identical(length(vals), as.integer(N_TASKS)))
  cat(sprintf("%-28s %8.3f s  (%5.1f us/task)\n", label, el,
              1e6 * el / N_TASKS))
  el
}

t_pool <- bench("width-8 pool", function(n)
  lapply(seq_len(n), function(i) mirai(x + 1, x = i, .compute = "pool")))
t_rr <- bench("8 x width-1, round-robin", function(n)
  lapply(seq_len(n), function(i)
    mirai(x + 1, x = i, .compute = paste0("d", 1L + (i %% N)))))

# -- B. identity: do width-1 profiles really pin tasks to one daemon? --------

pids <- vapply(seq_len(N), function(i)
  mirai(Sys.getpid(), .compute = paste0("d", i))[], integer(1))
hit <- vapply(seq_len(200L), function(k) {
  i <- 1L + (k %% N)
  mirai(Sys.getpid(), .compute = paste0("d", i))[] == pids[[i]]
}, logical(1))
cat(sprintf("identity: %d/200 tasks landed on the addressed daemon; %d distinct pids\n",
            sum(hit), length(unique(pids))))

# -- C. warm-state routing: fake compile (0.5 s) on 2 of 8 daemons -----------
# A "scan task" needs the compiled state; cold daemons pay the compile.
# Directed: route the 16 tasks only at the 2 pre-warmed daemons.
# Anonymous: the width-8 pool spreads them, most daemons compile cold.

# State must live cleanup-proof (mirai daemons reset globalenv between
# tasks); garry's real jit cache is a namespace env, so use it.
task <- quote({
  e <- garry:::.daemon_cache          # env: mutate by reference
  if (is.null(e[["warm"]])) {
    Sys.sleep(0.5)
    e[["warm"]] <- TRUE
  }
  Sys.sleep(0.05)
  Sys.getpid()
})
warm <- function(profile) mirai(eval(t), t = task, .compute = profile)

# directed: warm d1, d2, then route every task at them (depth 2 each)
invisible(lapply(c("d1", "d2"), function(p) warm(p)[]))
t0 <- proc.time()[["elapsed"]]
ms <- lapply(seq_len(16L), function(i)
  mirai(eval(t), t = task, .compute = paste0("d", 1L + (i %% 2L))))
p_dir <- vapply(ms, function(m) m[], integer(1))
t_dir <- proc.time()[["elapsed"]] - t0

# anonymous: fresh state on the pool (its daemons are cold for .warm)
t0 <- proc.time()[["elapsed"]]
ms <- lapply(seq_len(16L), function(i) mirai(eval(t), t = task, .compute = "pool"))
p_anon <- vapply(ms, function(m) m[], integer(1))
t_anon <- proc.time()[["elapsed"]] - t0

cat(sprintf("warm-routing: directed %.2f s over %d daemons; anonymous %.2f s over %d daemons\n",
            t_dir, length(unique(p_dir)), t_anon, length(unique(p_anon))))

daemons(0, .compute = "pool")
for (i in seq_len(N)) daemons(0, .compute = paste0("d", i))

cat(sprintf("\noverhead ratio (width-1 rr / pool): %.2fx\n", t_rr / t_pool))
