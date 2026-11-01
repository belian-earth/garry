# Generate the KFAS fixture for garry's Kalman smoother tests.
#
# Run once, from the package root, on a machine with KFAS installed:
#
#     Rscript tools/kfas_make_fixture.R
#
# Writes tests/testthat/fixtures/kfas/kalman-llt.rds. The cases are series
# with the local linear trend smoothed by KFAS::KFS (exact diffuse start):
# test-scan-kalman-kfas.R compares kalman_llt() against the saved values, so
# the tests hold without KFAS installed.
#
# All cases but `regime` use q_lvl = 1, q_slp = 0.01, h = 4, the hyperparameters
# of the tests' .k_body(): sigma_lvl 1, sigma_slp 0.1, sigma_obs 2.

out <- "tests/testthat/fixtures/kfas/kalman-llt.rds"

kfas_llt <- function(y, q_lvl, q_slp, h) {
  # h: scalar or length(y) vector of observation variances.
  # SSMtrend must be resolvable UNQUALIFIED inside the formula (KFAS's
  # formula introspection breaks on namespace-qualified calls).
  SSMtrend <- KFAS::SSMtrend
  m <- KFAS::SSModel(
    y ~ SSMtrend(degree = 2, Q = list(matrix(q_lvl), matrix(q_slp))),
    H = array(h, c(1, 1, length(y)))
  )
  ks <- KFAS::KFS(m, filtering = "state", smoothing = "state")
  list(
    mean = as.numeric(ks$alphahat[, "level"]),
    sd = sqrt(pmax(ks$V[1, 1, ], 0)),
    fmean = as.numeric(ks$att[, "level"]),
    fsd = sqrt(pmax(ks$Ptt[1, 1, ], 0)),
    innov = as.numeric(ks$v) / sqrt(as.numeric(ks$F))
  )
}

# Faithful transcription of hutan's robust loop (smooth-stack.R:121-150)
# around the KFAS reference, with time-varying level noise.
kfas_llt_robust <- function(y, q_lvl, q_slp, h, iters = 2L, thr = 3, infl = 100) {
  SSMtrend <- KFAS::SSMtrend
  T_ <- length(y)
  Q_scale <- rep(1, T_)
  res <- NULL
  for (it in seq_len(iters + 1L)) {
    m <- KFAS::SSModel(
      y ~ SSMtrend(
        degree = 2,
        Q = list(array(q_lvl * Q_scale, c(1, 1, T_)), matrix(q_slp))
      ),
      H = array(h, c(1, 1, T_))
    )
    ks <- KFAS::KFS(m, smoothing = "state")
    res <- list(
      mean = as.numeric(ks$alphahat[, "level"]),
      sd = sqrt(pmax(ks$V[1, 1, ], 0)),
      q_years = which(Q_scale != 1)
    )
    if (it > iters) break
    converged <- TRUE
    inn <- diff(res$mean)
    inn_sd <- stats::mad(inn, na.rm = TRUE)
    if (is.finite(inn_sd) && inn_sd > 0) {
      z <- abs(c(0, inn)) / inn_sd
      nq <- ifelse(z > thr, infl, 1)
      if (any(nq != Q_scale)) converged <- FALSE
      Q_scale <- nq
    }
    if (converged) break
  }
  res
}

.k_series <- function(T_ = 15) {
  cumsum(cumsum(stats::rnorm(T_, 0, 0.1)) + stats::rnorm(T_, 0, 1)) +
    stats::rnorm(T_, 0, 2)
}

# Dense and gappy series, one too short to be anything but diffuse-heavy.
set.seed(2)
base <- list(
  dense = .k_series(),
  leading = { y <- .k_series(); y[1:4] <- NaN; y },
  trailing = { y <- .k_series(); y[12:15] <- NaN; y },
  midgap = { y <- .k_series(); y[6:9] <- NaN; y },
  three = { y <- .k_series(); y[-c(2, 9, 14)] <- NaN; y },
  short5 = .k_series(5)
)
base <- lapply(base, function(y) c(list(y = y), kfas_llt(y, 1, 0.01, 4)[c("mean", "sd")]))

# Filtered output. Until two years are observed KFAS and garry differ by
# design, and just after that the gap depends on the series: these hold garry
# within 1e-5 of KFAS, so changing them changes the tests' tolerance too.
set.seed(12)
filtered <- list(
  dense = .k_series(),
  leading = { y <- .k_series(); y[1:4] <- NaN; y },
  midgap = { y <- .k_series(); y[6:9] <- NaN; y },
  short5 = .k_series(5)
)
filtered <- lapply(filtered, function(y) {
  c(list(y = y), kfas_llt(y, 1, 0.01, 4)[c("fmean", "fsd")])
})

# Standardised innovations, with one missing year.
set.seed(14)
y <- .k_series()
y[7] <- NaN
innov <- list(y = y, innov = kfas_llt(y, 1, 0.01, 4)$innov)

# Per-year relative observation variance; missing years leave r irrelevant.
set.seed(3)
y <- .k_series()
y[c(4, 11)] <- NaN
r <- stats::runif(15, 0.5, 3)
r[c(4, 11)] <- NaN
ref <- kfas_llt(y, 1, 0.01, h = 4 * ifelse(is.na(r), 1, r))
relvar <- list(y = y, r = r, mean = ref$mean, sd = ref$sd)

# Series with injected level breaks, the robust loop's target. `twobreak`'s
# steps run the same way: opposite steps spread the smoothed differences until
# neither clears the threshold. `smooth` has no break, so the loop converges on
# its first pass.
set.seed(8)
robust <- list(
  onebreak = { y <- .k_series(); y[8:15] <- y[8:15] + 25; y },
  twobreak = {
    y <- .k_series()
    y[5:15] <- y[5:15] + 40
    y[11:15] <- y[11:15] + 40
    y
  },
  breakgap = {
    y <- .k_series()
    y[9:15] <- y[9:15] + 25
    y[c(3, 10, 11)] <- NaN
    y
  },
  smooth = .k_series()
)
robust <- lapply(robust, function(y) c(list(y = y), kfas_llt_robust(y, 1, 0.01, 4)))

# A step at `b`: each side smoothed alone is what a regime boundary must give.
# sigma_lvl 0.1, sigma_slp 0.05, sigma_obs 0.5.
set.seed(15)
T_ <- 16L
b <- 10L
y <- c(rep(3, b - 1L), rep(9, T_ - b + 1L)) + stats::rnorm(T_, 0, 0.5)
regime <- list(
  y = y,
  b = b,
  pre = kfas_llt(y[1:(b - 1L)], q_lvl = 0.01, q_slp = 0.0025, h = 0.25)[c("mean", "sd")],
  post = kfas_llt(y[b:T_], q_lvl = 0.01, q_slp = 0.0025, h = 0.25)["mean"]
)

dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
saveRDS(
  list(
    meta = list(
      generator = "tools/kfas_make_fixture.R",
      oracle = paste("KFAS", utils::packageVersion("KFAS")),
      r = R.version.string,
      date = format(Sys.Date())
    ),
    cases = list(
      base = base,
      filtered = filtered,
      innov = innov,
      relvar = relvar,
      robust = robust,
      regime = regime
    )
  ),
  out,
  version = 2,
  compress = "xz"
)
