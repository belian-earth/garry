# Phase 12c: raw-f32 store

Goal: eliminate the R-double carrier between GDAL, the inter-stage
store, and the device. Store values for float32 stages become raw
byte payloads; uploads and downloads become memcpys. Projected from
the 12b profiles and the upstream session measurements: fleet peak
-2 to -3 GB, per-hop conversions and transposes gone, wall toward
the ~15 s fetch floor (ODC CPU parity). The nan_rm median kernel is
independently 2.3x from the anvl selection fast path and needs no
garry change.

## Dependencies and fallback

Requires the locally patched anvl/pjrt builds (branches in
~/belian/{anvl,pjrt}; see design/anvl-upstream-proposal.md). These
are unreviewed and unpublished: garry MUST keep working against
released anvl. So the raw path is capability-detected at run time
(`.g_has_raw_upload()`: one memoised probe upload) behind
`options(garry.store_values = "auto" | "raw" | "double")`, default
`auto`. CI without the patches exercises the double path unchanged;
raw tests skip.

## Decisions (12c)

- D19 store payload: raw f32, ROW-major `[y, x]` element order.
  Row-major matches both ends: GDAL RasterIO buffers are row-major
  (today's `matrix(byrow = TRUE)` transposes them; the raw path
  skips that) and XLA's default layout is row-major (column-major
  payloads pay one relayout copy per upload, measured +244 MiB
  transient and ~0.1 s per 256 MB). Downloads use
  `as_raw(row_major = TRUE)`. GDAL sink writes take row-major
  vectors, so the sink's `t()` disappears too.
- D20 self-describing values: payloads carry `gdim` (dims, `[nr,
  nc]`) and `gdt` (dtype) attributes. mori preserves attributes on
  shared raw elements (verified); RDS trivially. Task metadata is
  unchanged.
- D21 scope: f32 payloads only. Non-f32 store values (none on the
  benchmark's hot path after 12b fusion) and the unsigned-carrier
  upload of in-fuse Fmask windows keep the double path. Halo-padded
  fused reads (mask chains, H > 0) keep the matrix path up to the
  kernel; only the kernel's f32 OUTPUT converts, via as_raw, so the
  double download disappears there as well.
- Single-upload median stacking stays deferred: with raw values the
  110 per-plane uploads are memcpys (0.08 s/chunk measured for the
  marshalling today); re-profile after this phase and only then
  touch the reduce-stage input contract.

## Data flow after 12c (f32 band path)

GDAL read (row-major buffer) -> nodata NaN on the numeric vector ->
writeBin f32 -> raw store value (split producer-side by byte-matrix
slicing) -> mori/RDS -> compute daemon extracts element ->
`nv_array(raw, "f32", shape, byrow = TRUE)` (one memcpy) -> kernel
-> `as_raw(out, row_major = TRUE)` -> raw store value -> sink
readBin -> row-major vector -> `ds$write` (no transpose anywhere).

## Implementation map

- ops.R (sole anvl surface): `.g_has_raw_upload()` probe;
  `g_upload_raw(bytes, dtype, dim, device)`;
  `g_download_raw(x)` returning gdim/gdt-tagged raw.
- executor.R: store-value helpers `.sv_is`, `.sv_from_vec` (numeric
  row-major vector -> f32 payload), `.sv_slice` (byte-matrix window),
  `.sv_trim`, `.sv_to_matrix` (readBin -> `[y, x]` matrix),
  `.sv_upload` (dispatch raw/matrix), `.sv_download_exports`
  (f32 exports -> raw, others -> R arrays).
- gdal_adapter.R: `gdal_read_window(..., out = "raw")` variant
  returning the row-major payload without the `matrix(byrow)`
  transpose; `gdal_write_window` accepts raw store values and skips
  `t()`.
- scheduler.R task bodies: source/split/shm producers emit raw
  values on the f32 path; compute bodies upload via `.sv_upload`;
  downloads via `.sv_download_exports`; sink harvest converts via
  `.sv_to_matrix` (or writes the vector directly).
- tests: test-raw-store.R — helper equivalences vs the matrix path,
  round trips, and plan-level equivalence raw vs double store values
  across rds and mori stores; skips without the patched anvl.

## Gates

1. Full suite green with and without the patched anvl on the lib
   path (double fallback intact).
2. Plan equivalence: identical outputs (bit-level for f32) between
   `store_values = "raw"` and `"double"` on offline pipelines
   covering map, focal-fused reads, stack + median, and sinks.
3. Benchmark re-run same-sitting vs ODC: expect fleet peak drop and
   wall movement toward the fetch floor; record in this doc.
