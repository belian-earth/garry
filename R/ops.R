# ---------------------------------------------------------------------------
# The garry op vocabulary (decision D9).
#
# Every named operation a stage function may use lives here, and this is
# the ONLY file allowed to touch anvl's `nv_*` API (grep-enforced by
# test-backend-insulation.R). Each op dispatches on its input: traced
# values go to nv_*, and plain R arrays take a pure-R reference path.
#
# The pure-R path is NOT a user execution path (one-compute-path rule):
# it is the permanent test oracle, and it lets planner golden tests run
# without anvl installed. Every op checks
# .g_traced() and routes AnvlArray / tracer values to nv_*; plain R
# arrays take the oracle path.
#
# Semantics contract (matches anvl/XLA, verified in the spike):
# - nodata is NaN (decision D8); `nan_rm = TRUE` reductions skip it;
# - reducing an all-NaN slice with nan_rm: sum -> 0, min/max -> +/-Inf,
#   mean/median -> NaN, count -> 0;
# - bitwise ops operate on integral values (stored as R doubles/ints);
# - g_cast to integer truncates toward zero (XLA convert semantics).
# ---------------------------------------------------------------------------

# Is this value an anvl array or tracer value (vs a plain R array)?
.g_traced <- function(x) {
  inherits(x, c("AnvlArray", "GraphBox", "AnvlBox"))
}

# Promote a plain R scalar to the traced operand's dtype. The cast would
# truncate 0.5 to 0 in silence and refuse NaN in anvl's words.
.g_scalar_like <- function(x, value) {
  if (.g_is_integer(x) && (!is.finite(value) || value != trunc(value))) {
    cli::cli_abort(
      c(
        "an integer array cannot hold the scalar {.val {value}}.",
        "i" = "{.fn g_cast} the array to a float dtype first."
      ),
      class = c("garry_kernel_error", "garry_error")
    )
  }
  anvl::nv_scalar_like(x, value)
}

# -- Executor bridge (the only anvl entry points outside the ops) ------------

#' JIT-compile a stage closure via anvl (executor bridge).
#'
#' @param f Stage closure.
#' @param device Optional device override (e.g. "cuda"); NULL uses the
#'   anvl default device.
#' @return A compiled function (anvl `JitFunction`).
#' @keywords internal
g_jit <- function(f, device = NULL) {
  anvl::jit(f, device = device)
}

#' Reverse-mode value-and-gradient of a scalar-loss closure (bridge).
#'
#' User code should call [lazy_value_and_grad()] instead.
#'
#' @param f Function returning a scalar float; first argument is the
#'   differentiation target.
#' @param wrt Name of the argument to differentiate with respect to.
#' @return A function returning `list(value, grad$<wrt>)` (jit-compiled).
#' @keywords internal
g_value_and_gradient <- function(f, wrt) {
  anvl::jit(.g_value_and_gradient_fn(f, wrt))
}

# The same before its jit, for .host_kernel(), which jits what it keeps.
.g_value_and_gradient_fn <- function(f, wrt) {
  anvl::value_and_gradient(f, wrt = wrt)
}

# The dtype a kernel holds `dtype` in: unsigned values upload through a
# carrier, so arithmetic on them leaves the unsigned range (Byte 200 * 2L
# is 400, 7 - 8L is -1) and returns this dtype, not the unsigned one.
.carrier_dtype <- function(dtype) {
  carrier <- unname(.anvl_upload_dtype[dtype])
  if (is.na(carrier)) dtype else carrier
}

# The dtype a stored value reaches a kernel as.
.input_dtype <- function(dtype) {
  as.character(.to_anvl_dtype(.carrier_dtype(dtype)))
}

# One key for a kernel's inputs. `dtypes` are as they reach the kernel.
.input_key <- function(dtypes, shapes) {
  paste(
    unlist(Map(
      function(d, s) paste0(d, ":", paste(s, collapse = "x")),
      dtypes,
      shapes
    )),
    collapse = ","
  )
}

# Content identity of an array a kernel captures: its handle is a pointer.
.g_is_array <- function(x) inherits(x, "AnvlArray")
.g_array_identity <- function(x) {
  dtype <- as.character(anvl::dtype(x))
  shape <- as.integer(anvl::shape(x))
  # a constant made while tracing is plain R data, with no raw form yet
  if (identical(x$backend, "plain")) {
    x <- pjrt::pjrt_buffer(anvl::as_array(x), dtype = dtype, shape = shape)
  }
  list(v = anvl::as_raw(x, row_major = TRUE), dtype = dtype, shape = shape)
}

# Abstract kernel inputs: a dtype and a shape, no data.
.input_avals <- function(dtypes, shapes) {
  unname(Map(
    function(d, s) anvl::nv_aval(.input_dtype(d), shape = as.integer(s)),
    dtypes,
    shapes
  ))
}

# The dtype `fn` (list of inputs -> one array) returns at these dtypes
# and shapes, in anvl's vocabulary. An abstract trace: nothing runs and
# nothing compiles.
.kernel_out_dtype <- function(fn, dtypes, shapes) {
  graph <- anvl::trace_fn(
    function(inputs) list(fn(inputs)),
    list(inputs = .input_avals(dtypes, shapes))
  )
  as.character(graph$outputs[[1L]]$aval$dtype)
}

# A kernel output at the dtype its node declares: the convert a stage
# export needs when the two differ, nothing when they agree.
.g_as_declared <- function(x, dtype) {
  if (!.g_traced(x) || identical(as.character(anvl::dtype(x)), .input_dtype(dtype))) {
    return(x)
  }
  anvl::nv_convert(x, .input_dtype(dtype))
}

# Trace `fn` (list of inputs -> named list of exports) at these dtypes
# and shapes and lower it. Closed-over arrays come back as constants,
# leading inputs of the program, carried as R data.
.program_build <- function(fn, dtypes, shapes) {
  graph <- anvl::trace_fn(
    function(inputs) unname(fn(inputs)),
    list(inputs = .input_avals(dtypes, shapes)),
    optimize = TRUE
  )
  low <- anvl::stablehlo(
    graph,
    donate_unaliased_outputs = TRUE,
    platform = "cpu"
  )
  list(
    src = stablehlo::repr(low[[1L]]),
    constants = lapply(low[[2L]], function(k) .g_array_identity(k$aval$data)),
    # Fresh output buffers per call, as jit() has: they are how R counts
    # a CPU output's memory, so gc keeps pace with it.
    phantoms = lapply(low[[3L]], function(spec) {
      list(dtype = as.character(spec$dtype), shape = as.integer(spec$shape))
    }),
    # The outputs' nesting as plain R: an RTree is a native handle and
    # does not cross a process. A reduce_partial export nests its parts.
    out_shape = pjrt::unflatten(graph$out_tree, as.list(seq_along(graph$outputs))),
    out_avals = lapply(graph$outputs, function(x) {
      list(dtype = as.character(x$aval$dtype), shape = anvl::shape(x$aval))
    })
  )
}

# anvl's own dispatch path: the same executable cache, buffer wrapping and
# output accounting a jitted function has, with the compile callback
# reading the program instead of tracing a closure. A set's shapes share
# one device buffer per constant, and a compiled shape's text and an
# uploaded constant's bytes go, so a daemon keeps each once.
.program_kernel <- function(set, device = NULL) {
  pool <- attr(set, "constants")
  attr(set, "constants") <- NULL
  buffers <- vector("list", length(pool))
  compiled <- vector("list", length(set))
  keys <- names(set)
  compile <- function(i) {
    p <- set[[i]]
    exec <- pjrt::pjrt_compile(
      pjrt::pjrt_program(src = p$src, format = "mlir"),
      device = device
    )
    dev <- pjrt::device(exec)
    for (k in p$constants) {
      if (is.null(buffers[[k]])) {
        buffers[[k]] <<- pjrt::pjrt_buffer(
          pool[[k]]$v,
          dtype = pool[[k]]$dtype,
          device = dev,
          shape = pool[[k]]$shape,
          row_major = TRUE
        )
        pool[k] <<- list(NULL)
      }
    }
    e <- list(
      exec = exec,
      client = pjrt::pjrt_client(pjrt::platform(dev)),
      device = dev,
      out_tree = pjrt::build_tree(p$out_shape),
      out_avals = p$out_avals,
      const_arrays = buffers[p$constants],
      phantom_specs = p$phantoms
    )
    compiled[[i]] <<- e
    set[i] <<- list(NULL)
    e
  }
  disp <- pjrt::dispatcher(
    max(1L, length(keys)),
    function(info) {
      key <- .input_key(
        vapply(info$avals, function(v) as.character(v$dtype), character(1)),
        lapply(info$avals, `[[`, "shape")
      )
      i <- match(key, keys)
      # Never run an executable on inputs it was not built for: PJRT
      # checks size alone, so an f32 program would read i32 bytes. The
      # host works out every input before it traces, so this is a defect.
      if (is.na(i)) {
        .program_miss(key, keys)
      }
      compiled[[i]] %||% compile(i)
    },
    backend = "pjrt",
    default_device = function() anvl::default_device("pjrt")
  )
  dispatch <- pjrt::dispatch
  run <- function(inputs) dispatch(disp, list(inputs))
  # A warm-up compiles the set's first shape, its modal chunk (chunk_iter()
  # lists that first). Others compile where a task first meets them.
  attr(run, "warm") <- function() {
    if (is.null(compiled[[1L]])) {
      compile(1L)
    }
    invisible(NULL)
  }
  run
}

.program_miss <- function(key, keys) {
  built <- paste(keys, collapse = "; ")
  cli::cli_abort(
    c(
      "a kernel met inputs its plan did not list. This is a garry bug: please report it.",
      "x" = "inputs {.val {key}}, built for {.val {built}}.",
      "i" = "{.code options(garry.kernel_wire = \"closure\")} runs the kernel without programs."
    ),
    class = c("garry_no_program_error", "garry_error"),
    call = NULL
  )
}

# Unsigned dtypes upload through a signed (or f64 for u64) carrier wide
# enough for the full value range. anvl >= 0.5 can build unsigned arrays
# from R, but the kernels are verified against the carriers, so they stay.
# Bitwise/comparison semantics are unchanged for the non-negative values
# QA bands hold.
.anvl_upload_dtype <- c(u8 = "i16", u16 = "i32", u32 = "i64", u64 = "f64")

#' Upload an R array to an AnvlArray of the given garry dtype.
#'
#' Unsigned dtypes upload via a wider signed carrier.
#'
#' @param x R array/matrix.
#' @param dtype garry dtype string (anvl-aligned).
#' @param device Optional device (e.g. "cuda"); NULL uses the default.
#' @return An `AnvlArray`.
#' @export
g_upload <- function(x, dtype, device = NULL) {
  carrier <- .carrier_dtype(dtype)
  # An integer buffer cannot hold NaN, garry's nodata. Padding that reaches
  # an integer buffer is 0 from the start (.sv_grow, .exec_read_padded), so
  # a NaN here is a real missing cell: a read that failed, or one no tile
  # reaches.
  if (!startsWith(carrier, "f") && anyNA(x)) {
    cli::cli_abort(
      c(
        "a {.val {dtype}} raster holds missing values, which an integer buffer cannot.",
        "i" = "Declare {.arg nodata} on the source so it reads as a float dtype, where NaN is nodata."
      ),
      class = c("garry_nodata_error", "garry_error"),
      call = NULL
    )
  }
  anvl::nv_array(x, dtype = carrier, device = device)
}

#' Download an AnvlArray (or a nested list of them) to R arrays.
#'
#' @param x `AnvlArray` or (nested) list.
#' @return R array / nested list of R arrays.
#' @export
g_download <- function(x) {
  # Order matters: an AnvlArray is itself a list internally.
  if (.g_traced(x)) {
    v <- anvl::as_array(x)
    # 64-bit integers arrive as bit64, whose doubles only hold their bits:
    # every R array garry handles is a plain number
    if (inherits(v, "integer64")) {
      d <- dim(v)
      v <- as.double(v)
      dim(v) <- d
    }
    return(v)
  }
  if (is.list(x)) {
    return(lapply(x, g_download))
  }
  x
}

# -- Raw f32 transport (phase 12c, D19/D20) -----------------------------------

#' Upload a raw byte payload to an AnvlArray.
#'
#' `bytes` holds `prod(dim)` elements of `dtype` in ROW-major element
#' order: one memcpy to the device, no double conversion, and no
#' XLA relayout (row-major matches the default layout).
#'
#' @param bytes Raw vector (native little-endian payload).
#' @param dtype garry dtype string (typically `"f32"`).
#' @param dim Integer dims, `[nr, nc]` or `[t, nr, nc]`.
#' @param device Optional device (e.g. "cuda"); NULL uses the default.
#' @return An `AnvlArray`.
#' @keywords internal
g_upload_raw <- function(bytes, dtype, dim, device = NULL) {
  attributes(bytes) <- NULL
  anvl::nv_array(bytes, shape = dim, dtype = dtype, byrow = TRUE, device = device)
}

#' Construct a constant-filled AnvlArray on the device.
#'
#' The fill is represented in the program (no host buffer of `prod(dim)`
#' elements is built or transferred), so it is the cheap way to make a
#' large device array: e.g. warm-up dummies for kernel precompiles.
#'
#' @param value Scalar fill value.
#' @param dim Integer dims, `[nr, nc]` or `[t, nr, nc]`.
#' @param dtype garry dtype string (default `"f32"`).
#' @param device Optional device (e.g. "cuda"); NULL uses the default.
#' @return An `AnvlArray`.
#' @export
g_fill <- function(value, dim, dtype = "f32", device = NULL) {
  anvl::nv_fill(value, dim, .to_anvl_dtype(dtype), device = device)
}

#' Download an AnvlArray as a raw store payload.
#'
#' Row-major byte payload tagged with `gdim`/`gdt` attributes; no
#' double materialisation. Raw f64 is bit-identical to the doubles
#' path.
#'
#' @param x `AnvlArray` (f32 or f64).
#' @return Raw vector with `gdim` and `gdt` attributes.
#' @keywords internal
g_download_raw <- function(x) {
  dt <- .g_dtype(x)
  # f32/f64 are the store's compute payloads (D19/f64-store); the
  # integer dtypes are g_quantize() sinks, which are only ever written.
  # u32 is excluded: R cannot readBin unsigned 4-byte values, and the
  # writer must be able to recover a plain integer vector from the
  # payload.
  if (!dt %in% c("f32", "f64", "u8", "i8", "i16", "u16", "i32")) {
    cli::cli_abort(
      "raw store payloads are f32/f64 or sink integers; got {.val {dt}}"
    )
  }
  structure(anvl::as_raw(x, row_major = TRUE), gdim = .g_shape(x), gdt = dt)
}

#' Round to nearest integer value (half to even), elementwise.
#'
#' Matches base R's `round(x)` semantics (IEEE round-half-to-even), so
#' device-side quantization reproduces the historical writer-side
#' `round()` exactly.
#'
#' @param x Traced array or plain numeric.
#' @return Same shape as `x`.
#' @export
g_round <- function(x) {
  if (.g_traced(x)) {
    return(anvl::nv_round(x))
  }
  round(x)
}

#' Clamp values to a closed range, elementwise.
#'
#' @param x Traced array or plain numeric.
#' @param lo,hi Range bounds (scalars).
#' @return Same shape as `x`.
#' @export
g_clamp <- function(x, lo, hi) {
  if (.g_traced(x)) {
    return(anvl::nv_clamp(x, lo, hi))
  }
  out <- pmin(pmax(x, lo), hi)
  dim(out) <- dim(x)
  out
}

# Integer output ranges for quantized sinks (mirrors GDAL's clamp at
# the double -> integer band conversion).
.g_int_range <- list(
  u8 = c(0, 255),
  i8 = c(-128, 127),
  u16 = c(0, 65535),
  i16 = c(-32768, 32767),
  i32 = c(-2147483648, 2147483647)
)

#' Quantize physical values to integer digital numbers, on device.
#'
#' The sink-side write transform `round((x - offset) / scale)` --
#' clamped to `dtype`'s range (as GDAL's conversion would), with NaN
#' mapped to `nodata` BEFORE the integer cast (casting NaN to an
#' integer is undefined). Runs in f32 on the producer, so every
#' execution route yields byte-identical digital numbers; the writer
#' daemon then only writes.
#'
#' @param x Traced f32 array (physical values; NaN = nodata).
#' @param scale,offset Write quantization: `DN = round((x - offset) / scale)`.
#' @param nodata Integer sentinel NaN maps to (must fit `dtype`).
#' @param dtype Integer output dtype (`"u8"`, `"i8"`, `"i16"`, `"u16"`,
#'   `"i32"`).
#' @return Traced array of `dtype`.
#' @keywords internal
g_quantize <- function(x, scale, offset, nodata, dtype) {
  if (inherits(x, "AnvlArray") && length(nodata) == 1L) {
    # Called eagerly (the daemons quantize kernel outputs outside the
    # cached kernels), each operation below is its own device pass over
    # the cube; jitted, they fuse into one.
    return(.g_quantize_jit(scale, offset, nodata, dtype)(x))
  }
  rng <- .g_int_range[[dtype]]
  if (is.null(rng)) {
    cli::cli_abort("unsupported quantize dtype {.val {dtype}}")
  }
  q <- g_round((x - offset) / scale)
  # Out-of-range values saturate at the dtype's limits; a sentinel on one
  # of those limits is kept for nodata alone, so a saturated valid pixel
  # never reads back as nodata.
  if (length(nodata) == 1L && nodata == rng[[1L]]) {
    rng[[1L]] <- rng[[1L]] + 1
  }
  if (length(nodata) == 1L && nodata == rng[[2L]]) {
    rng[[2L]] <- rng[[2L]] - 1
  }
  q <- g_clamp(q, rng[[1L]], rng[[2L]])
  if (length(nodata) == 1L) {
    q <- g_ifelse(g_is_nodata(x), nodata, q)
  } else {
    # No sentinel: legal for NaN-free data. NaN cannot survive the
    # integer cast, so check on device and fail. Eager-only branch (the
    # check downloads a scalar); every current seam is eager.
    n_nan <- g_download(g_sum(g_cast(g_is_nodata(x), "f32")))
    if (n_nan > 0) {
      .garry_error(
        paste0(
          "result contains nodata (NaN) but no nodata sentinel was ",
          "given for integer output dtype '",
          dtype,
          "'"
        ),
        "garry_write_error"
      )
    }
  }
  g_cast(q, dtype)
}

# One jitted g_quantize per quantization (anvl's jit cache keys each by
# input shape), a kernel of this process's cache like any other.
.g_quantize_jit <- function(scale, offset, nodata, dtype) {
  .daemon_kernel(
    rlang::hash(list("quantize", scale, offset, nodata, dtype)),
    function(x) g_quantize(x, scale, offset, nodata, dtype)
  )
}

# Shape of an AnvlArray (bridge; the executor must not touch anvl).
.g_shape <- function(x) {
  anvl::shape(x)
}

# garry names unsigned integers u8..u64 and booleans pred, anvl names them
# ui8..ui64 and bool; the two vocabularies agree otherwise.
.anvl_dtype_names <- c(u8 = "ui8", u16 = "ui16", u32 = "ui32", u64 = "ui64", pred = "bool")
.to_anvl_dtype <- function(dtype) {
  unname(.anvl_dtype_names[dtype]) %|NA|% dtype
}
`%|NA|%` <- function(a, b) if (is.na(a)) b else a

# Dtype of an AnvlArray in garry's vocabulary (bridge for the executor's
# raw download dispatch).
.g_dtype <- function(x) .from_anvl_dtype(as.character(anvl::dtype(x)))
.from_anvl_dtype <- function(dt) {
  hit <- match(dt, .anvl_dtype_names)
  if (is.na(hit)) dt else names(.anvl_dtype_names)[[hit]]
}

#' Elementwise select: `yes` where `cond`, else `no`.
#'
#' @param cond Logical array, or a stored 0/1 mask: nonzero is true.
#' @param yes,no Arrays or scalars, broadcast against `cond`.
#' @return Array shaped like `cond`.
#' @export
g_ifelse <- function(cond, yes, no) {
  if (.g_traced(cond)) {
    # a logical is stored 0/1 at a numeric dtype
    if (.g_dtype(cond) != "pred") {
      cond <- cond != .g_scalar_like(cond, 0)
    }
    if (
      is.numeric(yes) && length(yes) == 1L &&
        is.numeric(no) && length(no) == 1L
    ) {
      # both branches scalars: nothing to take a dtype from, so f32
      yes <- anvl::nv_fill(yes, .g_shape(cond), "f32")
    }
    if (is.numeric(yes) && length(yes) == 1L) {
      yes <- .g_scalar_like(no, yes)
    }
    if (is.numeric(no) && length(no) == 1L) {
      no <- .g_scalar_like(yes, no)
    }
    return(anvl::nv_ifelse(cond, yes, no))
  }
  ifelse(cond, yes, no)
}

#' Is a value nodata? NaN is the nodata sentinel.
#'
#' @param x Numeric array.
#' @return Logical array.
#' @export
g_is_nodata <- function(x) {
  if (.g_traced(x)) {
    return(anvl::nv_is_nan(x))
  }
  is.na(x) # TRUE for both NaN and NA_real_
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
  if (h == 0L) {
    return(x)
  }
  if (.g_traced(x)) {
    # Pad the LAST two (spatial) dims; leading dims (e.g. time in a (t,y,x)
    # cube) are left full so one focal op vectorises over the whole cube.
    lead <- rep(0L, length(anvl::shape(x)) - 2L)
    return(anvl::nv_pad(
      x,
      .g_scalar_like(x, value),
      low = c(lead, h, h),
      high = c(lead, h, h)
    ))
  }
  # the last two (spatial) dims of any rank, as on the traced path
  d <- dim(x)
  r <- length(d)
  nd <- d
  nd[c(r - 1L, r)] <- d[c(r - 1L, r)] + 2L * h
  out <- array(value, nd)
  idx <- c(
    lapply(d[seq_len(r - 2L)], seq_len),
    list(h + seq_len(d[[r - 1L]]), h + seq_len(d[[r]]))
  )
  do.call(`[<-`, c(list(out), idx, list(value = x)))
}

#' Shifted slice of a padded matrix (the stencil building block).
#'
#' Given `xpad = g_pad(x, h)`, returns the view of `x`'s shape offset by
#' (`dy`, `dx`) pixels, `dy`/`dx` in `[-h, h]`. Rows are y, columns are
#' x.
#'
#' @param xpad Padded matrix.
#' @param dy,dx Integer offsets in pixels.
#' @param out_nrow,out_ncol Dimensions of the unpadded matrix.
#' @param h Pad width used to build `xpad`.
#' @return An `out_nrow x out_ncol` matrix.
#' @export
g_shift_slice <- function(xpad, dy, dx, out_nrow, out_ncol, h) {
  if (.g_traced(xpad)) {
    # Slice the LAST two (spatial) dims; leading dims (time in a (t,y,x) cube)
    # are taken in full, so the stencil vectorises over the whole cube.
    sh <- anvl::shape(xpad)
    lead <- length(sh) - 2L
    return(anvl::nv_static_slice(
      xpad,
      start_indices = c(rep(1L, lead), 1L + h + dy, 1L + h + dx),
      end_indices = c(
        sh[seq_len(lead)],
        out_nrow + h + dy,
        out_ncol + h + dx
      ),
      strides = rep(1L, lead + 2L)
    ))
  }
  d <- dim(xpad)
  idx <- c(
    rep(list(quote(expr = )), length(d) - 2L),
    list((1L + h + dy):(out_nrow + h + dy), (1L + h + dx):(out_ncol + h + dx))
  )
  do.call(`[`, c(list(xpad), idx, list(drop = FALSE)))
}

# `x` with its cells past the raster back at nodata for `dtype`, as a stage
# boundary leaves them (.exec_mask_edge()). `ring` counts those cells on each
# side of a stage's padded input (.ring_cells()) and `d` is how far in from
# that input `x` sits. Inside a kernel `ring` is a run-time array, as one
# kernel serves every chunk of a stage, so a select picks the cells.
.g_mask_ring <- function(x, ring, d, dtype) {
  if (!.g_traced(x)) {
    return(.mask_cells(x, pmax(ring - d, 0L), dtype))
  }
  g_ifelse(.g_on_raster(x, ring, d), x, .sv_fill(dtype))
}

# TRUE on the cells of traced `x` that lie on the raster.
.g_on_raster <- function(x, ring, d) {
  sh <- .g_shape(x)
  inside <- function(axis, lo, hi) {
    i <- anvl::nv_iota(axis, sh, "i32")
    i > g_index_scalar(ring, lo) - d & i <= sh[[axis]] - g_index_scalar(ring, hi) + d
  }
  n <- length(sh)
  inside(n - 1L, 1L, 3L) & inside(n, 2L, 4L)
}

#' Cast to a garry dtype.
#'
#' Integer targets truncate toward zero; `pred` maps nonzero to TRUE.
#' On plain R arrays the cast changes value semantics only (storage
#' stays double).
#'
#' @param x Numeric array.
#' @param dtype Target dtype string.
#' @return Array with `dtype`'s value semantics.
#' @export
g_cast <- function(x, dtype) {
  stopifnot(dtype_valid(dtype))
  if (.g_traced(x)) {
    return(anvl::nv_convert(x, .to_anvl_dtype(dtype)))
  }
  fam <- .dtype_family(dtype)
  out <- if (fam == "float") {
    x + 0
  } else if (fam == "pred") {
    # NaN is nonzero, as the traced convert treats it
    out <- x != 0
    out[is.nan(x)] <- TRUE
    out
  } else {
    trunc(x)
  }
  out
}

#' Stack same-shaped arrays along a new leading axis.
#'
#' `(y, x)` matrices stack into a `(t, y, x)` cube;
#' `(t, y, x)` cubes stack into a `(k, t, y, x)` hyper-cube
#' (e.g. a rolling window's shifted copies, reduced over dim 1).
#'
#' @param values List of same-shaped arrays.
#' @return A `length(values) x dim(values[[1]])` array.
#' @export
g_stack <- function(values) {
  if (.g_traced(values[[1L]])) {
    ex <- lapply(values, function(v) anvl::nv_unsqueeze(v, 1L))
    return(do.call(anvl::nv_concatenate, c(ex, list(axis = 1L))))
  }
  d <- dim(values[[1L]])
  if (is.null(d)) {
    return(unlist(values)) # scalars (or vectors) stack along one axis
  }
  arr <- simplify2array(values) # (d..., k)
  aperm(arr, c(length(d) + 1L, seq_along(d))) # -> (k, d...)
}

#' Extract element `i` of a 1-D array as a scalar (static index).
#'
#' @param v 1-D array (e.g. a flattened kernel).
#' @param i 1-based static index.
#' @return Scalar.
#' @export
g_index_scalar <- function(v, i) {
  if (.g_traced(v)) {
    return(anvl::nv_reshape(
      anvl::nv_static_slice(
        v,
        start_indices = i,
        end_indices = i,
        strides = 1L
      ),
      integer(0)
    ))
  }
  v[[i]]
}

# -- Scan (carried-state loop along dim 1) ------------------------------------

# anvl >= 0.5 provides nv_scan, so scans trace wherever anvl is. Kept for
# hutan's engine, which gates on it.

#' Can scans take the traced path?
#'
#' Internal capability check.
#' @return `TRUE` if anvl is installed.
#' @keywords internal
#' @export
.g_has_nv_scan <- function() {
  rlang::is_installed("anvl")
}

# Slice step `t` off dim 1 of a plain-R array, dropping the unit axis
# (a 1-D input yields a scalar) -- the oracle mirror of nv_scan's read.
.g_scan_slice <- function(x, t) {
  d <- dim(x) %||% length(x)
  if (length(d) == 1L) {
    return(x[[t]])
  }
  idx <- rep(list(quote(expr = )), length(d) - 1L)
  out <- do.call(`[`, c(list(x, t), idx, list(drop = FALSE)))
  array(out, dim = d[-1L])
}

# Write a step's leaf into row `t` of its (n, ...) buffer.
.g_scan_assign <- function(buf, leaf, t) {
  idx <- rep(list(quote(expr = )), length(dim(buf)) - 1L)
  do.call(`[<-`, c(list(buf, t), idx, list(value = leaf)))
}

# Recursive tree helpers for the oracle path (leaves = non-list values;
# the traced path delegates tree handling to anvl::nv_scan).
# A traced array is a list underneath, so it must be recognised as a leaf.
.g_tree_map <- function(x, f) {
  if (is.list(x) && !.g_traced(x)) lapply(x, .g_tree_map, f = f) else f(x)
}
.g_tree_map2 <- function(x, y, f) {
  if (is.list(x) && !.g_traced(x)) {
    Map(.g_tree_map2, x, y, MoreArgs = list(f = f))
  } else {
    f(x, y)
  }
}
.g_tree_any <- function(x, f) {
  if (is.list(x) && !.g_traced(x)) {
    any(vapply(x, .g_tree_any, logical(1), f = f))
  } else {
    f(x)
  }
}

# anvl's scan fixes the carry's type across steps (as JAX's lax.scan does),
# while a garry body may start from a scalar that broadcasts on its first step
# (`init = NaN` in fill_gaps). Probe the body once on the first slice of `xs`
# and bring every rank-0 init leaf to the type the body hands back. Only
# probes when there is such a leaf; the probe's ops are dead code that XLA
# removes, so the cost is one extra trace of the body.
.g_scan_settle_init <- function(init, body, xs) {
  is_scalar <- function(v) {
    if (.g_traced(v)) !length(.g_shape(v)) else is.null(dim(v)) && length(v) == 1L
  }
  if (!.g_tree_any(init, is_scalar)) {
    return(init)
  }
  first <- .g_tree_map(xs, function(x) {
    sl <- g_slice_t(x, 1L, 1L)
    if (.g_traced(sl)) {
      anvl::nv_reshape(sl, .g_shape(x)[-1L])
    } else {
      array(sl, dim = dim(x)[-1L])
    }
  })
  probe <- body(init, first)$carry
  .g_tree_map2(init, probe, function(i, p) {
    if (!is_scalar(i) || !.g_traced(p) || !length(.g_shape(p))) {
      return(i)
    }
    if (.g_traced(i)) {
      anvl::nv_broadcast_to(
        anvl::nv_convert(i, .to_anvl_dtype(.g_dtype(p))),
        .g_shape(p)
      )
    } else {
      anvl::nv_fill(i, shape = .g_shape(p), dtype = .to_anvl_dtype(.g_dtype(p)))
    }
  })
}

#' Scan: carry state along dim 1, emitting per-step outputs.
#'
#' The loop op behind [scan_over()] bodies (Kalman smoothers, EWMA, IIR
#' filters, cumulative custom ops). At step `t`, `body(carry, x)` gets
#' the current carry and the step-`t` slice of `xs` (taken along dim 1
#' with that unit axis dropped) and returns `list(carry = , out = )`;
#' the `out`s are stacked into `(length, ...)` buffers. `reverse = TRUE`
#' runs `t = length..1`, still reading and writing at position `t` (what
#' a backward smoothing pass needs, e.g. Rauch-Tung-Striebel). Traced
#' values route to `anvl::nv_scan`; plain R arrays take the pure-R
#' reference implementation with identical semantics.
#'
#' The scanned axis must be dim 1 of every `xs` leaf (garry's canonical
#' layout puts the scanned non-spatial axis first); bodies scanning a
#' non-leading margin must permute first.
#'
#' @param init Initial carry: array or (nested) named list of arrays.
#' @param body Step function `function(carry, x) -> list(carry, out)`;
#'   `out` may be an array, a (nested) list, or `NULL`.
#' @param xs Per-step inputs sliced along dim 1 (array or nested list).
#' @param reverse Run steps in reverse order?
#' @return `list(carry = final carry, out = stacked outputs)`.
#' @export
g_scan <- function(init, body, xs, reverse = FALSE) {
  if (.g_tree_any(init, .g_traced) || .g_tree_any(xs, .g_traced)) {
    return(anvl::nv_scan(
      .g_scan_settle_init(init, body, xs),
      xs = xs,
      body = body,
      reverse = reverse
    ))
  }
  # -- pure-R oracle path ------------------------------------------------------
  lens <- unlist(.g_tree_map(xs, function(x) (dim(x) %||% length(x))[[1L]]))
  if (!all(lens == lens[[1L]])) {
    cli::cli_abort("all leaves of {.arg xs} must agree on the size of dim 1")
  }
  n <- as.integer(lens[[1L]])
  carry <- init
  bufs <- NULL
  steps <- if (isTRUE(reverse)) rev(seq_len(n)) else seq_len(n)
  for (t in steps) {
    st <- body(carry, .g_tree_map(xs, function(x) .g_scan_slice(x, t)))
    if (
      !is.list(st) ||
        is.null(names(st)) ||
        !setequal(names(st), c("carry", "out"))
    ) {
      cli::cli_abort("{.arg body} must return {.code list(carry = , out = )}")
    }
    carry <- st$carry
    if (is.null(bufs) && !is.null(st$out)) {
      bufs <- .g_tree_map(st$out, function(leaf) {
        d <- dim(leaf)
        if (is.null(d) && length(leaf) > 1L) {
          d <- length(leaf)
        }
        array(NA_real_, dim = c(n, d))
      })
    }
    if (!is.null(st$out)) {
      bufs <- .g_tree_map2(bufs, st$out, function(buf, leaf) {
        .g_scan_assign(buf, leaf, t)
      })
    }
  }
  list(carry = carry, out = bufs)
}

#' Static range slice along dim 1 (the scanned axis).
#'
#' `x[from:to, ...]` keeping the leading axis: the building block for
#' scan bodies that pair a series with its own shift (e.g. an RTS
#' smoother reading the NEXT step's prediction).
#'
#' @param x Array with the scanned axis first.
#' @param from,to 1-based static bounds (inclusive).
#' @return Array with dim 1 of length `to - from + 1`.
#' @export
g_slice_t <- function(x, from, to) {
  from <- as.integer(from)
  to <- as.integer(to)
  if (.g_traced(x)) {
    sh <- .g_shape(x)
    return(anvl::nv_static_slice(
      x,
      start_indices = c(from, rep(1L, length(sh) - 1L)),
      end_indices = c(to, sh[-1L]),
      strides = rep(1L, length(sh))
    ))
  }
  d <- dim(x)
  idx <- rep(list(quote(expr = )), length(d) - 1L)
  do.call(`[`, c(list(x, from:to), idx, list(drop = FALSE)))
}

# Slice `from:to` (1-based, inclusive) along one axis of a traced array
# and concatenate along one axis: the bridge .apply_fuse_tiled uses to
# run a fused kernel over row tiles of a device window (traced only).
.g_slice_axis <- function(x, axis, from, to) {
  sh <- .g_shape(x)
  st <- rep(1L, length(sh))
  lim <- as.integer(sh)
  st[[axis]] <- as.integer(from)
  lim[[axis]] <- as.integer(to)
  anvl::nv_static_slice(
    x,
    start_indices = st,
    end_indices = lim,
    strides = rep(1L, length(sh))
  )
}

.g_concat_axis <- function(xs, axis) {
  do.call(anvl::nv_concatenate, c(xs, list(axis = as.integer(axis))))
}

# Apply `f` (a list of traced (outer.., y, x) arrays -> a list of the
# same) over row strips of `rows` rows inside one program: the inputs
# are cut into strips along a new leading axis (the last strip padded
# with zero rows) and a scan applies `f` to one strip per step; the
# padded rows are cut from the outputs. Exact for an `f` that is
# pointwise in y and x (.strip_stage_fn). Inputs that disagree on their
# y and x extents, or no taller than a strip, run whole.
.g_map_row_strips <- function(f, inputs, rows) {
  yx <- lapply(inputs, function(v) utils::tail(.g_shape(v), 2L))
  ny <- yx[[1L]][[1L]]
  nx <- yx[[1L]][[2L]]
  if (ny <= rows || length(unique(yx)) != 1L) {
    return(f(inputs))
  }
  ns <- as.integer(ceiling(ny / rows))
  pad <- ns * rows - ny
  # (outer.., ny, nx) -> (ns, outer.., rows, nx)
  to_strips <- function(v) {
    n <- length(.g_shape(v))
    if (pad > 0L) {
      v <- anvl::nv_pad(
        v,
        .g_scalar_like(v, 0),
        low = rep(0L, n),
        high = c(rep(0L, n - 2L), pad, 0L)
      )
    }
    outer <- .g_shape(v)[seq_len(n - 2L)]
    v <- .g_reshape_rm(v, c(outer, ns, rows, nx))
    if (n == 2L) {
      v
    } else {
      anvl::nv_transpose(v, c(n - 1L, seq_len(n - 2L), n, n + 1L))
    }
  }
  # (ns, outer.., rows, nx) -> (outer.., ny, nx)
  from_strips <- function(v) {
    m <- length(.g_shape(v))
    if (m > 3L) {
      v <- anvl::nv_transpose(v, c(2:(m - 2L), 1L, m - 1L, m))
    }
    outer <- .g_shape(v)[seq_len(m - 3L)]
    v <- .g_reshape_rm(v, c(outer, ns * rows, nx))
    if (pad > 0L) .g_slice_axis(v, m - 2L, 1L, ny) else v
  }
  res <- anvl::nv_scan(
    init = anvl::nv_fill(0, shape = integer(), dtype = "f32"),
    xs = lapply(inputs, to_strips),
    body = function(carry, s) list(carry = carry, out = f(unname(s)))
  )
  lapply(res$out, from_strips)
}

#' Concatenate along dim 1 (the scanned axis).
#'
#' Matrices are treated as single (1, y, x) slices, so a scan's stacked
#' buffers and a final plane concatenate directly.
#'
#' @param xs List of arrays: (k, y, x) cubes and/or (y, x) matrices.
#' @return Array with dim 1 = total slice count.
#' @export
g_concat_t <- function(xs) {
  if (.g_traced(xs[[1L]])) {
    ex <- lapply(xs, function(v) {
      if (length(.g_shape(v)) == 2L) anvl::nv_unsqueeze(v, 1L) else v
    })
    return(do.call(anvl::nv_concatenate, c(ex, list(axis = 1L))))
  }
  ex <- lapply(xs, function(v) {
    d <- dim(v)
    if (length(d) == 2L) array(v, c(1L, d)) else v
  })
  n <- sum(vapply(ex, function(v) dim(v)[[1L]], integer(1)))
  d1 <- dim(ex[[1L]])
  out <- array(NA_real_, c(n, d1[2L], d1[3L]))
  at <- 0L
  for (v in ex) {
    k <- dim(v)[[1L]]
    out[(at + 1L):(at + k), , ] <- v
    at <- at + k
  }
  out
}

#' Replicate a (y, x) plane along a new leading axis.
#'
#' The broadcast helper for per-pixel statistics against a (t, y, x)
#' cube (e.g. a per-pixel MAD over the scanned axis reused at every t).
#'
#' @param x A (y, x) matrix (traced or plain).
#' @param n Number of leading-axis copies.
#' @return An (n, y, x) array.
#' @export
g_rep_t <- function(x, n) {
  n <- as.integer(n)
  if (.g_traced(x)) {
    sh <- .g_shape(x)
    return(anvl::nv_broadcast_to(anvl::nv_unsqueeze(x, 1L), c(n, sh)))
  }
  d <- dim(x)
  # column-major: the leading axis is fastest, so each element repeats n times
  array(rep(as.vector(x), each = n), c(n, d))
}

#' Insert a broadcast axis at an arbitrary position.
#'
#' The rank-general sibling of [g_rep_t()]: expands `x` with a new axis
#' of `n` copies at position `axis`, so a reduced statistic broadcasts
#' back against the array it came from (base R arrays do not broadcast,
#' so the untraced path materialises the copies; traced, this is
#' a free `broadcast_to`).
#'
#' @param x Array (traced or plain).
#' @param axis 1-based position of the new axis in the output.
#' @param n Length of the new axis.
#' @return Array of rank `length(dim(x)) + 1`.
#' @export
g_expand <- function(x, axis, n) {
  axis <- as.integer(axis)
  n <- as.integer(n)
  if (.g_traced(x)) {
    sh <- .g_shape(x)
    out_sh <- append(sh, n, after = axis - 1L)
    return(anvl::nv_broadcast_to(anvl::nv_unsqueeze(x, axis), out_sh))
  }
  d <- dim(x) %||% length(x) # vectors are rank-1
  arr <- array(as.vector(x), c(d, n)) # copies on a trailing axis
  aperm(arr, append(seq_along(d), length(d) + 1L, after = axis - 1L))
}

# -- Pixel-matrix bridge (band-collapsing linear algebra) ----------------------

# Row-major reshape of a traced array. anvl reshapes column-major and
# lowers that as reverse-axes transpose, row-major reshape, reverse-axes
# transpose; wrapping it in the same reversals cancels both transposes, so
# this is a free reshape of the row-major device buffer. A column-major
# reshape that merges (y, x) would put y fastest against a buffer that
# stores x fastest, and XLA then copies the whole chunk.
.g_reshape_rm <- function(x, shape) {
  rev_axes <- function(v) {
    n <- length(.g_shape(v))
    if (n <= 1L) v else anvl::nv_transpose(v, perm = rev(seq_len(n)))
  }
  rev_axes(anvl::nv_reshape(rev_axes(x), rev(as.integer(shape))))
}

# Flatten a (band, y, x) chunk to a (band, npix) matrix and back. The
# pixel ordering is backend-defined (row-major traced, column-major in
# base R) so these are ONLY valid as an inverse pair around per-pixel
# math: matmul mixes bands within a pixel column, never across pixels,
# so the ordering cancels.
.g_flatten_yx <- function(x) {
  if (.g_traced(x)) {
    sh <- .g_shape(x)
    return(.g_reshape_rm(x, c(sh[[1L]], prod(sh[-1L]))))
  }
  d <- dim(x)
  matrix(x, nrow = d[[1L]])
}

.g_unflatten_yx <- function(v, ny, nx) {
  if (.g_traced(v)) {
    return(.g_reshape_rm(v, c(ny, nx)))
  }
  matrix(as.vector(v), ny, nx)
}
# Rank-3 inverse of .g_flatten_yx: (k, ny*nx) back to (k, ny, nx).
# Same contract as the pair above: each branch inverts its own
# flatten ordering, so it is only valid around per-pixel-column math.
.g_unflatten_kyx <- function(v, k, ny, nx) {
  if (.g_traced(v)) {
    return(.g_reshape_rm(v, c(k, ny, nx)))
  }
  array(as.vector(v), c(k, ny, nx))
}

# -- Reductions ---------------------------------------------------------------

# Shared shape handling: `dims` are integer array margins to REDUCE
# (planner maps named dims to margins). NULL reduces everything.
.g_reduce <- function(x, dims, f) {
  if (is.null(dims)) {
    return(f(as.vector(x)))
  }
  keep <- setdiff(seq_along(dim(x)), as.integer(dims))
  if (length(keep) == 0L) {
    return(f(as.vector(x)))
  }
  apply(x, keep, f)
}

.nan_filter <- function(v, nan_rm) if (nan_rm) v[!is.na(v)] else v

#' Reductions over array margins.
#'
#' `g_sum` accumulates 8- and 16-bit integers in i32 and 32-bit integers in
#' i64, so a sum does not wrap at the input type's range. `g_mean` averages
#' integers in f32.
#'
#' With `nan_rm = TRUE`, a slice that is entirely NaN reduces to the
#' reduction's identity value: `g_sum` gives 0, `g_min` gives `Inf`,
#' `g_max` gives `-Inf`, and `g_mean` / `g_median` give NaN. `g_count`
#' counts non-NaN values, so an all-NaN slice gives 0.
#'
#' @param x Numeric array.
#' @param dims Integer margins to reduce, or NULL for all.
#' @param nan_rm Skip NaN (nodata)?
#' @return Reduced array (margins in `dims` dropped) or scalar.
#' @name g-reductions
NULL

# Accumulator dtype for integer sums: 8- and 16-bit integers sum in i32,
# 32-bit integers in i64.
.g_sum_widen <- c(i8 = "i32", i16 = "i32", u8 = "i32", u16 = "i32", i32 = "i64", u32 = "i64")

#' @rdname g-reductions
#' @export
g_sum <- function(x, dims = NULL, nan_rm = FALSE) {
  if (.g_traced(x)) {
    # anvl sums in the input dtype and wraps on overflow; accumulate
    # narrow integers wider (see .reduce_dtype()).
    wide <- unname(.g_sum_widen[.g_dtype(x)])
    if (!is.na(wide)) {
      x <- anvl::nv_convert(x, wide)
    }
    return(anvl::nv_sum(x, axes = dims, nan_rm = nan_rm))
  }
  .g_reduce(x, dims, function(v) sum(.nan_filter(v, nan_rm)))
}

#' Broadcast arrays to a common shape (compute vocabulary).
#'
#' Broadcasting for the `g_*` vocabulary: the hook for per-band
#' constants in a band reducer -- multiply a `(band, y, x)` cube by a
#' `(band, 1, 1)` loading vector before summing over band (a linear projection;
#' see [band_project()]). anvl requires operands broadcast explicitly. Traces to
#' anvl when given traced arrays, else broadcasts plain-R arrays (same rank).
#'
#' @param ... Two or more arrays (traced or plain).
#' @return A list of the inputs broadcast to their common shape.
#' @export
g_broadcast_arrays <- function(...) {
  args <- list(...)
  if (.g_traced(args[[1L]])) {
    return(anvl::nv_broadcast_arrays(...))
  }
  # oracle (plain-R arrays): replicate singleton dims to the common shape.
  # Same-rank inputs (as the band reducer supplies); no rank padding.
  shp <- lapply(args, function(a) dim(a) %||% length(a))
  target <- do.call(pmax, shp)
  lapply(args, function(a) {
    s <- dim(a) %||% length(a)
    if (identical(as.integer(s), as.integer(target))) {
      return(a)
    }
    idx <- lapply(seq_along(target), function(ax) {
      if (s[[ax]] == 1L && target[[ax]] > 1L) {
        rep(1L, target[[ax]])
      } else {
        seq_len(target[[ax]])
      }
    })
    do.call(`[`, c(list(array(a, s)), idx, list(drop = FALSE)))
  })
}

# Is this a traced array of an integer dtype?
.g_is_integer <- function(x) {
  .g_traced(x) && isTRUE(.dtype_family(.g_dtype(x)) %in% c("int", "uint"))
}

# A chunk's sum, for a partial the host adds up: a chunk of Int16 cells
# passes 2^31 at a mean of about 2,100, so integers accumulate in f64,
# exact to 2^53, whatever the input's width.
.g_partial_sum <- function(x, dims, nan_rm) {
  g_sum(if (.g_is_integer(x)) g_cast(x, "f64") else x, dims, nan_rm)
}

#' @rdname g-reductions
#' @export
g_mean <- function(x, dims = NULL, nan_rm = FALSE) {
  if (.g_traced(x)) {
    # anvl 0.5.1 sums an integer input in its own dtype before dividing, so
    # the mean wraps (two i8 codes of 100 and 120 average to -4.5). Average
    # at f32, the dtype .reduce_dtype() promises.
    if (.g_is_integer(x)) {
      x <- anvl::nv_convert(x, "f32")
    }
    return(anvl::nv_mean(x, axes = dims, nan_rm = nan_rm))
  }
  .g_reduce(x, dims, function(v) mean(.nan_filter(v, nan_rm)))
}

#' @rdname g-reductions
#' @export
g_min <- function(x, dims = NULL, nan_rm = FALSE) {
  if (.g_traced(x)) {
    return(anvl::nv_min(x, axes = dims, nan_rm = nan_rm))
  }
  .g_reduce(x, dims, function(v) {
    v <- .nan_filter(v, nan_rm)
    if (length(v) == 0L) Inf else min(v) # XLA init value, no warning
  })
}

#' @rdname g-reductions
#' @export
g_max <- function(x, dims = NULL, nan_rm = FALSE) {
  if (.g_traced(x)) {
    return(anvl::nv_max(x, axes = dims, nan_rm = nan_rm))
  }
  .g_reduce(x, dims, function(v) {
    v <- .nan_filter(v, nan_rm)
    if (length(v) == 0L) -Inf else max(v)
  })
}

#' @rdname g-reductions
#' @export
g_median <- function(x, dims = NULL, nan_rm = FALSE) {
  if (.g_traced(x)) {
    if (length(dims) == 1L && .g_shape(x)[[dims]] %in% 2:32) {
      return(.g_median_net(x, as.integer(dims), nan_rm))
    }
    return(anvl::nv_median(x, axes = dims, nan_rm = nan_rm))
  }
  .g_reduce(x, dims, function(v) {
    m <- stats::median(v, na.rm = nan_rm)
    if (is.na(m)) NaN else m # all-nodata -> NaN, never NA
  })
}

# Median along one short axis as a sorting network. anvl's median moves
# the axis innermost (a transpose of the whole array) and ranks each
# slice with top_k, which XLA's CPU backend runs as a scalar loop per
# pixel: 85 ms for a (13, 480, 480) f64 cube on 10 cores. A sorting
# network is a fixed sequence of elementwise min/max over the axis's
# planes, which XLA fuses into one vectorised pass with no transpose
# (14 ms there), and the median reads the sorted planes at each pixel's
# valid count. The values are anvl's: the same order statistics, and
# the even-count average in anvl's form, lo * 0.5 + hi * 0.5, which
# does not overflow where (lo + hi) * 0.5 would near the dtype's limit.
.g_median_net <- function(x, axis, nan_rm) {
  if (!.g_dtype(x) %in% c("f16", "bf16", "f32", "f64")) {
    # as anvl: a median can fall between two integers
    x <- anvl::nv_convert(x, "f32")
  }
  sh <- .g_shape(x)
  n <- sh[[axis]]
  cnt <- g_count(x, dims = axis)
  if (nan_rm) {
    # NaN sorts last as +Inf, past every slot the valid count reads
    x <- g_ifelse(g_is_nodata(x), .g_scalar_like(x, Inf), x)
  }
  s <- lapply(seq_len(n), function(i) {
    .g_reshape_rm(.g_slice_axis(x, axis, i, i), sh[-axis])
  })
  for (cp in .sort_pairs(n)) {
    lo <- anvl::nv_pmin(s[[cp[[1L]]]], s[[cp[[2L]]]])
    s[[cp[[2L]]]] <- anvl::nv_pmax(s[[cp[[1L]]]], s[[cp[[2L]]]])
    s[[cp[[1L]]]] <- lo
  }
  # anvl's even-count weight, a run-time 0.5: with a literal 0.5 XLA's
  # simplifier refactors lo * 0.5 + hi * 0.5 into (lo + hi) * 0.5, which
  # overflows near the dtype's limit
  w <- g_cast(cnt, .g_dtype(x)) * 0 + 0.5
  mid <- function(k) {
    if (k %% 2L) {
      s[[(k + 1L) %/% 2L]]
    } else {
      s[[k %/% 2L]] * (1 - w) + s[[k %/% 2L + 1L]] * w
    }
  }
  if (!nan_rm) {
    # a NaN anywhere in the slice makes it NaN, as in anvl
    return(g_ifelse(cnt == n, mid(n), NaN))
  }
  out <- .g_scalar_like(s[[1L]], NaN) # all-NaN slices match no count
  for (k in seq_len(n)) {
    out <- g_ifelse(cnt == k, mid(k), out)
  }
  out
}

# Comparators (i, j), i < j, of Batcher's odd-even merge sort for n
# elements: after them, each position holds its order statistic. The
# network is built for the next power of two and pruned of comparators
# that touch a padding position: padding is +Inf, so those leave every
# real position as it was.
.sort_pairs <- function(n) {
  n_pow <- as.integer(2L^ceiling(log2(n)))
  out <- list()
  p <- 1L
  while (p < n_pow) {
    k <- p
    while (k >= 1L) {
      for (j in seq(k %% p, n_pow - 1L - k, by = 2L * k)) {
        for (i in 0:min(k - 1L, n_pow - j - k - 1L)) {
          a <- i + j
          b <- i + j + k
          if (a %/% (2L * p) == b %/% (2L * p) && b < n) {
            out[[length(out) + 1L]] <- c(a + 1L, b + 1L)
          }
        }
      }
      k <- k %/% 2L
    }
    p <- p * 2L
  }
  out
}

#' @rdname g-reductions
#' @export
g_count <- function(x, dims = NULL) {
  if (.g_traced(x)) {
    valid <- anvl::nv_convert(anvl::nv_not(anvl::nv_is_nan(x)), "f32")
    return(anvl::nv_sum(valid, axes = dims))
  }
  .g_reduce(x, dims, function(v) sum(!is.na(v)))
}

# -- Bitwise family (QA bitmask decoding) -------------------------------------

# bitwAnd and friends need integer inputs; QA values arrive as doubles
# holding integral values. Coercion preserving shape:
.bitw <- function(f, a, b) {
  out <- f(as.integer(a), as.integer(b))
  if (!is.null(dim(a))) {
    dim(out) <- dim(a)
  }
  out
}

#' Bitwise operations on integral arrays.
#'
#' @param a,b Integral arrays (or scalar `b`); recycled like base R.
#' @param n Shift amount in bits.
#' @return Integral array shaped like `a`.
#' @seealso [qa_bits()] and [apply_mask()] for the QA-masking verbs built on
#'   these ops.
#' @name g-bitwise
NULL

# Promote a plain R integer scalar to the traced operand's dtype.
.g_int_like <- function(a, b) {
  if (.g_traced(b)) {
    return(b)
  }
  .g_scalar_like(a, as.integer(b))
}

#' @rdname g-bitwise
#' @export
g_bitand <- function(a, b) {
  if (.g_traced(a)) {
    return(anvl::nv_and(a, .g_int_like(a, b)))
  }
  .bitw(bitwAnd, a, b)
}

#' @rdname g-bitwise
#' @export
g_bitor <- function(a, b) {
  if (.g_traced(a)) {
    return(anvl::nv_or(a, .g_int_like(a, b)))
  }
  .bitw(bitwOr, a, b)
}

#' @rdname g-bitwise
#' @export
g_bitxor <- function(a, b) {
  if (.g_traced(a)) {
    return(anvl::nv_xor(a, .g_int_like(a, b)))
  }
  .bitw(bitwXor, a, b)
}

#' @rdname g-bitwise
#' @export
g_bitnot <- function(a) {
  if (.g_traced(a)) {
    return(anvl::nv_not(a))
  }
  out <- bitwNot(as.integer(a))
  if (!is.null(dim(a))) {
    dim(out) <- dim(a)
  }
  out
}

#' @rdname g-bitwise
#' @export
g_shiftl <- function(a, n) {
  if (.g_traced(a)) {
    return(anvl::nv_shift_left(a, .g_int_like(a, n)))
  }
  .bitw(bitwShiftL, a, n)
}

#' @rdname g-bitwise
#' @export
g_shiftr <- function(a, n) {
  if (.g_traced(a)) {
    return(anvl::nv_shift_right_logical(a, .g_int_like(a, n)))
  }
  .bitw(bitwShiftR, a, n)
}

# -- Neural-network ops (OCM native inference) --------------------------------

#' 2D convolution over a (C, H, W) chunk.
#'
#' Torch-layout convolution for in-graph model inference: `x` is a
#' channels-first `(C_in, H, W)` array, `w` a `(C_out, C_in/groups, kH,
#' kW)` kernel, `bias` an optional length-`C_out` vector. `stride`,
#' `padding` (symmetric), and `dilation` are scalars or length-2
#' `(y, x)`. `groups` gives grouped/depthwise convolution. Weights and
#' bias are plain R arrays; traced they enter the kernel as constants
#' uploaded once at compile.
#'
#' The plain-R branch is an im2col matmul: correct at any size, meant
#' for tests, not throughput.
#'
#' @param x `(C_in, H, W)` array (traced or plain).
#' @param w `(C_out, C_in/groups, kH, kW)` numeric array.
#' @param bias Optional length-`C_out` numeric.
#' @param stride,padding,dilation Scalar or length-2 integers.
#' @param groups Feature group count.
#' @return `(C_out, H_out, W_out)` array.
#' @export
g_conv2d <- function(
  x,
  w,
  bias = NULL,
  stride = 1L,
  padding = 0L,
  dilation = 1L,
  groups = 1L
) {
  stride <- as.integer(rep_len(stride, 2L))
  padding <- as.integer(rep_len(padding, 2L))
  dilation <- as.integer(rep_len(dilation, 2L))
  groups <- as.integer(groups)
  co <- dim(w)[[1L]]
  if (.g_traced(x)) {
    out <- anvl::nv_conv2d(
      anvl::nv_unsqueeze(x, 1L),
      g_upload(w, "f32"),
      stride = stride,
      padding = padding,
      dilation = dilation,
      groups = groups
    )
    out <- anvl::nv_squeeze(out, 1L)
    if (!is.null(bias)) {
      bt <- g_upload(array(as.numeric(bias), c(co, 1L, 1L)), "f32")
      out <- out + anvl::nv_broadcast_to(bt, .g_shape(out))
    }
    return(out)
  }
  d <- dim(x)
  ci <- d[[1L]]
  h <- d[[2L]]
  wd <- d[[3L]]
  kh <- dim(w)[[3L]]
  kw <- dim(w)[[4L]]
  xp <- array(0, c(ci, h + 2L * padding[[1L]], wd + 2L * padding[[2L]]))
  xp[, padding[[1L]] + seq_len(h), padding[[2L]] + seq_len(wd)] <- x
  ho <- (dim(xp)[[2L]] - (kh - 1L) * dilation[[1L]] - 1L) %/% stride[[1L]] + 1L
  wo <- (dim(xp)[[3L]] - (kw - 1L) * dilation[[2L]] - 1L) %/% stride[[2L]] + 1L
  cig <- ci %/% groups
  cog <- co %/% groups
  out <- array(0, c(co, ho, wo))
  for (g in seq_len(groups)) {
    cs <- (g - 1L) * cig + seq_len(cig) # input channels of the group
    os <- (g - 1L) * cog + seq_len(cog) # output channels
    cols <- vector("list", kh * kw)
    wcols <- vector("list", kh * kw)
    i <- 0L
    for (ky in seq_len(kh)) {
      for (kx in seq_len(kw)) {
        ys <- (ky - 1L) *
          dilation[[1L]] +
          seq(1L, by = stride[[1L]], length.out = ho)
        xs <- (kx - 1L) *
          dilation[[2L]] +
          seq(1L, by = stride[[2L]], length.out = wo)
        sl <- xp[cs, ys, xs, drop = FALSE]
        i <- i + 1L
        cols[[i]] <- matrix(sl, nrow = cig) # (Cin/g, ho*wo) col-major
        wcols[[i]] <- matrix(w[os, , ky, kx], nrow = cog) # (Cout/g, Cin/g)
      }
    }
    res <- do.call(cbind, wcols) %*% do.call(rbind, cols) # (Cout/g, ho*wo)
    out[os, , ] <- array(res, c(cog, ho, wo))
  }
  if (!is.null(bias)) {
    out <- out + array(rep(as.numeric(bias), ho * wo), c(co, ho, wo))
  }
  out
}

#' Nearest-neighbour 2x upsample of a (C, H, W) chunk.
#'
#' Each pixel becomes a 2x2 block (the U-Net decoder upsample).
#'
#' @param x `(C, H, W)` array (traced or plain).
#' @return `(C, 2H, 2W)` array.
#' @export
g_upsample2x <- function(x) {
  if (.g_traced(x)) {
    sh <- .g_shape(x)
    u <- anvl::nv_unsqueeze(x, c(3L, 5L)) # (C,H,1,W,1)
    b <- anvl::nv_broadcast_to(u, c(sh[[1L]], sh[[2L]], 2L, sh[[3L]], 2L))
    return(.g_reshape_rm(b, c(sh[[1L]], 2L * sh[[2L]], 2L * sh[[3L]])))
  }
  d <- dim(x)
  x[,
    rep(seq_len(d[[2L]]), each = 2L),
    rep(seq_len(d[[3L]]), each = 2L),
    drop = FALSE
  ]
}

#' Pad the bottom/right edges of the last two dims.
#'
#' Grows the spatial dims by `(dy, dx)` cells of `value` on the high
#' side only: the shape-alignment pad (e.g. to a /32-divisible U-Net
#' input) that a later slice removes exactly.
#'
#' @param x Array of rank >= 2 (traced or plain).
#' @param dy,dx Non-negative cell counts to add below / to the right.
#' @param value Fill value.
#' @return Array with the last two dims grown by `dy`, `dx`.
#' @export
g_pad_rb <- function(x, dy, dx, value = 0) {
  dy <- as.integer(dy)
  dx <- as.integer(dx)
  if (.g_traced(x)) {
    r <- length(.g_shape(x))
    hi <- c(rep(0L, r - 2L), dy, dx)
    return(anvl::nv_pad(
      x,
      value,
      low = rep(0L, r),
      high = hi
    ))
  }
  d <- dim(x)
  nd <- d
  nd[length(d) - 1L] <- d[[length(d) - 1L]] + dy
  nd[length(d)] <- d[[length(d)]] + dx
  out <- array(value, nd)
  idx <- lapply(d, seq_len)
  do.call(`[<-`, c(list(out), idx, list(value = x)))
}

#' Transpose an array (general permutation).
#'
#' `perm[i]` names the input axis that becomes output axis `i`
#' (base R `aperm()` semantics); `NULL` reverses the axes.
#'
#' @param x Array (traced or plain).
#' @param perm Integer permutation, or `NULL`.
#' @return Permuted array.
#' @export
g_transpose <- function(x, perm = NULL) {
  if (.g_traced(x)) {
    return(anvl::nv_transpose(x, perm = perm))
  }
  aperm(x, perm)
}

#' Error function (exact GELU building block).
#'
#' @param x Numeric array (traced or plain).
#' @return `erf(x)` elementwise.
#' @export
g_erf <- function(x) {
  if (.g_traced(x)) {
    return(anvl::nv_erf(x))
  }
  2 * stats::pnorm(x * sqrt(2)) - 1
}

#' Drop a leading unit axis.
#'
#' The inverse of `g_expand(x, 1L, 1L)`: `(1, d...)` becomes `(d...)`
#' (e.g. a `g_slice_t` single-slice result back to its plane).
#'
#' @param x Array with `dim(x)[1] == 1` (traced or plain).
#' @return Array of one lower rank.
#' @export
g_squeeze1 <- function(x) {
  if (.g_traced(x)) {
    return(anvl::nv_squeeze(x, 1L))
  }
  d <- dim(x)
  stopifnot(d[[1L]] == 1L)
  array(x, d[-1L])
}
