# garry_http_auth(): prefix-scoped request headers for authenticated remote
# reads. Gates, against a local server that logs each request's
# Authorization header: the header reaches only its prefix; a change closes
# cached handles (GDAL keeps the header a file was opened with while any
# handle on it is open); function headers refresh when a collect starts;
# every pool, including pools started later, sends the header.

# Remove every registered header when the test ends.
local_http_auth <- function(env = parent.frame()) {
  withr::defer(
    for (k in names(.garry_state$http_auth)) garry_http_auth(k, NULL),
    envir = env
  )
  withr::local_envvar(
    CPL_VSIL_CURL_USE_HEAD = "NO",
    GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR",
    .local_envir = env
  )
}

.auth_of <- function(srv, f) unique(srv$log()$auth[srv$log()$file == f])

test_that("a header reaches only its own prefix", {
  local_http_auth()
  da <- withr::local_tempdir("ha")
  db <- withr::local_tempdir("hb")
  .http_tiffs(da, c("a1.tif", "a2.tif"))
  .http_tiffs(db, "b1.tif")
  A <- .http_log_server(da)
  B <- .http_log_server(db)

  expect_identical(
    garry_http_auth(A$prefix, "Authorization: Bearer tokA"),
    A$prefix
  )
  collect(lazy_source(A$url("a1.tif")) + 1, distributed = FALSE)
  collect(lazy_source(B$url("b1.tif")) + 1, distributed = FALSE)
  expect_identical(.auth_of(A, "a1.tif"), "Bearer tokA")
  expect_identical(.auth_of(B, "b1.tif"), "-")

  # removal: later opens send nothing
  garry_http_auth(A$prefix, NULL)
  expect_length(.garry_state$http_auth, 0L)
  collect(lazy_source(A$url("a2.tif")) + 1, distributed = FALSE)
  expect_identical(.auth_of(A, "a2.tif"), "-")
})

test_that("a changed header closes cached handles", {
  local_http_auth()
  d <- withr::local_tempdir("hc")
  .http_tiffs(d, "c.tif")
  S <- .http_log_server(d)
  u <- S$url("c.tif")

  garry_http_auth(S$prefix, "Authorization: Bearer one")
  gdal_read_window(u, 1L, 0L, 0L, 128L, 128L)
  expect_gt(length(.gdal_cache$handles), 0L)
  garry_http_auth(S$prefix, "Authorization: Bearer two")
  expect_length(.gdal_cache$handles, 0L)
  S$clear()
  gdal_read_window(u, 1L, 1792L, 1792L, 256L, 256L) # far from the header
  expect_identical(.auth_of(S, "c.tif"), "Bearer two")
})

test_that("function headers refresh when a collect starts", {
  local_http_auth()
  d <- withr::local_tempdir("hf")
  .http_tiffs(d, c("f1.tif", "f2.tif", "f3.tif"))
  S <- .http_log_server(d)
  n <- 0L
  tok <- function() {
    n <<- n + 1L
    paste0("Authorization: Bearer t", n)
  }
  backdate <- function() {
    .garry_state$http_auth[[S$prefix]]$at <- Sys.time() - 7200
  }

  garry_http_auth(S$prefix, tok, refresh = 3600)
  collect(lazy_source(S$url("f1.tif")) + 1, distributed = FALSE)
  expect_identical(.auth_of(S, "f1.tif"), "Bearer t1") # still fresh
  # the grid probe opens f2 under t1; the run then refreshes to t2 and
  # its reads must send t2, not the t1 of the handle the probe cached
  x <- lazy_source(S$url("f2.tif"))
  backdate()
  collect(x + 1, distributed = FALSE)
  expect_identical(n, 2L)
  a2 <- S$log()$auth[S$log()$file == "f2.tif"]
  expect_identical(unique(a2), c("Bearer t1", "Bearer t2"))
  expect_identical(a2[[length(a2)]], "Bearer t2")

  # a failing refresh warns and keeps the previous header
  .garry_state$http_auth[[S$prefix]]$source <- function() stop("idp down")
  backdate()
  expect_warning(
    collect(lazy_source(S$url("f3.tif")) + 1, distributed = FALSE),
    "keeping the previous one"
  )
  expect_identical(.auth_of(S, "f3.tif"), "Bearer t2")
})

test_that("every pool sends the header, including pools started later", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  local_http_auth()
  d <- withr::local_tempdir("hp")
  names <- c("d1.tif", "d2.tif", "d3.tif")
  .http_tiffs(d, names)
  S <- .http_log_server(d)
  # Read a file from inside every daemon of every pool: the host never
  # opens these files, so their log lines come from the daemons alone.
  daemon_read <- function(f) {
    for (p in c("garry_read", .comp_profiles(), "garry_write")) {
      r <- mirai::everywhere(
        {
          r <- methods::new(gdalraster::GDALRaster, u)
          r$read(1L, 0L, 0L, 128L, 128L, 128L, 128L)
          r$close()
        },
        u = S$url(f),
        .compute = p
      )
      lapply(r, function(m) m[])
    }
  }

  local_pools(1, 2)
  garry_http_auth(S$prefix, "Authorization: Bearer P1") # pushed to running pools
  daemon_read("d1.tif")
  expect_identical(.auth_of(S, "d1.tif"), "Bearer P1")

  garry_daemons(1, 2) # a new pool generation gets the stored header
  daemon_read("d2.tif")
  expect_identical(.auth_of(S, "d2.tif"), "Bearer P1")

  garry_http_auth(S$prefix, "Authorization: Bearer P2")
  daemon_read("d3.tif")
  expect_identical(.auth_of(S, "d3.tif"), "Bearer P2")
})

test_that("garry_http_auth validates its arguments without echoing headers", {
  local_http_auth()
  expect_error(garry_http_auth(c("a", "b"), "x"), "single non-empty")
  expect_error(garry_http_auth("https://h/", 1), "header")
  expect_error(garry_http_auth("https://h/", "x", refresh = 0), "positive")
  expect_error(
    garry_http_auth("https://h/", function() NA_character_),
    "must return a single non-empty string"
  )
  err <- tryCatch(
    garry_http_auth("https://h/", function() stop("bad")),
    error = function(e) conditionMessage(e)
  )
  expect_match(err, "/vsicurl/https://h/", fixed = TRUE)
  expect_length(.garry_state$http_auth, 0L)
})
