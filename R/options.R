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
  handle_cache_max = 4L,
  # Pixels a single source/warp read task aims for. Reads are coarser
  # than compute chunks (windowed reads of warped mosaics decompress
  # the same source blocks regardless of window size, so small read
  # windows amplify transfer); compute chunks slice out of the read
  # buffer. Applies only to halo-free plans.
  read_target_px = 3.2e7,
  # Path to a CSV the distributed scheduler appends per-task
  # launch/done timestamps to (plus drain_end/host_end marks), for
  # profiling where a plan's wall time goes. NULL disables.
  task_log = NULL,
  # Inter-stage chunk store for the distributed executor: "rds" writes
  # one uncompressed RDS per (stage, chunk) in tempdir(); "mori" keeps
  # chunks in POSIX shared memory (zero-copy across same-host daemons,
  # no producer-side split, no disk churn; needs the mori package and
  # the run's working set to fit in RAM).
  store = "rds",
  # What a failed source read does: "error" aborts the plan; "nodata"
  # logs a warning and yields an all-NaN window, so one bad object /
  # expired token / 404 costs a hole in the composite instead of the
  # whole run (odc-stac's fail_on_error=FALSE, stackstac's
  # errors_as_nodata).
  read_fail = "error",
  # Pooled scheduler (garry_daemons): optional hard cap on in-flight
  # compute chunks, on top of the byte budget (per-task resident
  # estimates gated against ram_budget_mb x pool size — small chunks
  # flow at full pool width, big fused medians self-limit). NULL =
  # twice the compute pool.
  compute_inflight = NULL,
  # Pooled scheduler: pre-compile each compute stage's modal chunk
  # shape on every compute-pool daemon at run start, while the read
  # pool owns the drain. Removes the first-execution compile
  # (~0.9 s/stage measured) from the tail. Ignored without pools.
  jit_warmup = TRUE,
  # Device compute stages jit and upload on: "cpu" (anvl's default
  # device) or "cuda" (requires the CUDA PJRT plugin; pair with a
  # small compute pool — concurrent chunks share the GPU's memory).
  # Reads and host-side combines are always CPU.
  device = "cpu",
  # Store-value payloads for the distributed executor (phase 12c):
  # "raw" holds f32 stage values as native byte payloads (row-major,
  # D19) so store traffic is 4 B/px and uploads/downloads are memcpys
  # with no R-double conversion; "double" is the historical R-matrix
  # store; "auto" uses raw when the installed anvl accepts raw
  # payloads (.g_has_raw_upload) and double otherwise. The
  # single-threaded executor always uses R matrices (it is the
  # correctness oracle).
  store_values = "auto",
  # Fetch/assemble split for GTI sources in the distributed scheduler
  # (phase 12): "auto" fetches per-item native windows to local tmpfs
  # first when the index holds remote (/vsi*) locations, then
  # assembles the mosaic locally — a remote warped read is ~74%
  # sequential network wait, so many tiny fetches saturate the link
  # where few big warped reads cannot. "direct" reads remote mosaics
  # as before; "force" fetches even local sources (testing; staging
  # slow filesystems).
  fetch = "auto",
  # Phase 12d GDAL-direct temporal-composite fast path. When TRUE and the
  # plan is the eligible shape (GTI source reads -> one fused compute sink,
  # no focal/warp/partial-reduce), collect(distributed=TRUE) warps each
  # slice's f32 pixels straight into device-bound memory and runs the fused
  # kernel, bypassing the staged scheduler (~22% faster on HLS median).
  # Requires the raw-f32 upload path. FALSE routes through the scheduler.
  composite_direct = FALSE
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
