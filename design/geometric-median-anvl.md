# Geometric median (and medoid) as an anvl reducer

A reference for expressing multivariate temporal reductions (reductions that see
the full band vector jointly) in anvl, as a garry custom reducer. Companion to
`ir-extensions-todo.md` #3.

## The problem

A per-band temporal median reduces each band independently, so the result can be
a spectrum that no real observation ever had. The **geometric median** (the L1 or
spatial median) fixes this: for each pixel it treats the T observations as
vectors in B-dimensional band space and returns the single band-vector that
minimises the sum of Euclidean distances to all of them,

```
m* = argmin_m  Σ_t ‖m − y_t‖₂ ,   y_t ∈ R^B
```

The output keeps the band axis (it is a genuine multivariate central tendency),
but the computation couples the bands: every distance is taken across all bands
at once.

## Weiszfeld iteration

The classic solver is a fixed point: the geometric median is a weighted mean of
the observations, weighted by the inverse of their distance to the current
estimate.

```
m^{k+1} = ( Σ_t  w_t y_t ) / ( Σ_t  w_t ) ,   w_t = 1 / ‖m^k − y_t‖₂
```

Initialise `m^0` at the coordinatewise mean and iterate.

## The anvl expression

Layout the cube as `(B, T, Y, X)`: band axis 1, time axis is the reduce axis
(`dims`, passed in by `reduce_over`), spatial axes 3 and 4. anvl reductions are
`nv_reduce_sum(x, dims=, drop=TRUE, nan_rm=FALSE)`, so `drop = FALSE` keeps the
reduced axis for broadcasting.

```r
# x : (B, T, Y, X)  — band axis = 1, `dims` = the time axis (garry passes it)
# returns (B, Y, X): the geometric (L1) median band-vector per pixel
geometric_median <- function(x, dims, iters = 20L, eps = 1e-6) {
  band <- 1L

  # m0 : coordinatewise mean over time, KEEP the axis so it broadcasts back
  m <- nv_mean(x, dims = dims, drop = FALSE, nan_rm = TRUE)        # (B, 1, Y, X)

  for (k in seq_len(iters)) {
    diff <- nv_sub(x, m)                                           # (B, T, Y, X)  m broadcasts over T
    # ‖m − y_t‖ per (t,y,x): sum of squares over the BAND axis, then sqrt
    dist <- nv_sqrt(nv_reduce_sum(nv_mul(diff, diff),
                                  dims = band, drop = FALSE))      # (1, T, Y, X)
    w    <- nv_div(nv_fill_like(dist, 1), nv_add(dist, eps))       # (1, T, Y, X)  w_t = 1/‖·‖
    num  <- nv_reduce_sum(nv_mul(w, x), dims = dims, drop = FALSE) # (B, 1, Y, X)  Σ_t w_t y_t
    den  <- nv_reduce_sum(w,            dims = dims, drop = FALSE) # (1, 1, Y, X)  Σ_t w_t
    m    <- nv_div(num, den)                                       # (B, 1, Y, X)
  }
  nv_squeeze(m, dims = dims)                                       # (B, Y, X)
}
```

## Why it is elegant

The two reductions happen over **different axes**, and that is the whole trick:

- the per-observation **distance** is an L2 norm over the **band** axis
  (`nv_reduce_sum(diff², dims = band)`), collapsing B to 1;
- the **update** is a weighted mean over the **time** axis
  (`nv_reduce_sum(w·y, dims = time)`), collapsing T to 1.

The two broadcasts read symmetrically:

- `w` is a scalar weight per timestep, `(1, T, Y, X)`, broadcast back across the
  band axis when multiplied by `x`;
- `m` is the current estimate per band, `(B, 1, Y, X)`, broadcast back across the
  time axis when subtracted from `x`.

Two `drop = FALSE` reductions, two broadcasts, batched over every pixel at once.
No per-pixel loop. The "multivariate" coupling that distinguishes it from a
per-band median is nothing more than *which axis you reduce*.

## Static graph, so it runs today

The R `for` loop runs at trace time, not at run time: it unrolls into a
fixed-depth DAG of `iters` steps that anvl/XLA compiles once. That is why a
fixed-iteration Weiszfeld works on the existing garry IR with no new node. Only a
convergence-based variant (stop when `m` stops moving, a data-dependent loop)
needs the Scan/Iterate node (`ir-extensions-todo.md` #1).

## NaN / masked slices

Real EO cubes have masked timesteps (NaN across all bands). A NaN observation
poisons the sums, so zero its weight before the weighted mean:

```r
  bad <- nv_reduce_max(nv_convert(nv_is_nan(x), "f32"), dims = band, drop = FALSE)
  w   <- nv_ifelse(nv_gt(bad, 0), nv_fill_like(w, 0), w)   # w_t = 0 for masked t
```

and keep `nan_rm = TRUE` on the mean initialisation.

## Medoid, for contrast

The medoid returns an actual observed slice (the one nearest all the others), so
it is fully static, no iteration:

1. pairwise inter-timestep distances: L2 over the band axis between every pair of
   timesteps, giving a `(T, T, Y, X)` distance tensor;
2. each slice's total distance to the rest: `nv_reduce_sum` over one T axis, to
   `(T, Y, X)`;
3. `nv_argmin` over the remaining T axis, then gather that slice's band-vector.

## Plugging into garry

```r
cube4d <- lazy_stack(per_time_band_slices, along = "band")   # (band, t, y, x)
gmed   <- reduce_over(cube4d, geometric_median, over = "t")  # (band, y, x)
```

`reduce_over` carries the function on `ReduceNode@fn` (op `"custom"`),
`.reduce_grid` drops only `t`, and `.eval_node` calls the reducer with the full
`(band, t, y, x)` array and the `t` axis index, so the reducer sees every band.
It runs via the general scheduler (it does not match the per-band composite fast
path), which keeps t and band full per spatial tile. See `ir-extensions-todo.md`
#3 for the enable/verify/wrap work still to do.
