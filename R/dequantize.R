#' @include ops.R
#' @keywords internal
NULL

#' Dequantize signed-power embedding codes.
#'
#' The decode `sign(x) * (|x| / scale)^power`: per-value, nonlinear and
#' sign-preserving. Geo-embedding products store float vectors as Int8
#' codes this way, spending more codes near zero where most values sit;
#' with the usual `scale = 127.5` the code range `[-127, 127]` maps to
#' about `[-1, 1]`. The `signed_power` method of the Embeddings Zarr
#' Convention's `geoemb:quantization` metadata names the two parameters.
#' [dequantize_aef()] and [dequantize_olmoearth()] are this decode with
#' `power = 2`.
#'
#' Written in the `g_*` vocabulary, so applying it with [lazy_map()] after
#' [lazy_dataset()] fuses the decode onto the read, on the device rather
#' than as a separate decode pass. A nodata code (`-128` in both
#' products) must reach the decode as NaN: `lazy_dataset()` does that
#' whenever the source declares it (a GeoTIFF nodata value, a Zarr fill
#' value), and NaN passes through the decode unchanged.
#'
#' @param x Int8 codes (traced array or plain numeric).
#' @param power Exponent of the decode (`2` for AEF and OlmoEarth).
#' @param scale Code magnitude that decodes to 1 (`127.5` for both).
#' @return The dequantized values, same shape as `x`.
#' @seealso [dequantize_aef()], [dequantize_olmoearth()]
#' @export
dequantize_signed_power <- function(x, power = 2, scale = 127.5) {
  if (!is.numeric(power) || length(power) != 1L || !is.finite(power) || power <= 0) {
    cli::cli_abort("{.arg power} must be a single positive number.")
  }
  if (!is.numeric(scale) || length(scale) != 1L || !is.finite(scale) || scale <= 0) {
    cli::cli_abort("{.arg scale} must be a single positive number.")
  }
  # Divide first so the arithmetic runs in f32 (an Int8 source would
  # overflow on x * |x| before any promotion).
  xn <- x / scale
  if (power == 2) {
    # sign(x) * x^2 written branchless as xn * |xn|: bit-identical to the
    # products' reference decodes, which square in f32
    return(xn * abs(xn))
  }
  sign(xn) * abs(xn)^power
}

#' Dequantize Alpha Earth (AEF) embedding codes.
#'
#' The AEF Int8 decode `((x / 127.5)^2) * sign(x)`: per-value, nonlinear, sign-
#' preserving, mapping the code range `[-127, 127]` to ~`[-1, 1]`. Written in
#' the `g_*` vocabulary, so applying it with [lazy_map()] after [lazy_dataset()]
#' fuses the decode onto the read, on the device rather than as a separate
#' decode pass. This is [dequantize_signed_power()] with its defaults.
#'
#' @param x Int8 codes (traced array or plain numeric).
#' @return The dequantized values, same shape as `x`.
#' @seealso [dequantize_signed_power()]
#' @export
dequantize_aef <- function(x) {
  dequantize_signed_power(x, power = 2, scale = 127.5)
}

#' Dequantize OlmoEarth embedding codes.
#'
#' The OlmoEarth v1.3 embeddings (Ai2, published on
#' Source Cooperative as a Zarr v3 store) quantize each 128-dimension
#' annual vector to Int8 with the `signed_power` scheme, power 2:
#' `sign(q) * (|q| / 127.5)^2`, with `-128` as nodata. That is the
#' decode [dequantize_aef()] applies too; this name records which
#' product a pipeline reads. `lazy_dataset()` turns the `-128` fill value
#' into NaN at the read, so nodata stays NaN through the decode.
#'
#' Decode before any arithmetic: the quantization is nonlinear, so
#' distances between raw codes are not proportional to distances between
#' embeddings. The vectors are not unit length (the per-pixel norm over
#' 128 dimensions is about 3.0 to 3.8); normalise them before taking a
#' dot product as cosine similarity.
#'
#' @param x Int8 codes (traced array or plain numeric).
#' @return The dequantized values, same shape as `x`.
#' @references
#' Team OlmoEarth et al. (2026). OlmoEarth v1.3 Embeddings. Ai2.
#' <https://allenai.org/papers/olmoearth-v1-3>
#'
#' <https://source.coop/olmoearth/olmoearth-v1-3-embeddings>
#' @seealso [dequantize_signed_power()]
#' @export
dequantize_olmoearth <- function(x) {
  dequantize_signed_power(x, power = 2, scale = 127.5)
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
