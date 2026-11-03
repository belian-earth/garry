# P2 gate: garry's native OCM forward pass against the Python
# OmniCloudMask golden fixture (tools/ocm_make_fixture.py, generated
# offline). The fixture carries the synthetic input plus per-model and
# ensemble raw logits and default argmax maps from predict_from_array
# on a single 128-px patch, so garry's whole-window channel_norm sees
# identical geometry. Weights are not distributed: tests needing them
# skip unless the OCM cache (or GARRY_OCM_WEIGHTS) is present.

skip_if_not_installed("jsonlite")

.ocm_fixture <- test_path("fixtures", "ocm", "golden-128.safetensors")
.ocm_wdir <- Sys.getenv("GARRY_OCM_WEIGHTS",
                        path.expand("~/.local/share/omnicloudmask/1.7.1"))

# The forward passes are pure and each takes seconds, so the file runs each
# once. A failure here fails every test that reads it.
.ocm_memo <- new.env(parent = emptyenv())
.ocm_once <- function(key, make) {
  if (is.null(.ocm_memo[[key]])) .ocm_memo[[key]] <- make()
  .ocm_memo[[key]]
}
.ocm_fx <- function() .ocm_once("fx", function() safetensors_read(.ocm_fixture))
# The golden input with its nodata as NaN (D8).
.ocm_x <- function() {
  .ocm_once("x", function() {
    x <- .ocm_fx()$input
    x[x == 0] <- NaN
    x
  })
}
.ocm_weights <- function(model) {
  .ocm_once(paste0("weights_", model), function() ocm_load_weights(.ocm_wdir, models = model)$weights)
}
.ocm_logits <- function(model) {
  .ocm_once(paste0("logits_", model), function() {
    forward <- switch(model, regnety = garry:::.ocm_forward_regnety, edgenext = garry:::.ocm_forward_edgenext)
    forward(garry:::.ocm_channel_norm(.ocm_x())$x, .ocm_weights(model)[[model]])
  })
}
.ocm_classes <- function() {
  .ocm_once("classes", function() garry:::.ocm_infer(.ocm_x(), .ocm_weights("regnety")))
}

test_that("the golden fixture holds the input and every model's outputs", {
  # Needs no weights, so a missing fixture fails where the tests below skip.
  ls <- safetensors_ls(.ocm_fixture)
  expect_setequal(ls$name, c(
    "input",
    paste0("logits_", c("regnety", "edgenext", "ensemble")),
    paste0("argmax_", c("regnety", "edgenext", "ensemble"))
  ))
  expect_identical(ls$shape[ls$name == "input"], "3,128,128")
})

test_that("regnety logits match Python OCM on the golden input", {
  skip_if(!dir.exists(.ocm_wdir), "OCM weights not present")

  lg <- .ocm_logits("regnety")
  expect_identical(dim(lg), dim(.ocm_fx()$logits_regnety))
  expect_lt(max(abs(lg - .ocm_fx()$logits_regnety)), 1e-4)
})

test_that("full inference matches Python argmax; nodata comes back NaN", {
  skip_if(!dir.exists(.ocm_wdir), "OCM weights not present")

  fx <- .ocm_fx()
  nodata <- apply(fx$input == 0, c(2, 3), any)

  cls <- .ocm_classes()
  am <- fx$argmax_regnety
  if (length(dim(am)) == 3L) am <- am[1L, , ]

  # Python masks nodata to class 0; garry masks it to NaN
  expect_identical(!is.finite(cls), nodata)
  ok <- is.finite(cls)
  expect_gte(mean(cls[ok] == am[ok]), 0.999)
  expect_true(all(cls[ok] %in% 0:3))
})

test_that("traced inference equals the oracle", {
  skip_if(!dir.exists(.ocm_wdir), "OCM weights not present")

  weights <- .ocm_weights("regnety")
  ref <- .ocm_classes()
  jf <- g_jit(function(inputs) garry:::.ocm_infer(inputs[[1L]], weights))
  got <- g_download(jf(list(g_upload(.ocm_x(), "f32"))))
  expect_identical(is.na(got), is.na(ref))
  ok <- !is.na(ref)
  expect_gte(mean(got[ok] == ref[ok]), 0.9999)
})

test_that("edgenext logits match Python OCM on the golden input", {
  skip_if(!dir.exists(.ocm_wdir), "OCM weights not present")

  expect_lt(max(abs(.ocm_logits("edgenext") - .ocm_fx()$logits_edgenext)), 1e-4)
})

test_that("the two-model ensemble matches Python OCM exactly", {
  skip_if(!dir.exists(.ocm_wdir), "OCM weights not present")

  fx <- .ocm_fx()
  le <- (.ocm_logits("regnety") + .ocm_logits("edgenext")) / 2
  expect_lt(max(abs(le - fx$logits_ensemble)), 1e-4)

  cls <- garry:::.ocm_infer(.ocm_x(), c(.ocm_weights("regnety"), .ocm_weights("edgenext")))
  am <- fx$argmax_ensemble
  if (length(dim(am)) == 3L) am <- am[1L, , ]
  ok <- is.finite(cls)
  expect_gte(mean(cls[ok] == am[ok]), 0.999)
})

test_that("CUDA inference equals the CPU classes", {
  skip_if(!dir.exists(.ocm_wdir), "OCM weights not present")
  skip_on_os(c("windows", "mac"))
  skip_if(!nzchar(Sys.which("nvidia-smi")), "no NVIDIA GPU")
  skip_if(!nzchar(Sys.getenv("GARRY_OCM_CUDA")),
          "set GARRY_OCM_CUDA=1 to run (~1 min XLA CUDA compile)")

  weights <- .ocm_weights("regnety")
  cpu <- .ocm_classes()
  jf <- g_jit(function(inputs) garry:::.ocm_infer(inputs[[1L]], weights),
              device = "cuda")
  gpu <- g_download(jf(list(g_upload(.ocm_x(), "f32", device = "cuda"))))
  expect_identical(is.na(gpu), is.na(cpu))
  ok <- !is.na(cpu)
  # conv reassociation differs across backends; borderline logits can
  # flip a class on isolated pixels
  expect_gte(mean(gpu[ok] == cpu[ok]), 0.999)
})

test_that("non-/32 window sizes pad and trim transparently", {
  skip_if(!dir.exists(.ocm_wdir), "OCM weights not present")

  cls <- garry:::.ocm_infer(.ocm_x()[, 1:33, 1:38], .ocm_weights("regnety"))
  expect_identical(dim(cls), c(33L, 38L))
  expect_true(any(is.finite(cls)))
  expect_true(all(cls[is.finite(cls)] %in% 0:3))
})
