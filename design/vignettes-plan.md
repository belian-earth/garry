# Vignette plan: the tutorial arc

Three tutorial vignettes forming a graded on-ramp, ending where the existing
case studies (`hls-harmonized-pca`, `aef-embeddings`) begin. Reading order:
Get started -> STAC composite -> Time series -> case studies.

All three are prerendered with the existing `precompute.R` pattern
(`.Rmd.orig` is the live source, knitted locally to a static `.Rmd`, figures
rewritten to GitHub raw URLs). Vignette 1 could evaluate live, but it reads a
remote file over `/vsicurl`, and R CMD check runs on five platforms whose
network access we do not want on the critical path; prerendering keeps CI
hermetic and the pattern uniform.

## 1. Getting started with garry (`garry.Rmd`)

The mental model. Named `garry.Rmd` so pkgdown places it in the *Get started*
nav slot.

**Data:** Mount Hood elevation (LANDFIRE, UTM 10N) from gdalraster's
sample-data, read directly over HTTP:
`/vsicurl/https://raw.githubusercontent.com/firelab/gdalraster/main/sample-data/lf_elev_220_mt_hood_utm.tif`.
Single small tile, no auth, no STAC machinery; real terrain makes the focal
examples legible.

**Sections:**

1. *What garry is.* One paragraph: lazy raster algebra; verbs build an IR
   graph, nothing computes until `collect()`; the closed primitive set
   (map / focal / reduce / scan / warp / stack); GDAL owns IO and warping,
   XLA (via anvl) owns compute.
2. *Open a raster lazily.* `el <- lazy_source(f)`; `print(el)` shows grid,
   CRS, dtype, and that zero pixels have been read. Accessors: `res()`,
   `xmin()` etc.
3. *Build a computation.* Arithmetic on the LazyRaster (rescale to km),
   `focal()` mean smooth, then the payoff: slope and aspect from central
   differences (radius-1 `focal()` with a shift-list fn using the `g_*`
   vocabulary), composed into a hillshade with `lazy_map()`. Each step is
   one more node; nothing runs.
4. *Look at the graph.* `draw(hs)` renders the IR tree; the graph is the
   object. `plan_lazy()` + `print` for stages/chunking if we want to show
   the planner (optional, keep light).
5. *Spatial semantics are strict.* Binary ops refuse mismatched grids; show
   the error deliberately and frame it as a feature. `align()` is the
   explicit, opt-in resample.
6. *Execute.* `preview(hs)` for the cheap decimated look;
   `collect(hs)` returns an array carrying the `gis` attribute (plot it);
   `collect(hs, path = ...)` streams a GeoTIFF; `as_terra()` for handoff.
7. *Scaling out.* Two sentences: this ran in-process; real workloads use
   `garry_daemons()` read/compute pools. Pointer to vignette 2.

**Figures:** grayscale elevation, smoothed elevation, hillshade (the money
shot), preview comparison.

## 2. From STAC to analysis-ready composite (`stac-composite.Rmd.orig`)

The flagship workflow, the README example expanded with the *why* at each
step. AOI: reuse the README/benchmark HLS area for continuity.

**Sections:**

1. *Discover.* `stac_query()` -> `stac_sign_mpc()` (what signing is, token
   caching) -> `stac_filter_cloud()`, `stac_filter_assets()`,
   `stac_drop_duplicates()`; filters compose on the items object.
2. *Frame.* `grid_from_bbox()`: why an equal-area grid derived from the AOI
   beats hand-picking an EPSG; resolution and snapping.
3. *Describe the data.* `lazy_dataset()`: the band table, `mask_asset`,
   nodata, per-band resampling. `qa_bits()` Fmask masking with
   morphological cleanup (opening + dilation as chained focal min/max).
4. *Compose.* `reduce_over("median", over = "t", nan_rm = TRUE)`; a derived
   NDVI band via dataset algebra ("just more graph"); `lazy_stack()` to a
   multiband output.
5. *Inspect before you commit.* `print()`, `draw()`, `preview()`; then
   `garry_daemons()` (what the read and compute pools do, machine-derived
   sizing) and `collect(path = ...)` streaming straight to GeoTIFF.
6. *Execution model.* Short closer: chunked, memory-bounded, warp-on-read,
   whole-graph fusion; rough performance framing (ODC parity per
   benchmarks/README).

**Figures:** item footprints over AOI, masked single date vs composite,
true-colour composite, NDVI.

## 3. NDVI time series: gap-filling and smoothing (`time-series.Rmd.orig`)

Modeled on the vrtility `ndvi-timeseries` article (West Texas agriculture,
whose structure worked well), redone with garry's scan primitive as the
temporal workhorse.

**Data:** HLS S30 (`hls2-s30`), AOI centred near (-102.2, 33.1), Dec 2023 to
Dec 2024, assets B04 / B08 / Fmask, cloud cover < 30%.

**Sections:**

1. *Acquire and mask.* Compressed recap of vignette 2's discovery/masking
   (cross-reference rather than repeat): `lazy_dataset()` + `qa_bits()`.
2. *A cloudy series.* NDVI per scene; plot the raw per-pixel series for a
   few sample pixels: ragged, gappy, spiky. This motivates everything after.
3. *Composite route.* `group_by_time()` monthly medians: one graph, twelve
   outputs; simple, robust, throws away sub-monthly dynamics.
4. *Smoothing route.* `kalman_smooth()` with `kalman_llt()` over the full
   masked series via the scan primitive (`scan_over`): gap-filled, smooth,
   keeps every acquisition date. Presented as a recipe (state-space model
   in two sentences, not theory). Compare sample-pixel series raw vs
   smoothed.
5. *Animate.* Animated GIF of the smoothed NDVI stack (gifski), Rocket
   palette, fixed scale: the phenology payoff mirroring the vrtility
   article's ending.
6. *Roll your own kernel.* Short section writing a custom temporal kernel
   with the `g_*` vocabulary inside `lazy_map()` (e.g. a QA-weighted mean),
   making the "closed primitive set, open composition" scope point
   concrete.

**Figures:** raw vs masked scene count map, sample-pixel series (raw /
monthly / kalman), smoothed map trio, final GIF.

**Follow-ups recorded, not in scope:**

- A Hampel filter verb (windowed median/MAD outlier knockdown over t) as a
  pre-smoothing step; the vrtility article used one and it composes
  naturally ahead of `kalman_smooth`. Candidate for ir-extensions once
  wanted.
- A footprint-erosion verb (`shrink_footprint(x, radius)` or similar).
  Diagnosed while building vignette 3: HLS granule data edges carry 1-2 px
  of corrupt radiometry (negative reflectance, Fmask-blind), which seeds
  line artifacts along every swath edge and survives per-pixel smoothing.
  The vignette spells it as a focal NaN-spread one-liner
  (`sh[[centre]] + 0 * Reduce("+", sh)`); a named verb would make the
  recipe discoverable and is standard practice (ODC pipelines buffer
  scene edges for the same reason).

## Mechanics

- `precompute.R` gains `prerender_it("garry.Rmd")`, `"stac-composite.Rmd"`,
  `"time-series.Rmd"`.
- `.Rbuildignore` already excludes `.Rmd.orig` and `figure/`; verify the new
  names are covered by the existing patterns.
- Add `_pkgdown.yml` with an `articles` menu ordering: Get started, STAC
  composite, Time series, then case studies.
- Delivery order: vignette 1 first (this branch), then 3 (kalman is the
  differentiator), then 2 (largest, but much of its content exists in the
  README and case studies to crib from).
