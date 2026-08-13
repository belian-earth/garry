# ---------------------------------------------------------------------------
# Minimal pure-R safetensors reader (weights ingestion for native model
# inference, e.g. OmniCloudMask). Format: 8-byte little-endian u64
# header length, JSON header mapping tensor name -> {dtype, shape,
# data_offsets = [begin, end)} relative to the first byte after the
# header, then the raw row-major tensor data. Only F32 payloads are
# materialised (I64 bookkeeping tensors like num_batches_tracked are
# skipped); that covers every model state dict garry consumes.
# ---------------------------------------------------------------------------

# Parse the JSON header. Returns list(offset = first data byte,
# tensors = named list of {dtype, shape, begin, end}).
.st_header <- function(path) {
  rlang::check_installed("jsonlite", reason = "to read safetensors files")
  path <- path.expand(path)
  if (!file.exists(path)) {
    cli::cli_abort("safetensors file not found: {.path {path}}")
  }
  con <- file(path, "rb")
  on.exit(close(con), add = TRUE)
  u32 <- readBin(con, "integer", n = 2L, size = 4L, endian = "little")
  # u64 header length via two u32 halves (headers are far below 2^31,
  # but the low word must be reassembled unsigned)
  lo <- if (u32[[1L]] < 0) u32[[1L]] + 2^32 else u32[[1L]]
  len <- lo + u32[[2L]] * 2^32
  j <- jsonlite::fromJSON(
    rawToChar(readBin(con, "raw", n = len)),
    simplifyVector = FALSE
  )
  j[["__metadata__"]] <- NULL
  tensors <- lapply(j, function(t) {
    list(
      dtype = t$dtype,
      shape = as.integer(unlist(t$shape)),
      begin = as.numeric(t$data_offsets[[1L]]),
      end = as.numeric(t$data_offsets[[2L]])
    )
  })
  list(offset = 8 + len, tensors = tensors)
}

#' Read tensors from a safetensors file.
#'
#' safetensors (<https://github.com/huggingface/safetensors>) is the
#' simple tensor serialisation format used across the machine-learning
#' ecosystem, typically for model weights.
#'
#' Returns a named list of R arrays indexed exactly like the source
#' torch tensors (`x[i, j, ...]` agrees elementwise): the row-major
#' payload is reshaped through the reversed dims and `aperm`ed back.
#' F32 tensors only; others (e.g. I64 `num_batches_tracked`) are
#' silently dropped. A 0-d tensor becomes a length-1 vector.
#'
#' @param path Path to a `.safetensors` file.
#' @param names Optional character vector restricting which tensors to
#'   read (default: all F32 tensors).
#' @return Named list of numeric arrays.
#' @seealso [safetensors_ls()] to list a file's tensors without
#'   reading data.
#' @export
safetensors_read <- function(path, names = NULL) {
  hdr <- .st_header(path)
  keep <- names(hdr$tensors)[vapply(
    hdr$tensors,
    function(t) {
      identical(t$dtype, "F32")
    },
    logical(1)
  )]
  if (!is.null(names)) {
    missing <- setdiff(names, names(hdr$tensors))
    if (length(missing)) {
      cli::cli_abort("tensors not in file: {.val {missing}}")
    }
    keep <- intersect(names, keep)
  }
  con <- file(path.expand(path), "rb")
  on.exit(close(con), add = TRUE)
  out <- vector("list", length(keep))
  names(out) <- keep
  for (nm in keep) {
    t <- hdr$tensors[[nm]]
    seek(con, hdr$offset + t$begin)
    n <- (t$end - t$begin) / 4
    v <- readBin(con, "numeric", n = n, size = 4L, endian = "little")
    out[[nm]] <- if (length(t$shape) <= 1L) {
      v
    } else {
      aperm(array(v, rev(t$shape)), rev(seq_along(t$shape)))
    }
  }
  out
}

#' List tensor names, dtypes, and shapes without reading data.
#'
#' @param path Path to a `.safetensors` file.
#' @return Data frame with `name`, `dtype`, `shape` (comma string).
#' @seealso [safetensors_read()] to read the tensors.
#' @export
safetensors_ls <- function(path) {
  hdr <- .st_header(path)
  data.frame(
    name = names(hdr$tensors),
    dtype = vapply(hdr$tensors, function(t) t$dtype, ""),
    shape = vapply(
      hdr$tensors,
      function(t) {
        paste(t$shape, collapse = ",")
      },
      ""
    ),
    row.names = NULL
  )
}
