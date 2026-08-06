# P1: safetensors reader + OCM weight folding. Gates: reader round-trip
# on a hand-built file (torch index order preserved); BN folding equals
# conv-then-batchnorm via torch; real OCM state dicts parse into the
# expected structure (gated on the weights being present locally).

skip_if_not_installed("jsonlite")

# Hand-build a safetensors file: header + row-major f32 payloads.
.st_write <- function(path, tensors) {
  entries <- list(); payload <- raw(0)
  for (nm in names(tensors)) {
    x <- tensors[[nm]]
    d <- dim(x) %||% length(x)
    v <- as.numeric(aperm(array(x, d), rev(seq_along(d))))  # row-major
    bytes <- writeBin(v, raw(), size = 4L, endian = "little")
    entries[[nm]] <- list(
      dtype = "F32", shape = I(as.integer(d)),
      data_offsets = I(c(length(payload), length(payload) + length(bytes))))
    payload <- c(payload, bytes)
  }
  hdr <- charToRaw(jsonlite::toJSON(entries, auto_unbox = TRUE))
  con <- file(path, "wb")
  writeBin(c(length(hdr), 0L), con, size = 4L, endian = "little")
  writeBin(hdr, con); writeBin(payload, con)
  close(con)
  path
}

test_that("safetensors_read round-trips torch index order", {
  set.seed(1)
  tensors <- list(
    "a.weight" = array(runif(2 * 3 * 4 * 5), c(2, 3, 4, 5)),
    "a.bias"   = runif(7),
    "b.mat"    = matrix(runif(12), 3, 4))
  f <- .st_write(tempfile(fileext = ".safetensors"), tensors)
  got <- safetensors_read(f)
  expect_setequal(names(got), names(tensors))
  for (nm in names(tensors))
    expect_equal(got[[nm]], tensors[[nm]], tolerance = 1e-6,
                 ignore_attr = TRUE, label = nm)
  ls <- safetensors_ls(f)
  expect_identical(ls$shape[ls$name == "a.weight"], "2,3,4,5")
  sub <- safetensors_read(f, names = "a.bias")
  expect_identical(names(sub), "a.bias")
  expect_error(safetensors_read(f, names = "nope"), "not in file")
})

test_that("BN folding equals conv-then-batchnorm (torch referee)", {
  skip_if_not_installed("torch")
  skip_if_not_installed("anvl")
  set.seed(2)
  co <- 5L; ci <- 3L
  w  <- array(runif(co * ci * 9, -1, 1), c(co, ci, 3, 3))
  g  <- runif(co, 0.5, 2); b <- runif(co, -1, 1)
  mu <- runif(co, -1, 1); v <- runif(co, 0.5, 2)
  std <- list("c.weight" = w, "bn.weight" = g, "bn.bias" = b,
              "bn.running_mean" = mu, "bn.running_var" = v)
  fold <- garry:::.ocm_fold_conv_bn(std, "c.weight", "bn")

  x <- array(runif(ci * 11 * 13, -1, 1), c(ci, 11, 13))
  got <- g_conv2d(x, fold$w, fold$b, padding = 1L)

  ref <- torch::nnf_batch_norm(
    torch::nnf_conv2d(torch::torch_tensor(array(x, c(1L, dim(x)))),
                      torch::torch_tensor(w), padding = 1L),
    running_mean = torch::torch_tensor(mu),
    running_var = torch::torch_tensor(v),
    weight = torch::torch_tensor(g), bias = torch::torch_tensor(b),
    training = FALSE, eps = 1e-5)
  expect_equal(got, as.array(ref)[1, , , , drop = TRUE],
               tolerance = 1e-5, ignore_attr = TRUE)
})

test_that("real OCM regnety state dict parses into the expected structure", {
  dir <- Sys.getenv("GARRY_OCM_WEIGHTS",
                    path.expand("~/.local/share/omnicloudmask/1.7.1"))
  skip_if(!dir.exists(dir), "OCM weights not present")

  wl <- ocm_load_weights(dir, models = "regnety")
  W <- wl$weights$regnety
  expect_identical(W$arch, "regnety_004")
  expect_identical(vapply(W$stages, length, 0L), c(1L, 3L, 6L, 6L))
  expect_identical(dim(W$stem$w), c(32L, 3L, 3L, 3L))
  expect_identical(dim(W$stages[[4]][[1]]$conv2$w)[1:2], c(440L, 8L))
  expect_identical(W$stages[[1]][[1]]$groups, 6L)
  expect_identical(dim(W$decoder[[1]]$conv1$w), c(256L, 648L, 3L, 3L))
  expect_identical(dim(W$head$w), c(4L, 16L, 3L, 3L))
  expect_true(all(vapply(W$stages, function(st)
    all(vapply(st, function(b) is.numeric(b$conv1$b), TRUE)), TRUE)))

  # cache hit returns the same kernel_id
  wl2 <- ocm_load_weights(dir, models = "regnety")
  expect_identical(wl2$kernel_id, wl$kernel_id)
})

test_that("ocm_fetch_weights verifies and is idempotent", {
  skip_if(!nzchar(Sys.getenv("GARRY_RUN_NETWORK")),
          "set GARRY_RUN_NETWORK=1 to run (downloads ~58 MB)")
  dir <- withr::local_tempdir()
  got <- ocm_fetch_weights(dir, quiet = TRUE)
  fs <- list.files(got, pattern = "safetensors$", full.names = TRUE)
  expect_length(fs, 2L)
  for (f in fs)
    expect_true(rlang::hash_file(f) %in% garry:::.ocm_release_hash)
  # second call: verified, no re-download
  expect_message(ocm_fetch_weights(dir), "already present")
  # a corrupted file is re-fetched, a bad mirror refused
  writeBin(as.raw(1:100), fs[[1L]])
  got2 <- ocm_fetch_weights(dir, quiet = TRUE)
  expect_identical(rlang::hash_file(fs[[1L]]),
                   unname(garry:::.ocm_release_hash[
                     match(basename(fs[[1L]]),
                           garry:::.ocm_release_files)]))
  # and the fetched dir loads end to end
  wl <- ocm_load_weights(got, models = "regnety")
  expect_identical(wl$weights$regnety$arch, "regnety_004")
})
