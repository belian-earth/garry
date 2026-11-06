# A garry daemon's launcher (R/tasks.R, .pools_spawn()). garry starts every
# daemon of a pool generation at once, each with this script, before it creates
# their mizu pools, so the R start-ups run side by side rather than one per
# pool. The script loads mizu, writes its pid, then waits for its token file:
# the join token and slot of the pool garry made for it, written once the pool
# exists. It then runs as that pool's worker until the pool stops.
#
# argv, hex-encoded (any path survives, with no quoting): the token file, then
# the host's library paths. A daemon garry never joins exits after two minutes,
# or as soon as its generation's directory is gone.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L || !all(grepl("^([0-9a-f][0-9a-f])+$", args))) {
  quit(save = "no", status = 2L)
}
unhex <- function(x) {
  n <- nchar(x)
  s <- rawToChar(as.raw(strtoi(
    substring(x, seq.int(1L, n, 2L), seq.int(2L, n, 2L)),
    16L
  )))
  Encoding(s) <- "UTF-8"
  s
}
.libPaths(vapply(args[-1L], unhex, character(1L), USE.NAMES = FALSE))
f <- unhex(args[[1L]])
loadNamespace("mizu")
writeLines(as.character(Sys.getpid()), paste0(f, ".pid"))
t0 <- Sys.time()
while (!file.exists(f)) {
  if (
    !dir.exists(dirname(f)) || difftime(Sys.time(), t0, units = "secs") > 120
  ) {
    quit(save = "no", status = 3L)
  }
  Sys.sleep(0.002)
}
tok <- readLines(f)
# A daemon shares the host's process group, so a Ctrl-C at the host's
# terminal reaches it too. No one interrupts a daemon on purpose: a cancel
# never does, and a pool stops through its shared memory. So the worker's own
# loop takes no interrupt, and each task resumes through one
# (garry:::.daemon_resumable()), as mizu turns interrupts back on to run it.
suspendInterrupts(mizu:::worker_main(tok[[1L]], as.integer(tok[[2L]])))
