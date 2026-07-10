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

## Gap 1: no fetch/compute overlap

ODC streams read -> mask -> median through one dask graph; a spatial chunk
reduces as soon as its time-slices land. garry warps everything, then computes.
To overlap: pipeline the GDAL-direct reduce with the warp -- a producer/consumer
where daemons warp slices into a shared /dev/shm cube and the main process
reduces each spatial TILE the moment all its slices are present. Hides the
~5.6 s compute under the ~16 s fetch drain -> garry approaches fetch-bound.

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

1. Warp-on-read direct to array (Gap 2) -- PRIORITISED.
2. Median spatial-tile fetch/compute overlap (Gap 1).
