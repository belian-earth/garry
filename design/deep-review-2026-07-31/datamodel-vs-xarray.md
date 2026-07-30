# garry's data model and user API vs xarray

Deep review, 2026-07-31. Reference: xarray stable docs (data-structures,
computation, combining, time-series, io user guides; rioxarray CRS management
guide). garry state: branch `placement-pass`, files `R/grid.R`, `R/lazy_raster.R`,
`R/dataset.R`, `R/generics.R`, `R/node.R`, `R/stac.R`, `R/collect.R`.

## Verdict summary

| Axis | Classification | One-line judgement |
|---|---|---|
| 1. Coordinate model (spatial) | DIFFERENT-BY-DESIGN | Affine transform as the sole x/y coordinate is the correct raster model; it avoids the coord-array/transform disagreement class of rioxarray bugs. |
| 1. Coordinate model (time/band) | BEHIND (structural, bounded fix) | `t` is a bare size. Slice dates exist as list names in `LazyDataset` and are dropped at `lazy_stack()`. No label selection, no dt for scans, no labelled output. |
| 2. Alignment semantics (spatial) | DIFFERENT-BY-DESIGN | Exact-equality + explicit `align()` is a defensible EO stance; error surface is BEHIND cosmetically (no diagnosis of what differs). |
| 2. Alignment semantics (temporal) | BEHIND | Dataset-dataset combination pairs slices by name only when one side's names are a superset, else positionally; no label inner-join. |
| 3. groupby / time operations | DIFFERENT-BY-DESIGN, partially BEHIND | `group_by_time()` covers the EO compositing core; no data-value groupby, no rolling temporal windows, no upsampling/gap interpolation. |
| 4. API ergonomics | MIXED | Masking and lazy reprojection AHEAD; operator/Math coverage and selection verbs BEHIND (cosmetic); temporal fill BEHIND (scan_over is the right primitive, unexposed). |
| 5. Ecosystem interop | BEHIND on paper, adequate in scope | No NetCDF/Zarr; GDAL reach plus `gis`-attributed arrays and GeoTIFF sinks cover the stated COG-first scope. |

## What dims and coords are in garry (ground truth)

`GridSpec` (`R/grid.R:137`) is `crs` (canonical WKT), `transform` (GDAL
geotransform, north-up, unrotated), `extent`, `dims`, `dtype`. `dims` is a
named integer vector: first two entries `x`, `y`, optional extras `t`, `band`
(`.dim_names`, `R/grid.R:123`). Dims are sizes only. There are no coordinate
arrays anywhere in the model:

- x/y coordinates are implicit in `transform` + `extent`, with a validator
  enforcing coherence (`R/grid.R:186-195`).
- Time labels exist only as the names of each band's slice list in
  `LazyDataset` (`ds@bands[[a]]`, named by slice date strings from
  `stac_time_slices()`). `lazy_stack(unname(b))` (`R/dataset.R:218`, 298)
  strips them, so a `(t, y, x)` `LazyRaster` carries no time identity at all.
- Band names live in `names(ds@bands)`; `collect()` captures them before
  `stack_bands()` collapses the band axis and writes them as GDAL band
  descriptions (`R/collect.R:41-44`). A bare `(band, y, x)` `LazyRaster` has
  no band names.

xarray's model, for contrast: dims are named axes; coordinates are optional
label arrays; a 1-D coordinate whose name matches its dimension becomes a
dimension coordinate backed by a `pandas.Index`, which is what powers `.sel`,
label alignment, groupby and resample. Dims without coordinates are legal in
xarray too; garry's non-spatial axes are permanently in that state.

## Axis 1: the coordinate model

### Spatial: sizes-plus-transform is the better raster model

xarray (with rioxarray) materialises x/y as explicit coordinate arrays of
pixel-centre positions, plus a `spatial_ref` scalar coordinate holding CRS WKT
and a transform stored in attrs/encoding. rioxarray's own docs warn that
"operations on xarray objects can cause data loss" and that CRS must be written
into a coordinate to survive; the coord-array representation additionally admits
float drift between the coords and the transform, and the well-known
`reproject`-then-compare pitfalls. garry stores the affine transform as the
single source of truth and validates extent/dims/transform coherence at
construction. For regular grids (garry's declared scope; rotated grids are
rejected) nothing is lost: any x/y coordinate is derivable on demand.

What garry genuinely loses spatially: no `.sel(x=slice(...))` window/crop verb.
The idiom is "construct the analysis `GridSpec`, everything reads onto it",
which covers the common case at source but has no answer for cropping an
existing lazy pipeline without a `WarpNode`. A `crop(x, extent)` that
produces a snapped sub-grid (pure windowing, no warp, since the sub-grid shares
the transform) would be cheap: it is a grid recomputation plus a windowed read
plan, not a new IR node class. Cosmetic gap.

### Time and band: the real structural gap

Consequences of `t` being a bare size, with evidence:

1. No label selection. There is no `.sel(time="2023-06")` analog at any layer.
   Filtering happens before construction (STAC table filters) or via
   `group_by_time()`. Once a stack exists, slices are addressable only by
   position, and nothing user-facing addresses them at all.
2. Labels die at the dataset/raster boundary. `ds[["B04"]]` returns a
   `(t, y, x)` stack whose slice dates are gone (`R/dataset.R:218`). Any
   downstream consumer (a custom reducer fitting a harmonic model, a Kalman
   `scan_over()` needing irregular time steps) must carry the dates out of
   band. The hutan SI pipeline does exactly this today.
3. Time resampling correctness rests on string conventions. `group_by_time()`
   groups by prefixes of the slice NAME (`.time_group`, `R/dataset.R:353`),
   which works only because `stac_time_slices()` named them `YYYY-MM-DD`.
   `as_dataset()` accepts unnamed lists, silently producing objects on which
   `group_by_time()` aborts ("are the band slices named by date?"). The
   contract is implicit.
4. Unreduced multi-temporal output is unlabelled. `collect()` on a stack
   returns `(y, x, band)` with a `gis` attribute but no per-layer time labels;
   only dataset band names survive as descriptions.
5. Scans are spacing-blind. `ScanNode` knows `over` and `direction` but not
   the axis labels, so an irregular-Δt smoother cannot be expressed against
   the object; Δt must be closed over in the body by the user.

What garry gains: `grid_equal()` is a string compare plus eight float
comparisons; planning never inspects, realigns, or propagates coordinate
arrays; there is no index machinery to keep consistent across the IR, the
planner, and the daemons; StackNode/ReduceNode grid algebra is a few lines
(`.reduce_grid`, `R/generics.R:103`). This is real: xarray's index/alignment
subsystem is one of its largest and most bug-prone components, and garry's
planner correctness argument leans on grid identity being trivial.

### Recommendation (highest-value change in this review)

Add an optional `labels` property to `GridSpec`: a named list of character
vectors, one entry per non-spatial dim, length-checked against `dims` by the
validator (e.g. `labels = list(t = c("2023-01-04", ...), band = c("B04",
...))`). Labels are metadata, not data: no planner pass reads them, so
planning simplicity is preserved. Wire-through is bounded and mechanical:

- `lazy_stack()` keeps the slice names it currently strips; `StackNode`'s
  `output_grid` copies them (`R/generics.R:64`).
- `ScanNode`/`MapNode`/`FocalNode` `output_grid` already return the parent
  grid unchanged, so labels flow for free; `ReduceNode` drops the reduced
  entry, which `.reduce_grid` already does for the dim.
- `collect()` writes `t` labels as band descriptions for unreduced stacks
  (the `band_names` plumbing exists, `R/executor.R:457`).

That unlocks, in rough order of cost: labelled output (free once carried);
`time_sel(x, "2023-06")`/`band_sel()` label selection on a `LazyRaster`
(a slice-selecting node or a StackNode rewrite; modest); `group_by_time()` on
a bare cube, removing the dataset-layer-only restriction; and Δt-aware scan
bodies (`fn(xs, margin, labels)`). Estimated cost of the base carry:
GridSpec + one validator clause + three `output_grid` methods + two
`unname()` deletions; no scheduler changes.

## Axis 2: alignment semantics

xarray auto-aligns on coordinate labels: binary ops take the intersection of
labels by default (configurable to outer), `merge` takes the union with NaN
fill, `join="exact"` opts into strictness. Misaligned inputs therefore never
error by default; they silently shrink (arithmetic) or NaN-pad (merge). For EO
this is a documented footgun: two rasters a half-pixel apart have disjoint
float coordinates, and xarray arithmetic returns an empty or near-empty
intersection with no warning, which is why rioxarray grew `reproject_match`.

garry takes the opposite stance (decisions D8 and the `align()` contract):
binary ops require `grid_equal()` (tolerance 1e-9) and never resample;
`align()` injects an explicit `WarpNode`; sub-pixel-shifted "near misses" warp
rather than paste (`R/lazy_raster.R:571-577`). This is the right default for a
pixel-integrity-first engine and should be kept.

Tested behaviour on mismatched inputs (shifted extent, different res,
sub-pixel shift; run against the loaded package):

```
a + b            -> Error: grids differ; use `align(a, b, to = ...)` first
lazy_stack(...)  -> Error: layer 2 is not on the same grid; `align()` it first
lazy_map(...)    -> Error: input 2 is not on the same grid; `align()` it first
```

The errors are consistent and prescriptive but undiagnostic: they never say
WHAT differs. A user with a 1e-7-degree extent drift, a res mismatch, and a
CRS variant gets the same message. Cosmetic fix, high leverage: a
`grid_diff(a, b)` helper reporting the first differing component
(crs / res / extent offset in pixels / dims) and embedding it in the abort,
e.g. "extents differ by 0.31 px in x; align(b, to = a) will warp". This turns
garry's strictness from a wall into a guardrail.

Temporal alignment is the weaker half. `.ds_align_slices()`
(`R/dataset.R:525`) pairs value layers with mask layers (and dataset with
dataset in arithmetic) by name only when every left name appears on the right;
otherwise it falls back to positional pairing and aborts on count mismatch.
Two datasets whose date coverage differs by one slice therefore error
("slices do not align") instead of inner-joining on dates, and two unnamed
equal-length datasets pair positionally with no check that the dates
correspond. xarray would inner-join by label. Recommendation: when both sides
are named, pair on the name intersection and report dropped slices; add a
`join = c("inner", "exact")` argument defaulting to `"exact"` to preserve
current strictness where wanted. Small, contained in `.ds_align_slices()`.

## Axis 3: groupby and time operations

xarray: `resample(time="6h"|"10D"|"MS")` with the full pandas frequency
grammar, up- and down-sampling (`ffill`, `interpolate`), `groupby("time.month")`
and any `.dt` component, `SeasonGrouper`/`SeasonResampler`, and general
groupby over arbitrary variables (the basis of zonal statistics).

garry: `group_by_time(by = year/quarter/month/week/day | function)`
(`R/dataset.R:393`) partitions a dataset's slices; a following
`reduce_over(over = "t")` composites per group; `collect()` fans out per group
including `{group}` path templating. Assessment:

- The EO compositing core (calendar-period composites from daily slices) is
  fully covered, including ISO weeks and ragged bands (a band absent from a
  group simply drops out). The function escape hatch covers custom epochs:
  a 16-day NBAR-style bin is `by = \(s) sprintf(...)` over the date string,
  since the function receives the slice name. This deserves a documented
  example; users coming from `resample(time="16D")` will not guess it.
- `solar_day` slicing at STAC ingest (`R/stac.R:323`, the odc-stac rule) is
  MORE correct for EO than xarray's naive-UTC resample, which splits
  antimeridian-adjacent overpasses. Worth advertising.
- Missing relative to xarray, in decreasing order of EO relevance:
  (a) rolling/overlapping temporal windows (moving composites); (b) gap
  filling and upsampling (`interpolate_na`, `ffill` along t); (c) groupby over
  data values (zonal stats by a classification layer); (d) sub-daily grouping.
  (a) and (b) are expressible on the existing IR: a temporal rolling mean is a
  `scan_over()` body (EWMA today) or a strided reuse of slices across groups;
  `ffill`/`bfill` are one-line forward/backward `g_scan` carries, and
  `interpolate_na` along t is a bidirectional scan. These should ship as named
  helpers (`fill_gaps(ds, method = "ffill"|"linear")`) rather than remaining
  folklore. (c) is a genuinely new capability (data-dependent grouping breaks
  the static chunk table) and should stay out of scope until a concrete user
  appears.
- `group_by_time()` exists only on `LazyDataset`, a direct casualty of the
  Axis 1 label gap; the GridSpec-labels change lifts it to `LazyRaster`.

## Axis 4: API ergonomics for the EO scientist

Method coverage matrix (garry vs xarray+rioxarray):

| Operation | xarray | garry | Gap class |
|---|---|---|---|
| Arithmetic `+ - * /` | full, auto-broadcast | LazyRaster + LazyDataset, scalar both sides (`R/lazy_raster.R:243`, `R/dataset.R:626`) | par |
| Comparison `> < == !=`, `^`, `%%`| full Ops group | NOT registered; requires `lazy_map(x, fn = \(v) v > 5)` | BEHIND, cosmetic |
| Math (`log`, `sqrt`, `abs`, ...) | full ufunc surface | via `lazy_map` + `g_*` vocabulary only | BEHIND, cosmetic |
| Reductions over named dims | sum/mean/median/quantile/std/min/max/... `dim=` | `reduce_over()` with 12 named ops + custom anvl reducer over t/band (`R/node.R:15`) | par; custom-reducer path (per-pixel fits, `band_project`) is AHEAD |
| Rolling spatial | `.rolling` on any dim | `focal()` arbitrary anvl fn + differentiable `focal_kernel()`; boundary "nodata" only | par (boundary policies pending) |
| Rolling temporal | `.rolling(time=...)` | none exposed; `scan_over()` covers recursive filters | BEHIND, expressible today |
| Masking / QA | `.where(cond)` | `mask(where = values | qa_bits() | fn, open=, dilate=)` with shared-subgraph dedup and morphology | AHEAD for EO; no bare `.where` verb on LazyRaster (use `lazy_map` + `g_ifelse`) |
| Fill / interpolate NA | `fillna`, `ffill`, `interpolate_na` | none | BEHIND, cheap via scan (see Axis 3) |
| Selection by label | `.sel`, partial datetime strings | band: `ds[["B04"]]`, `ds[c(...)]`; time: none; space: none | BEHIND (time structural, space cosmetic) |
| Selection by index | `.isel` | none | BEHIND, cosmetic |
| Reprojection | rioxarray `rio.reproject` (eager) | `align()` lazy WarpNode + per-band warp-on-read resampling in `lazy_dataset()` | AHEAD (lazy, planned, QA forced to "near") |
| Grouped time reduce | `resample`/`groupby` | `group_by_time()` + `reduce_over` | par for compositing, see Axis 3 |
| Autodiff | none | `focal_kernel` + gradient path | AHEAD (out of xarray's scope) |
| Plot/inspect | `.plot`, rich repr | `print` cards, `draw()` IR, `preview()` overview-resolution run | par; `preview()` is a genuinely good idea xarray lacks |

The two cheap wins are the missing Ops/Math group generics (each is a
one-line `MapNode` registration; comparisons need a `pred`/`f32` dtype rule
already present in `dtype_promote`) and `where()`/`clamp()` sugar. Neither
touches the planner. The absence of `==`/`>` today pushes users into
`lazy_map` for the single most common masking idiom in map algebra.

## Axis 5: ecosystem interop

xarray's gravity is NetCDF (self-described, groups) and Zarr (cloud-chunked,
consolidated metadata, region writes), plus GRIB/kerchunk/OPeNDAP through the
backend plugin system. garry reads what GDAL reads (COG, GTI mosaics, VSI
remote) and writes GeoTIFF; in-memory results are base arrays with a
`read_ds()`-style `gis` attribute (`R/collect.R:142`). terra appears only in
Suggests; there is no `as_terra()`/`as_stars()` helper.

For the stated scope (STAC COG in, analysis-ready composite out) the absence
of NetCDF/Zarr costs little today: the EO archive garry targets is
COG-over-HTTP, and GDAL's NetCDF and Zarr drivers give a read path for free if
a source demands it (untested in garry; worth one smoke test). It matters at
two boundaries:

1. Intermediate/checkpoint storage. Once pipelines grow (SI tail, grouped
   outputs), a chunk-aligned intermediate store beats a directory of GeoTIFFs;
   GDAL's Zarr driver or a thin native writer would slot in at the sink layer
   without touching the IR.
2. Hand-off to collaborators in the Python stack. A one-call
   `as_terra()`/`write_zarr()` matters more for adoption than for capability.
   The `gis` attribute makes `as_terra()` nearly free (terra::rast on the
   array + ext/crs); recommend adding it.

Multi-dimensional non-EO data (climate model output, ensembles, groups) is
firmly xarray's territory and should be declared out of scope rather than
chased: garry's 4-dim `(x, y, t, band)` vocabulary is a feature, not a
limitation, for its domain.

## Ranked recommendations

1. GridSpec `labels` for t/band (structural; bounded cost, detailed under
   Axis 1). Unlocks labelled output, label selection, cube-level
   group_by_time, Δt-aware scans. Everything else temporal builds on it.
2. `grid_diff()` embedded in every "grids differ" abort (cosmetic; small).
   Directly addresses the main day-one friction of the strict-alignment
   stance.
3. Register the remaining Ops (comparisons, `^`) and Math group generics on
   LazyRaster/LazyDataset (cosmetic; mechanical).
4. Name-based inner join with reporting in `.ds_align_slices()` plus
   `join =` argument (small; fixes the positional-pairing hazard in
   dataset-dataset arithmetic and value/mask pairing).
5. `fill_gaps()` / `ffill` / temporal rolling helpers as documented
   `scan_over()` bodies (cheap; closes the most-asked xarray gap that the IR
   already supports).
6. `crop(x, extent)` windowing without a warp (small; grid algebra only).
7. `as_terra()` using the existing `gis` attribute; consider a Zarr sink via
   GDAL later (interop; low cost, adoption-weighted).

Not recommended: coordinate arrays on x/y (the affine model is strictly
better in scope), automatic alignment of any kind (D8 is correct for EO),
data-value groupby and NetCDF-group data models (out of scope until a
concrete workload demands them).
