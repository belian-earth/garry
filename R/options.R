# ---------------------------------------------------------------------------
# Central policy constants. Planner and executor tunables are read through
# garry_opt() so there is exactly one source of truth for defaults.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Option registry: tier + one-liner + value validator per option, so the
# 30-plus flat garry.* namespace is discoverable (garry_options()) and a
# typo'd VALUE fails loudly at execute entry instead of silently meaning
# something else (a read_fail typo used to silently mean "error",
# inverting the operator's stated intent on a long run).
# Tiers: "user" (day-one switches), "tuning" (budgets/targets),
# "calibration" (cost-model constants measured on one machine).
# ---------------------------------------------------------------------------

# Validator constructors (used in .garry_options_table's check
# fields). Each returns function(value) -> TRUE or a short problem
# string.
.opt_num <- function(min = -Inf, max = Inf, int = FALSE, null_ok = FALSE) {
  force(min)
  force(max)
  force(int)
  force(null_ok)
  function(v) {
    if (is.null(v)) {
      return(if (null_ok) TRUE else "must not be NULL")
    }
    if (!is.numeric(v) || length(v) != 1L || !is.finite(v)) {
      return("must be a single finite number")
    }
    if (int && v != as.integer(v)) {
      return("must be a whole number")
    }
    if (v < min || v > max) {
      return(.glue("must be in [{format(min)}, {format(max)}]"))
    }
    TRUE
  }
}
.opt_flag <- function() {
  function(v) {
    if (isTRUE(v) || isFALSE(v)) TRUE else "must be TRUE or FALSE"
  }
}
.opt_choice <- function(...) {
  choices <- c(...)
  function(v) {
    if (is.character(v) && length(v) == 1L && v %in% choices) {
      TRUE
    } else {
      .glue("must be one of {paste0('\"', choices, '\"', collapse = ', ')}")
    }
  }
}
.opt_path <- function() {
  function(v) {
    if (is.null(v) || (is.character(v) && length(v) == 1L && nzchar(v))) {
      TRUE
    } else {
      "must be NULL or a single path"
    }
  }
}

.garry_options_table <- list(
  # Minimum pixels per chunk the planner aims for. Below this, per-call
  # dispatch overhead (~410 us measured in the spike) stops being
  # negligible relative to kernel runtime.
  chunk_target_px = list(
    default = 1e6,
    tier = "tuning",
    desc = "minimum pixels per compute chunk the planner aims for",
    check = .opt_num(min = 1e-9)
  ),
  # Per-worker RAM budget (MB) used by the chunking pass to cap chunk size.
  ram_budget_mb = list(
    default = 512,
    tier = "tuning",
    desc = "per-worker RAM budget (MB) capping chunk size",
    check = .opt_num(min = 1e-9)
  ),
  # Safety margin, in input cells, added to cross-CRS planning windows.
  # Planning windows must CONTAIN the true window (decision D5); the
  # margin absorbs residual densification error.
  window_margin = list(
    default = 2L,
    tier = "tuning",
    desc = "safety margin (input cells) on cross-CRS planning windows",
    check = .opt_num(min = 0, int = TRUE)
  ),
  # Print task-completion progress from the distributed scheduler.
  # Long network-bound plans are otherwise silent for minutes.
  progress = list(
    default = FALSE,
    tier = "user",
    desc = "print task-completion progress during distributed drains",
    check = .opt_flag()
  ),
  # Max open GDAL dataset handles per process (LRU-evicted, closed on
  # eviction). Open warped/GTI mosaics pin warper + cache memory; on
  # daemons this bounds it. Reopening an evicted dataset is cheap.
  handle_cache_max = list(
    default = 4L,
    tier = "tuning",
    desc = "max open GDAL dataset handles per process (LRU)",
    check = .opt_num(min = 1, int = TRUE)
  ),
  # Default open-handle cache depth on READ daemons (garry_daemons()'s
  # read_handles argument when not given explicitly). Depth 1 suits
  # rarely-revisited per-slice remote mosaics; plans that revisit a
  # handful of local files across many windows (per-band sources over
  # multi-band GTiffs) want a depth >= the number of files interleaved
  # by the launch order, because closing a dataset discards its GDAL
  # block cache.
  read_handles = list(
    default = 1L,
    tier = "tuning",
    desc = "default open-handle cache depth on read daemons",
    check = .opt_num(min = 1, int = TRUE)
  ),
  # GDAL block cache (MB, per process) applied by garry_gdal_config()
  # on read daemons. GDAL's own default is 5% of RAM PER PROCESS,
  # which a read fleet multiplies; this caps it. Raise it when reads
  # revisit interleaved multi-band files: a pixel-interleaved strip
  # decompresses ALL bands, and only blocks that stay cached let
  # later band reads of the same window skip the re-inflate.
  gdal_cachemax_mb = list(
    default = 256,
    tier = "tuning",
    desc = "GDAL block cache (MB per process) on read daemons",
    check = .opt_num(min = 1)
  ),
  # Pixels a single source/warp read task aims for. Reads are coarser
  # than compute chunks (windowed reads of warped mosaics decompress
  # the same source blocks regardless of window size, so small read
  # windows amplify transfer); compute chunks slice out of the read
  # buffer. Applies only to halo-free plans.
  read_target_px = list(
    default = 3.2e7,
    tier = "tuning",
    desc = "pixels a single source/warp read task aims for",
    check = .opt_num(min = 1e-9)
  ),
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
  read_budget_mb = list(
    default = 4096,
    tier = "tuning",
    desc = "cap (MB) on resident inter-stage read regions",
    check = .opt_num(min = 1e-9)
  ),
  # Collapse a band stack of single-band SourceNodes addressing the
  # SAME file into one multi-band SourceNode at plan time (multi-band
  # read coalescing). One read task then reads every band of a window
  # in one decompress pass instead of one task per band: per-band
  # reads of an N-band pixel-interleaved file decompress ~N x the
  # window bytes (each band's read inflates every band's strips), and
  # the task count scales as bands^2 once the read budget shrinks the
  # windows. FALSE restores the per-band plan shape (debugging).
  read_coalesce = list(
    default = TRUE,
    tier = "user",
    desc = "collapse same-file band stacks into multi-band reads",
    check = .opt_flag()
  ),
  # Path to a CSV the distributed scheduler appends task events to.
  # Schema (header written on a fresh file):
  #   time,event,key,pool,slot,mb,store_mb,ready
  # Events: launch (with pool/slot, admission-priced MB, store MB and
  # the ready timestamp, so queue-wait separates from run time), done,
  # write, rss (per-daemon anon-RSS sample, key = pid), model (modelled
  # in-flight + resident MB), drain_end, host_end. garry_task_report()
  # summarises a log. NULL disables.
  task_log = list(
    default = NULL,
    tier = "user",
    desc = "CSV path for task events (see garry_task_report()); NULL off",
    check = .opt_path()
  ),
  # What a failed source read does: "error" aborts the plan; "nodata"
  # logs a warning and yields an all-NaN window, so one bad object /
  # expired token / 404 costs a hole in the composite instead of the
  # whole run (odc-stac's fail_on_error=FALSE, stackstac's
  # errors_as_nodata).
  read_fail = list(
    default = "error",
    tier = "user",
    desc = "failed read: abort the plan, or warn and read a nodata hole",
    check = .opt_choice("error", "nodata")
  ),
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
  read_retry = list(
    default = 2L,
    tier = "user",
    desc = "task-scoped retries for reads/fetches (jittered backoff)",
    check = .opt_num(min = 0, max = 10, int = TRUE)
  ),
  # Pooled scheduler (garry_daemons): optional hard cap on in-flight
  # compute chunks, on top of the byte budget (per-task resident
  # estimates gated against ram_budget_mb x pool size — small chunks
  # flow at full pool width, big fused medians self-limit). NULL =
  # twice the compute pool.
  compute_inflight = list(
    default = NULL,
    tier = "tuning",
    desc = "optional hard cap on in-flight compute chunks",
    check = .opt_num(min = 1, int = TRUE, null_ok = TRUE)
  ),
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
  exec_ram_fraction = list(
    default = 0.6,
    tier = "tuning",
    desc = "fraction of available RAM the scheduler may commit",
    check = .opt_num(min = 1e-300, max = 1)
  ),
  # Pooled scheduler: pre-compile each compute stage's modal chunk
  # shape on every compute-pool daemon at run start, while the read
  # pool owns the drain. Removes the first-execution compile
  # (~0.9 s/stage measured) from the tail. Ignored without pools.
  jit_warmup = list(
    default = TRUE,
    tier = "user",
    desc = "pre-compile modal chunk shapes on the compute pool at run start",
    check = .opt_flag()
  ),
  # Device compute stages jit and upload on: "cpu" (anvl's default
  # device) or "cuda" (requires the CUDA PJRT plugin; pair with a
  # small compute pool — concurrent chunks share the GPU's memory).
  # Reads and host-side combines are always CPU.
  device = list(
    default = "cpu",
    tier = "user",
    desc = "device compute stages jit and upload on",
    check = .opt_choice("cpu", "cuda")
  ),
  # Fetch/assemble split for GTI sources in the distributed scheduler
  # (phase 12): "auto" fetches per-item native windows to local tmpfs
  # first when the index holds remote (/vsi*) locations, then
  # assembles the mosaic locally — a remote warped read is ~74%
  # sequential network wait, so many tiny fetches saturate the link
  # where few big warped reads cannot. "direct" reads remote mosaics
  # as before; "force" fetches even local sources (testing; staging
  # slow filesystems).
  fetch = list(
    default = "auto",
    tier = "user",
    desc = "fetch/assemble split for GTI sources",
    check = .opt_choice("auto", "direct", "force")
  ),
  # Phase 12d GDAL-direct temporal-composite fast path (default ON). When the
  # plan is an eligible composite (GTI source reads -> masked temporal reduce,
  # optionally with morphology and multiple bands), collect(distributed=TRUE)
  # warps each slice's f32 pixels straight into device-bound memory and runs
  # one lean cube kernel, bypassing the staged scheduler (~30-40% faster on
  # HLS median). Needs the raw-f32 upload path. HEAVY composites (estimated
  # whole-grid compute > gd_compute_budget) fall through to the scheduler,
  # whose warm parallel compute pool overlaps compute with the fetch drain.
  # FALSE forces the scheduler.
  composite_direct = list(
    default = TRUE,
    tier = "user",
    desc = "GDAL-direct composite fast path (default route)",
    check = .opt_flag()
  ),
  # Route decision for composite_direct: n_bands (+1 if morphology) x
  # n_slices x grid pixels. Above this, the whole-grid single-process compute
  # is heavy enough that the scheduler's overlapped parallel compute wins, so
  # the plan falls through. Calibrated ~ the 3-band morphology crossover;
  # machine/link dependent, so tunable.
  gd_compute_budget = list(
    default = 2.2e8,
    tier = "tuning",
    desc = "composite-direct routing threshold (bands x slices x px)",
    check = .opt_num(min = 1e-9)
  ),
  # Fraction of AVAILABLE RAM the fetch-ordered pipeline may commit to
  # concurrent compute working sets. Each band median holds ~3.5 cubes (band +
  # shared mask + median scratch); the pipeline caps how many run at once so
  # their combined resident set stays under this fraction, regardless of how big
  # the compute pool is. The headroom (1 - fraction) covers the read daemons,
  # the host, and the OS. Users never set this; it exists so "use every daemon"
  # can't OOM on a many-band job. Ignored when available RAM can't be read.
  compute_ram_fraction = list(
    default = 0.6,
    tier = "tuning",
    desc = "fraction of available RAM for pipeline compute working sets",
    check = .opt_num(min = 1e-300, max = 1)
  ),
  # Largest fraction of the grid a point-sampling sub-window may cover
  # before sample_points() gives up and plans the full grid. Rebuilding the
  # graph over the points' bounding box is what actually cuts the FETCH
  # (chunk pruning alone does not: a 2048^2 grid plans one 5120^2 source
  # read window), but it only pays when the points are spatially
  # concentrated -- scattered points span the raster and the rewrite is
  # pure overhead. Measured 2026-08-14: 200 clustered points touched 1
  # source tile of 49, 5000 scattered touched 42.
  sample_window_fraction = list(
    default = 0.5, tier = "tuning",
    desc = "largest grid fraction a point-sample sub-window may cover",
    check = .opt_num(min = 1e-300, max = 1)),
  # Multi-band composites (n_bands > 1): fan the per-band medians out to the
  # (XLA-pre-warmed) compute pool instead of one whole-grid kernel in-process.
  # On a garry_daemons SPLIT pool this uses the fetch-ordered pipeline (fetch
  # fmask first, compute the shared mask + each band's median overlapping the
  # remaining band fetches) for ODC-parity wall time; on a single pool it fans
  # the medians across the shared pool. Single-band runs are unaffected (the
  # whole-grid kernel is already fetch-bound). FALSE forces the whole-grid
  # kernel and re-enables the scheduler route for heavy composites.
  gd_parallel = list(
    default = TRUE,
    tier = "user",
    desc = "fan multi-band composite medians across the compute pool",
    check = .opt_flag()
  ),
  # Fetch-ordered pipeline: split each band's median into this many
  # horizontal strips so the post-fetch drain spreads across the whole
  # compute pool instead of leaving the last band's median on one
  # daemon (the bins are row-major f32, the median is spatially
  # pointwise, and the mask cube is already materialised, so strips
  # need no halo and reassemble byte-identically). 0 = auto: one strip
  # per compute daemon. 1 restores whole-band jobs.
  gd_strips = list(
    default = 0,
    tier = "tuning",
    desc = "band-median strips in the fetch-ordered pipeline (0 = auto)",
    check = .opt_num(min = 0)
  ),
  # Pooled scheduler: /dev/shm headroom the store must leave free, in MB.
  # The mori store, the fetch cache and gdal-direct cubes all live on
  # tmpfs, whose pages are unreclaimable RAM; the budget's resident-byte
  # accounting is an estimate decremented at queue-drop time, so it can
  # run ahead of the physical unlink. refresh_mem_budgets clamps the
  # store budget against ACTUAL free /dev/shm minus this headroom and
  # force-flushes queued drops when free space falls below it.
  shm_headroom_mb = list(
    default = 512,
    tier = "tuning",
    desc = "/dev/shm headroom (MB) the store must leave free",
    check = .opt_num(min = 0)
  ),
  # Per-daemon measured-memory correction (refresh_mem_budgets): when
  # the fleet's anon RSS grows beyond the run-start baseline + the
  # trailing tolerated window + in-flight work, the compute budget
  # shrinks by the excess (estimate defects become throughput dips, not
  # OOMs). FALSE disables the correction (measurement samples still log
  # to the task log) — the A/B switch for attributing wall-time to it.
  rss_correction = list(
    default = TRUE,
    tier = "user",
    desc = "tighten the compute budget on measured fleet-RSS growth",
    check = .opt_flag()
  ),
  # How many compute profiles are DESIGNATED for scan tasks per
  # scan-bearing plan (clamped to the pool width).
  # Scan live/retained memory is confined to this many working sets by
  # construction (~6-12 GB each for the SI smoother), so it is the
  # scan-memory knob: raise it on big-RAM boxes to widen scan
  # throughput, never past what `K x working set + map profiles + host`
  # leaves room for.
  scan_profiles = list(
    default = 2L,
    tier = "tuning",
    desc = "routed mode: profiles designated for scan (cold) kernels",
    check = .opt_num(min = 1, int = TRUE)
  ),
  # Placement decision mode for source->compute chains in the pooled
  # scheduler (design/placement-cost-pass.md): "cost" (default)
  # compares modelled fuse-vs-materialise wall time per chain, with
  # thread, memory and window-working-set admission; "rules" restores
  # the phase 12b structural predicate (single-band non-sink chains
  # fuse, everything else materialises) as the escape hatch. Flipped
  # 2026-07-30 after the SI sweep validation: crop=2048 predict
  # 551 -> 175 s with both arms fused, crop=0 completes, morphology
  # and ndvi/composite unregressed (benchmarks/README.md).
  placement = list(
    default = "cost",
    tier = "user",
    desc = "fuse-vs-materialise decision mode for source->compute chains",
    check = .opt_choice("cost", "rules")
  ),
  # Cost-mode calibration: sustained per-core throughput (GFLOP/s) of
  # jitted kernels, and effective /dev/shm copy bandwidth (MB/s).
  # Order-of-magnitude constants; tune from garry.task_log traces of
  # both routes rather than a priori.
  cost_gflops_core = list(
    default = 4,
    tier = "calibration",
    desc = "sustained per-core kernel throughput (GFLOP/s)",
    check = .opt_num(min = 1e-9)
  ),
  cost_shm_bw_mbs = list(
    default = 2000,
    tier = "calibration",
    desc = "effective /dev/shm copy bandwidth (MB/s)",
    check = .opt_num(min = 1e-9)
  ),
  # Effective parallel efficiency of the FAT compute pool relative to
  # spread-out narrow clients: 2 all-cores XLA daemons measured 81.4
  # win/s vs 159.8 for 10 x 2-CPU clients on the MLP kernel shape
  # (spike B, benchmarks/README.md 2026-07-29) = 0.51. Applied to the
  # materialise route's compute term; without it the model credits the
  # warm pool with machine-wide throughput it does not deliver and
  # keeps wide kernels off the readers by a false margin.
  cost_comp_efficiency = list(
    default = 0.55,
    tier = "calibration",
    desc = "fat compute pool efficiency vs narrow clients",
    check = .opt_num(min = 1e-9, max = 1)
  ),
  # Cost mode: without a reader thread cap (garry.pool_affinity), a
  # kernel above this flops/px never fuses. Fusing wide compute onto N
  # uncapped readers spawns N all-cores XLA clients — a bigger thread
  # cliff than the 2-daemon pool it escapes (scheduling review
  # 2026-07-29). Mask cleanup (~10 flops/px) fuses either way; a
  # 145-band MLP (~2e4) needs the cap.
  fuse_flops_max = list(
    default = 128,
    tier = "calibration",
    desc = "flops/px above which kernels never fuse onto uncapped readers",
    check = .opt_num(min = 0)
  ),
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
  pool_affinity = list(
    default = "auto",
    tier = "user",
    desc = "disjoint per-daemon CPU pinning at pool creation",
    check = .opt_choice("auto", "off")
  ),
  # Cost mode: per-reader budget (MB) for a FUSED kernel's live working
  # set — the read window plus its activation cubes at READ granularity
  # (fused kernels are unchunked; see .stage_fuse_act_bytes_px). Fusion
  # is refused for chains whose window working set exceeds this: the
  # AEF MLP fits a ~1 Mpx window (~2.4 GB) and OOM-killed readers at
  # ~4.2 Mpx (~9 GB).
  fuse_reader_mb = list(
    default = 2500,
    tier = "tuning",
    desc = "per-reader budget (MB) for a fused kernel's working set",
    check = .opt_num(min = 1e-9)
  ),
  # Cost-mode memory admission: estimated resident cost of one XLA CPU
  # client on a read daemon (client + jitted kernel state; spike A
  # measured ~277 MB after one trivial jit). Fusion is refused when
  # n_read x this does not fit in the RAM the exec budget leaves free.
  cost_xla_client_mb = list(
    default = 350,
    tier = "calibration",
    desc = "estimated resident cost (MB) of one XLA CPU client",
    check = .opt_num(min = 0)
  )
)

# Derived default lookup (one flat list; garry_opt()'s hot path).
.garry_defaults <- lapply(.garry_options_table, `[[`, "default")

#' Read a garry policy option.
#'
#' Looks up `getOption("garry.<name>")`, falling back to the package
#' default. Unknown option names error.
#'
#' @param name Option name without the `garry.` prefix.
#' @return The option value.
#' @seealso [garry_options()]
#' @export
garry_opt <- function(name) {
  if (!name %in% names(.garry_defaults)) {
    cli::cli_abort("unknown garry option: {.val {name}}")
  }
  getOption(paste0("garry.", name), .garry_defaults[[name]])
}


#' List every garry option: default, current value, tier, description.
#'
#' The registry surface for the flat `garry.*` option namespace: one row
#' per option with its tier (`user` day-one switches, `tuning`
#' budgets/targets, `calibration` cost-model constants), package
#' default, current session value and a one-line description. Values are
#' validated against the same registry when execution starts.
#'
#' @return A data.frame with columns `option`, `tier`, `default`,
#'   `current`, `set` (is the session overriding the default?) and
#'   `description`.
#' @seealso [garry_opt()]
#' @export
garry_options <- function() {
  fmt <- function(v) {
    if (is.null(v)) "NULL" else paste(format(v), collapse = ",")
  }
  nm <- names(.garry_defaults)
  data.frame(
    option = nm,
    tier = vapply(nm, function(n) .garry_options_table[[n]]$tier, ""),
    default = vapply(nm, function(n) fmt(.garry_defaults[[n]]), ""),
    current = vapply(nm, function(n) fmt(garry_opt(n)), ""),
    set = vapply(
      nm,
      function(n) {
        !is.null(getOption(paste0("garry.", n)))
      },
      logical(1)
    ),
    description = vapply(nm, function(n) .garry_options_table[[n]]$desc, ""),
    row.names = NULL
  )
}

# Validate every registered option's CURRENT value; classed abort naming
# the option, its value and the constraint. Runs at execute entry
# (execute_plan / execute_plan_mirai / collect routes), so a typo fails
# the run in seconds, not silently after hours.
.garry_opt_check <- function() {
  for (n in names(.garry_defaults)) {
    info <- .garry_options_table[[n]]
    if (is.null(info)) {
      next
    }
    ok <- info$check(garry_opt(n))
    if (!isTRUE(ok)) {
      .garry_error(
        .glue(
          "invalid value for option garry.{n} ",
          "({paste(deparse(garry_opt(n)), collapse = '')}): it {ok}"
        ),
        "garry_option_error"
      )
    }
  }
  invisible(NULL)
}

# glue to PLAIN character, evaluated in the caller. The house pattern for
# VALUE strings (task keys, registry names, file names, GDAL args): glue's
# classed return breaks identical() against stored plain strings and rides
# its attributes into cross-process task payloads. Prose (messages, print
# cards) uses glue::glue directly.
.glue <- function(...) {
  as.character(glue::glue(..., .envir = parent.frame(), .trim = FALSE))
}

# %.10g-equivalent numeric formatting (proj-string coordinates).
.g10 <- function(v) formatC(v, format = "g", digits = 10, width = 1)
