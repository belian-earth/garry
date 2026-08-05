# P2 gate: garry's native OCM forward pass against the Python
# OmniCloudMask golden fixture (tools/ocm_make_fixture.py, generated
# offline). The fixture carries the synthetic input plus per-model and
# ensemble raw logits and default argmax maps from predict_from_array
# on a single 128-px patch, so garry's whole-window channel_norm sees
# identical geometry. Weights are not distributed: tests needing them
# skip unless the OCM cache (or GARRY_OCM_WEIGHTS) is present.

skip_if_not_installed("anvl")
skip_if_not_installed("jsonlite")

.ocm_fixture <- test_path("fixtures", "ocm", "golden-128.safetensors")
.ocm_wdir <- Sys.getenv("GARRY_OCM_WEIGHTS",
                        path.expand("~/.local/share/omnicloudmask/1.7.1"))

test_that("regnety logits match Python OCM on the golden input", {
  skip_if(!file.exists(.ocm_fixture), "golden fixture not present")
  skip_if(!dir.exists(.ocm_wdir), "OCM weights not present")

  fx <- safetensors_read(.ocm_fixture)
  wl <- ocm_load_weights(.ocm_wdir, models = "regnety")
  x <- fx$input
  x[x == 0] <- NaN                       # D8: nodata is NaN

  cn <- garry:::.ocm_channel_norm(x)
  lg <- garry:::.ocm_forward_regnety(cn$x, wl$weights$regnety)
  expect_identical(dim(lg), dim(fx$logits_regnety))
  expect_lt(max(abs(lg - fx$logits_regnety)), 1e-4)
})

test_that("full inference matches Python argmax; nodata comes back NaN", {
  skip_if(!file.exists(.ocm_fixture), "golden fixture not present")
  skip_if(!dir.exists(.ocm_wdir), "OCM weights not present")

  fx <- safetensors_read(.ocm_fixture)
  wl <- ocm_load_weights(.ocm_wdir, models = "regnety")
  x <- fx$input
  nodata <- apply(x == 0, c(2, 3), any)
  x[x == 0] <- NaN

  cls <- garry:::.ocm_infer(x, wl$weights)
  am <- fx$argmax_regnety
  if (length(dim(am)) == 3L) am <- am[1L, , ]

  # Python masks nodata to class 0; garry masks it to NaN
  expect_identical(!is.finite(cls), nodata)
  ok <- is.finite(cls)
  expect_gte(mean(cls[ok] == am[ok]), 0.999)
  expect_true(all(cls[ok] %in% 0:3))
})

test_that("traced inference equals the oracle", {
  skip_if(!file.exists(.ocm_fixture), "golden fixture not present")
  skip_if(!dir.exists(.ocm_wdir), "OCM weights not present")

  fx <- safetensors_read(.ocm_fixture)
  wl <- ocm_load_weights(.ocm_wdir, models = "regnety")
  x <- fx$input
  x[x == 0] <- NaN

  ref <- garry:::.ocm_infer(x, wl$weights)
  jf <- g_jit(function(inputs) garry:::.ocm_infer(inputs[[1L]], wl$weights))
  got <- g_download(jf(list(g_upload(x, "f32"))))
  expect_identical(is.na(got), is.na(ref))
  ok <- !is.na(ref)
  expect_gte(mean(got[ok] == ref[ok]), 0.9999)
})

test_that("edgenext logits match Python OCM on the golden input", {
  skip_if(!file.exists(.ocm_fixture), "golden fixture not present")
  skip_if(!dir.exists(.ocm_wdir), "OCM weights not present")

  fx <- safetensors_read(.ocm_fixture)
  wl <- ocm_load_weights(.ocm_wdir, models = "edgenext")
  x <- fx$input
  x[x == 0] <- NaN
  cn <- garry:::.ocm_channel_norm(x)
  lg <- garry:::.ocm_forward_edgenext(cn$x, wl$weights$edgenext)
  expect_lt(max(abs(lg - fx$logits_edgenext)), 1e-4)
})

test_that("the two-model ensemble matches Python OCM exactly", {
  skip_if(!file.exists(.ocm_fixture), "golden fixture not present")
  skip_if(!dir.exists(.ocm_wdir), "OCM weights not present")

  fx <- safetensors_read(.ocm_fixture)
  wl <- ocm_load_weights(.ocm_wdir)
  x <- fx$input
  x[x == 0] <- NaN
  cn <- garry:::.ocm_channel_norm(x)
  le <- (garry:::.ocm_forward_regnety(cn$x, wl$weights$regnety) +
         garry:::.ocm_forward_edgenext(cn$x, wl$weights$edgenext)) / 2
  expect_lt(max(abs(le - fx$logits_ensemble)), 1e-4)

  cls <- garry:::.ocm_infer(x, wl$weights)
  am <- fx$argmax_ensemble
  if (length(dim(am)) == 3L) am <- am[1L, , ]
  ok <- is.finite(cls)
  expect_gte(mean(cls[ok] == am[ok]), 0.999)
})

test_that("non-/32 window sizes pad and trim transparently", {
  skip_if(!file.exists(.ocm_fixture), "golden fixture not present")
  skip_if(!dir.exists(.ocm_wdir), "OCM weights not present")

  fx <- safetensors_read(.ocm_fixture)
  wl <- ocm_load_weights(.ocm_wdir, models = "regnety")
  x <- fx$input[, 1:97, 1:110]
  x[x == 0] <- NaN
  cls <- garry:::.ocm_infer(x, wl$weights)
  expect_identical(dim(cls), c(97L, 110L))
  expect_true(all(cls[is.finite(cls)] %in% 0:3))
})
