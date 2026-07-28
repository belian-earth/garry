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
  # Default open-handle cache depth on READ daemons (garry_daemons()'s
  # read_handles argument when not given explicitly). Depth 1 suits
  # rarely-revisited per-slice remote mosaics; plans that revisit a
  # handful of local files across many windows (per-band sources over
  # multi-band GTiffs) want a depth >= the number of files interleaved
  # by the launch order, because closing a dataset discards its GDAL
  # block cache.
  read_handles = 1L,
  # GDAL block cache (MB, per process) applied by garry_gdal_config()
  # on read daemons. GDAL's own default is 5% of RAM PER PROCESS,
  # which a read fleet multiplies; this caps it. Raise it when reads
  # revisit interleaved multi-band files: a pixel-interleaved strip
  # decompresses ALL bands, and only blocks that stay cached let
  # later band reads of the same window skip the re-inflate.
  gdal_cachemax_mb = 256,
  # Pixels a single source/warp read task aims for. Reads are coarser
  # than compute chunks (windowed reads of warped mosaics decompress
  # the same source blocks regardless of window size, so small read
  # windows amplify transfer); compute chunks slice out of the read
  # buffer. Applies only to halo-free plans.
  read_target_px = 3.2e7,
  # Cap (MB) on RESIDENT inter-stage read regions. Source/warp store
  # values live in shared memory from launch until every consumer has
  # retired, so residency — not concurrency — is what a read fleet
  # costs. Two things are sized against this: the coarse read window
  # (a stage consuming n bands pins n regions at once, so the read
  # target shrinks as n grows) and the scheduler's read-launch gate
  # (independent read stages in one plan would otherwise all drain
  # into RAM before the first compute stage releases any of them).
  # Without it a 145-band MLP predict over a 23 Mpx mosaic pins
  # ~12 GB per year, and a 22-year multi-export collect asks for
  # ~210 GB.
  read_budget_mb = 4096,
  # Collapse a band stack of single-band SourceNodes addressing the
  # SAME file into one multi-band SourceNode at plan time (multi-band
  # read coalescing). One read task then reads every band of a window
  # in one decompress pass instead of one task per band: per-band
  # reads of an N-band pixel-interleaved file decompress ~N x the
  # window bytes (each band's read inflates every band's strips), and
  # the task count scales as bands^2 once the read budget shrinks the
  # windows. FALSE restores the per-band plan shape (debugging).
  read_coalesce = TRUE,
  # Path to a CSV the distributed scheduler appends per-task
  # launch/done timestamps to (plus drain_end/host_end marks), for
  # profiling where a plan's wall time goes. NULL disables.
  task_log = NULL,
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
  # Fraction of AVAILABLE RAM (MemAvailable, re-read during the drain)
  # the distributed scheduler may commit to in-flight compute working
  # sets plus resident read regions. The configured budgets
  # (ram_budget_mb x compute pool, read_budget_mb) are CAPS, not
  # entitlements: a fixed budget is blind to what else is resident, so
  # a caller whose own session already holds tens of GB (fits, point
  # tables, a previous stage's outputs) would otherwise have the
  # scheduler launch as though it owned the machine and OOM mid-drain.
  # Re-read on a clock so a host that grows DURING the run tightens the
  # gates instead of overcommitting. The remainder (1 - fraction) covers
  # the host, the read daemons' buffers and the OS. Ignored where
  # available RAM cannot be read (no /proc/meminfo).
  exec_ram_fraction = 0.6,
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
  # Fetch/assemble split for GTI sources in the distributed scheduler
  # (phase 12): "auto" fetches per-item native windows to local tmpfs
  # first when the index holds remote (/vsi*) locations, then
  # assembles the mosaic locally — a remote warped read is ~74%
  # sequential network wait, so many tiny fetches saturate the link
  # where few big warped reads cannot. "direct" reads remote mosaics
  # as before; "force" fetches even local sources (testing; staging
  # slow filesystems).
  fetch = "auto",
  # Phase 12d GDAL-direct temporal-composite fast path (default ON). When the
  # plan is an eligible composite (GTI source reads -> masked temporal reduce,
  # optionally with morphology and multiple bands), collect(distributed=TRUE)
  # warps each slice's f32 pixels straight into device-bound memory and runs
  # one lean cube kernel, bypassing the staged scheduler (~30-40% faster on
  # HLS median). Needs the raw-f32 upload path. HEAVY composites (estimated
  # whole-grid compute > gd_compute_budget) fall through to the scheduler,
  # whose warm parallel compute pool overlaps compute with the fetch drain.
  # FALSE forces the scheduler.
  composite_direct = TRUE,
  # Route decision for composite_direct: n_bands (+1 if morphology) x
  # n_slices x grid pixels. Above this, the whole-grid single-process compute
  # is heavy enough that the scheduler's overlapped parallel compute wins, so
  # the plan falls through. Calibrated ~ the 3-band morphology crossover;
  # machine/link dependent, so tunable.
  gd_compute_budget = 2.2e8,
  # Fraction of AVAILABLE RAM the fetch-ordered pipeline may commit to
  # concurrent compute working sets. Each band median holds ~3.5 cubes (band +
  # shared mask + median scratch); the pipeline caps how many run at once so
  # their combined resident set stays under this fraction, regardless of how big
  # the compute pool is. The headroom (1 - fraction) covers the read daemons,
  # the host, and the OS. Users never set this; it exists so "use every daemon"
  # can't OOM on a many-band job. Ignored when available RAM can't be read.
  compute_ram_fraction = 0.6,
  # Fraction of AVAILABLE RAM the lazy_cog staging pass may commit to
  # /dev/shm buffers. .ck_resolve stages every CK source set whole-AOI
  # before compute; tmpfs pages are unreclaimable RAM, so an oversized
  # staging set would OOM exactly like an oversized compute set. When the
  # estimated staged bytes exceed this fraction, staging falls back to
  # disk (tempdir) -- slower reads, no OOM. The compute-side cap
  # (compute_ram_fraction) re-reads MemAvailable after staging, so the
  # two budgets compose. Ignored when available RAM can't be read.
  ck_stage_ram_fraction = 0.4,
  # Multi-band composites (n_bands > 1): fan the per-band medians out to the
  # (XLA-pre-warmed) compute pool instead of one whole-grid kernel in-process.
  # On a garry_daemons SPLIT pool this uses the fetch-ordered pipeline (fetch
  # fmask first, compute the shared mask + each band's median overlapping the
  # remaining band fetches) for ODC-parity wall time; on a single pool it fans
  # the medians across the shared pool. Single-band runs are unaffected (the
  # whole-grid kernel is already fetch-bound). FALSE forces the whole-grid
  # kernel and re-enables the scheduler route for heavy composites.
  gd_parallel = TRUE
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
    cli::cli_abort("unknown garry option: {.val {name}}")
  getOption(paste0("garry.", name), .garry_defaults[[name]])
}
