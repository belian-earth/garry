# ---------------------------------------------------------------------------
# Central policy constants. Planner and executor tunables are read through
# garry_opt() so there is exactly one source of truth for defaults.
# ---------------------------------------------------------------------------

.garry_defaults <- list(
  # Minimum pixels per chunk the planner aims for. Below this, per-call
  # dispatch overhead (~410 us measured in the spike) stops being
  # negligible relative to kernel runtime.
  chunk_target_px = 1e6,
  # Per-worker RAM budget (MB) used by the chunking pass to cap chunk size.
  ram_budget_mb = 512,
  # Safety margin, in input cells, added to cross-CRS planning windows.
  # Planning windows must CONTAIN the true window (decision D5); the
  # margin absorbs residual densification error.
  window_margin = 2L,
  # Print task-completion progress from the distributed scheduler.
  # Long network-bound plans are otherwise silent for minutes.
  progress = FALSE,
  # Max open GDAL dataset handles per process (LRU-evicted, closed on
  # eviction). Open warped/GTI mosaics pin warper + cache memory; on
  # daemons this bounds it. Reopening an evicted dataset is cheap.
  handle_cache_max = 4L
)

#' Read a garry policy option.
#'
#' Looks up `getOption("garry.<name>")`, falling back to the package
#' default. Unknown names error: constants must be registered in
#' `.garry_defaults` so defaults live in one place.
#'
#' @param name Option name without the `garry.` prefix.
#' @return The option value.
#' @export
garry_opt <- function(name) {
  if (!name %in% names(.garry_defaults))
    stop("unknown garry option: ", name)
  getOption(paste0("garry.", name), .garry_defaults[[name]])
}
