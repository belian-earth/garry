# anvl upstream proposal: raw-buffer transport + CPU client controls

What garry needs from anvl (r-xla/anvl) to close the remaining
CPU-side gap to ODC, with the measurements that motivate each ask.
Context: after phases 10-12b, garry's HLS morphology benchmark runs
28.6 s vs ODC's 16.7 s on the same link; the remaining difference is
carrier and wrap-around cost, not kernel speed. R has no f32 and no
threads, so today every byte crossing GDAL -> store -> device rides
as an R double and every hop converts.

## Ask 1: upload from a raw buffer

```r
nv_array(x, dtype, dim = NULL, device = NULL)
```

Extend `x` to accept a **raw vector** holding the native
little-endian payload of `prod(dim)` elements of `dtype` (f32, i16,
u8, u16, i32, ...). `dim` is required for raw input. The upload goes
payload -> device buffer with no double materialisation; if PJRT
allows, zero-copy from the R-owned buffer for the duration of the
transfer. ALTREP-backed raw vectors (e.g. mori shared memory
mappings) must be accepted without forcing materialisation.

Why (measured):
- garry's inter-stage store holds f32-on-disk data as R doubles:
  8 B/px through every hop for 4 B/px of information. On the
  benchmark that is ~2 GB of store traffic and a measurable slice
  of the 10.5 GB fleet peak.
- A fused median task uploads 110 chunk planes per execution; each
  upload converts double -> f32. With raw f32 store values the
  upload is a memcpy (or zero-copy).
- The unsigned-dtype carrier hack disappears: garry currently
  uploads u8/u16/u32 through widened signed carriers
  (`.anvl_upload_dtype`) because doubles are the only numeric entry
  point. A raw path expresses unsigned payloads exactly.

## Ask 2: download to a raw buffer

```r
as_array(x, raw = TRUE)      # or nv_raw(x)
```

Inverse of ask 1: device buffer -> raw vector of the buffer's dtype
payload plus `dim`/`dtype` attributes (no double conversion). garry
stores compute outputs back through mori as raw; today every
download doubles the bytes before they hit shared memory.

## Ask 3: PJRT CPU client thread-pool size

```r
options(anvl.cpu_threads = N)   # or an env var read at client init
```

The CPU client currently inherits hardware concurrency. garry runs
several daemon processes per host; measured on a 20-core box:
- 3-6 compute daemons x ~20 XLA threads each oversubscribe the box
  and contend with the read fleet (renicing the compute pool bought
  4-8 s of drain).
- XLA sort scratch scales with the thread pool: compute daemons
  measured at 1.1-1.4 GB anon DURING a chunk vs ~0.3 GB in a
  single-process reproduction.
garry would set this to ~cores / n_compute_daemons.

## Ask 4 (question first): nan_rm median lowering

If `nv_reduce_median(..., nan_rm = TRUE)` lowers to a full sort per
pixel, a selection formulation (top_k to the middle, or a fixed
selection network for small reduce extents — garry's typical t is
30-90) is plausibly ~2x on CPU. Worth checking the current HLO
before doing anything; garry's median tail is 16 tasks x 0.6-1.5 s
of exec.

## Acceptance tests garry will gate on

1. Round trip identity per dtype (f32, i16, u8, u16, i32):
   raw -> nv_array -> as_array(raw = TRUE) reproduces the payload
   byte-for-byte; dim preserved.
2. Equivalence: nv_array(raw_f32, "f32", dim) equals
   nv_array(matrix_double, "f32") elementwise for the same values,
   including NaN and signed zero.
3. Unsigned exactness: u16 payloads with values > 2^15 round-trip
   exactly (the carrier hack loses nothing today, but the raw path
   must too).
4. No-materialisation: uploading an ALTREP raw vector does not force
   it (observable via mori: the mapping's RSS cost stays shared).
5. Thread-pool option: with anvl.cpu_threads = 2, an execution's
   host CPU time is bounded accordingly (smoke: elapsed vs cpu
   ratio), and two clients in one process are not created.

## Composition with garry (planned 12c)

With asks 1+2, garry's store becomes raw-f32 end to end: read tasks
share raw planes, fused kernels upload one contiguous (t, y, x)
column per median chunk (single memcpy, single XLA parameter — the
110-parameter marshalling and its per-input conversions go away),
downloads store back as raw. Estimated from tonight's profiles:
fleet peak -2 to -3 GB, median tail roughly halves, and the
remaining wall gap to ODC (~12 s) shrinks to fetch-floor territory.

## Measured note on single-upload medians (2026-07-08)

Building the (t, y, x) column daemon-side and uploading once was
re-measured NEUTRAL with double carriers (host stacking ~0.13 s per
chunk buys back exactly the per-parameter upload cost it saves;
verified twice, before and after compute-on-read). It becomes
clearly positive only with ask 1, when the stack is a raw memcpy —
implement it in garry as part of the raw-store migration, not
before.
