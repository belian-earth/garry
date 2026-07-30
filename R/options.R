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
  # Path to a CSV the distributed scheduler appends task events to.
  # Schema (header written on a fresh file):
  #   time,event,key,pool,slot,mb,store_mb,ready
  # Events: launch (with pool/slot, admission-priced MB, store MB and
  # the ready timestamp, so queue-wait separates from run time), done,
  # write, rss (per-daemon anon-RSS sample, key = pid), model (modelled
  # in-flight + resident MB), drain_end, host_end. garry_task_report()
  # summarises a log. NULL disables.
  task_log = NULL,
  # What a failed source read does: "error" aborts the plan; "nodata"
  # logs a warning and yields an all-NaN window, so one bad object /
  # expired token / 404 costs a hole in the composite instead of the
  # whole run (odc-stac's fail_on_error=FALSE, stackstac's
  # errors_as_nodata).
  read_fail = "error",
  # Task-scoped retries for read/fetch/warp operations, on top of
  # GDAL's per-request HTTP retry. GDAL retries individual range
  # requests inside one operation; a whole-operation failure (curl
  # timeout after 60 s, TLS reset, transient DNS, a failed open) is
  # otherwise terminal for the task — under read_fail = "nodata" that
  # is the difference between a transient blip and a silent hole in a
  # composite. Reads are idempotent, so each failed operation is
  # re-attempted up to this many times with jittered exponential
  # backoff (0.5 * 2^k s) before the read_fail contract fires.
  # 0 disables.
  read_retry = 2L,
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
  gd_parallel = TRUE,
  # Pooled scheduler: /dev/shm headroom the store must leave free, in MB.
  # The mori store, the fetch cache and gdal-direct cubes all live on
  # tmpfs, whose pages are unreclaimable RAM; the budget's resident-byte
  # accounting is an estimate decremented at queue-drop time, so it can
  # run ahead of the physical unlink. refresh_mem_budgets clamps the
  # store budget against ACTUAL free /dev/shm minus this headroom and
  # force-flushes queued drops when free space falls below it.
  shm_headroom_mb = 512,
  # Per-daemon measured-memory correction (refresh_mem_budgets): when
  # the fleet's anon RSS grows beyond the run-start baseline + the
  # trailing tolerated window + in-flight work, the compute budget
  # shrinks by the excess (estimate defects become throughput dips, not
  # OOMs). FALSE disables the correction (measurement samples still log
  # to the task log) — the A/B switch for attributing wall-time to it.
  rss_correction = TRUE,
  # Placement decision mode for source->compute chains in the pooled
  # scheduler (design/placement-cost-pass.md): "cost" (default)
  # compares modelled fuse-vs-materialise wall time per chain, with
  # thread, memory and window-working-set admission; "rules" restores
  # the phase 12b structural predicate (single-band non-sink chains
  # fuse, everything else materialises) as the escape hatch. Flipped
  # 2026-07-30 after the SI sweep validation: crop=2048 predict
  # 551 -> 175 s with both arms fused, crop=0 completes, morphology
  # and ndvi/composite unregressed (benchmarks/README.md).
  placement = "cost",
  # Cost-mode calibration: sustained per-core throughput (GFLOP/s) of
  # jitted kernels, and effective /dev/shm copy bandwidth (MB/s).
  # Order-of-magnitude constants; tune from garry.task_log traces of
  # both routes rather than a priori.
  cost_gflops_core = 4,
  cost_shm_bw_mbs = 2000,
  # Effective parallel efficiency of the FAT compute pool relative to
  # spread-out narrow clients: 2 all-cores XLA daemons measured 81.4
  # win/s vs 159.8 for 10 x 2-CPU clients on the MLP kernel shape
  # (spike B, benchmarks/README.md 2026-07-29) = 0.51. Applied to the
  # materialise route's compute term; without it the model credits the
  # warm pool with machine-wide throughput it does not deliver and
  # keeps wide kernels off the readers by a false margin.
  cost_comp_efficiency = 0.55,
  # Cost mode: without a reader thread cap (garry.pool_affinity), a
  # kernel above this flops/px never fuses. Fusing wide compute onto N
  # uncapped readers spawns N all-cores XLA clients — a bigger thread
  # cliff than the 2-daemon pool it escapes (scheduling review
  # 2026-07-29). Mask cleanup (~10 flops/px) fuses either way; a
  # 145-band MLP (~2e4) needs the cap.
  fuse_flops_max = 128,
  # Pool CPU affinity: "auto" pins each daemon of BOTH pools to a
  # disjoint interleaved set of k = max(2, cores %/% pool_size) CPUs at
  # pool creation (Linux + taskset only; silently off elsewhere). Any
  # XLA client created there then sizes its thread pool to k instead of
  # all cores. This is the general rule that makes pool width a free
  # parameter: threads are bounded per daemon, byte admission bounds
  # concurrency, so extra daemons cost idle RSS, not thread storms.
  # Enables fusing wide kernels onto readers (placement cost mode) and
  # wide narrow compute pools (spike B: 10 x 2-CPU clients ~2x the
  # matmul throughput of 2 uncapped fat ones). k floors at 2: a 1-CPU
  # XLA client segfaults (spike A). The compute pool is not pinned on
  # device = "cuda". "off" disables.
  pool_affinity = "auto",
  # Cost mode: per-reader budget (MB) for a FUSED kernel's live working
  # set — the read window plus its activation cubes at READ granularity
  # (fused kernels are unchunked; see .stage_fuse_act_bytes_px). Fusion
  # is refused for chains whose window working set exceeds this: the
  # AEF MLP fits a ~1 Mpx window (~2.4 GB) and OOM-killed readers at
  # ~4.2 Mpx (~9 GB).
  fuse_reader_mb = 2500,
  # Admission surcharge (MB) for a COLD scan kernel: an unrolled
  # (bidirectional) scan's XLA compile holds this much privately on the
  # daemon compiling it, on top of the task's working set (the robust
  # Kalman smoother measured one daemon at ~16.5 GB total during
  # compile+first-chunk vs ~6.5 GB warmed). Charged against the
  # in-flight byte budget until every compute daemon has plausibly
  # compiled the kernel, so the LIVE budget — not just the slow-start
  # ramp — bounds concurrent cold compiles on wide pools.
  scan_compile_mb = 10000,
  # Cost-mode memory admission: estimated resident cost of one XLA CPU
  # client on a read daemon (client + jitted kernel state; spike A
  # measured ~277 MB after one trivial jit). Fusion is refused when
  # n_read x this does not fit in the RAM the exec budget leaves free.
  cost_xla_client_mb = 350
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

# ---------------------------------------------------------------------------
# Option registry: tier + one-liner + value validator per option, so the
# 30-plus flat garry.* namespace is discoverable (garry_options()) and a
# typo'd VALUE fails loudly at execute entry instead of silently meaning
# something else (a read_fail typo used to silently mean "error",
# inverting the operator's stated intent on a long run).
# Tiers: "user" (day-one switches), "tuning" (budgets/targets),
# "calibration" (cost-model constants measured on one machine).
# ---------------------------------------------------------------------------

# Validator constructors. Each returns function(value) -> TRUE or a
# short problem string.
.opt_num <- function(min = -Inf, max = Inf, int = FALSE, null_ok = FALSE) {
  force(min); force(max); force(int); force(null_ok)
  function(v) {
    if (is.null(v)) return(if (null_ok) TRUE else "must not be NULL")
    if (!is.numeric(v) || length(v) != 1L || !is.finite(v))
      return("must be a single finite number")
    if (int && v != as.integer(v)) return("must be a whole number")
    if (v < min || v > max)
      return(sprintf("must be in [%s, %s]", format(min), format(max)))
    TRUE
  }
}
.opt_flag <- function() function(v)
  if (isTRUE(v) || isFALSE(v)) TRUE else "must be TRUE or FALSE"
.opt_choice <- function(...) {
  choices <- c(...)
  function(v) {
    if (is.character(v) && length(v) == 1L && v %in% choices) TRUE
    else sprintf("must be one of %s", paste0('"', choices, '"', collapse = ", "))
  }
}
.opt_path <- function() function(v) {
  if (is.null(v) || (is.character(v) && length(v) == 1L && nzchar(v))) TRUE
  else "must be NULL or a single path"
}

.garry_opt_info <- list(
  chunk_target_px  = list(tier = "tuning", check = .opt_num(min = 1e-9),
    desc = "minimum pixels per compute chunk the planner aims for"),
  ram_budget_mb    = list(tier = "tuning", check = .opt_num(min = 1e-9),
    desc = "per-worker RAM budget (MB) capping chunk size"),
  window_margin    = list(tier = "tuning", check = .opt_num(min = 0, int = TRUE),
    desc = "safety margin (input cells) on cross-CRS planning windows"),
  progress         = list(tier = "user", check = .opt_flag(),
    desc = "print task-completion progress during distributed drains"),
  handle_cache_max = list(tier = "tuning", check = .opt_num(min = 1, int = TRUE),
    desc = "max open GDAL dataset handles per process (LRU)"),
  read_handles     = list(tier = "tuning", check = .opt_num(min = 1, int = TRUE),
    desc = "default open-handle cache depth on read daemons"),
  gdal_cachemax_mb = list(tier = "tuning", check = .opt_num(min = 1),
    desc = "GDAL block cache (MB per process) on read daemons"),
  read_target_px   = list(tier = "tuning", check = .opt_num(min = 1e-9),
    desc = "pixels a single source/warp read task aims for"),
  read_budget_mb   = list(tier = "tuning", check = .opt_num(min = 1e-9),
    desc = "cap (MB) on resident inter-stage read regions"),
  read_coalesce    = list(tier = "user", check = .opt_flag(),
    desc = "collapse same-file band stacks into multi-band reads"),
  task_log         = list(tier = "user", check = .opt_path(),
    desc = "CSV path for task events (see garry_task_report()); NULL off"),
  read_fail        = list(tier = "user", check = .opt_choice("error", "nodata"),
    desc = "failed read: abort the plan, or warn and read a nodata hole"),
  read_retry       = list(tier = "user", check = .opt_num(min = 0, max = 10, int = TRUE),
    desc = "task-scoped retries for reads/fetches (jittered backoff)"),
  compute_inflight = list(tier = "tuning", check = .opt_num(min = 1, int = TRUE, null_ok = TRUE),
    desc = "optional hard cap on in-flight compute chunks"),
  exec_ram_fraction = list(tier = "tuning", check = .opt_num(min = 1e-300, max = 1),
    desc = "fraction of available RAM the scheduler may commit"),
  jit_warmup       = list(tier = "user", check = .opt_flag(),
    desc = "pre-compile modal chunk shapes on the compute pool at run start"),
  device           = list(tier = "user", check = .opt_choice("cpu", "cuda"),
    desc = "device compute stages jit and upload on"),
  fetch            = list(tier = "user", check = .opt_choice("auto", "direct", "force"),
    desc = "fetch/assemble split for GTI sources"),
  composite_direct = list(tier = "user", check = .opt_flag(),
    desc = "GDAL-direct composite fast path (default route)"),
  gd_compute_budget = list(tier = "tuning", check = .opt_num(min = 1e-9),
    desc = "composite-direct routing threshold (bands x slices x px)"),
  compute_ram_fraction = list(tier = "tuning", check = .opt_num(min = 1e-300, max = 1),
    desc = "fraction of available RAM for pipeline compute working sets"),
  ck_stage_ram_fraction = list(tier = "tuning", check = .opt_num(min = 1e-300, max = 1),
    desc = "fraction of available RAM for lazy_cog tmpfs staging"),
  gd_parallel      = list(tier = "user", check = .opt_flag(),
    desc = "fan multi-band composite medians across the compute pool"),
  shm_headroom_mb  = list(tier = "tuning", check = .opt_num(min = 0),
    desc = "/dev/shm headroom (MB) the store must leave free"),
  placement        = list(tier = "user", check = .opt_choice("cost", "rules"),
    desc = "fuse-vs-materialise decision mode for source->compute chains"),
  rss_correction   = list(tier = "user", check = .opt_flag(),
    desc = "tighten the compute budget on measured fleet-RSS growth"),
  cost_gflops_core = list(tier = "calibration", check = .opt_num(min = 1e-9),
    desc = "sustained per-core kernel throughput (GFLOP/s)"),
  cost_shm_bw_mbs  = list(tier = "calibration", check = .opt_num(min = 1e-9),
    desc = "effective /dev/shm copy bandwidth (MB/s)"),
  cost_comp_efficiency = list(tier = "calibration", check = .opt_num(min = 1e-9, max = 1),
    desc = "fat compute pool efficiency vs narrow clients"),
  fuse_flops_max   = list(tier = "calibration", check = .opt_num(min = 0),
    desc = "flops/px above which kernels never fuse onto uncapped readers"),
  pool_affinity    = list(tier = "user", check = .opt_choice("auto", "off"),
    desc = "disjoint per-daemon CPU pinning at pool creation"),
  fuse_reader_mb   = list(tier = "tuning", check = .opt_num(min = 1e-9),
    desc = "per-reader budget (MB) for a fused kernel's working set"),
  scan_compile_mb  = list(tier = "calibration", check = .opt_num(min = 0),
    desc = "admission surcharge (MB) for a cold scan-kernel compile"),
  cost_xla_client_mb = list(tier = "calibration", check = .opt_num(min = 0),
    desc = "estimated resident cost (MB) of one XLA CPU client")
)

#' List every garry option: default, current value, tier, description.
#'
#' The registry surface for the flat `garry.*` option namespace: one row
#' per option with its tier (`user` day-one switches, `tuning`
#' budgets/targets, `calibration` cost-model constants), package
#' default, current session value and a one-line description. Values are
#' validated against the same registry at execute entry
#' (`.garry_opt_check()`).
#'
#' @return A data.frame with columns `option`, `tier`, `default`,
#'   `current`, `set` (is the session overriding the default?) and
#'   `description`.
#' @export
garry_options <- function() {
  fmt <- function(v) if (is.null(v)) "NULL" else paste(format(v), collapse = ",")
  nm <- names(.garry_defaults)
  data.frame(
    option = nm,
    tier = vapply(nm, function(n) .garry_opt_info[[n]]$tier, ""),
    default = vapply(nm, function(n) fmt(.garry_defaults[[n]]), ""),
    current = vapply(nm, function(n) fmt(garry_opt(n)), ""),
    set = vapply(nm, function(n)
      !is.null(getOption(paste0("garry.", n))), logical(1)),
    description = vapply(nm, function(n) .garry_opt_info[[n]]$desc, ""),
    row.names = NULL)
}

# Validate every registered option's CURRENT value; classed abort naming
# the option, its value and the constraint. Runs at execute entry
# (execute_plan / execute_plan_mirai / collect routes), so a typo fails
# the run in seconds, not silently after hours.
.garry_opt_check <- function() {
  for (n in names(.garry_defaults)) {
    info <- .garry_opt_info[[n]]
    if (is.null(info)) next
    ok <- info$check(garry_opt(n))
    if (!isTRUE(ok))
      .garry_error(sprintf(
        "invalid value for option garry.%s (%s): it %s",
        n, paste(deparse(garry_opt(n)), collapse = ""), ok),
        "garry_option_error")
  }
  invisible(NULL)
}
