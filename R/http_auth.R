#' Authenticate remote reads under a URL prefix.
#'
#' Registers an HTTP header, typically `Authorization: Bearer <token>`,
#' that GDAL sends with every request to a URL starting with `prefix`. It
#' applies on the host and on every garry daemon, including pools that
#' [garry_daemons()] starts later. The header is scoped to the prefix, so
#' a token for one provider never reaches another. Setting
#' `GDAL_HTTP_HEADERS` in the environment instead sends it to every host
#' garry reads from.
#'
#' For short-lived tokens, pass a function as `header`. It is called now,
#' and again when a [collect()] starts once `refresh` seconds have passed;
#' a changed header is pushed to every daemon. GDAL keeps the header a
#' file was opened with until every handle on that file closes, so a
#' change also closes garry's cached dataset handles in every process.
#' Tokens refresh between runs, not during one: choose `refresh` so that
#' a token outlives `refresh` plus your longest run.
#'
#' Header values are never printed, and they do not appear in task logs
#' or [garry_task_report()].
#'
#' @param prefix URL prefix, e.g. `"https://catalog.maap.eo.esa.int/"`. A
#'   bare `http(s)://` prefix is registered in its `/vsicurl/` form, which
#'   is how garry opens remote sources; other GDAL virtual file system
#'   prefixes are taken as given.
#' @param header A header line (several lines joined by `"\r\n"`), a
#'   function returning one, or `NULL` to remove the prefix's header.
#' @param refresh Seconds before a function `header` is called again.
#'   Ignored for a fixed header.
#' @return Invisibly, the registered prefixes.
#' @seealso [garry_daemons()], [garry_gdal_config()]
#' @examples
#' \dontrun{
#' # ESA MAAP: exchange an offline token for a 10 h access token
#' garry_http_auth(
#'   "https://catalog.maap.eo.esa.int/",
#'   function() paste("Authorization: Bearer", maap_access_token()),
#'   refresh = 3600
#' )
#' }
#' @export
garry_http_auth <- function(prefix, header, refresh = 1800) {
  if (!is.character(prefix) || length(prefix) != 1L || is.na(prefix) || !nzchar(prefix)) {
    cli::cli_abort("{.arg prefix} must be a single non-empty string.")
  }
  if (!is.null(header) && !is.function(header) && !.http_auth_valid(header)) {
    cli::cli_abort(
      "{.arg header} must be a single header string, a function returning one, or {.code NULL}."
    )
  }
  if (!is.numeric(refresh) || length(refresh) != 1L || is.na(refresh) || refresh <= 0) {
    cli::cli_abort("{.arg refresh} must be a positive number of seconds.")
  }
  key <- .gdal_href(prefix)
  auth <- .garry_state$http_auth %||% list()
  if (is.null(header)) {
    auth[[key]] <- NULL
    .garry_state$http_auth <- auth
    .http_auth_push(clear = key)
    return(invisible(names(auth)))
  }
  auth[[key]] <- list(
    source = header,
    value = .http_auth_value(header, key),
    at = Sys.time(),
    refresh = as.numeric(refresh)
  )
  .garry_state$http_auth <- auth
  .http_auth_push()
  invisible(names(auth))
}

.http_auth_valid <- function(v) {
  is.character(v) && length(v) == 1L && !is.na(v) && nzchar(v)
}

# Resolve a registered header source to its value. Error messages name
# the prefix, never the value.
.http_auth_value <- function(source, key) {
  if (!is.function(source)) {
    return(source)
  }
  v <- tryCatch(source(), error = function(e) {
    cli::cli_abort(c(
      "The {.arg header} function for {.val {key}} failed.",
      "x" = conditionMessage(e)
    ))
  })
  if (!.http_auth_valid(v)) {
    cli::cli_abort(
      "The {.arg header} function for {.val {key}} must return a single non-empty string."
    )
  }
  v
}

# Install headers in THIS process (host or daemon): `set` is a named
# character (prefix -> header), `clear` the prefixes to drop. Cached
# handles are closed because GDAL keeps the header a file was opened
# with while any handle on it stays open.
.http_auth_apply <- function(set = character(0), clear = character(0)) {
  for (p in clear) {
    gdal_clear_path_options(p)
  }
  for (p in names(set)) {
    gdal_set_path_option(p, "GDAL_HTTP_HEADERS", set[[p]])
  }
  .gdal_handle_reset()
  invisible(TRUE)
}

# Apply the registered headers on the host and every running daemon.
.http_auth_push <- function(clear = character(0)) {
  auth <- .garry_state$http_auth %||% list()
  set <- vapply(auth, function(e) e$value, character(1))
  .http_auth_apply(set, clear)
  .pool_broadcast(
    quote(asNamespace("garry")$.http_auth_apply(s, cl)),
    profiles = c("garry_read", .comp_profiles(), "garry_write"),
    s = set,
    cl = clear,
    quiet = TRUE
  )
  invisible(NULL)
}

# Run-start refresh (collect): re-resolve function headers older than
# their `refresh`, and push when any value changed. A failed refresh
# keeps the previous header and is retried at the next run.
.http_auth_sync <- function() {
  auth <- .garry_state$http_auth
  if (!length(auth)) {
    return(invisible(FALSE))
  }
  changed <- FALSE
  now <- Sys.time()
  for (k in names(auth)) {
    e <- auth[[k]]
    age <- as.numeric(difftime(now, e$at, units = "secs"))
    if (!is.function(e$source) || age < e$refresh) {
      next
    }
    v <- tryCatch(.http_auth_value(e$source, k), error = function(err) {
      cli::cli_warn(c(
        "Could not refresh the header for {.val {k}}; keeping the previous one.",
        "x" = conditionMessage(err)
      ))
      NULL
    })
    if (is.null(v)) {
      next
    }
    auth[[k]]$at <- now
    if (!identical(v, e$value)) {
      auth[[k]]$value <- v
      changed <- TRUE
    }
  }
  .garry_state$http_auth <- auth
  if (changed) {
    .http_auth_push()
  }
  invisible(changed)
}
