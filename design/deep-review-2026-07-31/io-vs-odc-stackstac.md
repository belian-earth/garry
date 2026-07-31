# IO layer review: garry vs odc-stac, stackstac, rioxarray/rasterio

Date: 2026-07-30 (deep review 2026-07-31 series). Branch: placement-pass.

Scope: garry's IO layer (STAC discovery -> source table -> GTI mosaics,
fetch/assemble split, warp-on-read, multi-band coalescing, handle cache,
lazy_cog/cptkirk, failure handling) reviewed against odc-stac 0.5.2
(odc-loader main), stackstac 0.5.1, and rioxarray/rasterio + GDAL cloud
best practice. External facts were verified against current docs and
source on 2026-07-30; garry facts are file:line on this branch. Prior
internal ground truth: design/phase10-odc-gaps.md (source deep-dive
pinned to odc-stac 9ebd9cd / stackstac 3857190, 2026-07-08),
design/phase12-fetch-assemble.md (measured spike + ship),
benchmarks/README.md (same-sitting A/B results).

Verdict shorthand: AHEAD (garry stronger, with evidence), BEHIND (real
gap, sized), DIFFERENT-BY-DESIGN (deliberate divergence, trade-off
stated), PARITY.

## Summary table

| Area | Verdict | One-line basis |
|---|---|---|
| Request shaping, scheduler path | AHEAD-to-PARITY | fetch/assemble = many tiny srcwin fetches; 616 MB in 12.2 s at 50.3 MB/s vs ~20 MB/s whole-slice (phase12 spike) |
| Request shaping, gdal-direct path | DIFFERENT-BY-DESIGN | whole-slice warp per task; wins wall (15.6 vs 15.7 s ODC) but higher run-to-run variance |
| Retry/backoff | BEHIND (moderate) | GDAL-level retry configured, but single task attempt; no re-dispatch, retry-code list drops 504 |
| Failure net | PARITY defaults, BEHIND observability | read_fail="error" == odc fail_on_error=True; "nodata" holes only warn per event |
| Grid/CRS semantics | DIFFERENT-BY-DESIGN (+1 gap) | explicit analysis grid vs metadata-derived; no proj-extension native-grid helper |
| Overview use | AHEAD-to-PARITY | GTI overview selection regression-gated by test; fetch decimation via -outsize |
| Auth/signing | AHEAD (MPC), BEHIND (expiry) | collection-token cache beats per-item signing; no mid-run re-sign |
| Caching | AHEAD | LRU handle cache (odc-loader's is a TODO), capped GDAL_CACHEMAX, tmpfs fetch cache; one footgun: ALLOWED_EXTENSIONS=.tif |

## 1. Request shaping

### What the references do

stackstac materialises one dask task per (item, asset, spatial chunk),
chunksize default 1024 px; each task opens the asset lazily (per-thread
re-open for GTiff, `sharing=False`), wraps it in a `WarpedVRT` when the
native grid differs, and reads one window (stackstac/to_dask.py,
rio_reader.py; stack docstring). GDAL range merging is enabled
(`GDAL_HTTP_MULTIRANGE=YES`, `GDAL_HTTP_MERGE_CONSECUTIVE_RANGES=YES` in
`DEFAULT_GDAL_ENV`). odc-stac partitions the output geobox into
`GeoboxTiles` and maps each (t, y, x) chunk to its contributing items;
each read is a per-item rasterio windowed read (paste when pixel-aligned
within `ttol`, else `rasterio.warp.reproject`) into the destination
slice (odc-loader `_rio.py`), on a thread pool or dask. Both are
many-small-requests architectures; neither has a fetch/assemble split.

### What garry does

Two regimes, selected by route:

- Staged scheduler (fetch mode "auto", R/options.R:113): remote GTI
  sources split into per item-asset fetch tasks — plain
  `gdal_translate -srcwin` of the AOI-intersecting window (+8 px warp
  margin) to uncompressed tmpfs GTiffs (R/gdal_adapter.R:555-591),
  dispatched at priority 1 so the read fleet downloads flat-out before
  taking assembles (R/scheduler.R:864, design/phase12-fetch-assemble.md
  "Saturation follow-up"); assembly is the ordinary GTI warped read
  over a location-rewritten local index (R/scheduler.R:818-876).
- gdal-direct (composite_direct=TRUE default, R/options.R:123): one
  `gdalwarp` per slice straight into an f32 MEM:::DATAPOINTER buffer
  (R/composite_direct.R:289-309, R/gdal_adapter.R:418-439) — few large
  whole-slice reads, parallel across the read pool (~220 tasks on the
  HLS benchmark), no local staging.

### Evidence by link regime

Measured (design/phase12-fetch-assemble.md, fast link, 2026-07-08):

- Whole-slice remote warped reads are 74% network wait; fleet ~20 MB/s
  of 60+ available; p90 per-slice tail ~12 s.
- Fetch/assemble: 392 windows, 616 MB in 12.2 s sustained 50.3 MB/s
  with 16 workers; per-fetch med 0.36 s, p90 0.75 s; RX byte parity
  1.02x with the remote-GTI path; bit-identical output.
- Slow link: both regimes are bandwidth-bound; the split preserves
  parity with at-least-equal parallelism (design argument, ibid.).

Measured (benchmarks/README.md, 2026-07-14): the gdal-direct routes put
garry at parity-to-ahead of ODC+dask same-sitting (median composite
15.63 s vs 15.72 s; NDVI 11.97 s vs 12.64 s, garry won 4/4 reps), but
"garry's run-to-run variance is higher than ODC's (whole-slice warp
reads vs ODC's fine-window threaded reads)" (README:93-96).

### Verdict

- Scheduler path: AHEAD-to-PARITY. The fetch/assemble split reproduces
  the many-small-requests property that makes stackstac/odc saturate
  links, adds byte parity, priority separation, and a tmpfs refcounted
  cache — none of which the references have (they rely on dask/thread
  scheduling alone). Task-shaping is deliberate (uniform ~0.3 s units)
  where stackstac's is emergent from chunking.
- gdal-direct path: DIFFERENT-BY-DESIGN. Few-large-windows re-couples
  fetch latency to whole slices — exactly the regime phase 12 measured
  as 74% wait — but wins overall because slice-level pool parallelism
  covers it and per-task overhead is near zero. The cost is the
  documented higher variance and a long-tail exposure (one cold object
  stalls one slice's whole warp; under read_fail="nodata" a slow-but-
  alive object cannot be salvaged part-way). Recommendation R6 below:
  a benchmark-gated option to route gdal-direct's item reads through
  the srcwin fetch cache on links where the variance dominates.

## 2. Robustness: retries, backoff, rate limits, failure nets

### Ground truth

- odc-stac: no application-level retry. `configure_rio(cloud_defaults=
  True)` sets exactly `GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR`,
  `GDAL_HTTP_MAX_RETRY=10`, `GDAL_HTTP_RETRY_DELAY=0.5` (odc-loader
  `_rio.py` GDAL_CLOUD_DEFAULTS), delegating retry entirely to GDAL
  with GDAL's default retry-code set. `fail_on_error` defaults to
  True (raise); False logs "Ignoring read failure" and returns an
  empty array (pixels stay nodata).
- stackstac: no retry logic anywhere and no GDAL retry env — a user
  must supply `gdal_env` or rely on dask task retries.
  `errors_as_nodata` defaults to matching only
  `RasterioIOError("HTTP response code: 404")`; matching errors are
  warned and filled, everything else propagates.
- GDAL (see section refs at end): retries apply to HTTP range requests
  within a single open/RasterIO; `GDAL_HTTP_MAX_RETRY` default 0;
  retry delay grows exponentially from `GDAL_HTTP_RETRY_DELAY`
  (default 30 s); the default retriable set is 429/502/503/504 plus
  certain transient curl errors; `GDAL_HTTP_RETRY_CODES=ALL` widens to
  all 4xx/5xx (GDAL >= 3.10).

### garry

- GDAL-level: `garry_gdal_config()` sets `GDAL_HTTP_MAX_RETRY=10`,
  `GDAL_HTTP_RETRY_DELAY=0.5`, `GDAL_HTTP_RETRY_CODES=429,500,502,503`,
  `GDAL_HTTP_TIMEOUT=60`, `GDAL_HTTP_CONNECTTIMEOUT=10`
  (R/gdal_adapter.R:466-471) — odc's cadence plus the timeouts odc
  omits (design/phase10-odc-gaps.md item 5). Applied on every read
  daemon (R/scheduler.R:678-689, R/composite_direct.R:383-390).
- Task-level: exactly one attempt everywhere. A fetch that errors
  after GDAL's internal retries either aborts the plan
  (read_fail="error", the default, R/options.R:75) or writes a 16x16
  nodata placeholder and warns (.daemon_fetch_window,
  R/scheduler.R:233-249; gdal_nodata_window,
  R/gdal_adapter.R:604-618). gdal-direct warps write an all-NaN slice
  and carry the error into `$err`, enforced by the same contract
  (.cd_fetch_warp / .gd_fetch_fail, R/composite_direct.R:289-309,
  410-430). Assembles/reads fill NaN under the same option
  (R/executor.R:36-57).

### Assessment

- Default-failure semantics are at PARITY with odc (raise) and
  stricter than stackstac (which silently nodata-fills 404s by
  default — arguably a footgun garry rightly avoids).
- Retry posture is BEHIND in three specific, production-relevant ways:
  1. The explicit `GDAL_HTTP_RETRY_CODES` list drops 504 (in GDAL's
     default set) and gains 500. Overriding the default set narrows
     coverage as GDAL evolves; either add 504 or drop the override and
     keep only MAX_RETRY/DELAY like odc does. Severity: low-moderate
     (504s are common on object stores under load).
  2. No task-scoped retry: GDAL's retry covers per-request HTTP
     failures inside one operation, but a whole-operation failure
     (curl timeout after 60 s, TLS reset, transient DNS, a GTI open
     failing) is terminal for the task. stackstac users get this from
     dask task retries; garry's mirai tasks have no equivalent.
     Fetch tasks are ~0.3 s and idempotent — a cheap place to be more
     robust than both references. Severity: moderate; under
     read_fail="nodata" this is the difference between a transient
     blip and a silent hole in a composite.
  3. Rate-limit awareness is config-only (429 in the retry list).
     There is no concurrency backoff: a 24-fetcher fleet that trips a
     provider limiter retries 24-wide at 0.5 s cadence. odc/stackstac
     are no better; noted as a shared ceiling, not a gap.
- Failure observability is BEHIND odc slightly: holes are per-event
  `cli_warn`s scattered across daemons; a run that produced 3 holes in
  392 fetches ends successfully with no summary. odc logs centrally
  through Python logging; dask surfaces warning counts.

Recommendations R1-R3, R5 below.

## 3. Grid / CRS / resolution semantics

### Ground truth

- odc-stac: target geobox cascade geobox= > like= > explicit
  crs/resolution/bbox > auto-inference from the STAC proj extension
  (`proj:shape`/`proj:transform`/`proj:code`), picking the most common
  (CRS, resolution, anchor) tuple with a 10% histogram threshold;
  mixed UTM zones resolve to the most common zone, others warp into
  it. Snapping: edge anchor by default, `anchor`/`align` parameters.
  groupby="solar_day" uses one longitude (output-extent centroid) and
  snaps the solar offset to whole hours (`int(lon/15)*3600`,
  model.py:_convert_to_solar_time).
- stackstac: requires a single common `proj:epsg` across all assets
  (ValueError otherwise; no auto-pick); output resolution is the
  minimum across assets; bounds are the union; `snap_bounds=True`
  snaps outward to whole multiples of resolution. dtype default
  float64 + nan fill.
- rioxarray: no target-grid inference on open; `reproject`/
  `reproject_match` for explicit regridding.

### garry

- The analysis grid is always explicit and user-owned: `grid_spec()` /
  `grid_from_bbox()` (LAEA centred on the AOI by default — an
  analysis-first choice no reference makes; UTM/AEQD/conic options),
  extent snapped outward to whole multiples of res with integer dims
  (R/grid_from.R:41-52). Every slice mosaic is pinned to it via GTI
  open options SRS/RESX/RESY/MINX..MAXY (R/gdal_adapter.R:630-650);
  mixed per-tile CRS (HLS spans UTM zones) is reprojected per tile by
  the GTI driver, with the benign multi-operation PROJ notice muffled
  (R/gdal_adapter.R:60-70). One metadata probe per asset, not per
  slice (R/stac.R:519-525).
- Solar-day grouping: `stac_time_slices(granularity="solar_day")`
  shifts by `lon * 240 s` (continuous) with lon defaulting to the
  circular mean of footprint centres (R/stac.R:323-343).
- Paste-vs-warp: exact grid equality pastes; sub-pixel tolerance is
  deliberately rejected (odc pastes within ttol=0.9 px for nearest —
  a half-cell shift garry refuses; design/phase10-odc-gaps.md item 7).

### Assessment

- DIFFERENT-BY-DESIGN, and defensible: an explicit equal-area analysis
  grid is a better scientific default than inheriting the archive's
  storage grid, and the GTI pin makes every slice exactly congruent —
  stackstac cannot even load mixed-zone collections without a manual
  epsg choice.
- One real gap (BEHIND, low severity): no helper that derives a
  native GridSpec from STAC proj-extension metadata, so "load on the
  collection's native grid, zero warp" — odc's default and its
  cheapest read path — requires the user to hand-build the grid from
  one asset. Recommendation R7.
- One reproducibility footnote: garry's continuous solar offset and
  odc's whole-hour snap disagree for acquisitions within ~30 min of a
  local-hour boundary near slice edges; a cross-tool comparison can
  therefore group a scene differently. Worth one line in the
  stac_time_slices docs, not a code change (garry's rule is the more
  faithful one).

## 4. Overview / decimation use

- odc-stac: `use_overviews=True` hard-coded; `pick_overview` selects
  the largest overview factor <= the required shrink and reopens with
  `overview_level` (odc-loader `_reader.py:281-291`).
- stackstac: implicit via the per-asset `WarpedVRT`; docs demonstrate
  efficient 100 m loads from 10 m COGs.
- rioxarray: explicit `overview_level` on open; decimated reads via
  rasterio `out_shape`.
- garry: three covered paths. (a) GTI mosaic reads select the matching
  overview when the pinned grid is coarser — verified against GDAL
  3.13 and regression-gated in tests/testthat/test-gti.R:192-246 (a
  poked-overview fixture, so a GDAL upgrade cannot silently regress
  it; design/phase10-odc-gaps.md item 6). (b) The fetch path decimates
  with `-outsize` when the target res is >1.5x native, so only
  overview-level bytes cross the network (R/gdal_adapter.R:570-581),
  used by distributed preview() (R/preview.R:298-299). (c) warp-on-read
  goes through gdalwarp's standard overview selection.

Verdict: AHEAD-to-PARITY — parity of mechanism, ahead on having it
regression-gated; none of the references test overview selection
against driver upgrades. One latent assumption: the fetch decimation
ratio compares `out_res` to the source res assuming both metric
(comment at R/gdal_adapter.R:572-574); a degree-res source under a
metric target would mis-derive the factor. Cheap guard: skip
decimation when the source CRS is geographic and the target is not
(R8).

## 5. Auth / signing

- odc-stac: `patch_url=` hook (canonically `planetary_computer.sign`);
  token caching/refresh is the pc package's job. stackstac: nothing
  built in; users sign items pre-stack; an expired token's 404 can
  silently become nodata under the default `errors_as_nodata` — a
  documented-by-community trap garry does not share.
- garry: `stac_sign_mpc()` caches the collection-level SAS token in
  memory and on disk under `R_user_dir`, reusing it until
  `msft:expiry` — one signing request per collection vs
  `rstac::items_sign()`'s per-call requests, chosen after measuring
  per-URL GDAL signing (`VSICURL_PC_URL_SIGNING`) storm MPC's limiter
  into 429s across daemon fleets (R/stac.R:14-21, 57-138). cptkirk
  reads pre-signed SAS URLs natively (R/lazy_cog.R:26-31).

Verdict: AHEAD for the MPC path (deliberate, measured, cached).
BEHIND on token lifetime: hrefs are signed once at discovery, so a
run outliving the SAS token (the header itself says reserve per-URL
signing for >~45 min jobs) starts collecting 403s, which — 403 not
being retriable — become aborts or holes. odc inherits refresh from
the pc package (which re-signs per open via patch_url); garry has no
refresh point after `stac_sources()` freezes the URLs. Recommendation
R4. Non-MPC auth (S3 credentials, Earthdata) is delegated to the GDAL
environment in all three stacks: PARITY.

## 6. Caching layers

| Layer | garry | odc-stac | stackstac |
|---|---|---|---|
| Open-dataset handles | LRU cache, cap 4 host / 1 per read daemon, evicted handles closed (R/gdal_adapter.R:33-83, R/options.R:23,31) | none — literal `TODO: open file handle cache goes here` (odc-loader `_rio.py`); open/close per read | per-thread re-opens, cached for the dataset's life (`ThreadLocalRioDataset`) |
| GDAL block cache | capped `GDAL_CACHEMAX=256` MB/process (fleet-aware; R/options.R:38) | untouched (5% RAM per worker process) | untouched |
| HTTP/VSI | HTTP/2 multiplex, single-range header ingest (`GDAL_INGESTED_BYTES_AT_OPEN=32768`), readdir off | readdir off | multirange+merge, `VSI_CACHE=True` at open / `False` at read |
| Fetched bytes | tmpfs window cache, refcounted, eagerly unlinked per assembled slice (phase12; R/scheduler.R:813-815) | none | none |
| Tokens | MPC SAS memory+disk cache (R/stac.R:93-131) | delegated to pc package | none |
| Staging RAM guard | lazy_cog tmpfs-vs-disk fallback under `ck_stage_ram_fraction` (R/lazy_cog.R:352-380) | n/a | n/a |

Verdict: AHEAD across the board — the handle cache and the capped
block cache both exist precisely because of measured fleet OOMs
(benchmarks/README.md "Memory postmortem"), a failure mode the
single-process references never face and therefore never engineered
for. Two notes:

1. `CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif"`
   (R/gdal_adapter.R:475) is a session-global allowlist that makes
   vsicurl refuse non-.tif remote paths — `.tiff` (AEF tiles;
   currently saved by cptkirk owning that path), `.jp2` (Sentinel-2
   L1C mirrors), `.nc`, `.vrt` would all fail with an opaque error if
   they ever reach the GDAL reader. Neither reference sets it (they
   rely on `GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR` alone, which
   already suppresses the sidecar probing this option targets).
   Recommendation R3.
2. stackstac's `VSI_CACHE=True`-at-open trick exists to make its
   per-thread re-opens cheap; garry's handle cache solves the same
   problem structurally, so not adopting it is correct.

## 7. Multi-band and specialist read paths (context)

Not present in any reference as a distinct mechanism, listed for
completeness of the AHEAD ledger:

- Multi-band read coalescing: same-file single-band sources collapse
  to one multi-band SourceNode at plan time (`read_coalesce`,
  R/options.R:65), and the window read walks bands inside
  cache-sized row slabs so each interleaved block decompresses once
  (measured 31x on a 72-band 1-row-strip DEFLATE file;
  R/gdal_adapter.R:176-215). odc/stackstac read band-per-task and
  rely on the GDAL block cache getting lucky.
- lazy_cog/cptkirk: batched async-tiff COG reads, one open per tile,
  32-way range concurrency, native-dtype staging as
  VRTRawRasterBand over tmpfs (R/lazy_cog.R:247-288, 302-326) — a
  Rust read engine neither reference has an analogue of.

## Recommendations (sized for garry)

R1 (small, do first): task-scoped retry with exponential backoff.
Wrap the single attempt in `.daemon_fetch_window` and
`.cd_fetch_warp` (and the `gdal_read_window` catch in
`.exec_read_padded`) with `garry.read_retry = 2` attempts, delay
`0.5 * 2^k` s plus jitter, retrying on error before the
read_fail contract fires. Fetch tasks are idempotent and ~0.3 s, so
the cost of a retry is negligible against the cost of a hole or an
aborted 40 s run. ~25 lines plus one option and tests.

R2 (tiny): retry-code list. Add 504 to `GDAL_HTTP_RETRY_CODES` (or
drop the override entirely and keep GDAL's default set, which
already includes 429/502/503/504 plus transient curl errors; keep
the explicit list only if 500 has been observed from MPC).

R3 (tiny): widen or drop `CPL_VSIL_CURL_ALLOWED_EXTENSIONS`.
`.tif,.tiff,.TIF,.TIFF,.vrt,.jp2` at minimum, or rely on
EMPTY_DIR readdir suppression alone as odc/stackstac do.

R4 (medium): expiry-aware re-signing. Keep the unsigned href and the
token separately in the sources table (or record `msft:expiry`
alongside), and have fetch dispatch re-append a fresh cached token
when the stored one is within a margin of expiry —
`stac_sign_mpc()`'s cache already knows how to refresh; only the
dispatch-time hook is missing. Closes the >45 min-run failure mode
without per-URL signing storms.

R5 (small): hole accounting. Under read_fail="nodata", count failed
fetches/warps per run and emit one end-of-collect summary (n holes,
example locations) — and consider returning it as an attribute of
the collected result so pipelines can gate on it.

R6 (benchmark-gated): optional fetch/assemble routing for
gdal-direct. The variance note in benchmarks/README.md:93-96 is the
motivation; the srcwin fetch cache already exists. Try
`garry.gd_fetch = "auto"` mirroring the scheduler's mode, measure
same-sitting on a noisy link before adopting.

R7 (medium, discovery-side): `grid_from_stac(sources, ...)` deriving
a native GridSpec from proj-extension fields with odc's most-common
rule, so zero-warp native-grid loads are one call. Pure table code
in stac.R; no engine change.

R8 (tiny): guard the fetch decimation factor when the source CRS is
geographic and the target projected (skip `-outsize` rather than
mis-scale).

R9 (small): fix `gdal_nodata_window`'s hardcoded Int16/Byte-255
placeholder (R/gdal_adapter.R:604-618): take dtype from the source
entry (the .meta.rds sidecar carries it, or probe once per index) so
a placeholder in an f32 or u16-sentinel collection does not
introduce a dtype mismatch into the local mosaic.

## External references

- odc-stac load API and configure_rio:
  https://odc-stac.readthedocs.io/en/latest/_api/odc.stac.load.html,
  https://odc-stac.readthedocs.io/en/latest/_api/odc.stac.configure_rio.html;
  source: opendatacube/odc-stac@develop `odc/stac/{_stac_load.py,_mdtools.py,model.py}`,
  opendatacube/odc-loader@main `src/odc/loader/{_reader.py,_rio.py}`.
- stackstac: https://stackstac.readthedocs.io/en/latest/api/main/stackstac.stack.html;
  source: gjoseph92/stackstac@main `stackstac/{to_dask.py,prepare.py,rio_reader.py,rio_env.py}`.
- GDAL: /vsicurl/ and config-options documentation (gdal.org) for
  retry, caching and multiplexing options; see section 2 and the
  companion notes below.
