# P4: the OCM user API. Gates (weights-gated like the golden tests):
# ocm_predict builds the patch graph and executes chunked == whole, in
# process and on daemons; ocm_mask derives per slice, masks value bands,
# consumes the class band, and preserves slice names.

skip_if_not_installed("jsonlite")

.ocm_wdir2 <- Sys.getenv("GARRY_OCM_WEIGHTS",
                         path.expand("~/.local/share/omnicloudmask/1.7.1"))

.ocm_memo <- new.env(parent = emptyenv())
.ocm_toy_model <- function() {
  if (is.null(.ocm_memo$model)) {
    .ocm_memo$model <- ocm_model(.ocm_wdir2, models = "regnety", halo = 32L)
  }
  .ocm_memo$model
}

test_that("ocm_predict builds a patch graph; it holds chunked and on daemons", {
  skip_if(!dir.exists(.ocm_wdir2), "OCM weights not present")
  m <- .ocm_toy_model()
  f <- fixture_gradient_f32()
  g <- graph_new()
  r <- lazy_source(f, graph = g)
  cls <- ocm_predict(r * 1000, r * 900, r * 2500, model = m)
  expect_identical(names(cls@grid@dims), c("x", "y"))
  whole <- .with_chunk_px(1e7, execute_plan(plan_lazy(cls)))
  expect_identical(dim(whole), c(40L, 60L))
  expect_true(any(is.finite(whole)))
  expect_true(all(whole[is.finite(whole)] %in% 0:3))

  # window-dependent normalisation: agreement, not identity
  p <- .with_chunk_px(400, plan_lazy(cls))
  small <- execute_plan(p)
  expect_gte(mean(small == whole, na.rm = TRUE), 0.98)

  # the same chunks agree exactly wherever they run
  local_pools(2, 1)
  d <- execute_plan_mirai(p)
  expect_identical(is.na(d), is.na(small))
  expect_gte(mean(d == small, na.rm = TRUE), 1)
})

test_that("ocm_mask masks value bands per slice and keeps names", {
  skip_if(!dir.exists(.ocm_wdir2), "OCM weights not present")
  m <- .ocm_toy_model()
  # The golden input and its mirror image: the gradient scene is all clear,
  # and a mask needs cells of both kinds to show it works.
  x <- safetensors_read(test_path("fixtures", "ocm", "golden-128.safetensors"))$input
  x[x == 0] <- NaN
  y <- x[, 128:1, ]
  g <- graph_new()
  sx <- .slice_sources(x, g)
  sy <- .slice_sources(y, g)
  slices <- c("2024-01-01", "2024-02-01")
  ds <- as_dataset(lapply(
    list(B04 = 1L, B03 = 2L, B8A = 3L),
    function(b) stats::setNames(list(sx[[b]], sy[[b]]), slices)
  ))

  masked <- ocm_mask(ds, red = "B04", green = "B03", nir = "B8A", model = m)
  expect_setequal(names(masked@bands), c("B04", "B03", "B8A"))  # ocm consumed
  expect_identical(names(masked@bands$B04), slices)

  # each slice is masked by its own classes, and only there
  out <- collect(masked[["B04"]], distributed = FALSE)
  raw <- list(x[1L, , ], y[1L, , ])
  for (i in 1:2) {
    s <- list(sx, sy)[[i]]
    cls <- collect(ocm_predict(s[[1L]], s[[2L]], s[[3L]], model = m), distributed = FALSE)
    hit <- matrix(cls %in% 1:3, nrow(cls), ncol(cls))
    expect_true(any(hit) && !all(hit), info = i)
    want <- raw[[i]]
    want[hit] <- NaN
    .expect_cells(unclass(out[, , i]), want, tolerance = 1e-6, info = i)
  }
})

test_that("ocm_model validates and prints", {
  skip_if(!dir.exists(.ocm_wdir2), "OCM weights not present")
  expect_error(ocm_model(.ocm_wdir2, halo = 8L), ">= 32")
  m <- .ocm_toy_model()
  expect_output(print(m), "ocm_model")
  expect_match(m$kernel_id, "^ocm-")
})

test_that("an ocm_model prints its summary from a user's session", {
  # A user's print() finds the method through base's S3 table; this test's
  # environment inherits garry's namespace, so it calls from one that does not.
  m <- structure(
    list(
      models = c("regnety", "edgenext"),
      halo = 128L,
      kernel_id = "ocm-abc-regnety+edgenext"
    ),
    class = "garry_ocm_model"
  )
  user <- new.env(parent = globalenv())
  user$m <- m
  expect_identical(
    utils::capture.output(evalq(print(m), user)),
    "<ocm_model> regnety+edgenext  halo=128  kernel=ocm-abc-regnety+edgenext"
  )
})

test_that("the default OCM weights dir is the newest Python cache with v4 files", {
  home <- withr::local_tempdir()
  base <- file.path(home, ".local", "share", "omnicloudmask")
  for (v in c("9.2", "10.0", "11.0")) dir.create(file.path(base, v), recursive = TRUE)
  for (v in c("9.2", "10.0")) {
    file.create(file.path(base, v, garry:::.ocm_release_files))
  }
  withr::local_envvar(HOME = home, GARRY_OCM_WEIGHTS = "", R_USER_DATA_DIR = home)
  expect_identical(basename(garry:::.ocm_default_dir()), "10.0")
})
