#' @include ops.R
#' @keywords internal
NULL

#' Dequantize Alpha Earth (AEF) embedding codes.
#'
#' The AEF Int8 decode `((x / 127.5)^2) * sign(x)`: per-value, nonlinear, sign-
#' preserving, mapping the code range `[-127, 127]` to ~`[-1, 1]`. Written in
#' the `g_*` vocabulary, so applying it with [lazy_map()] after [lazy_dataset()]
#' fuses the decode onto the read, on the device rather than as a separate
#' decode pass.
#'
#' @param x Int8 codes (traced array or plain numeric).
#' @return The dequantized values, same shape as `x`.
#' @export
dequantize_aef <- function(x) {
  # sign(x) * (x / 127.5)^2, written branchless as xn * |xn| with xn = x / 127.5.
  # Divide first so the arithmetic runs in f32 (an Int8 source would overflow on
  # x * |x| before any promotion); the sign at x = 0 is irrelevant (magnitude 0).
  xn <- x / 127.5
  xn * abs(xn)
}

#' Dequantize Embedded Seamless Data (ESD) FSQ codes.
#'
#' Decodes ONE level from packed Finite Scalar Quantisation indices: each
#' uint16 code factorises into `length(levels)` per-level integers via the
#' positional basis `B = cumprod(c(1, levels[-length(levels)]))`, and each
#' rescales to roughly `[-1, 1]`:
#'
#' \deqn{c_j = \lfloor x / B_j \rfloor \bmod L_j, \quad
#'       v_j = (c_j - \lfloor L_j/2 \rfloor) / \lfloor L_j/2 \rfloor}
#'
#' Written in the `g_*` vocabulary so it fuses onto the read as a garry map
#' (one [lazy_map()] per band and level) -- on the device, not a separate
#' decode pass. Integer division truncates toward zero; all arithmetic is
#' exact in f32 because codes are integers below `prod(levels)` (64000 for
#' the ESD default, well under 2^24). NaN nodata is re-masked explicitly
#' after the decode, so nodata pixels stay NaN in the output.
#'
#' The default `levels` matches the ESD upstream quantiser (12 monthly
#' uint16 bands x 6 levels = 72 embedding channels). Any FSQ-packed
#' product decodes by passing its own `levels`.
#'
#' @param x Packed FSQ codes (traced array or plain numeric).
#' @param level Which level to decode (index into `levels`).
#' @param levels Integer vector of per-level cardinalities. Default
#'   `c(8L, 8L, 8L, 5L, 5L, 5L)` (the ESD quantiser).
#' @return The decoded level, same shape as `x`, in `[-1, 1]`.
#' @references
#' Chen S., et al. ESD quantiser:
#' <https://github.com/shuangchencc/ESD/blob/main/esd_quantizer.py>
#'
#' Mentzer F., Minnen D., Agustsson E., Tschannen M. (2024). Finite
#' scalar quantization: VQ-VAE made simple. ICLR.
#' @export
dequantize_esd <- function(x, level, levels = c(8L, 8L, 8L, 5L, 5L, 5L)) {
  if (
    length(level) != 1L || is.na(level) || level < 1L || level > length(levels)
  ) {
    cli::cli_abort(
      "{.arg level} must be a single index in 1..{length(levels)}."
    )
  }
  basis <- cumprod(c(1, levels[-length(levels)]))[[level]]
  L <- as.numeric(levels[[level]])
  half <- floor(L / 2)
  trunc_f <- function(z) g_cast(g_cast(z, "i32"), "f32")
  a <- trunc_f(x / basis)
  code <- a - trunc_f(a / L) * L
  g_ifelse(g_is_nodata(x), NaN, (code - half) / half)
}
