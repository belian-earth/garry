#' Where a plan reads its sources
#'
#' Lists the windows a plan's read stages read and the source pixels and
#' tiles behind each, without reading any pixels. A read stage reads its
#' grid in windows: the chunks the planner cut, grown to whole read tasks
#' where [collect()] would grow them for a plan that only reads. Each
#' window maps onto its source file by the route that reads it:
#'
#' * `"read"`: a source read on its own pixels, the window itself.
#' * `"direct"`: a warp served by a plain or decimating read of the file
#'   (an aligned target), the window scaled into the file.
#' * `"warp"`: a warp through GDAL's warper, the box of the window's
#'   footprint on the source, padded for the resampling kernel as the
#'   warper pads its source windows.
#' * `"window_warp"`, `"mosaic"`, `"zarr"`, `"coarsen"`: reads of several
#'   files, a mosaic (a GTI index, or a local VRT of files placed across
#'   its extent), a Zarr array or a coarsened warp. Their windows
#'   are listed, their source windows and tiles are `NA`: each of them
#'   reads its files in its own pieces.
#'
#' Tiles are the file's blocks: a COG's tiles, a striped file's strips.
#' A local VRT reads through to its files and is described by the tiles
#' its `SourceProperties` record, which holds for a VRT whose bands each
#' take one file on the VRT's own pixels, such as a classic VRT of a
#' daily series. A footprint is a box, so a rotated or curved warp lists
#' tiles in its corners that it does not read. A decimating read may
#' take a file's overview, which GDAL chooses; its tiles are given at full
#' resolution.
#'
#' With `tiles = TRUE` each window becomes one row per source tile, with
#' the tile's byte `offset` and `length` in its file, from the file's TIFF
#' metadata (`0` for a tile a sparse file leaves empty). This opens each
#' file, and a remote file costs its header fetch, if it is not open
#' already. A VRT's window takes the file under its centre (GDAL's
#' `LocationInfo`), whose tiles are listed only where it has the VRT's
#' size and one band.
#'
#' @param x A `LazyRaster`, a `LazyDataset` (its bands are stacked first,
#'   as in [collect()]) or a `Plan` from [plan_lazy()].
#' @param tiles List one row per source tile, with its bytes, instead of
#'   one row per window?
#' @param distributed As in [collect()]: whether the plan is read by the
#'   daemon pools, which reads a remote mosaic by fetching its items.
#' @return A data frame with one row per window: `stage`, `route`,
#'   `chunk`, `path`, `band` (comma-separated for a band stack), the
#'   window `x_off`, `y_off`, `x_size`, `y_size` in the stage's grid,
#'   halo included, the source window `src_x_off`, `src_y_off`,
#'   `src_x_size`, `src_y_size` in the file's pixels (rows from the
#'   north), and the inclusive tile range `tile_x0`, `tile_y0`, `tile_x1`,
#'   `tile_y1` with the tile size `tile_x_size`, `tile_y_size` (tile rows
#'   count from the file's first row, the south edge of a south-up file).
#'   With `tiles = TRUE`, one row per window, band and tile in place of
#'   the range: `file`, `band`, `tile_x`, `tile_y`, `offset`, `length`.
#' @seealso [plan_view()] for the stages themselves.
#' @examples
#' f <- system.file("extdata", "storml_elev.tif", package = "gdalraster")
#' r <- lazy_source(f)
#' plan_reads(r)
#' plan_reads(r, tiles = TRUE)
#' @export
plan_reads <- function(x, tiles = FALSE, distributed = garry_daemons_set()) {
  if (S7::S7_inherits(x, LazyDatasetGroups)) {
    cli::cli_abort(
      c(
        "{.fn plan_reads} takes one plan; a grouped dataset makes one a group.",
        "i" = "Pass one group's dataset, or a {.cls Plan} from {.fn plan_lazy}."
      ),
      class = c("garry_plan_error", "garry_error")
    )
  }
  p <- if (S7::S7_inherits(x, Plan)) {
    x
  } else {
    if (S7::S7_inherits(x, LazyDataset)) {
      x <- stack_bands(x)
    }
    plan_lazy(x)
  }
  graph <- p@graph
  # a source only a warp reads is read by that warp, never on its own
  warp_only <- .placement_scan(p)$warp_only
  stages <- Filter(
    function(s) s@kind == "warp" || (s@kind == "source_read" && !warp_only[[s@id]]),
    p@stages
  )
  # a plan that only reads grows its windows to whole read tasks
  spec <- .read_only_spec(p, distributed)
  if (!is.null(spec)) {
    grown <- stats::setNames(spec$read_stage, vapply(spec$read_stage, function(s) as.character(s@id), ""))
    stages <- lapply(stages, function(s) grown[[as.character(s@id)]] %||% s)
  }
  rows <- lapply(stages, function(s) .plan_stage_reads(graph, s))
  out <- do.call(rbind, c(list(.plan_reads_empty()), rows))
  rownames(out) <- NULL
  if (!tiles) {
    return(out)
  }
  .plan_reads_tiles(out)
}

# The windows of one read stage, as plan_reads() rows.
.plan_stage_reads <- function(graph, s) {
  node <- graph_get(graph, s@members[[1L]])
  warp <- s@kind == "warp"
  snode <- if (warp) graph_get(graph, node@parents[[1L]]) else node
  ra <- .stage_read_args(graph, s)
  route <- .plan_read_route(s, snode, ra)
  path <- if (length(ra$path) == 1L) ra$path else NA_character_
  file <- if (route == "warp") snode@path else path
  desc <- if (route %in% c("read", "direct", "warp")) {
    .gdal_source_desc(
      file,
      snode@grid,
      snode@stored,
      snode@block_dim,
      snode@open_options,
      ra$resampling %||% "near"
    )
  }
  vrt <- if (route == "warp") .gdal_handle(ra$path)
  ck <- chunk_iter(s@chunks)
  rows <- lapply(seq_len(nrow(ck)), function(i) {
    w <- chunk_window_with_halo(s@chunks, ck$x_off[[i]], ck$y_off[[i]], ck$x_size[[i]], ck$y_size[[i]])
    win <- c(w$x_off, w$y_off, w$x_size, w$y_size)
    src <- switch(
      route,
      read = win,
      direct = c(
        ra$decim$x_off + win[[1L]] * ra$decim$fx,
        ra$decim$y_off + win[[2L]] * ra$decim$fy,
        win[[3L]] * ra$decim$fx,
        win[[4L]] * ra$decim$fy
      ),
      warp = {
        b <- .gdal_warp_src_window(vrt, desc, win)
        if (is.null(b)) rep(NA_real_, 4L) else c(b[[1L]], b[[2L]], b[[3L]] - b[[1L]] + 1, b[[4L]] - b[[2L]] + 1)
      },
      rep(NA_real_, 4L)
    )
    c(i, win, src, .plan_tile_range(src, desc))
  })
  m <- do.call(rbind, rows)
  data.frame(
    stage = s@id,
    route = route,
    chunk = as.integer(m[, 1L]),
    path = file,
    band = paste(if (warp && length(node@bands)) node@bands else snode@band, collapse = ","),
    x_off = m[, 2L],
    y_off = m[, 3L],
    x_size = m[, 4L],
    y_size = m[, 5L],
    src_x_off = m[, 6L],
    src_y_off = m[, 7L],
    src_x_size = m[, 8L],
    src_y_size = m[, 9L],
    tile_x0 = m[, 10L],
    tile_y0 = m[, 11L],
    tile_x1 = m[, 12L],
    tile_y1 = m[, 13L],
    tile_x_size = m[, 14L],
    tile_y_size = m[, 15L],
    stringsAsFactors = FALSE
  )
}

# How a read stage reads its source (.stage_read_args() `ra`).
.plan_read_route <- function(s, snode, ra) {
  if (length(ra$decim$parts) || (length(ra$path) == 1L && startsWith(ra$path, "GTI:"))) {
    return("mosaic")
  }
  if (length(ra$path) != 1L) {
    return("window_warp")
  }
  if (.gdal_is_zarr(ra$path)) {
    return("zarr")
  }
  if (!is.null(ra$decim$coarsen)) {
    return("coarsen")
  }
  if (.plan_mosaic_vrt(snode@path)) {
    return("mosaic")
  }
  if (isTRUE(ra$warped)) {
    return("warp")
  }
  if (!is.null(ra$decim$fx)) {
    return("direct")
  }
  if (s@kind == "warp") "window_warp" else "read"
}

# Is `path` a local VRT whose bands are not each one file on the VRT's own
# pixels: several sources to a band, or one placed or sized otherwise? Its
# pixels are then no one file's, and nor are its tiles. Read from the XML.
.plan_mosaic_vrt <- function(path) {
  if (length(path) != 1L || .gdal_is_remote(path) || !grepl("\\.vrt$", path, ignore.case = TRUE)) {
    return(FALSE)
  }
  xml <- paste(readLines(path, warn = FALSE), collapse = "\n")
  size <- regmatches(xml, regexec('<VRTDataset[^>]*rasterXSize="([0-9]+)"[^>]*rasterYSize="([0-9]+)"', xml))[[1L]][-1L]
  bands <- strsplit(xml, "<VRTRasterBand", fixed = TRUE)[[1L]][-1L]
  whole <- function(b) {
    if (lengths(regmatches(b, gregexpr("<(Simple|Complex|Averaged|Kernel)Source", b))) != 1L) {
      return(FALSE)
    }
    props <- regmatches(b, regexec('<SourceProperties[^>]*RasterXSize="([0-9]+)"[^>]*RasterYSize="([0-9]+)"', b))[[1L]][-1L]
    dst <- regmatches(b, regexec('<DstRect xOff="([-0-9.e+]+)" yOff="([-0-9.e+]+)" xSize="([-0-9.e+]+)" ySize="([-0-9.e+]+)"', b))[[1L]][-1L]
    (!length(props) || identical(props, size)) &&
      (!length(dst) || isTRUE(all(as.numeric(dst) == c(0, 0, as.numeric(size)))))
  }
  !length(size) || !all(vapply(bands, whole, NA))
}

# The inclusive tile range c(tx0, ty0, tx1, ty1) and tile size under source
# window `src` c(x_off, y_off, x_size, y_size), rows from the north, clipped to
# the file; NA where there is no window. Tile rows count from the file's first
# row.
.plan_tile_range <- function(src, desc) {
  if (is.null(desc) || anyNA(src)) {
    return(rep(NA_real_, 6L))
  }
  tile <- desc$tile
  c0 <- max(0, src[[1L]])
  c1 <- min(desc$dims[[1L]] - 1, src[[1L]] + src[[3L]] - 1)
  r <- c(max(0, src[[2L]]), min(desc$dims[[2L]] - 1, src[[2L]] + src[[4L]] - 1))
  if (c1 < c0 || r[[2L]] < r[[1L]]) {
    return(rep(NA_real_, 6L))
  }
  if (desc$south_up) {
    r <- rev(desc$dims[[2L]] - 1 - r)
  }
  c(c0 %/% tile[[1L]], r[[1L]] %/% tile[[2L]], c1 %/% tile[[1L]], r[[2L]] %/% tile[[2L]], tile)
}

# plan_reads(tiles = TRUE): each window row as one row per band and tile of
# the file it reads, with the tile's bytes.
.plan_reads_tiles <- function(win) {
  keep <- !is.na(win$tile_x0)
  rows <- lapply(which(keep), function(i) {
    r <- win[i, ]
    file <- r$path
    bands <- as.integer(strsplit(r$band, ",", fixed = TRUE)[[1L]])
    if (grepl("\\.vrt$", file, ignore.case = TRUE) && !.gdal_is_remote(file)) {
      # the file under the window's centre, read on the VRT's own pixels
      vrt <- .gdal_handle(file)
      file <- gdal_vrt_file_at(
        r$path,
        bands[[1L]],
        floor(r$src_x_off + r$src_x_size / 2),
        floor(r$src_y_off + r$src_y_size / 2)
      )
      one <- if (is.na(file)) NULL else .gdal_probe(file)
      same <- !is.null(one) &&
        one$getRasterCount() == 1L &&
        one$getRasterXSize() == vrt$getRasterXSize() &&
        one$getRasterYSize() == vrt$getRasterYSize()
      if (!same) {
        return(NULL)
      }
      bands <- 1L
    }
    tx <- seq(r$tile_x0, r$tile_x1)
    ty <- seq(r$tile_y0, r$tile_y1)
    grid <- expand.grid(tile_x = tx, tile_y = ty, band = bands)
    by <- lapply(bands, function(b) {
      sel <- grid$band == b
      gdal_tile_bytes(file, b, grid$tile_x[sel], grid$tile_y[sel])
    })
    data.frame(
      stage = r$stage,
      route = r$route,
      chunk = r$chunk,
      path = r$path,
      file = file,
      band = grid$band,
      tile_x = grid$tile_x,
      tile_y = grid$tile_y,
      offset = unlist(lapply(by, `[[`, "offset")),
      length = unlist(lapply(by, `[[`, "length")),
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, c(
    list(data.frame(
      stage = integer(0), route = character(0), chunk = integer(0), path = character(0),
      file = character(0), band = integer(0), tile_x = numeric(0), tile_y = numeric(0),
      offset = numeric(0), length = numeric(0), stringsAsFactors = FALSE
    )),
    rows
  ))
  rownames(out) <- NULL
  out
}

.plan_reads_empty <- function() {
  num <- numeric(0)
  data.frame(
    stage = integer(0), route = character(0), chunk = integer(0), path = character(0),
    band = character(0), x_off = num, y_off = num, x_size = num, y_size = num,
    src_x_off = num, src_y_off = num, src_x_size = num, src_y_size = num,
    tile_x0 = num, tile_y0 = num, tile_x1 = num, tile_y1 = num,
    tile_x_size = num, tile_y_size = num, stringsAsFactors = FALSE
  )
}
