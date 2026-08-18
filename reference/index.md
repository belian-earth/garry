# Package index

## Discovery & sources

Turn a STAC search into grid-pinned lazy rasters. Entry point for remote
(Planetary Computer / element84) collections.

- [`stac_query()`](https://belian-earth.github.io/garry/reference/stac_query.md)
  : Query a STAC API and return the item collection.
- [`stac_sign_mpc()`](https://belian-earth.github.io/garry/reference/stac_sign_mpc.md)
  : Sign Planetary Computer STAC items, caching the token per
  collection.
- [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  : Rectangularise STAC items into a source table.
- [`stac_filter_assets()`](https://belian-earth.github.io/garry/reference/stac_filter_assets.md)
  : Keep only the named assets in a STAC item collection (or sources
  table).
- [`stac_filter_cloud()`](https://belian-earth.github.io/garry/reference/stac_filter_cloud.md)
  : Filter a source table by maximum cloud cover.
- [`stac_filter_coverage()`](https://belian-earth.github.io/garry/reference/stac_filter_coverage.md)
  : Drop STAC items (or sources) that barely overlap an area of
  interest.
- [`stac_filter_orbit()`](https://belian-earth.github.io/garry/reference/stac_filter_orbit.md)
  : Filter STAC items by orbit state (Sentinel-1 ascending /
  descending).
- [`stac_drop_duplicates()`](https://belian-earth.github.io/garry/reference/stac_drop_duplicates.md)
  : Drop duplicate acquisitions (identical footprint and datetime).
- [`stac_rename_assets()`](https://belian-earth.github.io/garry/reference/stac_rename_assets.md)
  : Rename assets to a common band schema.
- [`stac_merge()`](https://belian-earth.github.io/garry/reference/stac_merge.md)
  : Concatenate source tables into one harmonised collection.
- [`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)
  : Group acquisitions into time slices.
- [`stac_gti_index()`](https://belian-earth.github.io/garry/reference/stac_gti_index.md)
  : Write a source table as a GTI index for one asset.
- [`lazy_stac_stack()`](https://belian-earth.github.io/garry/reference/lazy_stac_stack.md)
  : Lazy time-sliced stack of one STAC asset on a target grid.
- [`lazy_source()`](https://belian-earth.github.io/garry/reference/lazy_source.md)
  : Build a LazyRaster from a GDAL source.

## Datasets

The named multi-band, multi-time object; verbs apply across every band.
Build from a STAC table or from rasters, then select, stack, and
collapse.

- [`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
  : Build a lazy dataset from a STAC source table or raster file(s).
- [`as_dataset()`](https://belian-earth.github.io/garry/reference/as_dataset.md)
  : Assemble a lazy dataset from existing rasters.
- [`LazyDataset()`](https://belian-earth.github.io/garry/reference/LazyDataset.md)
  : A named, multi-band, multi-time lazy dataset.
- [`stack_bands()`](https://belian-earth.github.io/garry/reference/stack_bands.md)
  : Collapse a dataset's bands into a single stacked raster.
- [`band_sel()`](https://belian-earth.github.io/garry/reference/band_sel.md)
  : Select bands of a stacked raster by label.
- [`time_sel()`](https://belian-earth.github.io/garry/reference/time_sel.md)
  : Select time slices of a stacked raster by label.

## Masking & cloud removal

Mask value bands from a QA band or from a pre-trained cloud model. The
ocm\_\* functions run the OmniCloudMask segmentation model natively (no
Python) to derive cloud/shadow masks from red, green, and NIR bands.

- [`mask()`](https://belian-earth.github.io/garry/reference/mask.md) :
  Mask a dataset from a QA band.
- [`qa_bits()`](https://belian-earth.github.io/garry/reference/qa_bits.md)
  : Build a QA-bitmask predicate.
- [`ocm_model()`](https://belian-earth.github.io/garry/reference/ocm.md)
  [`ocm_predict()`](https://belian-earth.github.io/garry/reference/ocm.md)
  [`ocm_mask()`](https://belian-earth.github.io/garry/reference/ocm.md)
  : Cloud and shadow masking with OmniCloudMask
- [`ocm_fetch_weights()`](https://belian-earth.github.io/garry/reference/ocm_weights.md)
  [`ocm_load_weights()`](https://belian-earth.github.io/garry/reference/ocm_weights.md)
  : OmniCloudMask model weights
- [`shrink_footprint()`](https://belian-earth.github.io/garry/reference/shrink_footprint.md)
  : Shrink the valid-data footprint by a pixel margin.

## Time series & compositing

Collapse or smooth the time axis: calendar grouping, multivariate
composites, gap filling, and per-pixel smoothers.

- [`group_by_time()`](https://belian-earth.github.io/garry/reference/group_by_time.md)
  : Group a dataset's time slices into calendar periods.

- [`geomedian()`](https://belian-earth.github.io/garry/reference/geomedian.md)
  : Geometric median reducer over time (multivariate).

- [`medoid()`](https://belian-earth.github.io/garry/reference/medoid.md)
  : Medoid reducer over time (multivariate).

- [`fill_gaps()`](https://belian-earth.github.io/garry/reference/fill_gaps.md)
  : Fill nodata gaps along the time axis.

- [`hampel_smooth()`](https://belian-earth.github.io/garry/reference/hampel_smooth.md)
  : Hampel filter a stack over its time axis.

- [`kalman_smooth()`](https://belian-earth.github.io/garry/reference/kalman_smooth.md)
  : Smooth a stack with a local-linear-trend Kalman smoother.

- [`kalman_llt()`](https://belian-earth.github.io/garry/reference/kalman_llt.md)
  :

  Kalman local-linear-trend smoother body for
  [`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md).

## Geo-embeddings & model weights

Special operations for published geo-embedding products: the quantiser
decodes (fused onto multi-band reads via lazy_map) and safetensors
weight IO.

- [`dequantize_aef()`](https://belian-earth.github.io/garry/reference/dequantize_aef.md)
  : Dequantize Alpha Earth (AEF) embedding codes.
- [`dequantize_esd()`](https://belian-earth.github.io/garry/reference/dequantize_esd.md)
  : Dequantize Embedded Seamless Data (ESD) FSQ codes.
- [`safetensors_read()`](https://belian-earth.github.io/garry/reference/safetensors_read.md)
  : Read tensors from a safetensors file.
- [`safetensors_ls()`](https://belian-earth.github.io/garry/reference/safetensors_ls.md)
  : List tensor names, dtypes, and shapes without reading data.

## Raster & dataset algebra

Lazily build and transform rasters and datasets. Every verb adds IR
nodes and returns a new lazy object; nothing reads or computes until
collect().

- [`lazy_map()`](https://belian-earth.github.io/garry/reference/lazy_map.md)
  : Elementwise map over one or more aligned rasters.

- [`lazy_stack()`](https://belian-earth.github.io/garry/reference/lazy_stack.md)
  : Stack aligned rasters along a new outer dim (default time).

- [`focal()`](https://belian-earth.github.io/garry/reference/focal.md) :
  Focal (stencil) op.

- [`focal_kernel()`](https://belian-earth.github.io/garry/reference/focal_kernel.md)
  : Linear focal op with an explicit kernel (differentiable).

- [`bilateral_focal()`](https://belian-earth.github.io/garry/reference/bilateral_focal.md)
  :

  A bilateral (edge-preserving) focal body for
  [`focal()`](https://belian-earth.github.io/garry/reference/focal.md).

- [`reduce_over()`](https://belian-earth.github.io/garry/reference/reduce_over.md)
  : Reduction over named dims.

- [`band_project()`](https://belian-earth.github.io/garry/reference/band_project.md)
  : A band reducer for a linear combination of bands.

- [`mlp_project()`](https://belian-earth.github.io/garry/reference/mlp_project.md)
  : An MLP band reducer (predict a trained network across the raster).

- [`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md)
  : Scan along an axis, keeping it (temporal recursions).

- [`lazy_patch()`](https://belian-earth.github.io/garry/reference/lazy_patch.md)
  :

  Whole-window model op (advanced): apply `fn` to the raw padded chunk.

- [`align()`](https://belian-earth.github.io/garry/reference/align.md) :
  Lazily resample/reproject onto a target grid.

## Execution

Plan, distribute across daemons, and write the result.

- [`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
  : Materialise a LazyRaster (or inspect its plan).
- [`write_tif()`](https://belian-earth.github.io/garry/reference/write_tif.md)
  : Execute a lazy raster and stream it to a GeoTIFF.
- [`materialise()`](https://belian-earth.github.io/garry/reference/materialise.md)
  : Materialise a lazy object locally and stay lazy.
- [`as_terra()`](https://belian-earth.github.io/garry/reference/as_terra.md)
  : Convert a collected result to a terra SpatRaster.
- [`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)
  : Set up split mirai daemon pools for distributed execution.
- [`garry_daemons_set()`](https://belian-earth.github.io/garry/reference/garry_daemons_set.md)
  : Are the garry daemon pools running?
- [`garry_pool_hygiene()`](https://belian-earth.github.io/garry/reference/garry_pool_hygiene.md)
  : Reclaim daemon memory across the pools.
- [`garry_gdal_config()`](https://belian-earth.github.io/garry/reference/garry_gdal_config.md)
  : Apply garry's default GDAL configuration for remote COG reads.
- [`garry_opt()`](https://belian-earth.github.io/garry/reference/garry_opt.md)
  : Read a garry policy option.
- [`garry_options()`](https://belian-earth.github.io/garry/reference/garry_options.md)
  : List every garry option: default, current value, tier, description.

## Diagnostics & visualisation

Inspect data and understand what an execution did: quick plots, pipeline
drawings, and run reports.

- [`preview()`](https://belian-earth.github.io/garry/reference/preview.md)
  : Preview a lazy object, a collected array, or a raster file.

- [`draw()`](https://belian-earth.github.io/garry/reference/draw.md) :
  Draw the pipeline of a lazy object.

- [`plan_view()`](https://belian-earth.github.io/garry/reference/plan_view.md)
  : Interactive Plan viewer.

- [`garry_last_route()`](https://belian-earth.github.io/garry/reference/garry_last_route.md)
  :

  Which execution route did the last
  [`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
  take?

- [`garry_task_report()`](https://belian-earth.github.io/garry/reference/garry_task_report.md)
  :

  Summarise a `garry.task_log` CSV.

- [`garry_explain_placement()`](https://belian-earth.github.io/garry/reference/garry_explain_placement.md)
  : Explain the scheduler's placement decisions for a computation.

## Grids & spatial helpers

Define and interrogate the analysis grid; dtype rules.

- [`grid_spec()`](https://belian-earth.github.io/garry/reference/grid_spec.md)
  : Convenience constructor: derive the transform from extent + dims (or
  res).

- [`grid_from_bbox()`](https://belian-earth.github.io/garry/reference/grid_from_bbox.md)
  : Build an analysis grid from a lon/lat bounding box.

- [`grid_from_src()`](https://belian-earth.github.io/garry/reference/grid_from_src.md)
  : Build an analysis grid from a raster or vector source.

- [`gdal_grid_spec()`](https://belian-earth.github.io/garry/reference/gdal_grid_spec.md)
  : Inspect a GDAL source and build its GridSpec (plus read metadata).

- [`xmin()`](https://belian-earth.github.io/garry/reference/grid-accessors.md)
  [`ymin()`](https://belian-earth.github.io/garry/reference/grid-accessors.md)
  [`xmax()`](https://belian-earth.github.io/garry/reference/grid-accessors.md)
  [`ymax()`](https://belian-earth.github.io/garry/reference/grid-accessors.md)
  [`res()`](https://belian-earth.github.io/garry/reference/grid-accessors.md)
  : Grid extent and resolution accessors.

- [`grid_equal()`](https://belian-earth.github.io/garry/reference/grid_equal.md)
  : Structural equality of two grids (geometry only, not dtype).

- [`grid_diff()`](https://belian-earth.github.io/garry/reference/grid_diff.md)
  : Describe how two grids differ.

- [`crs_equal()`](https://belian-earth.github.io/garry/reference/crs_equal.md)
  : Are two CRS strings the same reference system?

- [`dtype_valid()`](https://belian-earth.github.io/garry/reference/dtype_valid.md)
  :

  Is `dtype` a member of garry's dtype vocabulary?

- [`dtype_promote()`](https://belian-earth.github.io/garry/reference/dtype_promote.md)
  : Promote two dtypes for a binary operation.

- [`snap_to_blocks()`](https://belian-earth.github.io/garry/reference/snap_to_blocks.md)
  : Snap requested chunk size to a multiple of native block size.

- [`output_grid()`](https://belian-earth.github.io/garry/reference/output_grid.md)
  : Compute the output grid given this node and its parents' grids.

## anvl compute vocabulary

The g\_\* traced-array ops for writing map/focal/reducer functions.
These run fused inside an XLA stage under both the pure-R reference
implementation and PJRT.

- [`g_ifelse()`](https://belian-earth.github.io/garry/reference/g_ifelse.md)
  :

  Elementwise select: `yes` where `cond`, else `no`.

- [`g_is_nodata()`](https://belian-earth.github.io/garry/reference/g_is_nodata.md)
  : Is a value nodata? NaN is the nodata sentinel.

- [`g_cast()`](https://belian-earth.github.io/garry/reference/g_cast.md)
  : Cast to a garry dtype.

- [`g_fill()`](https://belian-earth.github.io/garry/reference/g_fill.md)
  : Construct a constant-filled AnvlArray on the device.

- [`g_pad()`](https://belian-earth.github.io/garry/reference/g_pad.md) :

  Pad a matrix by `h` cells on every side with `value`.

- [`g_pad_rb()`](https://belian-earth.github.io/garry/reference/g_pad_rb.md)
  : Pad the bottom/right edges of the last two dims.

- [`g_shift_slice()`](https://belian-earth.github.io/garry/reference/g_shift_slice.md)
  : Shifted slice of a padded matrix (the stencil building block).

- [`g_stack()`](https://belian-earth.github.io/garry/reference/g_stack.md)
  : Stack same-shaped arrays along a new leading axis.

- [`g_index_scalar()`](https://belian-earth.github.io/garry/reference/g_index_scalar.md)
  :

  Extract element `i` of a 1-D array as a scalar (static index).

- [`g_scan()`](https://belian-earth.github.io/garry/reference/g_scan.md)
  : Scan: carry state along dim 1, emitting per-step outputs.

- [`g_slice_t()`](https://belian-earth.github.io/garry/reference/g_slice_t.md)
  : Static range slice along dim 1 (the scanned axis).

- [`g_concat_t()`](https://belian-earth.github.io/garry/reference/g_concat_t.md)
  : Concatenate along dim 1 (the scanned axis).

- [`g_rep_t()`](https://belian-earth.github.io/garry/reference/g_rep_t.md)
  : Replicate a (y, x) plane along a new leading axis.

- [`g_expand()`](https://belian-earth.github.io/garry/reference/g_expand.md)
  : Insert a broadcast axis at an arbitrary position.

- [`g_squeeze1()`](https://belian-earth.github.io/garry/reference/g_squeeze1.md)
  : Drop a leading unit axis.

- [`g_transpose()`](https://belian-earth.github.io/garry/reference/g_transpose.md)
  : Transpose an array (general permutation).

- [`g_bitand()`](https://belian-earth.github.io/garry/reference/g-bitwise.md)
  [`g_bitor()`](https://belian-earth.github.io/garry/reference/g-bitwise.md)
  [`g_bitxor()`](https://belian-earth.github.io/garry/reference/g-bitwise.md)
  [`g_bitnot()`](https://belian-earth.github.io/garry/reference/g-bitwise.md)
  [`g_shiftl()`](https://belian-earth.github.io/garry/reference/g-bitwise.md)
  [`g_shiftr()`](https://belian-earth.github.io/garry/reference/g-bitwise.md)
  : Bitwise operations on integral arrays.

- [`g_sum()`](https://belian-earth.github.io/garry/reference/g-reductions.md)
  [`g_mean()`](https://belian-earth.github.io/garry/reference/g-reductions.md)
  [`g_min()`](https://belian-earth.github.io/garry/reference/g-reductions.md)
  [`g_max()`](https://belian-earth.github.io/garry/reference/g-reductions.md)
  [`g_median()`](https://belian-earth.github.io/garry/reference/g-reductions.md)
  [`g_count()`](https://belian-earth.github.io/garry/reference/g-reductions.md)
  : Reductions over array margins.

- [`g_erf()`](https://belian-earth.github.io/garry/reference/g_erf.md) :
  Error function (exact GELU building block).

- [`g_conv2d()`](https://belian-earth.github.io/garry/reference/g_conv2d.md)
  : 2D convolution over a (C, H, W) chunk.

- [`g_upsample2x()`](https://belian-earth.github.io/garry/reference/g_upsample2x.md)
  : Nearest-neighbour 2x upsample of a (C, H, W) chunk.

- [`g_broadcast_arrays()`](https://belian-earth.github.io/garry/reference/g_broadcast_arrays.md)
  : Broadcast arrays to a common shape (compute vocabulary).

- [`g_upload()`](https://belian-earth.github.io/garry/reference/g_upload.md)
  : Upload an R array to an AnvlArray of the given garry dtype.

- [`g_download()`](https://belian-earth.github.io/garry/reference/g_download.md)
  : Download an AnvlArray (or a nested list of them) to R arrays.

- [`lazy_value_and_grad()`](https://belian-earth.github.io/garry/reference/lazy_value_and_grad.md)
  : Value and gradient of a scalar LazyRaster loss wrt a focal kernel.

## GDAL adapter (low-level IO)

Direct windowed read/write, warp, staging, and GTI index construction.
Used by the cube layer; exposed for bespoke IO.

- [`gdal_read_window()`](https://belian-earth.github.io/garry/reference/gdal_read_window.md)
  : Read a window from a GDAL source as a garry-oriented matrix.

- [`gdal_write_window()`](https://belian-earth.github.io/garry/reference/gdal_write_window.md)
  : Write a garry-oriented matrix into an open output dataset.

- [`gdal_create_output()`](https://belian-earth.github.io/garry/reference/gdal_create_output.md)
  : Create an output raster for a grid.

- [`gdal_warp_vrt()`](https://belian-earth.github.io/garry/reference/gdal_warp_vrt.md)
  : Build a warped VRT of a source onto an exact target grid.

- [`stage_raw_cube()`](https://belian-earth.github.io/garry/reference/stage_raw_cube.md)
  :

  Stage a GDAL raster as a raw-BSQ cube (`.bin` + sibling `.vrt`).

- [`gti_index_create()`](https://belian-earth.github.io/garry/reference/gti_index_create.md)
  : Create a GTI tile index layer from a source table.

- [`gti_open_options()`](https://belian-earth.github.io/garry/reference/gti_open_options.md)
  : Build GTI open options pinning a target grid and slice filter.

## IR & planner (extension API)

The intermediate representation and planner. Needed only to build on the
IR directly (custom nodes, alternate executors) – not for normal use.

- [`LazyRaster()`](https://belian-earth.github.io/garry/reference/LazyRaster.md)
  : Lazy raster array (single band stack).

- [`GridSpec()`](https://belian-earth.github.io/garry/reference/GridSpec.md)
  : Spatial grid specification.

- [`Graph()`](https://belian-earth.github.io/garry/reference/Graph.md) :
  Compute graph.

- [`ChunkGrid()`](https://belian-earth.github.io/garry/reference/ChunkGrid.md)
  : A chunk partition of a GridSpec.

- [`Stage()`](https://belian-earth.github.io/garry/reference/Stage.md) :
  One schedulable unit of a Plan.

- [`Plan()`](https://belian-earth.github.io/garry/reference/Plan.md) : A
  physical execution plan: stages in dependency order.

- [`Node()`](https://belian-earth.github.io/garry/reference/Node.md) :
  Abstract IR node.

- [`SourceNode()`](https://belian-earth.github.io/garry/reference/SourceNode.md)
  : A GDAL-readable source: path + band + optional nodata sentinel.

- [`MapNode()`](https://belian-earth.github.io/garry/reference/MapNode.md)
  :

  Elementwise map. `fn` is an R function over scalars/arrays; it will be
  composed with neighbouring fusable nodes and wrapped in
  [`anvl::jit()`](https://r-xla.github.io/anvl/reference/jit.html) at
  plan time. Created by
  [`lazy_map()`](https://belian-earth.github.io/garry/reference/lazy_map.md).

- [`FocalNode()`](https://belian-earth.github.io/garry/reference/FocalNode.md)
  :

  Focal (stencil) op. `radius` is the halo in pixels; `boundary` is one
  of "constant", "reflect", "nearest", "wrap", "none". Created by
  [`focal()`](https://belian-earth.github.io/garry/reference/focal.md).

- [`ReduceNode()`](https://belian-earth.github.io/garry/reference/ReduceNode.md)
  : Reduction over named dims. Barrier: forces materialisation of its
  inputs.

- [`ScanNode()`](https://belian-earth.github.io/garry/reference/ScanNode.md)
  :

  Scan along a named dim, preserving it. Barrier over `over`.

- [`WarpNode()`](https://belian-earth.github.io/garry/reference/WarpNode.md)
  :

  Lazy resample/reproject to a target grid. Created by
  [`align()`](https://belian-earth.github.io/garry/reference/align.md).
  Barrier. At execution time this materialises as a gdalraster VRT warp.

- [`StackNode()`](https://belian-earth.github.io/garry/reference/StackNode.md)
  :

  Combine inputs along a named dim (e.g. time). Created by
  [`lazy_stack()`](https://belian-earth.github.io/garry/reference/lazy_stack.md).

- [`FusedNode()`](https://belian-earth.github.io/garry/reference/FusedNode.md)
  :

  Output of the composition pass. Holds a composed R function assembled
  from its members; ready for
  [`anvl::jit()`](https://r-xla.github.io/anvl/reference/jit.html) at
  execution time.

- [`PatchNode()`](https://belian-earth.github.io/garry/reference/PatchNode.md)
  : Whole-window model op: fn over the raw padded chunk. Halo-consuming.

- [`graph_new()`](https://belian-earth.github.io/garry/reference/graph_new.md)
  : Create an empty graph.

- [`graph_add()`](https://belian-earth.github.io/garry/reference/graph_add.md)
  :

  Add a node. `ctor` is an S7 node constructor; `...` are its properties
  (the `id` property is assigned here and passed automatically).

- [`graph_get()`](https://belian-earth.github.io/garry/reference/graph_get.md)
  : Look up a node by id.

- [`graph_ids()`](https://belian-earth.github.io/garry/reference/graph_ids.md)
  : All node ids in the graph, in ascending id order.

- [`graph_toposort()`](https://belian-earth.github.io/garry/reference/graph_toposort.md)
  : Topological sort of all node ids. Errors on cycles.

- [`graph_replace()`](https://belian-earth.github.io/garry/reference/graph_replace.md)
  : Replace a node in place (for rewrite passes).

- [`graph_import()`](https://belian-earth.github.io/garry/reference/graph_import.md)
  :

  Import the subgraph reachable from `root_id` in `src` into `dst`.

- [`plan_lazy()`](https://belian-earth.github.io/garry/reference/plan_lazy.md)
  : Plan a LazyRaster: run all planner passes and export a Plan.

- [`plan_dot()`](https://belian-earth.github.io/garry/reference/plan_dot.md)
  : Render a Plan as DOT (Graphviz) text.

- [`execute_plan()`](https://belian-earth.github.io/garry/reference/execute_plan.md)
  : Execute a Plan on the anvl backend (single process).

- [`execute_plan_mirai()`](https://belian-earth.github.io/garry/reference/execute_plan_mirai.md)
  : Execute a Plan across mirai daemons.

- [`fusable()`](https://belian-earth.github.io/garry/reference/fusable.md)
  : Can this node be composed with fusable neighbours into a single
  kernel?

- [`is_barrier()`](https://belian-earth.github.io/garry/reference/is_barrier.md)
  : Does this node force a stage boundary?

- [`required_halo()`](https://belian-earth.github.io/garry/reference/required_halo.md)
  : Halo radius required by this node from its inputs.

- [`chunk_iter()`](https://belian-earth.github.io/garry/reference/chunk_iter.md)
  : Enumerate chunks.

- [`chunk_window_with_halo()`](https://belian-earth.github.io/garry/reference/chunk_window_with_halo.md)
  : Expand a chunk window by the ChunkGrid's halo, clipped to the grid.

- [`cross_grid_window()`](https://belian-earth.github.io/garry/reference/cross_grid_window.md)
  :

  Map an output-chunk window on `out_grid` to the minimal input window
  required on `in_grid`.
