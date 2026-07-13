# The dataset API: applying functions across bands and time

A design for a first-class multi-band, multi-time lazy object so users stop
writing nested `lapply`s over bands and slices. Companion to
`ir-extensions-todo.md` (the custom/multi-band reducers this API surfaces) and
the pkgdown reference grouping in `_pkgdown.yml`.

## The problem

The composite workload today is three nested `lapply`s over the primitive
layer (`lazy_source`/`lazy_map`/`lazy_stack`/`reduce_over`):

```r
cleaned    <- lapply(slices, bad_of)                       # per slice: build mask
composites <- lapply(bands, function(band) {               # per band
  masked <- lapply(slices, \(sl)                           #   per slice: apply mask
    lazy_map(slice_of(band, sl), cleaned[[sl]], fn = mask_fn))
  lazy_stack(masked) |> reduce_over("median", "t")
})
out <- lazy_stack(composites, along = "band")
```

The primitive layer is correct and stays; it is just too low-level for the
common case. We want the vrtility ergonomic — one object holding the whole
`(band, t, y, x)` cube, verbs applied across every band by default, a band
argument to target the mask — without reproducing vrtility's structure.

## Why garry needs ONE object, not vrtility's three

vrtility (see its `data-structures-and-terminology` vignette) has `vrt_block`,
`vrt_collection` (time-major: each item is one epoch holding all bands) and
`vrt_stack` (band-major: each band holds all its time sources). It needs both
layouts because it is built on GDAL VRTs, where bands are a fixed axis of a 2D
raster; `vrt_stack()` is a **transpose** between the layouts, forced by GDAL's
band model. Multiband ops (geometric median) run on the collection because they
must see all bands per epoch; per-band temporal reductions run on the stack.

garry has no such constraint. Its IR is a true 4D `(band, t, y, x)` array, so
**one object serves both**: a band-separable temporal reduce and a multiband
reduce differ only in which axis you reduce, with no wide/long transpose to
represent. garry therefore collapses the block/collection/stack trichotomy into
a single lazy object. This is a real advantage and should be stated as such in
the docs.

## The object: `LazyDataset`

A named, ordered set of bands, each a time series, sharing one grid and one IR
graph. It is the xarray *Dataset* analog; garry's existing `LazyRaster` is the
*DataArray* analog (a single array, which in garry can already carry `t` and
`band` dims because the IR is 4D).

Concretely it is a light wrapper: a named, band-major list, keeping band
**names** (needed to target the mask) and each band's own nodata/dtype, on a
shared graph + grid, and **deferring the band-axis assembly to `collect()`** —
so the shared-mask-subgraph dedup and single-plan scheduling the benchmark
hand-codes become automatic.

Implementation note: each band is stored as a list of **per-time-slice 2D
`LazyRaster`s**, not a single `(t, y, x)` node. The reduce stacks a band's
slices into `(t, y, x)` and collapses `t`. The reason is that `.eval_node`'s
focal branch is 2D (`nrow`/`ncol` + `g_shift_slice`), so `mask()`'s morphology
must run on 2D inputs; `g_pad`/`g_shift_slice` are already leading-dim-aware, so
a future 3D-focal path could switch bands to single `(t, y, x)` nodes without
changing the API. This per-slice layout is invisible above the object.

### The name

`LazyDataset`, constructed by `lazy_dataset()`. Constraints considered: not
`cube` (the metaphor breaks for multispectral data — a cube implies one
homogeneous value axis, but bands are heterogeneous variables), not `collection`
(clashes with the terminal verb `collect()`). GDAL's own top object is the
*dataset* (a `GDALDataset` is precisely the band-holding container), so this is
the most GDAL-native term available, and it matches xarray's Dataset/DataArray
pairing with garry's `LazyDataset`/`LazyRaster`.

Decisive over `LazyStack`: `stack` must stay free as a **verb**. The band-axis
collapse (`stack_bands()`, below) *is* a stack operation, and the low-level node
binder is `lazy_stack(along = "band")`. Naming the object `LazyStack` would
overload "stack" across the object, the constructor, the collapse verb, and the
node binder — reintroducing exactly the "stack = add bands" ambiguity vrtility's
vignette warns about. With `LazyDataset` the noun is the dataset and "stack"
stays a clean, directional verb: `dataset -> stack the bands -> array`, mirroring
xarray's `Dataset.to_dataarray()`. Ruled out: `LazyScene` (a scene is one
acquisition, wrong for multi-temporal), `LazyBrick` (terra deprecated "brick").

## Verbs: polymorphic, not a new prefix

Reuse the existing S7-dispatched verbs; add methods for `LazyDataset` so a
single vocabulary covers both a single raster and a whole dataset. Each gains a
`bands =` selector (default: all bands).

- `lazy_map(x, fn, bands = NULL, dtype = NULL)` — elementwise per band.
- `focal(x, fn, radius, bands = NULL)` — stencil per band.
- `reduce_over(x, op, over = "t", bands = NULL)` — per-band reduce; `op` may be
  a name (`"median"`) or a custom anvl reducer (`ir-extensions-todo.md` #2).
- Arithmetic (`+ - * /`) broadcasts scalars across bands and matches bands
  between two datasets.
- `ds[["B04"]]` / `ds[c("B04","B03")]` — escape hatch back to a `LazyRaster` /
  a sub-dataset.
- `collect(x, path, ...)` — assembles the band axis into one node and executes
  a single plan.

`mask()` is the one genuinely new verb (below): "compute a mask from a named
band, apply to every other band, drop the mask band" has no single-raster
analog.

### Do we need a `stack()` verb? `stack_bands()`

No transposing `stack()` (vrtility's `vrt_stack()`); there is no wide/long layout
to convert. The only related op is assembling the named bands into one 4D
`(band, t, y, x)` node so a **multiband** reducer (geometric median/medoid) can
see all bands jointly. That happens implicitly at `collect()`; expose it
explicitly only as the multiband-reduce hook:

```r
# x : LazyDataset; x@bands is a named list of LazyRaster, each (t, y, x),
#     all on one graph + grid
stack_bands <- function(x) {
  lazy_stack(x@bands, along = "band")   # -> one LazyRaster, (band, t, y, x)
}

# only needed for a reducer that must see all bands at once:
gmed <- reduce_over(stack_bands(ds), geometric_median, over = "t")
```

`dataset -> stack the bands -> array` reads cleanly precisely because the object
is a dataset, not a stack (see the naming note above). This is xarray's
`Dataset.to_dataarray()`.

## Masking

The centrepiece verb. Compute a bad-pixel mask from a named QA band, optionally
clean it with morphology, set bad pixels to NaN on every *value* band, and drop
the QA band.

```r
mask(x, from, where, open = 0, dilate = 0, drop = TRUE)
```

- `from` — name of the QA band to derive the mask from (e.g. `"Fmask"`,
  `"SCL"`).
- `where` — the **removal predicate** (mask where TRUE). Polymorphic:
  - a numeric vector -> **value membership** (bad if the pixel value is in the
    set). This is the categorical case: Sentinel-2 SCL is a class label 0-11,
    so `where = c(0,1,2,3,8,9,10,11)` masks nodata/saturated/shadow/cloud/
    cirrus/snow directly, matching vrtility's `mask_values`.
  - `qa_bits(bits)` -> **bitmask** test (bad if any listed bit is set). This is
    the bitwise case: Fmask / Landsat QA_PIXEL pack independent flags per bit
    (Fmask bit 0 cirrus, 1 cloud, 2 adjacent, 3 shadow), which a value list
    cannot express. `where = qa_bits(0:3)`.
  - a function `\(f) ...` -> a raw anvl predicate, for anything exotic.
- `open` — opening radius (erosion then dilation at the same radius):
  **despeckle**. Removes isolated flagged pixels and thin filaments up to the
  radius; large cloud bodies unchanged. Cleans false-positive QA flags.
  `open = 0` skips it.
- `dilate` — dilation radius: **buffer**. Grows the surviving bad regions
  outward, catching cloud-edge/adjacency contamination the flag missed. A
  deliberate safety margin. `dilate = 0` skips it.
- `drop` — drop the QA band from the output dataset (default TRUE).

Morphology is always open-then-dilate (matching odc-algo's `mask_cleanup`
`(opening, dilation)`); `open`/`dilate` are independent scalars because they do
opposite jobs — shrink noise vs grow a safety buffer. An arbitrary
erosion/dilation sequence goes through `where =` as a raw fn.

`qa_bits(bits)` is the only helper needed: it returns the predicate
`\(f) g_bitand(g_cast(f, "i32"), sum(2^bits)) > 0`, so the common QA case never
touches bitand (which is error-prone by hand). The categorical case needs no
helper — the bare vector is the test.

### Helper summary

| QA encoding        | Example bands        | `where =`                       |
|--------------------|----------------------|---------------------------------|
| categorical (class)| S2 SCL               | `c(0,1,2,3,8,9,10,11)`          |
| bitmask (flags)    | HLS Fmask, LS QA_PIXEL | `qa_bits(0:3)`                |
| arbitrary          | anything             | `\(f) ...` anvl predicate       |

## The workload, rewritten

```r
ds <- lazy_dataset(src, grid = target, assets = bands, mask_asset = "Fmask")

ds |>
  mask(from = "Fmask", where = qa_bits(0:3), open = 2, dilate = 3) |>
  reduce_over("median", over = "t") |>
  collect(path = "composite.tif", nodata = -9999)
```

Three nested `lapply`s become four lines. The mask is a shared subgraph
computed once per slice and dedup'd across bands (garry's IR, not per-asset VRT
pixel functions); the morphology fuses (D11); the whole dataset collapses to one
scheduler pass at `collect()`.

## garry advantages to preserve and advertise

- **One object** because the IR is a real nd-array (no collection/stack
  transpose).
- **Shared-subgraph dedup**: a mask defined once is computed once across all
  bands; `collect()` plans the whole dataset in one pass.
- **Arbitrary anvl masks and reducers**: `where =` and custom reducers accept
  full anvl kernels (multiband logic, morphology, per-pixel fits), not just
  value lists / named ops.
- **Explicit alignment (D8)**: dataset construction requires one grid; nothing
  auto-resamples.
- **Fully lazy to `collect()`**: unlike vrtility, which materialises at warp;
  garry defers everything.

## Build order

1. `LazyDataset` class + `lazy_dataset()` constructor and `[[`/`[`/`print`
   methods.
2. Polymorphic `bands =` methods on `lazy_map`/`focal`/`reduce_over` +
   band-matched arithmetic.
3. `mask()` + `qa_bits()` + the `where =` polymorphism.
4. `collect()` band-axis assembly (implicit) + `stack_bands()` escape hatch.
5. Rewrite the benchmark on the new surface; retitle the pkgdown "Cube algebra"
   section to "Dataset algebra"; keep the low-level `lazy_stack()` node binder
   as a Tier-2 IR primitive.
6. Later: multiband reducers (`ir-extensions-todo.md` #3) via `stack_bands()`.
