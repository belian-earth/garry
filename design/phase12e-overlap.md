# Phase 12e: closing the ODC gap (read fusion + overlap)

Back-to-back on a fast link (3-band morphology median, EPSG:20255 30 m,
one year HLS S30): garry ~23 s, ODC+Dask ~15-17 s. ODC is ~1.4x faster on a
fast link. On a slow / fetch-bound link the two converge (both fetch-limited).

Diagnostic: garry's **fetch+warp alone (~16 s) is ODC's entire runtime**, then
garry adds ~5.6 s of compute *sequentially*. Two gaps and one floor.

## Gap 2 (PRIORITISED): read path == ODC's whole pipeline

garry today does two steps per source: `gdal_translate -srcwin` the item window
to a tmpfs GTiff (fetch), then a separate warp of a per-slice local GTI into a
`MEM:::DATAPOINTER` f32 buffer. Two opens + a tmpfs round-trip per item.

**Warp-on-read (direct to array, no write):** warp the REMOTE item(s) of a
slice straight into the DATAPOINTER buffer in one `gdalraster::warp()` call --
gdalwarp mosaics multiple remote sources into the target grid itself. Removes
the tmpfs GTiff and the per-slice GTI build. Reuses the raw-f32 direct-to-mem
work (`MEM:::DATAPOINTER,DATATYPE=Float32`) already in `.cd_fetch_warp`; the
only change is the warp source (remote item URLs) instead of local tiles.
Per-item (whole-window) warp amortises the vsicurl header read, unlike the
per-CHUNK remote warp that was slow earlier in the phase.

## Gap 1: no fetch/compute overlap (DONE -- fetch-ordered pipeline)

A per-pixel median needs EVERY time-slice, so it cannot stream under the fetch
of its own band's slices -- the earlier "reduce streams under the warp" framing
was wrong. What CAN overlap the fetch: (1) the morphology mask (needs only the
fmask slices), and (2) each band's median relative to LATER bands' fetches.

Implemented (`.execute_composite_pipeline`, split pool only): fetch fmask FIRST
on the read pool; the moment it lands, compute the cleaned mask ONCE on the
compute pool (cube-vectorised morphology) and write it to one mask .bin, WHILE
the bands are still downloading; then as each band's fetch lands, dispatch its
median (async, on the compute pool) reading the shared mask -- so band B's
median runs while later bands still fetch. Only the LAST band's median is
exposed after the drain. The mask is computed once (not once per band), and
g_upload_raw/g_download_raw round-trip the 3D mask cube through the .bin with no
transpose (row-major both ways).

Result (3-band morphology, split 16+6): 17.5 s total, compute tail after the
fetch ~1.6 s (mask + two medians hid under the fetch), output exact. Down from
19.6 s (parallel, warm-overlap only), 21.1 s (whole-grid), 24 s (original) --
now inside the ODC 15-17 s band.

## Floor: R has no threads

dask overlaps + shares memory with a thread pool in one process; garry overlaps
with mirai processes (serialization + dispatch tax per task). Even fully
overlapped + fused reads, garry likely draws level on a fast link and stays
ahead on a slow one, but clearly beating ODC on a fast link needs in-process
threaded compute (which R lacks).

## TODO (deferred)

- **Incremental algebraic reduce** (mean/sum/min/max): fold each slice into a
  running accumulator as it lands -- perfect overlap, never holds the whole
  cube. Deferred (Hugh: lower interest); median still needs the tile-overlap
  above. Revisit if mean/sum composites become common.

## Order of attack

1. Warp-on-read direct to array (Gap 2) -- DONE (8418cac).
2. Fetch-ordered pipeline (Gap 1) -- DONE (fmask-first, mask + per-band medians
   overlap the band fetch on a split pool).
