# Terminal rendering: print() cards and draw() (the pre-execution pipeline
# visual). Output is ANSI-stripped before matching so the gates do not depend on
# terminal colour; glyph/dash regexes tolerate the UTF-8 vs ASCII fallback.

.strip <- function(expr) cli::ansi_strip(paste(capture.output(expr), collapse = "\n"))

mk_ds <- function() {
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  as_dataset(
    list(B04 = list(s(), s(), s()), B03 = list(s(), s(), s()),
         Fmask = list(s(), s(), s())),
    mask_asset = "Fmask")
}

test_that("print(LazyDataset) shows a compact card", {
  out <- .strip(print(mk_ds()))
  expect_match(out, "LazyDataset")
  expect_match(out, "B04 B03")
  expect_match(out, "Fmask")
  expect_match(out, "3 slices")
  expect_match(out, "draw\\(x\\)")
})

test_that("draw(LazyDataset) draws the step pipeline with mask detail", {
  comp <- mk_ds() |>
    mask(from = "Fmask", where = qa_bits(0:3), open = 2, dilate = 3) |>
    reduce_over("median", over = "t")
  out <- .strip(draw(comp))
  expect_match(out, "source")
  expect_match(out, "mask")
  expect_match(out, "bits 0.3")             # en dash or hyphen
  expect_match(out, "open 2")
  expect_match(out, "dilate 3")
  expect_match(out, "median over t")
  expect_match(out, "3 slices")             # original count survives the reduce
})

test_that("draw(LazyRaster) collapses identical sibling branches to xN", {
  comp <- mk_ds() |>
    mask(from = "Fmask", where = qa_bits(0:3)) |>
    reduce_over("median", over = "t")
  out <- .strip(draw(comp[["B04"]]))
  expect_match(out, "median")
  expect_match(out, "stack")
  expect_match(out, "[x×]3")           # the three slices folded to one branch
  expect_match(out, "source")
})

test_that("a value-set mask renders a compact range", {
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  ds <- as_dataset(list(V = list(s()), Q = list(s())), mask_asset = "Q") |>
    mask(where = c(0, 1, 2, 3, 8, 9, 10, 11))
  out <- .strip(draw(ds))
  expect_match(out, "values 0.3, 8.11")
})

test_that("draw() returns its input invisibly", {
  ds <- mk_ds()
  expect_false(withVisible(draw(ds))$visible)
  expect_true(S7::S7_inherits(draw(ds), LazyDataset))
})

test_that("print(LazyRaster) headlines the op and hints draw()", {
  lr <- reduce_over(lazy_stack(list(lazy_source(fixture_gradient_f32()),
                                    lazy_source(fixture_gradient_f32()))),
                    "median", "t")
  out <- .strip(print(lr))
  expect_match(out, "LazyRaster")
  expect_match(out, "median")
  expect_match(out, "draw\\(x\\)")
})
