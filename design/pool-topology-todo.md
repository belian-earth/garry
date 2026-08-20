# Pool topology: does the read/compute split earn its keep? (deferred)

Deferred 2026-08-20. The question is open, not answered: the measurement
below could not resolve it because the test link was too slow.

## The question

`garry_daemons()` runs two mirai pools: `garry_read` (fetch, sized to all
logical cores) and `garry_compute` (XLA, sized to cores/3 capped at 8).
Hugh's standing doubt is whether a separate compute pool earns its place
at all, given anvl already threads within a process. An earlier
measurement found the split helped; this note records an attempt to
re-confirm it and why that attempt was inconclusive.

## What was measured

HLS S30 median composite over Planetary Computer (the workload in
`benchmarks/hls-median-composite.R`), full year, 55 day slices, 392
item-assets, three bands plus Fmask, mask morphology on. Topology was
crossed with CPU pinning, because `garry.pool_affinity = "auto"` pins
every daemon to a disjoint core slice at pool creation: with 20 read
daemons a shared topology would run XLA on a ~1-core mask and lose for a
pinning reason rather than an architectural one.

"Shared" is not directly expressible (`compute = 0` disables distribution
entirely, since `garry_daemons_set()` needs both pools). It was faked by
arming a token 1-daemon compute pool and pointing
`.garry_state$comp_profiles` at `"garry_read"`, so compute dispatches to
the read daemons. The composite path honours that alias
(`composite_direct.R` dispatches compute through `.comp_profiles()`).

All four topologies produced byte-identical composites.

| config | wall (n=2) | fetch+dispatch | compute-sum |
|---|---|---|---|
| split, no pin | 46.1-100.1 s | 44.0-97.8 s | 8.8-9.4 s |
| split, pinned (default) | 45.7-52.2 s | 43.6-50.0 s | 11.0 s |
| shared, no pin | 57.3-60.0 s | 55.3-58.0 s | 23.4-23.6 s |
| shared, pinned | 58.2-65.9 s | 56.1-64.0 s | 22.3-22.8 s |

## Why it did not resolve

Fetch is **96.5% of wall clock**. There is almost no compute to arrange,
so no topology can move the total much. Worse, wall clock is not a usable
discriminator at this link speed: the same config (split, no pin) ranged
46.1 s to 100.1 s, a 2.2x spread, which is larger than any difference
between configs. An earlier uncontrolled run appeared to show shared
winning by 2.5x; the controlled interleaved run did not reproduce it, and
the shipped default came out fastest. That apparent result was network
drift.

The link is the problem. `benchmarks/README.md` records 23.2 s for this
exact workload on this machine; the runs above took 46-100 s, so the test
regime was 2-4x more fetch-bound than the one the original "the split
helps" conclusion came from. These numbers therefore do not contradict
that conclusion, they just cannot see the effect.

## The one robust signal

`compute-sum` (summed compute-task seconds across daemons) is stable
across repetitions, unlike wall clock, and it favours the split:
**10.2 s vs 23.1 s, so shared costs 2.3x the CPU for identical output.**
Plausibly compute on the read daemons contends with in-flight fetch work
(decompression, TLS) inside the same processes, plus XLA is loaded into
20 processes instead of 6. That cost is invisible while compute hides
behind the network, and becomes the whole story when it does not.

## How to settle it

Remove the network rather than fight it. Stage a subset of the HLS tiles
to local disk once, then run the identical composite from local files.
That puts the pipeline in the compute-bound regime where the split either
pays or does not, and it eliminates the 2x run-to-run variance that makes
the remote numbers unusable. Re-running the remote sweep with more
repetitions is not worth it: the noise floor is larger than the effect.

Two secondary questions worth folding in:

- `garry.pool_affinity = "auto"` is a default nobody has re-measured
  since the reads got cheaper. On the shorter (3-month) remote workload
  the pinned split was the slowest of four configs (21.5 s vs 16.6 s),
  though again within link noise.
- The local-path pool result from the same session: on the Landsat chain
  the pool cost ~0.92 s fixed per collect and its marginal cost per read
  was *worse* than single-process (0.090 s vs 0.072 s), so `collect()`
  should probably gate on estimated work rather than defaulting to the
  pools whenever they happen to be running.

Scripts: `pool_sweep*.R` from the 2026-08-20 session (scratchpad, not
committed).
