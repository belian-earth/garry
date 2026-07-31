# f64 as a first-class store dtype

Status: scoped 2026-07-30, implementation on `placement-pass`.
Extends D19-D21 (the raw byte-payload store) from f32-only to
{f32, f64}. Companion to `placement-cost-pass.md` (the writer daemon
isolated the write-side conversion; this removes the store-side ones).

## Why

The IR already carries f64: `ScanNode@dtype` (the Kalman smoother's
whole state path is f64 by numerical necessity) and any
`lazy_map(dtype = "f64")`. But the raw store only accepts f32, so
every f64 chunk falls back to R doubles: `g_download` materialises a
double array on the producing daemon, mori shares it, consumers
convert it back on upload, `.sv_materialise` copies it again for
writes and combines. On the SI tail — whose compute is almost entirely
f64 scan stages — these are the largest per-task transients after the
kernel working sets themselves.

Raw f64 is the SAME 8 B/px as R doubles, so unlike f32 this buys no
residency. What it buys:

- **No conversion copies.** Download is one `as_raw` memcpy off the
  device (verified against anvl: `nv_array(raw, "f64", byrow = TRUE)`
  and `as_raw(x, row_major = TRUE)` both work, including on jitted
  outputs — no upstream change needed); upload is one memcpy back;
  producer-side window splitting uses the byte-matrix slicer instead
  of R array indexing.
- **Row-major transport.** Payloads reach the writer daemon in GDAL's
  write order; the single remaining conversion (gdalraster's write API
  takes R numeric vectors) happens once, on the writer, not per hop.
- **Honest store estimates.** f64 regions were priced at 4 B/px
  whenever the raw store was on (the estimate keyed on `use_raw`, not
  the region's dtype) — a latent 2x under-count of exactly the tail's
  regions. Estimates become dtype-aware.

## Scope

IN: the sv layer (`.sv_*`, executor.R) parameterised by the payload's
`gdt` attribute (which exists on every payload already, constant
"f32" until now); `g_download_raw` tagging the array's real dtype;
the raw-store dispatch gates (`.sv_download_exports`, `.apply_fuse`)
widening from `== "f32"` to `%in% c("f32", "f64")`; dtype-aware store
byte estimates in the scheduler; the write path's element-size
arithmetic.

OUT (deliberately):
- **Raw f64 reads.** Sources are f32/integer files in practice;
  `gdal_read_window(out = "raw_f32")` stays as is.
- **Integer dtypes.** Bitwise/exactness semantics differ (nodata
  sentinels, masks); float-only keeps the NaN-is-nodata contract (D8).
- **gdalraster raw writes.** Its API takes R vectors; the one
  conversion at the GDAL boundary remains, isolated on the writer
  daemon.
- The single-threaded executor stays all-doubles: it is the
  correctness oracle, and raw f64 round-trips are bit-exact against
  it (same IEEE754 doubles, no precision change anywhere).

## Implementation map

- `R/executor.R`: `.sv_es(v)` (element size from `gdt`, 4 or 8);
  `.sv_from_vec` gains a dtype argument; `.sv_slicer`, `.sv_trim`,
  `.sv_to_matrix`, `.sv_to_vec`, `.sv_materialise` replace their
  hard-coded `4L` with the payload's element size and propagate `gdt`;
  `.sv_upload` uploads with the payload's `gdt`, not `"f32"`;
  `.sv_download_exports` accepts f32/f64; `.exec_write_chunk` plane
  arithmetic by element size.
- `R/ops.R`: `g_download_raw` tags `gdt = .g_dtype(x)` and validates
  it is f32/f64.
- `R/scheduler.R`: `.apply_fuse` raw-store gate widens to f32/f64;
  `.store_region_mb` takes bytes-per-element derived from the region's
  dtype (`4` only when raw AND f32), fixing the f64 under-count.
- Tests: f64 round-trips through the sv layer; a `dtype = "f64"` map
  fused under cost mode matches the oracle bitwise; the distributed
  Kalman equivalence suite now rides raw f64 and must stay
  bit-identical.

## Validation

- Full suite (the scan/Kalman gates are the real assertion: raw f64 is
  bit-identical to the doubles path, so tolerances must not loosen).
- SI bench crop=1024/2048 cost: expect a modest tail-time reduction
  (fewer multi-hundred-MB conversion copies per scan chunk hop) and
  cleaner daemon RSS; no output change.
