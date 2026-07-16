# ---------------------------------------------------------------------------
# Kalman local-linear-trend scan bodies (design/scan-node-design.md, section 7).
#
# State space (matching hutan/R/smooth-stack.R):
#   level_t = level_{t-1} + slope_{t-1} + w_lvl,  Var(w_lvl) = sigma_lvl^2
#   slope_t = slope_{t-1}               + w_slp,  Var(w_slp) = sigma_slp^2
#   y_t     = level_t + v_t,                      Var(v_t)   = sigma_obs^2 * r_t
# with r_t an optional per-year RELATIVE observation variance (QA policy,
# regime inflation etc. stay upstream MapNode algebra).
#
# The body runs a forward filter and a backward RTS smoother as ONE fused
# kernel over two `g_scan()`s, batched over the chunk's [y, x] planes: the
# carry is five 2x2-covariance/mean planes advanced together. It runs
# identically traced (anvl -> StableHLO while loops) and untraced (the
# pure-R oracle) -- the oracle is the referee for the KFAS diff.
#
# Numerical notes:
# - Everything computes in f64. With the big-kappa diffuse approximation
#   (P1 = kappa * I, kappa = 1e7 vs KFAS's exact P1inf = I), the first
#   update evaluates P11p - P11p^2 / (P11p + H): a cancellation of
#   ~kappa-magnitude terms leaving an O(H) remainder. f32 (~7 significant
#   digits) destroys it; f64 leaves ~1e-9 relative error. Constants are
#   injected via nv_scalar_like (R double literals materialise as f32
#   anvl constants and would silently round).
# - The backward pass does NOT use the textbook RTS forms
#   J = P_f F' S^-1 and P_s = P_f + J (P_s_next - S) J' (S = predicted
#   covariance at t+1): before a pixel's second observation those cancel
#   kappa^2-scale products down to O(q) results, which costs
#   eps * kappa^2 / q absolute error (~6e-2 in the smoothed sd at
#   kappa = 1e7 on a 3-observation series). Substituting
#   S = F P_f F' + Q gives the exact, cancellation-free equivalents
#     J   = F^-1 (I - Q S^-1)
#     P_s = F^-1 (Q - Q S^-1 Q) F^-1' + J P_s_next J'
#   whose terms are all O(q) or O(P_s_next); with them the KFAS diff
#   stays ~1e-7 across dense, gappy, and minimal (3-obs) series.
# - kappa stays at 1e7: large enough to be diffuse (error in the smoothed
#   moments is O(H/kappa)), small enough that squared terms (~1e14) keep
#   f64 headroom.
# - Missing years (NaN under D8) skip the update: the NaN propagates
#   through the update arithmetic and g_ifelse selects the prediction.
# ---------------------------------------------------------------------------

#' Kalman local-linear-trend smoother body for [scan_over()].
#'
#' Returns a scan body `fn(xs, margin)` computing the smoothed level mean
#' (or its standard error) of a per-pixel local-linear-trend Kalman
#' filter + RTS smoother over the `t` axis, batched over the chunk's
#' pixels. Use with `scan_over(x, kalman_llt(...), direction = "bidir")`;
#' `x` is the observation stack, optionally `list(x, r)` with `r` a
#' per-year relative observation-variance stack (`Var(v_t) =
#' sigma_obs^2 * r_t`; `r` must be finite wherever `y` is observed).
#'
#' Hyperparameters are fixed R scalars, fitted off-raster (e.g. hutan's
#' marginal-likelihood MLE) and closed over as f64 constants. Pixels
#' with fewer than 3 valid observations return all-NaN (matching
#' hutan). Initialisation is the large-variance diffuse approximation
#' `P1 = kappa * I`; see the file header for the f64/kappa rationale.
#'
#' `output = "mean"` and `output = "sd"` are separate scan bodies (one
#' export per node); the smoother recomputes per node, which is noise at
#' T ~ 15 next to IO.
#'
#' @param sigma_lvl,sigma_slp,sigma_obs Noise standard deviations (level
#'   disturbance, slope disturbance, observation).
#' @param output `"mean"` (smoothed level) or `"sd"` (its standard error).
#' @param robust_iters Robust reweighting passes (0 = plain smoother).
#'   Each pass inflates the level noise at years whose smoothed-level
#'   innovation exceeds `robust_threshold` MADs by `robust_inflation`.
#' @param robust_threshold,robust_inflation Robust loop constants.
#' @param kappa Diffuse-initialisation variance.
#' @param out_dtype Output dtype the body casts to (align with
#'   `scan_over(dtype = )`; default `"f32"`).
#' @return A scan body `fn(xs, margin)` for [scan_over()].
#' @seealso [scan_over()], [g_scan()]
#' @export
kalman_llt <- function(sigma_lvl, sigma_slp, sigma_obs = 1,
                       output = c("mean", "sd"),
                       robust_iters = 0L, robust_threshold = 3,
                       robust_inflation = 100,
                       kappa = 1e7, out_dtype = "f32") {
  output <- match.arg(output)
  for (v in c(sigma_lvl = sigma_lvl, sigma_slp = sigma_slp,
              sigma_obs = sigma_obs, kappa = kappa))
    if (!is.numeric(v) || length(v) != 1L || !is.finite(v) || v <= 0)
      cli::cli_abort("hyperparameters must be finite positive scalars")
  robust_iters <- as.integer(robust_iters)
  stopifnot(dtype_valid(out_dtype))
  force(robust_threshold); force(robust_inflation)

  function(xs, margin) {
    if (!identical(as.integer(margin), 1L))
      cli::cli_abort("kalman_llt() scans dim 1 (margin 1); got margin {margin}")
    y <- g_cast(xs[[1L]], "f64")
    rrel <- if (length(xs) >= 2L) g_cast(xs[[2L]], "f64") else NULL
    T_ <- if (.g_traced(y)) .g_shape(y)[[1L]] else dim(y)[[1L]]

    # [y, x] plane of f64 zeros (NaN-proof); the batched carry template.
    zero <- g_sum(y * 0, dims = 1L, nan_rm = TRUE)
    # f64 constant injection (R double literals would round through f32).
    kv <- function(v) if (.g_traced(zero)) .g_scalar_like(zero, v) else v
    q_lvl0 <- kv(sigma_lvl^2)
    q_slp  <- kv(sigma_slp^2)
    h0     <- kv(sigma_obs^2)
    kap    <- kv(kappa)

    ok <- g_count(y, dims = 1L) >= 3   # hutan: < 3 valid obs -> all-NaN

    # One filter+smoother pass. q_scale: NULL (plain) or a (t, y, x)
    # per-year level-noise multiplier (robust reweighting). Returns
    # (t, y, x) cubes of the smoothed level mean and sd, gap-masked.
    smooth_llt <- function(q_scale) {
      fxs <- list(y = y)
      if (!is.null(rrel)) fxs$r <- rrel
      if (!is.null(q_scale)) fxs$qs <- q_scale

      fwd <- g_scan(
        init = list(a1 = zero, a2 = zero,
                    P11 = zero + kap, P12 = zero, P22 = zero + kap),
        body = function(carry, s) {
          q_lvl <- if (!is.null(s$qs)) q_lvl0 * s$qs else q_lvl0
          h_t   <- if (!is.null(s$r)) h0 * s$r else h0
          # predict: x <- F x, P <- F P F' + Q  (F = [[1,1],[0,1]])
          a1p  <- carry$a1 + carry$a2
          a2p  <- carry$a2
          P11p <- carry$P11 + 2 * carry$P12 + carry$P22 + q_lvl
          P12p <- carry$P12 + carry$P22
          P22p <- carry$P22 + q_slp
          # update (analytic gain, Z = [1, 0]); NaN y flows through the
          # update terms and the select keeps the prediction.
          v  <- s$y - a1p
          Fv <- P11p + h_t
          K1 <- P11p / Fv
          K2 <- P12p / Fv
          miss <- g_is_nodata(s$y)
          a1  <- g_ifelse(miss, a1p,  a1p + K1 * v)
          a2  <- g_ifelse(miss, a2p,  a2p + K2 * v)
          P11 <- g_ifelse(miss, P11p, (1 - K1) * P11p)
          P12 <- g_ifelse(miss, P12p, (1 - K1) * P12p)
          P22 <- g_ifelse(miss, P22p, P22p - K2 * P12p)
          list(carry = list(a1 = a1, a2 = a2,
                            P11 = P11, P12 = P12, P22 = P22),
               out = list(a1f = a1, a2f = a2,
                          a1p = a1p, a2p = a2p,
                          P11p = P11p, P12p = P12p, P22p = P22p))
        },
        xs = fxs
      )

      # outputs at one step, gap-masked
      emit <- function(a1s, P11s) {
        sd <- sqrt(g_ifelse(P11s > 0, P11s, 0))
        list(m = g_ifelse(ok, a1s, NaN), s = g_ifelse(ok, sd, NaN))
      }
      last <- emit(fwd$carry$a1, fwd$carry$P11)   # smoothed(T) = filtered(T)
      if (T_ == 1L)
        return(list(mean = g_concat_t(list(last$m)),
                    sd   = g_concat_t(list(last$s))))

      # backward RTS over t = T-1 .. 1: step t reads filtered means at t
      # and the PREDICTED state at t+1 (the series shifted by one),
      # carrying smoothed(t+1). Cancellation-free forms (header note):
      #   J   = F^-1 (I - Q S^-1)
      #   P_s = F^-1 (Q - Q S^-1 Q) F^-1' + J P_s_next J'
      # with S = P_pred(t+1) and Q = diag(q_lvl(t+1), q_slp).
      f <- fwd$out
      bxs <- list(
        a1f = g_slice_t(f$a1f, 1L, T_ - 1L),
        a2f = g_slice_t(f$a2f, 1L, T_ - 1L),
        a1pn  = g_slice_t(f$a1p,  2L, T_),
        a2pn  = g_slice_t(f$a2p,  2L, T_),
        P11pn = g_slice_t(f$P11p, 2L, T_),
        P12pn = g_slice_t(f$P12p, 2L, T_),
        P22pn = g_slice_t(f$P22p, 2L, T_)
      )
      if (!is.null(q_scale)) bxs$qsn <- g_slice_t(q_scale, 2L, T_)
      bwd <- g_scan(
        init = list(a1s = fwd$carry$a1, a2s = fwd$carry$a2,
                    P11s = fwd$carry$P11, P12s = fwd$carry$P12,
                    P22s = fwd$carry$P22),
        body = function(carry, s) {
          q1 <- if (!is.null(s$qsn)) q_lvl0 * s$qsn else q_lvl0
          det <- s$P11pn * s$P22pn - s$P12pn * s$P12pn
          # M = I - Q S^-1  (S^-1 via the analytic 2x2 inverse)
          M11 <- 1 - q1 * s$P22pn / det
          M12 <- q1 * s$P12pn / det
          M21 <- q_slp * s$P12pn / det
          M22 <- 1 - q_slp * s$P11pn / det
          J11 <- M11 - M21
          J12 <- M12 - M22
          J21 <- M21
          J22 <- M22
          # a_s(t) = a_f(t) + J (a_s(t+1) - a_pred(t+1))
          d1 <- carry$a1s - s$a1pn
          d2 <- carry$a2s - s$a2pn
          a1s <- s$a1f + J11 * d1 + J12 * d2
          a2s <- s$a2f + J21 * d1 + J22 * d2
          # E = F^-1 (Q - Q S^-1 Q) F^-1'   (G symmetric)
          G11 <- q1 * (1 - q1 * s$P22pn / det)
          G12 <- q1 * q_slp * s$P12pn / det
          G22 <- q_slp * (1 - q_slp * s$P11pn / det)
          E11 <- G11 - 2 * G12 + G22
          E12 <- G12 - G22
          E22 <- G22
          # J P_s_next J'
          JP11 <- J11 * carry$P11s + J12 * carry$P12s
          JP12 <- J11 * carry$P12s + J12 * carry$P22s
          JP21 <- J21 * carry$P11s + J22 * carry$P12s
          JP22 <- J21 * carry$P12s + J22 * carry$P22s
          P11s <- E11 + JP11 * J11 + JP12 * J12
          P12s <- E12 + JP11 * J21 + JP12 * J22
          P22s <- E22 + JP21 * J21 + JP22 * J22
          list(carry = list(a1s = a1s, a2s = a2s,
                            P11s = P11s, P12s = P12s, P22s = P22s),
               out = emit(a1s, P11s))
        },
        xs = bxs,
        reverse = TRUE
      )
      list(mean = g_concat_t(list(bwd$out$m, last$m)),
           sd   = g_concat_t(list(bwd$out$s, last$s)))
    }

    sm <- smooth_llt(NULL)
    if (robust_iters > 0L)
      cli::cli_abort("robust_iters > 0 is not implemented yet (phase 4)")

    g_cast(if (output == "mean") sm$mean else sm$sd, out_dtype)
  }
}

#' Smooth a stack with the LLT Kalman smoother (mean + sd pair).
#'
#' Convenience wrapper: one [scan_over()] per requested output, sharing
#' one [kalman_llt()] parameterisation.
#'
#' @param x Observation stack (`LazyRaster` with a `t` axis), or a
#'   `LazyDataset` (each band smoothed independently).
#' @param obs_var Optional relative observation-variance stack on the
#'   same grid (`Var(v_t) = sigma_obs^2 * obs_var_t`).
#' @param outputs Which outputs to build (`"mean"`, `"sd"`).
#' @param dtype Output dtype (default f32).
#' @inheritParams kalman_llt
#' @param ... Passed to [kalman_llt()].
#' @return A named list of lazy objects, one per requested output.
#' @export
kalman_smooth <- function(x, sigma_lvl, sigma_slp, sigma_obs = 1,
                          obs_var = NULL, outputs = c("mean", "sd"),
                          dtype = "f32", ...) {
  outputs <- match.arg(outputs, several.ok = TRUE)
  target <- if (is.null(obs_var)) x else list(x, obs_var)
  stats::setNames(lapply(outputs, function(o) {
    scan_over(target,
              kalman_llt(sigma_lvl, sigma_slp, sigma_obs, output = o,
                         out_dtype = dtype, ...),
              over = "t", direction = "bidir", dtype = dtype)
  }), outputs)
}
