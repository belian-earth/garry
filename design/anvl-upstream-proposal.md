# anvl upstream proposal: raw-buffer transport + CPU client controls

What garry needs from the r-xla stack (anvl, pjrt) to close the
remaining CPU-side gap to ODC. Written 2026-07-08 as an ask list;
updated the same day after a source dive and patch session: most of
the transport already existed upstream, the rest is implemented on
local branches pending PRs. anvl is maintained by the r-xla project
(Fischer, Falbel, Kalinowski, German); it is not our package, so
everything below is structured as upstreamable patches with tests.

Context: after phases 10-12b, garry's HLS morphology benchmark runs
28.6 s vs ODC's 16.7 s on the same link; the remaining difference is
carrier and wrap-around cost, not kernel speed. R has no f32 and no
threads, so today every byte crossing GDAL -> store -> device rides
as an R double and every hop converts.

## Status summary (2026-07-08 patch session)

| Ask | Status | Where |
|---|---|---|
| 1. upload from raw | existed in pjrt; anvl plumbing added | anvl branch `raw-payload-nv-array` (~/belian/anvl) |
| 1a. no ALTREP forcing | fixed: pjrt read via `DATAPTR_RO` | pjrt branch `raw-upload-dataptr-ro` (~/belian/pjrt) |
| 2. download to raw | already shipped upstream | `anvl::as_raw(x, row_major = FALSE)` |
| 3. CPU thread-pool size | already exists: `PJRT_NPROC` env var | no change needed |
| 4. nan_rm median lowering | confirmed full sort; selection path implemented, 2.3x | second commit on `raw-payload-nv-array` |

Both branches pass their full suites (pjrt 983, anvl 2038). Patched
builds are installed in the session scratchpad Rlib for 12c
development. PRs to r-xla/pjrt and r-xla/anvl are the remaining
step; the two anvl commits are independent and can be split.

## Ask 1: upload from a raw buffer

```r
nv_array(x, dtype, shape)     # x = raw(), byrow selects row-major payload
```

`pjrt_buffer.raw` already existed (dtype, shape, `row_major`
required, byte-size checked, unsigned dtypes exact). anvl's
`new_data` simply never passed `row_major`, so raw input errored.
The anvl patch: `nv_array` accepts raw payloads (dtype and shape then
required), maps `byrow` onto `row_major`, and the xla backend passes
it through; the quickr and plain (tracing) backends abort clearly.

Measured transport behaviour (256 MB f32, CPU client):

- Upload is one memcpy into a fresh R-owned buffer that PJRT then
  aliases (`kMutableZeroCopy`): +244 MiB private per upload, freed
  with the buffer. No double materialisation anywhere.
- `row_major = TRUE` payloads match XLA's default layout. Column
  -major payloads (`byrow = FALSE`) cost one extra relayout copy
  inside XLA (+244 MiB transient, +0.1 s): 12c should store planes
  row-major and upload with `byrow = TRUE`.
- The double path for the same data costs ~1 GB host-side (double
  vector + conversion + buffer), so raw roughly halves upload RSS
  even before the store savings.

## Ask 1a (found during verification): ALTREP forcing in pjrt

pjrt read the upload source with `RAW(data)`, a writable pointer
request. That forces copy-on-write materialisation of ALTREP raw
sources: one full private duplicate per mori mapping, exactly the
cost the raw path exists to avoid. gdb attribution:
`mori_vec_Dataptr(writable = TRUE)` -> `Rf_allocVector` inside the
upload memcpy.

Fix (pjrt branch): read the source via `DATAPTR_RO`. mori's ALTREP
serves `Dataptr(writable = FALSE)` and `Dataptr_or_null` zero-copy
from the mapping, so uploads now fault the mapping's pages shared and
copy once into the device buffer.

Trap for the PR text: `RAW_RO()` is NOT equivalent. As of R 4.6 it
forces ALTREP payloads exactly like `RAW()`; only `DATAPTR_RO()`
dispatches read-only. Verified by pointer identity and RSS. (Possibly
worth a report to R-core.)

## Ask 2: download to a raw buffer

Already shipped upstream before this session: `as_raw(x, row_major)`
is exported from anvl (tengen generic), returns the buffer's byte
payload without double conversion. `row_major = FALSE` gives R-native
column-major order. No dim/dtype attributes on the result; garry
carries chunk dims itself, so no upstream ask.

## Ask 3: PJRT CPU client thread-pool size

No upstream change needed. The stock XLA CPU plugin reads the
`PJRT_NPROC` environment variable at client creation
(`xla::DefaultThreadPoolSize`), and pjrt reads
`PJRT_CPU_DEVICE_COUNT` for device count. Must be set before the
daemon processes start (same pattern as the `MALLOC_*` variables,
which garry's benchmark already sets pre-`daemons()`).

Measured (20-core box):

- Thread count per process: 63 default, 39 at `PJRT_NPROC=8`, 27 at
  `PJRT_NPROC=2` (the residue is R and PJRT service threads).
- A genuinely parallel op is bounded correctly: 2000x2000 f32 matmul
  runs at cpu/elapsed 10.8 default, 3.1 at NPROC=4, 1.8 at NPROC=2.
- The nan_rm median itself is SINGLE-THREADED in XLA (ratio 1.0 at
  every setting, wall unchanged). Compute-daemon oversubscription
  during the median tail therefore comes from pool existence plus the
  parallel elementwise/mask stages, not the median sort. Setting
  `PJRT_NPROC = cores / n_compute_daemons` costs medians nothing.
- VmHWM was flat across settings on the median workload, so the
  1.1-1.4 GB in-chunk anon observed in the fleet is not pool-scaled
  sort scratch; the double-carrier upload path remains the prime
  suspect, which 12c removes.

## Ask 4: nan_rm median lowering

Confirmed: `nv_quantile` lowered through a full `prim_sort` per
pixel. Implemented upstream (anvl branch, second commit): when every
requested prob puts its order statistics in the ascending prefix
window `[1, ceil((n-1)*max(probs)) + 1]` and that window is at most
about half the axis, the sort is replaced by `-nv_top_k(-x, k)`.
Correctness notes encoded in the patch: per-pixel `n_valid` under
`nan_rm` only shifts required indices down, so the prefix window
stays sufficient; `nan_rm = FALSE` slices containing NaN are forced
to NaN post-hoc so top_k's different NaN placement never surfaces;
floats only (negation is unsafe at integer domain edges).

Measured on garry-shaped chunks ((t, 512, 512) f32, nan_rm median
over t, CPU): t=31 0.50 -> 0.21 s, t=55 1.04 -> 0.47 s, t=90
1.94 -> 0.86 s per exec. Outputs bit-identical. garry's 16-task
median tail (~8 s) should roughly halve with no garry-side change
once the anvl patch is in.

## Acceptance tests garry gates on

Status against the patched branches:

1. Round trip identity per dtype (f32, i16, u8/ui8, u16/ui16, i32):
   PASS, byte-for-byte, dims preserved (anvl test-array.R additions).
2. Equivalence raw f32 vs double upload including NaN and signed
   zero: PASS (bit patterns compared).
3. Unsigned exactness u16 > 2^15: PASS (no carrier needed).
4. No-materialisation from mori mappings: PASS with the pjrt
   `DATAPTR_RO` fix; +244 MiB shared (mapping fault) + one private
   buffer copy per upload, per-mapping duplicate gone. FAILS on
   unpatched pjrt.
5. Thread-pool control: PASS via `PJRT_NPROC` (matmul cpu/elapsed
   bounded; client cached per platform so no second client).

## Composition with garry (12c, unblocked)

With the branches installed, garry's store becomes raw-f32 end to
end: read tasks share raw planes (row-major, so uploads skip XLA's
relayout copy), fused kernels upload one contiguous (t, y, x) column
per median chunk, downloads store back via `as_raw`. The
110-parameter marshalling and the unsigned-carrier hack
(`.anvl_upload_dtype`) go away. Estimated from the 12b profiles:
fleet peak -2 to -3 GB, median tail roughly halves again on top of
the selection fast path, remaining wall gap to ODC shrinks toward the
~15 s fetch floor.

Dependency note: 12c development runs against the scratchpad Rlib
builds; before merging, garry's Remotes pins move to the merged
upstream commits (or Hugh's fork refs while PRs are open).

## Measured note on single-upload medians (2026-07-08)

Building the (t, y, x) column daemon-side and uploading once was
re-measured NEUTRAL with double carriers (host stacking ~0.13 s per
chunk buys back exactly the per-parameter upload cost it saves;
verified twice, before and after compute-on-read). It becomes clearly
positive only with raw payloads, when the stack is a memcpy;
implement it in garry as part of the raw-store migration, not before.
