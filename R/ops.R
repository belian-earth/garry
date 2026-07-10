# ---------------------------------------------------------------------------
# The garry op vocabulary (decision D9).
#
# Every named operation a stage function may use lives here, and this is
# the ONLY file allowed to touch anvl's `nv_*` API (grep-enforced by
# test-backend-insulation.R). Phase 2 ships the pure-R reference
# implementations; Phase 5 adds traced dispatch (AnvilArray -> nv_*).
#
# The pure-R path is NOT a user execution path (one-compute-path rule):
# it is the permanent test oracle, and it lets planner golden tests run
# without anvl installed. Traced dispatch (Phase 5): every op checks
# .g_traced() and routes AnvlArray / tracer values to nv_*; plain R
# arrays take the oracle path.
#
# Semantics contract (matches anvl/XLA, verified in the spike):
# - nodata is NaN (decision D8); `nan_rm = TRUE` reductions skip it;
# - reducing an all-NaN slice with nan_rm: sum -> 0, min/max -> +/-Inf,
#   mean/median -> NaN, count -> 0;
# - bitwise ops operate on integral values (stored as R doubles/ints);
# - g_cast to integer truncates toward zero (XLA convert semantics).
# ---------------------------------------------------------------------------

# Is this value an anvl array or tracer value (vs a plain R array)?
.g_traced <- function(x) {
  inherits(x, c("AnvlArray", "GraphBox", "AnvlBox"))
}

.require_anvl <- function() {
  if (!requireNamespace("anvl", quietly = TRUE))
    stop("the anvl package is required for execution; install it from ",
         "https://r-xla.r-universe.dev", call. = FALSE)
}

# Promote a plain R scalar to the traced operand's dtype.
.g_scalar_like <- function(x, value) {
  anvl::nv_scalar_like(x, value)
}

# -- Executor bridge (the only anvl entry points outside the ops) ------------

#' JIT-compile a stage closure via anvl (executor bridge).
#'
#' @param f Stage closure.
#' @param device Optional device override (e.g. "cuda"); NULL uses the
#'   anvl default device.
#' @return A compiled function (anvl `JitFunction`).
#' @export
g_jit <- function(f, device = NULL) {
  .require_anvl()
  anvl::jit(f, device = device)
}

#' Reverse-mode value-and-gradient of a scalar-loss closure (bridge).
#'
#' @param f Function returning a scalar float; first argument is the
#'   differentiation target.
#' @param wrt Name of the argument to differentiate with respect to.
#' @return A function returning `list(value, grad$<wrt>)` (jit-compiled).
#' @export
g_value_and_gradient <- function(f, wrt) {
  .require_anvl()
  anvl::jit(anvl::value_and_gradient(f, wrt = wrt))
}

# anvl cannot build unsigned arrays from R numerics; upload through a
# signed (or f64 for u64) carrier wide enough for the full value range.
# Bitwise/comparison semantics are unchanged for the non-negative
# values QA bands hold. Candidate upstream contribution.
.anvl_upload_dtype <- c(u8 = "i16", u16 = "i32", u32 = "i64", u64 = "f64")

#' Upload an R array to an AnvlArray of the given garry dtype.
#'
#' Unsigned dtypes upload via a wider signed carrier (see
#' `.anvl_upload_dtype`): anvl cannot construct them from R numerics.
#'
#' @param x R array/matrix.
#' @param dtype garry dtype string (anvl-aligned).
#' @param device Optional device (e.g. "cuda"); NULL uses the default.
#' @return An `AnvlArray`.
#' @export
g_upload <- function(x, dtype, device = NULL) {
  .require_anvl()
  carrier <- unname(.anvl_upload_dtype[dtype])
  if (!is.na(carrier)) dtype <- carrier
  if (is.null(device)) anvl::nv_array(x, dtype)
  else anvl::nv_array(x, dtype, device = device)
}

#' Download an AnvlArray (or a nested list of them) to R arrays.
#'
#' @param x `AnvlArray` or (nested) list.
#' @return R array / nested list of R arrays.
#' @export
g_download <- function(x) {
  # Order matters: an AnvlArray is itself a list internally.
  if (.g_traced(x)) return(anvl::as_array(x))
  if (is.list(x)) return(lapply(x, g_download))
  x
}

# -- Raw f32 transport (phase 12c, D19/D20) -----------------------------------

# Does the installed anvl accept raw byte payloads in nv_array?
# Released anvl (<= 0.3.0.9000 upstream) does not; the patched local
# branch does at the same version string, so probe behaviour, not
# versions. Memoised per process (daemons probe once each).
.g_raw_probe <- new.env(parent = emptyenv())

#' Can uploads take the raw byte path?
#'
#' Internal capability probe (exported for daemon use via `::`).
#' @return `TRUE` if `anvl::nv_array` accepts raw payloads.
#' @keywords internal
#' @export
.g_has_raw_upload <- function() {
  ok <- .g_raw_probe$ok
  if (!is.null(ok)) return(ok)
  ok <- requireNamespace("anvl", quietly = TRUE) && tryCatch({
    x <- anvl::nv_array(as.raw(c(0L, 0L, 128L, 63L)), "f32", shape = 1L)
    identical(as.numeric(anvl::as_array(x)), 1)
  }, error = function(e) FALSE)
  .g_raw_probe$ok <- ok
  ok
}

#' Upload a raw byte payload to an AnvlArray.
#'
#' `bytes` holds `prod(dim)` elements of `dtype` in ROW-major element
#' order (D19): one memcpy to the device, no double conversion, and no
#' XLA relayout (row-major matches the default layout).
#'
#' @param bytes Raw vector (native little-endian payload).
#' @param dtype garry dtype string (f32 on the 12c path).
#' @param dim Integer dims, `[nr, nc]` or `[t, nr, nc]`.
#' @param device Optional device (e.g. "cuda"); NULL uses the default.
#' @return An `AnvlArray`.
#' @export
g_upload_raw <- function(bytes, dtype, dim, device = NULL) {
  .require_anvl()
  attributes(bytes) <- NULL
  if (is.null(device)) {
    anvl::nv_array(bytes, dtype, shape = dim, byrow = TRUE)
  } else {
    anvl::nv_array(bytes, dtype, shape = dim, byrow = TRUE, device = device)
  }
}

#' Download an AnvlArray as a raw f32 store payload.
#'
#' Row-major byte payload tagged with `gdim`/`gdt` (D20); no double
#' materialisation.
#'
#' @param x `AnvlArray` (f32).
#' @return Raw vector with `gdim` and `gdt` attributes.
#' @export
g_download_raw <- function(x) {
  .require_anvl()
  structure(anvl::as_raw(x, row_major = TRUE),
            gdim = .g_shape(x), gdt = "f32")
}

# Shape of an AnvlArray (bridge; the executor must not touch anvl).
.g_shape <- function(x) {
  anvl::shape(x)
}

# Dtype string of an AnvlArray output (bridge for the executor's
# f32-only raw download dispatch).
.g_dtype <- function(x) {
  as.character(anvl::dtype(x))
}

#' Elementwise select: `yes` where `cond`, else `no`.
#'
#' @param cond Logical array.
#' @param yes,no Arrays or scalars, broadcast against `cond`.
#' @return Array shaped like `cond`.
#' @export
g_ifelse <- function(cond, yes, no) {
  if (.g_traced(cond)) {
    if (is.numeric(yes) && length(yes) == 1L) yes <- .g_scalar_like(no, yes)
    if (is.numeric(no) && length(no) == 1L) no <- .g_scalar_like(yes, no)
    return(anvl::nv_ifelse(cond, yes, no))
  }
  ifelse(cond, yes, no)
}

#' Is a value nodata (NaN under the D8 sentinel model)?
#'
#' @param x Numeric array.
#' @return Logical array.
#' @export
g_is_nodata <- function(x) {
  if (.g_traced(x)) return(anvl::nv_is_nan(x))
  is.na(x)   # TRUE for both NaN and NA_real_
}

#' Pad a matrix by `h` cells on every side with `value`.
#'
#' @param x A matrix.
#' @param h Non-negative integer pad width.
#' @param value Fill value (default 0).
#' @return A `(nrow + 2h) x (ncol + 2h)` matrix.
#' @export
g_pad <- function(x, h, value = 0) {
  h <- as.integer(h)
  if (h == 0L) return(x)
  if (.g_traced(x)) {
    # Pad the LAST two (spatial) dims; leading dims (e.g. time in a (t,y,x)
    # cube) are left full so one focal op vectorises over the whole cube.
    lead <- rep(0L, length(anvl::shape(x)) - 2L)
    return(anvl::nv_pad(x, .g_scalar_like(x, value),
                        edge_padding_low = c(lead, h, h),
                        edge_padding_high = c(lead, h, h)))
  }
  out <- matrix(value, nrow(x) + 2L * h, ncol(x) + 2L * h)
  out[(h + 1L):(h + nrow(x)), (h + 1L):(h + ncol(x))] <- x
  out
}

#' Shifted slice of a padded matrix (the stencil building block).
#'
#' Given `xpad = g_pad(x, h)`, returns the view of `x`'s shape offset by
#' (`dy`, `dx`) pixels, `dy`/`dx` in `[-h, h]`. Rows are y, columns are x
#' (decision D13 orientation).
#'
#' @param xpad Padded matrix.
#' @param dy,dx Integer offsets in pixels.
#' @param out_nrow,out_ncol Dimensions of the unpadded matrix.
#' @param h Pad width used to build `xpad`.
#' @return An `out_nrow x out_ncol` matrix.
#' @export
g_shift_slice <- function(xpad, dy, dx, out_nrow, out_ncol, h) {
  if (.g_traced(xpad)) {
    # Slice the LAST two (spatial) dims; leading dims (time in a (t,y,x) cube)
    # are taken in full, so the stencil vectorises over the whole cube.
    sh <- anvl::shape(xpad); lead <- length(sh) - 2L
    return(anvl::nv_static_slice(
      xpad,
      start_indices = c(rep(1L, lead), 1L + h + dy, 1L + h + dx),
      limit_indices = c(sh[seq_len(lead)], out_nrow + h + dy, out_ncol + h + dx),
      strides = rep(1L, lead + 2L)))
  }
  xpad[(1L + h + dy):(out_nrow + h + dy),
       (1L + h + dx):(out_ncol + h + dx), drop = FALSE]
}

#' Cast to a garry dtype (oracle: value semantics only).
#'
#' Float targets keep double storage; integer targets truncate toward
#' zero; `pred` maps nonzero to TRUE.
#'
#' @param x Numeric array.
#' @param dtype Target dtype string.
#' @return Array with `dtype`'s value semantics.
#' @export
g_cast <- function(x, dtype) {
  stopifnot(dtype_valid(dtype))
  if (.g_traced(x)) return(anvl::nv_convert(x, dtype))
  fam <- .dtype_family(dtype)
  out <- if (fam == "float") {
    x + 0
  } else if (fam == "pred") {
    x != 0
  } else {
    trunc(x)
  }
  out
}

#' Stack 2D layers into a (t, y, x) array (decision D17 layout).
#'
#' @param values List of same-shaped (y, x) matrices.
#' @return A `length(values) x nrow x ncol` array.
#' @export
g_stack <- function(values) {
  if (.g_traced(values[[1L]])) {
    ex <- lapply(values, function(v) anvl::nv_unsqueeze(v, 1L))
    return(do.call(anvl::nv_concatenate, c(ex, list(dimension = 1L))))
  }
  nr <- nrow(values[[1L]]); nc <- ncol(values[[1L]])
  out <- array(NA_real_, c(length(values), nr, nc))
  for (i in seq_along(values)) out[i, , ] <- values[[i]]
  out
}

#' Extract element `i` of a 1-D array as a scalar (static index).
#'
#' @param v 1-D array (e.g. a flattened kernel).
#' @param i 1-based static index.
#' @return Scalar.
#' @export
g_index_scalar <- function(v, i) {
  if (.g_traced(v)) {
    return(anvl::nv_reshape(
      anvl::nv_static_slice(v, start_indices = i, limit_indices = i,
                            strides = 1L), integer(0)))
  }
  v[[i]]
}

# -- Reductions ---------------------------------------------------------------

# Shared shape handling: `dims` are integer array margins to REDUCE
# (planner maps named dims to margins). NULL reduces everything.
.g_reduce <- function(x, dims, f) {
  if (is.null(dims)) return(f(as.vector(x)))
  keep <- setdiff(seq_along(dim(x)), as.integer(dims))
  if (length(keep) == 0L) return(f(as.vector(x)))
  apply(x, keep, f)
}

.nan_filter <- function(v, nan_rm) if (nan_rm) v[!is.na(v)] else v

#' Reductions over array margins (pure-R oracle semantics).
#'
#' @param x Numeric array.
#' @param dims Integer margins to reduce, or NULL for all.
#' @param nan_rm Skip NaN (nodata)?
#' @return Reduced array (margins in `dims` dropped) or scalar.
#' @name g-reductions
NULL

#' @rdname g-reductions
#' @export
g_sum <- function(x, dims = NULL, nan_rm = FALSE) {
  if (.g_traced(x))
    return(anvl::nv_reduce_sum(x, dims = dims, nan_rm = nan_rm))
  .g_reduce(x, dims, function(v) sum(.nan_filter(v, nan_rm)))
}

#' @rdname g-reductions
#' @export
g_mean <- function(x, dims = NULL, nan_rm = FALSE) {
  if (.g_traced(x))
    return(anvl::nv_mean(x, dims = dims, nan_rm = nan_rm))
  .g_reduce(x, dims, function(v) mean(.nan_filter(v, nan_rm)))
}

#' @rdname g-reductions
#' @export
g_min <- function(x, dims = NULL, nan_rm = FALSE) {
  if (.g_traced(x))
    return(anvl::nv_reduce_min(x, dims = dims, nan_rm = nan_rm))
  .g_reduce(x, dims, function(v) {
    v <- .nan_filter(v, nan_rm)
    if (length(v) == 0L) Inf else min(v)   # XLA init value, no warning
  })
}

#' @rdname g-reductions
#' @export
g_max <- function(x, dims = NULL, nan_rm = FALSE) {
  if (.g_traced(x))
    return(anvl::nv_reduce_max(x, dims = dims, nan_rm = nan_rm))
  .g_reduce(x, dims, function(v) {
    v <- .nan_filter(v, nan_rm)
    if (length(v) == 0L) -Inf else max(v)
  })
}

#' @rdname g-reductions
#' @export
g_median <- function(x, dims = NULL, nan_rm = FALSE) {
  if (.g_traced(x))
    return(anvl::nv_median(x, dim = dims, nan_rm = nan_rm))
  .g_reduce(x, dims, function(v) {
    m <- stats::median(v, na.rm = nan_rm)
    if (is.na(m)) NaN else m               # all-nodata -> NaN, never NA
  })
}

#' @rdname g-reductions
#' @export
g_count <- function(x, dims = NULL) {
  if (.g_traced(x)) {
    valid <- anvl::nv_convert(anvl::nv_not(anvl::nv_is_nan(x)), "f32")
    return(anvl::nv_reduce_sum(valid, dims = dims))
  }
  .g_reduce(x, dims, function(v) sum(!is.na(v)))
}

# -- Bitwise family (QA bitmask decoding) -------------------------------------

# bitwAnd and friends need integer inputs; QA values arrive as doubles
# holding integral values. Coercion preserving shape:
.bitw <- function(f, a, b) {
  out <- f(as.integer(a), as.integer(b))
  if (!is.null(dim(a))) dim(out) <- dim(a)
  out
}

#' Bitwise operations on integral arrays.
#'
#' @param a,b Integral arrays (or scalar `b`); recycled like base R.
#' @param n Shift amount in bits.
#' @return Integral array shaped like `a`.
#' @name g-bitwise
NULL

# Promote a plain R integer scalar to the traced operand's dtype.
.g_int_like <- function(a, b) {
  if (.g_traced(b)) return(b)
  .g_scalar_like(a, as.integer(b))
}

#' @rdname g-bitwise
#' @export
g_bitand <- function(a, b) {
  if (.g_traced(a)) return(anvl::nv_and(a, .g_int_like(a, b)))
  .bitw(bitwAnd, a, b)
}

#' @rdname g-bitwise
#' @export
g_bitor <- function(a, b) {
  if (.g_traced(a)) return(anvl::nv_or(a, .g_int_like(a, b)))
  .bitw(bitwOr, a, b)
}

#' @rdname g-bitwise
#' @export
g_bitxor <- function(a, b) {
  if (.g_traced(a)) return(anvl::nv_xor(a, .g_int_like(a, b)))
  .bitw(bitwXor, a, b)
}

#' @rdname g-bitwise
#' @export
g_bitnot <- function(a) {
  if (.g_traced(a)) return(anvl::nv_not(a))
  out <- bitwNot(as.integer(a))
  if (!is.null(dim(a))) dim(out) <- dim(a)
  out
}

#' @rdname g-bitwise
#' @export
g_shiftl <- function(a, n) {
  if (.g_traced(a)) return(anvl::nv_shift_left(a, .g_int_like(a, n)))
  .bitw(bitwShiftL, a, n)
}

#' @rdname g-bitwise
#' @export
g_shiftr <- function(a, n) {
  if (.g_traced(a)) return(anvl::nv_shift_right_logical(a, .g_int_like(a, n)))
  .bitw(bitwShiftR, a, n)
}
