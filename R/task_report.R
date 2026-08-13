#' @include passes.R
#' @keywords internal
NULL

#' Summarise a `garry.task_log` CSV.
#'
#' Summarises the task log CSV the distributed scheduler writes when
#' the `garry.task_log` option is set (see [garry_options()]; schema
#' `time,event,key,pool,slot,mb,store_mb,ready`): per-stage task counts
#' and run/queue-wait quantiles, maximum concurrency, the drain vs
#' host-tail split, and the peak measured (per-daemon anonymous RSS) vs
#' modelled (in-flight + resident) memory. It answers "where did the
#' time and memory go" for a distributed run.
#'
#' @param path Path to a task-log CSV written by the scheduler.
#' @return Invisibly, a list: `events` (event counts), `tasks` (one row
#'   per launch/done pair: key, pool, slot, mb, store_mb, wait_s,
#'   run_s), `stages` (per-stage counts and p50/p95 run and wait
#'   seconds), `max_concurrency`, `drain_s`, `host_tail_s`,
#'   `peak_model_mb`, `peak_rss_mb`. Printed as a cli summary.
#' @export
garry_task_report <- function(path) {
  if (!file.exists(path)) {
    .garry_error(paste0("no task log at ", path), "garry_report_error")
  }
  df <- utils::read.csv(path, stringsAsFactors = FALSE)
  need <- c("time", "event", "key", "pool", "slot", "mb", "store_mb", "ready")
  if (!all(need %in% names(df))) {
    .garry_error(
      paste0(
        "not a garry task log (expected header time,event,key,pool,slot,",
        "mb,store_mb,ready; logs from before the schema was locked have ",
        "no header)"
      ),
      "garry_report_error"
    )
  }
  df$time <- as.numeric(df$time)
  events <- table(df$event)

  la <- df[
    df$event == "launch",
    c("time", "key", "pool", "slot", "mb", "store_mb", "ready")
  ]
  names(la)[[1L]] <- "t_launch"
  do <- df[df$event == "done", c("time", "key")]
  names(do)[[1L]] <- "t_done"
  tasks <- merge(la, do, by = "key")
  tasks$run_s <- tasks$t_done - tasks$t_launch
  tasks$wait_s <- tasks$t_launch - suppressWarnings(as.numeric(tasks$ready))
  tasks$stage <- sub("^([a-z]+[0-9]+)_.*$", "\\1", tasks$key)

  q <- function(x, p) {
    if (length(x)) {
      round(stats::quantile(x, p, na.rm = TRUE, names = FALSE), 3)
    } else {
      NA_real_
    }
  }
  stages <- do.call(
    rbind,
    lapply(split(tasks, tasks$stage), function(s) {
      data.frame(
        stage = s$stage[[1L]],
        pool = s$pool[[1L]],
        n = nrow(s),
        run_p50 = q(s$run_s, 0.5),
        run_p95 = q(s$run_s, 0.95),
        wait_p50 = q(s$wait_s, 0.5),
        wait_p95 = q(s$wait_s, 0.95)
      )
    })
  )
  stages <- stages[order(stages$stage), , drop = FALSE]
  row.names(stages) <- NULL

  # Max concurrency: +1 at each launch, -1 at each done, in time order.
  ev <- df[df$event %in% c("launch", "done"), c("time", "event")]
  ev <- ev[order(ev$time), , drop = FALSE]
  delta <- ifelse(ev$event == "launch", 1L, -1L)
  max_conc <- if (nrow(ev)) max(cumsum(delta)) else 0L

  t0 <- min(df$time)
  t_drain <- df$time[df$event == "drain_end"]
  t_host <- df$time[df$event == "host_end"]
  drain_s <- if (length(t_drain)) round(max(t_drain) - t0, 3) else NA_real_
  host_tail_s <- if (length(t_drain) && length(t_host)) {
    round(max(t_host) - max(t_drain), 3)
  } else {
    NA_real_
  }

  model <- df[df$event == "model", ]
  rss <- df[df$event == "rss", ]
  peak_model_mb <- if (nrow(model)) {
    max(
      suppressWarnings(as.numeric(model$mb)) +
        suppressWarnings(as.numeric(model$store_mb)),
      na.rm = TRUE
    )
  } else {
    NA_real_
  }
  peak_rss_mb <- if (nrow(rss)) {
    by_t <- vapply(
      split(suppressWarnings(as.numeric(rss$mb)), rss$time),
      sum,
      numeric(1),
      na.rm = TRUE
    )
    max(by_t)
  } else {
    NA_real_
  }

  cli::cli_h1("garry task report: {path}")
  cli::cli_inform(c(
    "*" = paste0(
      "events: ",
      paste(names(events), as.integer(events), sep = "=", collapse = ", ")
    ),
    "*" = "{nrow(tasks)} launch/done pairs, max concurrency {max_conc}",
    "*" = paste0("drain ", drain_s, " s; host tail ", host_tail_s, " s"),
    "*" = paste0(
      "peak modelled ",
      round(peak_model_mb),
      " MB; peak fleet ",
      "anon RSS ",
      round(peak_rss_mb),
      " MB"
    )
  ))
  if (nrow(stages)) {
    cli::cli_h2("per stage (seconds)")
    for (i in seq_len(nrow(stages))) {
      s <- stages[i, ]
      cli::cli_inform(paste0(
        "  ",
        format(s$stage, width = 8),
        " ",
        format(s$pool, width = 5),
        " n=",
        format(s$n, width = 5),
        "  run p50/p95 ",
        s$run_p50,
        "/",
        s$run_p95,
        "  wait p50/p95 ",
        s$wait_p50,
        "/",
        s$wait_p95
      ))
    }
  }
  invisible(list(
    events = events,
    tasks = tasks,
    stages = stages,
    max_concurrency = max_conc,
    drain_s = drain_s,
    host_tail_s = host_tail_s,
    peak_model_mb = peak_model_mb,
    peak_rss_mb = peak_rss_mb
  ))
}
