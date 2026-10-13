# A local range-serving HTTP server for files in `root` that logs every
# request's method, path and Authorization header (one tab-separated line
# each; "-" when absent) to `log`. HEAD replies carry no length, so callers
# set CPL_VSIL_CURL_USE_HEAD=NO and GDAL sizes files with a ranged GET.
.http_log_server <- function(root, env = parent.frame()) {
  testthat::skip_if_not_installed("webfakes")
  log <- tempfile("http-log-")
  file.create(log)
  app <- webfakes::new_app()
  app$locals$root <- root
  app$locals$log <- log
  app$all(webfakes::new_regexp("^/(?<file>[^/]+)$"), function(req, res) {
    cat(
      req$method, "\t", req$params$file, "\t",
      req$get_header("Authorization") %||% "-", "\n",
      sep = "", file = req$app$locals$log, append = TRUE
    )
    p <- file.path(req$app$locals$root, req$params$file)
    if (!file.exists(p)) {
      return(res$send_status(404L))
    }
    size <- file.size(p)
    a <- 0
    b <- size - 1
    rng <- req$get_header("Range")
    if (!is.null(rng)) {
      m <- regmatches(rng, regexec("bytes=(\\d+)-(\\d*)", rng))[[1]]
      a <- as.numeric(m[[2]])
      if (nzchar(m[[3]])) b <- min(as.numeric(m[[3]]), size - 1)
      res$set_status(206L)$set_header(
        "Content-Range",
        sprintf("bytes %.0f-%.0f/%.0f", a, b, size)
      )
    }
    res$set_header("Accept-Ranges", "bytes")
    con <- file(p, "rb")
    on.exit(close(con))
    seek(con, a)
    res$set_type("application/octet-stream")$send(readBin(con, "raw", b - a + 1))
  })
  srv <- webfakes::new_app_process(app)
  withr::defer(srv$stop(), envir = env)
  list(
    prefix = paste0("/vsicurl/", srv$url("/")),
    url = function(f) paste0("/vsicurl/", srv$url(paste0("/", f))),
    log = function() {
      l <- readLines(log)
      if (!length(l)) {
        return(data.frame(method = character(0), file = character(0), auth = character(0)))
      }
      utils::read.table(text = l, sep = "\t", col.names = c("method", "file", "auth"),
                        quote = "", comment.char = "")
    },
    clear = function() writeLines(character(0), log)
  )
}

# A tiled Float32 GeoTIFF per name in `names`, 2048 x 2048 in 256-pixel
# blocks (16 MB): larger than the 4 MB garry ingests when the host opens
# a remote file, so reads past the header still cost range requests.
.http_tiffs <- function(dir, names) {
  for (nm in names) {
    ds <- gdalraster::create(
      "GTiff", file.path(dir, nm), 2048, 2048, 1, "Float32",
      options = c("TILED=YES", "BLOCKXSIZE=256", "BLOCKYSIZE=256"),
      return_obj = TRUE
    )
    ds$setGeoTransform(c(0, 10, 0, 20480, 0, -10))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    ds$write(1, 0, 0, 2048, 2048, as.numeric(seq_len(2048 * 2048)))
    ds$close()
  }
  invisible(file.path(dir, names))
}
