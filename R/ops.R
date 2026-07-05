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
# without anvl installed.
#
# Semantics contract (matches anvl/XLA, verified in the spike):
# - nodata is NaN (decision D8); `nan_rm = TRUE` reductions skip it;
# - reducing an all-NaN slice with nan_rm: sum -> 0, min/max -> +/-Inf,
#   mean/median -> NaN, count -> 0;
# - bitwise ops operate on integral values (stored as R doubles/ints);
# - g_cast to integer truncates toward zero (XLA convert semantics).
# ---------------------------------------------------------------------------

#' Elementwise select: `yes` where `cond`, else `no`.
#'
#' @param cond Logical array.
#' @param yes,no Arrays or scalars, broadcast against `cond`.
#' @return Array shaped like `cond`.
#' @export
g_ifelse <- function(cond, yes, no) {
  ifelse(cond, yes, no)
}

#' Is a value nodata (NaN under the D8 sentinel model)?
#'
#' @param x Numeric array.
#' @return Logical array.
#' @export
g_is_nodata <- function(x) {
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
  .g_reduce(x, dims, function(v) sum(.nan_filter(v, nan_rm)))
}

#' @rdname g-reductions
#' @export
g_mean <- function(x, dims = NULL, nan_rm = FALSE) {
  .g_reduce(x, dims, function(v) mean(.nan_filter(v, nan_rm)))
}

#' @rdname g-reductions
#' @export
g_min <- function(x, dims = NULL, nan_rm = FALSE) {
  .g_reduce(x, dims, function(v) {
    v <- .nan_filter(v, nan_rm)
    if (length(v) == 0L) Inf else min(v)   # XLA init value, no warning
  })
}

#' @rdname g-reductions
#' @export
g_max <- function(x, dims = NULL, nan_rm = FALSE) {
  .g_reduce(x, dims, function(v) {
    v <- .nan_filter(v, nan_rm)
    if (length(v) == 0L) -Inf else max(v)
  })
}

#' @rdname g-reductions
#' @export
g_median <- function(x, dims = NULL, nan_rm = FALSE) {
  .g_reduce(x, dims, function(v) {
    m <- stats::median(v, na.rm = nan_rm)
    if (is.na(m)) NaN else m               # all-nodata -> NaN, never NA
  })
}

#' @rdname g-reductions
#' @export
g_count <- function(x, dims = NULL) {
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

#' @rdname g-bitwise
#' @export
g_bitand <- function(a, b) .bitw(bitwAnd, a, b)

#' @rdname g-bitwise
#' @export
g_bitor <- function(a, b) .bitw(bitwOr, a, b)

#' @rdname g-bitwise
#' @export
g_bitxor <- function(a, b) .bitw(bitwXor, a, b)

#' @rdname g-bitwise
#' @export
g_bitnot <- function(a) {
  out <- bitwNot(as.integer(a))
  if (!is.null(dim(a))) dim(out) <- dim(a)
  out
}

#' @rdname g-bitwise
#' @export
g_shiftl <- function(a, n) .bitw(bitwShiftL, a, n)

#' @rdname g-bitwise
#' @export
g_shiftr <- function(a, n) .bitw(bitwShiftR, a, n)
