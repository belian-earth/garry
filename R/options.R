# ---------------------------------------------------------------------------
# Central policy constants. Planner and executor tunables are read through
# garry_opt() so there is exactly one source of truth for defaults.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Option registry: tier + one-liner + value validator per option, so the
# flat garry.* namespace is discoverable (garry_options()) and a typo'd
# VALUE fails loudly at execute entry instead of silently meaning
# something else on a long run. A figure nobody tunes is a named constant
# beside its use, not an option.
# Tiers: "user" (day-one switches), "tuning" (budgets/targets).
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
    if (int && (v != round(v) || abs(v) > .Machine$integer.max)) {
      return("must be a whole number within R's integer range")
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
  # negligible relative to kernel runtime. A plan with a patch (model)
  # stage takes the largest chunk ram_budget_mb allows instead, unless
  # this is set: .plan_chunk_dim() asks whether it was, so setting it to
  # its default changes such a plan.
  chunk_target_px = list(
    default = 1e6,
    tier = "tuning",
    desc = "pixels per compute chunk the planner aims for (a patch plan takes the RAM cap unless set)",
    check = .opt_num(min = 1e-9)
  ),
  # RAM budget (MB) of one kernel call. The chunking pass caps chunks to
  # it, and a pointwise fused kernel whose window's activations exceed it
  # runs as row tiles on the reader (design/placement-cost-pass.md, "tiled
  # fused kernels"), so its in-flight bytes are the input window plus one
  # tile's activations rather than the whole window's. It does not bound
  # in-flight compute: exec_ram_fraction does.
  ram_budget_mb = list(
    default = 512,
    tier = "tuning",
    desc = "RAM budget (MB) of one kernel call: caps chunks, tiles wide fused windows",
    check = .opt_num(min = 1e-9)
  ),
  # Print task-completion progress from the distributed scheduler.
  # Long network-bound plans are otherwise silent for minutes.
  progress = list(
    default = FALSE,
    tier = "user",
    desc = "print task-completion progress during distributed drains",
    check = .opt_flag()
  ),
  # Warp with GDAL's exact transformer. GDAL's default interpolates the
  # transform along each row to within 0.125 source pixels. A warped VRT of
  # one source reads by fixed blocks, so its cells never depend on chunks
  # either way. A window warp (several sources together, a Zarr array, a
  # source of a mosaic read source by source) takes the window's rows, so
  # there a cell near a pixel boundary can take the neighbouring pixel in
  # another window layout unless this is on. A STAC band's warps (the GTI
  # driver, the composite routes) always take GDAL's default. Off by
  # default: it costs about 5x on a warped VRT and 3-15x on a one-band
  # window warp across projections.
  warp_exact = list(
    default = FALSE,
    tier = "tuning",
    desc = "exact transformer for warps of plain files and windows (slower)",
    check = .opt_flag()
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
  # GDAL block cache (MB, per process) on every daemon, taken at pool
  # creation and fixed for the pool's life. GDAL's own default is 5% of
  # RAM PER PROCESS, which a read fleet multiplies; this caps it. Raise
  # it when reads revisit interleaved multi-band files: a
  # pixel-interleaved strip decompresses ALL bands, and only blocks that
  # stay cached let later band reads of the same window skip the
  # re-inflate.
  gdal_cachemax_mb = list(
    default = 256,
    tier = "tuning",
    desc = "GDAL block cache (MB per process) on every garry daemon",
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
  # retired, so residency: not concurrency: is what a read fleet
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
  # Path to a CSV every distributed route appends task events to.
  # Schema (header written on a fresh file):
  #   time,event,key,pool,slot,mb,store_mb,ready
  # Events: launch (with pool/slot, admission-priced MB, store MB and
  # the ready timestamp, so queue-wait separates from run time), start
  # (the daemon's own start time for the task, so time queued behind
  # the daemon's previous task separates from run time), done,
  # write, rss (per-daemon anon-RSS sample, key = pid, pool = its role),
  # model (modelled in-flight + resident MB), host (the calling
  # process's anon RSS, key = pid), cgroup (usage and limit of the
  # binding memory cgroup as mb / store_mb), shm (/dev/shm used MB),
  # budget (compute / read admission budgets as mb / store_mb),
  # drain_end, host_end. garry_task_report() summarises a log. NULL
  # disables.
  task_log = list(
    default = NULL,
    tier = "user",
    desc = "CSV path for task events (see garry_task_report()); NULL off",
    check = .opt_path()
  ),
  # Task-scoped retries for read/fetch/warp operations, on top of
  # GDAL's per-request HTTP retry. GDAL retries individual range
  # requests inside one operation; a whole-operation failure (curl
  # timeout after 60 s, TLS reset, transient DNS, a failed open) is
  # otherwise terminal for the run. Reads are idempotent, so each failed
  # operation is re-attempted up to this many times with jittered
  # exponential backoff (0.5 * 2^k s) before the run aborts. 0 disables.
  read_retry = list(
    default = 2L,
    tier = "user",
    desc = "task-scoped retries for reads/fetches (jittered backoff)",
    check = .opt_num(min = 0, max = 10, int = TRUE)
  ),
  # Fraction of AVAILABLE RAM (MemAvailable, re-read during the drain) a
  # distributed run may commit to in-flight compute working sets plus
  # resident read regions, on the scheduler and the fetch-ordered
  # pipeline alike. read_budget_mb is a CAP, not an entitlement: a fixed
  # budget is blind to what else is resident, so a caller whose own
  # session already holds tens of GB (fits, point tables, a previous
  # stage's outputs) would otherwise have the scheduler launch as though
  # it owned the machine and OOM mid-drain. Re-read on a clock so a host
  # that grows DURING the run tightens the gates instead of
  # overcommitting. The remainder (1 - fraction) covers the host, the
  # read daemons' buffers and the OS. Ignored where available RAM cannot
  # be read (no /proc/meminfo).
  exec_ram_fraction = list(
    default = 0.6,
    tier = "tuning",
    desc = "fraction of available RAM a distributed run may commit",
    check = .opt_num(min = 1e-300, max = 1)
  ),
  # Device compute stages jit and upload on: "cpu" (anvl's default
  # device) or "cuda" (requires the CUDA PJRT plugin; pair with a
  # small compute pool: concurrent chunks share the GPU's memory).
  # Reads and host-side combines are always CPU.
  device = list(
    default = "cpu",
    tier = "user",
    desc = "device compute stages jit and upload on",
    check = .opt_choice("cpu", "cuda")
  ),
  # Fetch/assemble split for GTI sources in the distributed scheduler:
  # "auto" fetches per-item native windows to local tmpfs first when the
  # index holds remote (/vsi*) locations, then assembles the mosaic
  # locally: a remote warped read is ~74% sequential network wait, so many
  # tiny fetches saturate the link where few big warped reads cannot.
  # "direct" reads remote mosaics directly; "force" fetches even local
  # sources (testing; staging slow filesystems).
  fetch = list(
    default = "auto",
    tier = "user",
    desc = "fetch/assemble split for GTI sources",
    check = .opt_choice("auto", "direct", "force")
  ),
  # GDAL-direct temporal-composite route. When the plan is an eligible
  # composite (GTI source reads -> masked temporal reduce, optionally with
  # morphology and multiple bands), collect(distributed=TRUE) warps each
  # slice's f32 pixels straight into device-bound memory and runs one lean
  # cube kernel, bypassing the staged scheduler. A heavy single-band
  # composite (.gd_compute_budget) falls through to the scheduler, whose
  # warm parallel compute pool overlaps compute with the fetch drain. FALSE
  # forces the scheduler.
  composite_direct = list(
    default = TRUE,
    tier = "user",
    desc = "GDAL-direct composite fast path (default route)",
    check = .opt_flag()
  ),
  # Plans that only read (sources, warps and stacks of them) are copied
  # straight from GDAL into the result, skipping the compute kernels.
  read_only = list(
    default = TRUE,
    tier = "user",
    desc = "copy read-only plans from GDAL straight into the result",
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
    desc = "strips per band reduction on the direct route (0 = auto)",
    check = .opt_num(min = 0, int = TRUE)
  ),
  # Per-daemon measured-memory correction (refresh_mem_budgets): when
  # the fleet's anon RSS grows beyond the run-start baseline + the
  # trailing tolerated window + in-flight work, the compute budget
  # shrinks by the excess (estimate defects become throughput dips, not
  # OOMs). FALSE disables the correction (measurement samples still log
  # to the task log): the A/B switch for attributing wall-time to it.
  rss_correction = list(
    default = TRUE,
    tier = "user",
    desc = "tighten the compute budget on measured fleet-RSS growth",
    check = .opt_flag()
  ),
  # Grow a compute stage's edge chunks to its modal chunk shape at
  # execution, so they run the kernel the warm-up compiled for that
  # shape. A 2400-cell grid in 512-cell chunks has four chunk shapes;
  # without this every daemon compiled each stage for every edge shape
  # it met, about half the compute time of hutan's SI tail. The padding
  # is nodata, as beyond the raster's edge, and is cropped from the
  # outputs.
  pad_edge_chunks = list(
    default = TRUE,
    tier = "tuning",
    desc = "run edge chunks on their stage's modal kernel, grown and cropped",
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
    desc = "compute profiles designated for scan kernels",
    check = .opt_num(min = 1, int = TRUE)
  ),
  # What crosses to a compute daemon for a kernel. "closure" ships the
  # stage's R closure and the daemon traces it; "program" traces once on
  # the host and ships the StableHLO text, so no R closure crosses a
  # process (design/stablehlo-kernels.md).
  kernel_wire = list(
    default = "program",
    tier = "tuning",
    desc = "kernels reach daemons as R closures or StableHLO programs",
    check = .opt_choice("closure", "program")
  ),
  # "guarded" merges stages under .merge_stages()'s guards. "auto" also folds a
  # group of chunk-aligned compute stages into one XLA program when the
  # task overhead it saves outweighs the compile it costs (.merge_worth(),
  # design/stablehlo-kernels.md).
  stage_merge = list(
    default = "auto",
    tier = "tuning",
    desc = "merge compute stages as guarded, or further when worthwhile",
    check = .opt_choice("guarded", "auto")
  ),
  # Placement decision mode for source->compute chains in the pooled
  # scheduler (design/placement-cost-pass.md): "cost" (default)
  # compares modelled fuse-vs-materialise wall time per chain, with
  # thread, memory and window-working-set admission; "rules" restores
  # a structural predicate (single-band non-sink chains fuse, everything
  # else materialises) as the escape hatch.
  placement = list(
    default = "cost",
    tier = "user",
    desc = "fuse-vs-materialise decision mode for source->compute chains",
    check = .opt_choice("cost", "rules")
  ),
  # Pool CPU affinity: "auto" pins each daemon of BOTH pools to a
  # disjoint interleaved set of k = max(2, cores %/% pool_size) CPUs at
  # pool creation (Linux only: it warns where taskset is missing or
  # fails, and does nothing on other systems). Any
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
#' budgets/targets), package default, current session value and a
#' one-line description. Every `garry.*` option is checked against this
#' registry when a run starts and at [garry_daemons()]: a name it does not
#' hold (a typo or a retired option) or an invalid value aborts with a
#' `garry_option_error`.
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

# Validate every garry.* option: a name the registry does not hold (a
# typo, a retired option, a misnamed HUTAN_GARRY_* variable) would mean
# the default, so it aborts, as does a registered option's bad value,
# naming the option, its value and the constraint. Runs at execute entry
# (execute_plan / execute_plan_mirai / collect routes), so a typo fails
# the run in seconds, not silently after hours.
.garry_opt_check <- function() {
  unknown <- setdiff(
    grep("^garry\\.", names(options()), value = TRUE),
    paste0("garry.", names(.garry_defaults))
  )
  if (length(unknown)) {
    cli::cli_abort(
      c(
        "unknown garry option{?s}: {.val {unknown}}.",
        "i" = "{.fn garry_options} lists the options garry has."
      ),
      class = c("garry_option_error", "garry_error"),
      call = NULL
    )
  }
  for (n in names(.garry_defaults)) {
    ok <- .garry_options_table[[n]]$check(garry_opt(n))
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
