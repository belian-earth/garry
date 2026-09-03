# R package review: `garry`

## Scope and method

This review examined package metadata, exported API, core execution and raster source code, STAC helpers, daemon lifecycle code, option handling, tests, and CI-adjacent configuration. It also attempted an `R CMD check --no-manual --as-cran .` and ran the local `testthat` suite.

The package has a thoughtful architecture for lazy, spatially-aware raster computation. Its tests use deliberately asymmetric fixtures, and the distributed composite fast path has an explicit local-GTI equivalence suite. The concerns below focus on concrete failure modes, public API contracts, and maintainability rather than stylistic preferences.

## Summary of findings

| Priority | Finding | Risk |
|---|---|---|
| High | Package check cannot pass under the current R environment because required author metadata is not recognized | CRAN-style checks and release automation are blocked |
| High | Planetary Computer signing appends a second `?` to already-query-bearing URLs | Signed remote assets can become invalid |
| High | STAC source and coverage helpers accept malformed input or fail with generic errors | Public data-discovery APIs produce obscure failures or incorrect coverage values |
| Medium | Public argument validation is inconsistent; several paths use `stopifnot()` or weak coercion | Errors occur late and are hard for callers to handle |
| Medium | Route diagnostics are session-global mutable state | Route provenance is unreliable in concurrent/nested work |
| Medium | Supplying `grid` to `lazy_source()` can silently declare incorrect raster metadata | Incorrect geospatial output is possible without an early error |
| Low | Public namespace includes a large internal surface | Compatibility burden and accidental downstream coupling |
| Low | GDAL/GTI minimum-version messaging needs a single tested contract | User setup expectations can drift from actual support |

## Detailed findings

### 1. Package metadata blocks the attempted package check

**Priority:** High

Running `R CMD check --no-manual --as-cran .` stopped before code or tests with:

```text
Required fields missing or empty:
  ‘Author’ ‘Maintainer’
```

[`DESCRIPTION:4-5`](DESCRIPTION:4-5) provides only `Authors@R`, although this is normally sufficient for modern R package metadata. In the active R 4.6.1 environment, however, the check did not derive the required fields. This may be a change in the development R toolchain or a parsing/metadata edge case, but it is currently a release-blocking result.

**Recommendation:** Reproduce in a clean, supported R release and current R-devel environment. If this persists, add explicit `Author` and `Maintainer` fields generated from the same canonical author data, or adjust the `Authors@R` form to meet the newer checker’s expectations. Add a CI job that performs the same package check command used for releases.

### 2. `stac_sign_mpc()` mishandles URLs that already have query parameters

**Priority:** High

[`R/stac.R:103-107`](R/stac.R:103-107) obtains a SAS token and unconditionally constructs each asset URL as:

```r
paste0(a$href, "?", token)
```

If an asset URL already contains a query string, this produces a second question mark rather than joining query parameters with `&`. For example, `https://host/file.tif?foo=bar` becomes `https://host/file.tif?foo=bar?st=...`. Such a URL can invalidate or alter token interpretation.

**Recommendation:** Append the separator conditionally—`&` when a query string exists and `?` otherwise—or, preferably, parse and merge query components with a URL-aware utility. Add unit tests for unsigned plain URLs, URLs with an existing query, existing fragments, and re-signing behavior.

### 3. STAC helper validation is insufficient for a public ingestion boundary

**Priority:** High

[`stac_sources()`](R/stac.R:261) requires at least one feature through `stopifnot(length(feats) > 0L)` at [`R/stac.R:261-264`](R/stac.R:261-264). It subsequently indexes `ft$bbox[[1L]]` through `[[4L]]` at [`R/stac.R:280-283`](R/stac.R:280-283), assuming every item has a valid four-element bbox. Missing, non-numeric, or malformed bboxes lead to base indexing/coercion errors without identifying an item.

[`stac_filter_coverage()`](R/stac.R:324) similarly validates only vector length and range with `stopifnot()` at [`R/stac.R:324-330`](R/stac.R:324-330). It does not reject non-finite values, reversed extents, or zero-area AOIs. A zero-area bbox yields division by zero, and reversed bounds can yield nonsensical negative areas.

**Recommendation:** Create a shared internal validator for finite four-element bboxes satisfying `xmin < xmax` and `ymin < ymax`. Validate `min_coverage` as one finite scalar in `[0, 1]`; validate cloud-cover thresholds similarly. Use `cli::cli_abort()` with a stable error class and, for STAC items, include an item id or index in the message.

### 4. Input validation is inconsistent in several other public functions

**Priority:** Medium

The package often provides helpful `cli` errors, but several public entry points fall back to generic assertions or partial coercion:

- [`kalman_llt()`](R/scan_kalman.R:74) converts `robust_iters` using `as.integer()` at [`R/scan_kalman.R:96`](R/scan_kalman.R:96), but does not ensure a finite, scalar, non-negative integer. `robust_threshold` and `robust_inflation` are forced without checks at [`R/scan_kalman.R:97-99`](R/scan_kalman.R:97-99).
- [`write_tif()`](R/write_tif.R:83) permits `NA`, `NaN`, and infinite scale/offset because it checks only vector length and `scale == 0` at [`R/write_tif.R:101-107`](R/write_tif.R:101-107).
- `stac_sources()` and `stac_filter_coverage()` use `stopifnot()`, which yields errors that are not actionable or classed.

**Recommendation:** Apply a common scalar-validation policy at public API boundaries: type, length, missingness, finiteness, and meaningful range. Use a package error class hierarchy for input errors. Add tests for `NA`, `NaN`, `Inf`, fractional iteration counts, vectors, and invalid extents.

### 5. Execution-route provenance is held only in mutable global state

**Priority:** Medium

[`collect()`](R/collect.R:106) sets `.garry_state$route` during route selection at [`R/collect.R:121-130`](R/collect.R:121-130) and resets it for single-process execution at [`R/collect.R:160-168`](R/collect.R:160-168). [`garry_last_route()`](R/collect.R:224) returns only that session-global last value.

The explicit route test coverage is useful—see [`tests/testthat/test-composite-direct.R:11-64`](tests/testthat/test-composite-direct.R:11-64)—but the production diagnostic cannot be unambiguously associated with a specific output when multiple collections are interleaved, nested, or run by other package code in the same session.

**Recommendation:** Retain `garry_last_route()` as a convenience helper, but also expose route and execution diagnostics as metadata attached to an in-memory result or an explicit diagnostic/trace object returned on request. This would make reproducibility logs and route-specific tests less dependent on ambient state.

### 6. `lazy_source(grid = ...)` is a valuable but unsafe optimization path

**Priority:** Medium

The documentation clearly states that supplying `grid` skips metadata discovery and is “trusted, not checked” at [`R/lazy_raster.R:64-72`](R/lazy_raster.R:64-72). The implementation then validates only the class at [`R/lazy_raster.R:125-129`](R/lazy_raster.R:125-129). Grid geometry, CRS, dimensions, dtype, block geometry, and nodata compatibility are not checked against the eventual dataset.

This is an understandable performance escape hatch for remote mosaics. However, an incorrect caller declaration can lead to silently misaligned values or incorrect spatial metadata rather than a local, explainable failure.

**Recommendation:** Keep this fast path, but add `validate_grid = c("none", "metadata")`, defaulting to `"none"` for backward compatibility. The validating mode can open the source once and compare CRS, dimensions, transform, dtype, and selected band. Mark the unvalidated mode as advanced in the reference documentation and add mismatch tests.

### 7. The exported namespace makes internal execution machinery part of the compatibility surface

**Priority:** Low

[`NAMESPACE`](NAMESPACE) exports a broad mixture of primary user APIs and low-level machinery, including graph/planning types, daemon helpers, scheduler/executor entry points, and GDAL adapter functions. The pkgdown “internal” grouping does not prevent downstream code from importing or depending on those symbols.

**Recommendation:** Establish a documented supported API tier. Unexport functions that are not intended as extension points where feasible, and use internal registration/protocols for daemon execution. Where low-level exports are intentional, document their stability expectation and lifecycle.

### 8. Establish and test one GTI support contract

**Priority:** Low

[`DESCRIPTION:11`](DESCRIPTION:11) and the load-time diagnostic at [`R/zzz.R:9-18`](R/zzz.R:9-18) state that GTI requires GDAL 3.9. Other package documentation should be audited for identical wording and for whether a particular GTI feature actually requires a newer GDAL version.

**Recommendation:** Define the minimum version from the oldest GDAL release covered by integration tests, use that version consistently in metadata, runtime errors, docs, and CI matrices, and state which functions specifically depend on GTI.

## Verified strengths

The package includes several safeguards that materially improve confidence in raster correctness:

- The metadata transparently labels the project experimental ([`DESCRIPTION:6-9`](DESCRIPTION:6-9)).
- Test fixtures are designed to expose orientation errors rather than relying exclusively on symmetric data.
- The specialized default distributed composite route is explicitly checked against a single-threaded oracle, including both parallel modes, a halo/morphology variant, fallback routing, and GeoTIFF output ([`tests/testthat/test-composite-direct.R:1-65`](tests/testthat/test-composite-direct.R:1-65)).
- `collect()` exposes the selected route, which is useful for regression testing even though its transport should be improved.
- The load hook gives an early GDAL capability diagnostic rather than deferring a missing GTI failure to an unrelated read.

## Suggested remediation order

1. Resolve the `R CMD check --as-cran` metadata failure in the supported release toolchain and add CI coverage for it.
2. Correct URL query joining in `stac_sign_mpc()` and test pre-queried URLs.
3. Add structured STAC bbox and scalar argument validation.
4. Standardize validation/error classes for the remaining public APIs.
5. Make route provenance result-specific when diagnostics are requested.
6. Add an opt-in validation mode for declared source grids.
7. Document and narrow the stable API boundary over time.

## Validation record

`R CMD check --no-manual --as-cran .` was attempted on R 4.6.1 and stopped at DESCRIPTION metadata validation before executing package checks. The local test suite was launched with `testthat::test_local(reporter = "summary")`; its streamed contexts included `composite-direct`, `gd-general`, `mirai-equivalence`, route-matrix, scheduler failures, and broad grid/dtype tests, with no failure displayed in the returned output. Because the captured tool output was truncated and did not include the final testthat summary, this review does not claim an independently verified all-tests-passed result.
