#!/usr/bin/env python3
"""The Open Data Cube engine, both arms, under the contract at the top of benchmarks/README.md.

    odc.py --arm odc-dask|odc-threads --task ID --size S --variant V --out DIR [--warm] [--chunk N] [--read-pool N]
    odc.py --task geomedian_ref --size S --variant V

odc-dask is odc-stac, xarray, Dask threads and numbagg, the primary comparator. odc-threads is the same
reader without Dask: odc.stac.load(chunks=None, pool=N), then numbagg on NumPy. Each task is what a skilled
ODC user would write. ts_kalman alone leaves threads, on both arms: see task_ts_kalman. An error ends the run
with a nonzero exit.

The geomedian objective of a band vector m at one pixel is the sum over valid dates of ||x_t - m||, where a
date with any NaN band is not valid: geomad's rule and garry's, confirmed by test. geomedian_ref saves the
reference that check.py scores every engine against. The gap is (F(est) - F(ref)) / F(ref), summed over the
sampled pixels where both are finite, so one number covers garry's fixed iterations and geomad's eps.
"""

from __future__ import annotations

import time

STARTED = time.perf_counter()

import argparse  # noqa: E402
import gc  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import os  # noqa: E402
import sys  # noqa: E402
import multiprocessing  # noqa: E402
import threading  # noqa: E402
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor  # noqa: E402
from dataclasses import dataclass, field  # noqa: E402
from itertools import repeat  # noqa: E402
from pathlib import Path  # noqa: E402

# Python puts this folder first on the path, where this file would shadow the odc namespace package.
sys.path[:] = [p for p in sys.path if Path(p or ".").resolve() != Path(__file__).resolve().parent]

# Numba, numexpr, GDAL and BLAS read these at load. BLAS stays at one: nothing here gains from it, and each
# kernel already runs inside a pool of BENCH_THREADS.
THREADS = int(os.environ.get("BENCH_THREADS") or os.cpu_count())
os.environ.update(
    NUMBA_NUM_THREADS=str(THREADS),
    GDAL_NUM_THREADS=str(THREADS),
    NUMEXPR_MAX_THREADS=str(THREADS),
    NUMEXPR_NUM_THREADS="1",
    OMP_NUM_THREADS="1",
    OPENBLAS_NUM_THREADS="1",
)

import dask  # noqa: E402
import geomad  # noqa: E402
import numba  # noqa: E402
import numbagg  # noqa: E402
import numpy as np  # noqa: E402
import odc.algo  # noqa: E402
import odc.stac  # noqa: E402
import pyproj  # noqa: E402
import pystac  # noqa: E402
import rasterio  # noqa: E402
import rioxarray  # noqa: E402
import scipy  # noqa: E402
import simdkalman  # noqa: E402
import xarray as xr  # noqa: E402
from odc.algo import erase_bad, mask_cleanup, xr_geomedian, yxbt_sink  # noqa: E402
from odc.algo._masking import mask_cleanup_np  # noqa: E402
from odc.geo.geobox import GeoBox  # noqa: E402
from scipy import ndimage  # noqa: E402

HERE = Path(__file__).resolve().parent.parent
ARMS = ("odc-dask", "odc-threads")
KALMAN_KAPPA = 1e7  # garry's .kalman_kappa: a diffuse start
KALMAN_TASKS_PER_WORKER = 4  # how far both arms split the kernel: a worker must never wait on an empty queue
# Stops at a summed objective gap just inside garry's 12 iterations, measured on small aligned only: 1.69e-6
# against 1.85e-6. Equal in sum, not per pixel: garry's median pixel is tighter, 2e-10 against 6e-7, and its
# few-date pixels looser. geomad's default for float input, 1e-4 DN, reaches 5e-11 at about 1.4 times this wall.
# On warp this eps says nothing: the int16 read rounds, so the gap floors at 5.3e-6 at any eps. See spec "gap".
GEOMAD_EPS = 0.45
GEOMAD_MAXITERS = 1000


# ---- the median kernel, and proof that it ran ------------------------------------------------------

numbagg_calls = []
numbagg_compile_s = []  # one entry, from the process's first call
compile_lock = threading.Lock()
_nanmedian = numbagg.nanmedian


def compile_numbagg(a, **kwargs) -> None:
    """numba compiles numbagg on its first call in a process, and that stays in wall, as XLA's compile does for
    garry. A call on one cell times the compile alone: the first real call may be a whole cube."""
    with compile_lock:
        if not numbagg_compile_s:
            start = time.perf_counter()
            _nanmedian(np.full((1,) * a.ndim, np.nan, a.dtype), **kwargs)
            numbagg_compile_s.append(time.perf_counter() - start)


def nanmedian_counted(a, **kwargs):
    if not numbagg_compile_s:
        compile_numbagg(a, **kwargs)
    if a.size > 1:  # Dask infers metadata on empty and single-cell arrays: only real blocks are proof
        numbagg_calls.append(1)  # thread safe, and nothing beside a kernel call
    return _nanmedian(a, **kwargs)


def use_lane_median() -> None:
    """ts_hampel's median. numbagg has no loop for short windows: it allocates a float64 buffer per lane, and no
    package has a Hampel filter for this shape, so this is the loop a skilled user writes. Where a stock function
    exists the suite uses it. numba compiles a gufunc when it is defined, so this runs inside the clock, once."""
    global _nanmedian
    if numbagg_compile_s:
        return
    start = time.perf_counter()

    @numba.guvectorize(
        [(numba.float32[:], numba.float64[:]), (numba.float64[:], numba.float64[:])],
        "(n)->()",
        nopython=True,
        target="parallel",
    )
    def lane_median(lane, out):
        buffer = np.empty(lane.shape[0], np.float64)
        k = 0
        for i in range(lane.shape[0]):
            value = float(lane[i])
            if value == value:
                j = k
                while j > 0 and buffer[j - 1] > value:
                    buffer[j] = buffer[j - 1]
                    j -= 1
                buffer[j] = value
                k += 1
        if k == 0:
            out[0] = np.nan
        elif k % 2:
            out[0] = buffer[k // 2]
        else:
            out[0] = 0.5 * (buffer[k // 2 - 1] + buffer[k // 2])

    def median(a, axis=None, **kwargs):
        return lane_median(np.moveaxis(a, axis[0] if isinstance(axis, (list, tuple)) else axis, -1))

    _nanmedian = median
    numbagg_compile_s.append(time.perf_counter() - start)


# dask.array.nanmedian and xarray both look the function up on the module at call time.
numbagg.nanmedian = nanmedian_counted
USES_NUMBAGG = {"median", "ndvi", "ts_hampel"}  # ts_hampel through use_lane_median(), behind the same call


# ---- context --------------------------------------------------------------------------------------


@dataclass
class Ctx:
    args: argparse.Namespace
    spec: dict
    task: dict
    params: dict
    root: Path
    data: dict
    items: pystac.ItemCollection | None
    chunk: int
    read_pool: int
    pool: ThreadPoolExecutor = field(default_factory=lambda: ThreadPoolExecutor(THREADS))
    workers: ProcessPoolExecutor | None = None

    @property
    def lazy(self) -> bool:
        return self.args.arm == "odc-dask"


def find_task(spec: dict, task_id: str) -> dict:
    # The reference uses the geomedian task's data and tolerances.
    wanted = "geomedian" if task_id == "geomedian_ref" else task_id
    for task in spec["tasks"]:
        if task["id"] == wanted:
            return task
    raise SystemExit(f"odc.py: no task {task_id}")


def make_ctx(args: argparse.Namespace) -> Ctx:
    if "GARRY_BENCH_DATA" not in os.environ:
        raise SystemExit("odc.py: set GARRY_BENCH_DATA")
    spec = json.loads((HERE / "spec" / "tasks.json").read_text())
    task = find_task(spec, args.task)
    root = Path(os.environ["GARRY_BENCH_DATA"]) / args.size
    manifest = json.loads((root / "manifest.json").read_text())
    root = Path(manifest["root"])
    name = f"hls-{args.variant}" if task["data"] == "hls" else task["data"]
    data = manifest["datasets"][name]
    items = pystac.ItemCollection.from_file(str(root / data["items"])) if "items" in data else None
    chunk = args.chunk or spec["arms"]["odc-dask"]["chunk"].get(args.size)
    if chunk is None:
        raise SystemExit(f"odc.py: no chunk swept at size {args.size}: see Sweeps in benchmarks/README.md")
    read_pool = args.read_pool or spec["arms"]["odc-threads"]["read_pool"]
    return Ctx(args, spec, task, task["params"], root, data, items, chunk, read_pool)


# ---- pools ----------------------------------------------------------------------------------------


def single_threaded_gdal() -> None:
    os.environ["GDAL_NUM_THREADS"] = "1"


def start_workers() -> ProcessPoolExecutor:
    """Processes for a kernel the GIL would stall, started up front so wall excludes them, as for garry's pools.
    fork, before anything here has started a thread."""
    workers = ProcessPoolExecutor(
        THREADS, mp_context=multiprocessing.get_context("fork"), initializer=single_threaded_gdal
    )
    list(workers.map(abs, range(2 * THREADS)))
    return workers


# ---- reads ----------------------------------------------------------------------------------------


def geobox(ctx: Ctx) -> GeoBox:
    g = ctx.data["grid"]
    return GeoBox.from_bbox((g["xmin"], g["ymin"], g["xmax"], g["ymax"]), crs=g["crs"], resolution=g["res"])


def load_hls(ctx: Ctx, bands: list[str], dtype: str, nodata: float, items=None) -> xr.Dataset:
    """The dtype, the nodata, the per-band resampling and the daily mosaics are explicit, so nothing is left
    to what the STAC metadata happens to say. Without nodata= a float32 read keeps the metadata's -9999."""
    read = ctx.spec["hls_read"]
    placement = {"chunks": {"x": ctx.chunk, "y": ctx.chunk}} if ctx.lazy else {"pool": ctx.read_pool}
    return odc.stac.load(
        ctx.items if items is None else items,
        bands=bands,
        geobox=geobox(ctx),
        groupby=read["odc_groupby"],
        resampling=read["resampling"],
        dtype=dtype,
        nodata=nodata,
        **placement,
    )


def hls_masked(ctx: Ctx, bands: list[str], dtype: str = "float32") -> xr.Dataset:
    """Bits 0-3 of Fmask flag a pixel, then an opening despeckles and a dilation buffers, disk elements, as
    odc-stats does. Fmask nodata reads as clear, the QA-fill convention garry follows too.

    Two loads, because a per-band dtype mapping fails on the chunked path of odc-stac 0.5.3. The opening is
    spelled as erosion then dilation, which is the same operation: mask_cleanup sums radii to size its Dask
    overlap, so ("opening", r) gets r where it needs 2r and changes pixels at chunk borders. Masked pixels take
    the band's nodata: NaN in float32, the file's -9999 in int16."""
    d = ctx.data
    m = ctx.spec["hls_mask"]
    fill = float("nan") if dtype == "float32" else d["nodata"]
    fmask = load_hls(ctx, [d["mask_band"]], "uint8", d["mask_nodata"])[d["mask_band"]]
    flagged = ((fmask & sum(1 << bit for bit in m["bits"])) != 0) & (fmask != d["mask_nodata"])
    filters = [("erosion", m["open"]), ("dilation", m["open"]), ("dilation", m["dilate"])]
    if ctx.lazy:
        return erase_bad(load_hls(ctx, bands, dtype, fill), mask_cleanup(flagged, filters))  # fill: the nodata attr

    def clean_slice(flags: np.ndarray) -> np.ndarray:
        # One pixel of clear border: what the Dask path pads with, so the two arms agree at the raster edge.
        return mask_cleanup_np(np.pad(flags, 1), filters)[1:-1, 1:-1]

    # The per-slice filter the Dask graph runs; the pool stands in for the graph's threads. The mask comes
    # first: each filter's distance map is a whole slice per thread, and it need not sit beside the cube.
    clean = np.stack(list(ctx.pool.map(clean_slice, flagged.data)))
    ds = load_hls(ctx, bands, dtype, fill)
    for band in bands:
        ds[band].data[clean] = fill
    return ds


# ---- output ---------------------------------------------------------------------------------------


def write_tif(ctx: Ctx, data: xr.DataArray, path: str) -> None:
    """The output spec with rioxarray: tiled DEFLATE, band interleave, no overviews, no predictor."""
    out = {**ctx.spec["output"], **ctx.task.get("output", {})}
    nodata = float("nan") if out["nodata"] == "nan" else out["nodata"]
    data = data.transpose("band", "y", "x").rio.write_nodata(nodata)
    data.rio.to_raster(
        path,
        driver=out["driver"],
        dtype=out["dtype"],
        tiled=True,
        blockxsize=out["blocksize"],
        blockysize=out["blocksize"],
        compress=out["compress"],
        interleave=out["interleave"],
        bigtiff=out["bigtiff"],
        num_threads=THREADS,
    )


def as_bands(result: xr.Dataset, bands: list[str]) -> xr.DataArray:
    return result[bands].to_array("band").astype("float32")


def computed(ctx: Ctx, result):
    return result.compute() if ctx.lazy else result


# ---- tasks ----------------------------------------------------------------------------------------


def task_median(ctx: Ctx, path: str) -> None:
    bands = ctx.params["bands"]
    write_tif(ctx, computed(ctx, as_bands(hls_masked(ctx, bands).median("time"), bands)), path)


def task_ndvi(ctx: Ctx, path: str) -> None:
    red, nir = ctx.params["red"], ctx.params["nir"]
    composite = hls_masked(ctx, [red, nir]).median("time")
    ndvi = (composite[nir] - composite[red]) / (composite[nir] + composite[red])
    write_tif(ctx, computed(ctx, ndvi.expand_dims(band=[1])), path)


def task_geomedian(ctx: Ctx, path: str) -> None:
    """int16 in RAM, as odc-stats holds it: half the float32 cube, 8.9 GB on medium against 17.7, where no Dask
    plan tried streams. geomad's int16 kernel takes the nodata, drops a date with any band missing and returns
    float32. scale=1 keeps eps in DN, because that kernel defaults to reflectance. geomedian_with_mads would
    truncate the result to int16, so Dask takes odc.algo's other entry to the kernel, with one block: a chunked
    sink raises in odc-algo 1.2.2 unless the block divides the grid, and geomad's OpenMP does the parallel part."""
    bands = ctx.params["bands"]
    masked = hls_masked(ctx, bands, "int16")
    kernel = {
        "eps": GEOMAD_EPS,
        "maxiters": GEOMAD_MAXITERS,
        "nodata": ctx.data["nodata"],
        "scale": 1.0,
        "num_threads": THREADS,
    }
    if ctx.lazy:
        gm = xr_geomedian(yxbt_sink(masked[bands], (-1, -1, -1, -1)), axis="time", **kernel).data.compute()
    else:
        gm = geomad.nangeomedian_pcm(yxbt_copy(ctx, masked, bands), nocheck=True, **kernel)
    coords = {"band": bands, "y": masked.y, "x": masked.x, "spatial_ref": masked.spatial_ref}
    write_tif(ctx, xr.DataArray(gm.transpose(2, 0, 1), dims=("band", "y", "x"), coords=coords), path)


def yxbt_copy(ctx: Ctx, masked: xr.Dataset, bands: list[str]) -> np.ndarray:
    """(y, x, band, t) for geomad, one band at a time, freeing each as it goes: two whole cubes would not fit."""
    nt, ny, nx = masked[bands[0]].shape
    out = np.empty((ny, nx, len(bands), nt), masked[bands[0]].dtype)
    for b, band in enumerate(bands):
        source = masked[band].data

        def copy_rows(y: int) -> None:
            out[y, :, b, :] = source[:, y, :].T

        list(ctx.pool.map(copy_rows, range(ny)))
        del masked[band], source
    return out


def task_geomedian_ref(ctx: Ctx) -> None:
    """The tight reference, once, on a grid of pixels: enough to rank a solution by its objective."""
    params = ctx.params
    bands = params["bands"]
    stride = params["objective_stride"]
    grid = ctx.data["grid"]
    rows = np.arange(stride // 2, grid["ny"], stride)
    cols = np.arange(stride // 2, grid["nx"], stride)
    # Lazy, so a slice is read, masked and sampled in its own task, and the cube is never whole in memory.
    picked = hls_masked(ctx, bands).isel(y=rows, x=cols)
    cube = picked[bands].to_array("band").compute().transpose("y", "x", "band", "time").data
    ref = geomad.nangeomedian_pcm(cube, num_threads=THREADS, nocheck=True, **params["reference"])
    n = len(rows) * len(cols)
    rr, cc = np.meshgrid(rows, cols, indexing="ij")
    folder = ctx.root / "ref"
    folder.mkdir(exist_ok=True)
    np.savez_compressed(
        folder / f"geomedian-{ctx.args.variant}.npz",
        # float64, so check.py sums the objective without float32 rounding swamping a small gap
        cube=cube.transpose(2, 3, 0, 1).reshape(len(bands), -1, n).astype("float64"),
        ref=ref.transpose(2, 0, 1).reshape(len(bands), n).astype("float64"),
        rows=rr.ravel(),
        cols=cc.ravel(),
        digest=ctx.data["digest"],  # check.py refuses a reference of other data
    )
    emit({"phase": "ref", "pixels": n, "bands": bands, **params["reference"]})


def annual_stack(ctx: Ctx) -> xr.DataArray:
    """The annual files as (t, y, x) float32, NaN gaps, one chunk along t. lock=False: a read per file handle
    needs no global lock, and each dask task opens its own."""
    paths = [ctx.root / f["path"] for f in ctx.data["files"]]
    years = xr.IndexVariable("t", ctx.data["years"])
    if ctx.lazy:
        chunks = {"y": ctx.chunk, "x": ctx.chunk}
        layers = [rioxarray.open_rasterio(p, chunks=chunks, lock=False) for p in paths]
        return xr.concat(layers, dim=years).squeeze("band", drop=True).chunk({"t": -1})
    layers = list(ctx.pool.map(lambda p: rioxarray.open_rasterio(p, lock=False).load(), paths))
    return xr.concat(layers, dim=years).squeeze("band", drop=True)


def task_ts_hampel(ctx: Ctx, path: str) -> None:
    """Window, median and scaled MAD, the classic filter. construct pads the series ends with NaN, so a window
    shrinks there, and the median skips NaN, so gaps never count; a gap stays a gap."""
    use_lane_median()
    k, t0 = ctx.params["k"], ctx.params["t0"]
    cube = annual_stack(ctx)
    window = cube.rolling(t=2 * k + 1, center=True).construct("w")
    med = window.median("w")
    mad = abs(window - med).median("w") * 1.4826
    out = cube.where(abs(cube - med) <= t0 * mad, med).where(cube.notnull())
    write_tif(ctx, computed(ctx, out.rename(t="band").astype("float32")), path)


def smooth_block(block: np.ndarray, params: dict) -> np.ndarray:
    """garry's local linear trend, smoothed level of a (t, y, x) block. A pixel under three observations is NaN,
    as in kalman_llt().

    kalman_llt() predicts once from a diffuse N(0, kappa I) before the first year, so the covariance simdkalman
    takes for year one is that prediction: F (kappa I) F' + Q. Q then drives each step t -> t+1 on both sides,
    the one convention to name. Noise is sigma squared on both sides."""
    transition = np.array([[1.0, 1.0], [0.0, 1.0]])
    noise = np.diag([params["sigma_lvl"] ** 2, params["sigma_slp"] ** 2])
    kf = simdkalman.KalmanFilter(
        state_transition=transition,
        process_noise=noise,
        observation_model=np.array([[1.0, 0.0]]),
        observation_noise=np.array([[params["sigma_obs"] ** 2]]),
    )
    series = block.reshape(block.shape[0], -1).T.astype("float64")
    smooth = kf.smooth(
        series,
        initial_value=np.zeros(2),
        initial_covariance=transition @ (KALMAN_KAPPA * np.eye(2)) @ transition.T + noise,
        covariances=False,
    )
    level = np.where((~np.isnan(series)).sum(axis=1, keepdims=True) >= 3, smooth.observations.mean, np.nan)
    return level.T.reshape(block.shape).astype("float32")


def kalman_block(grid: dict) -> int:
    """Side of a square kernel block that gives at least the threads arm's task count on any grid. A kernel
    batch, not a read chunk: a fixed side would leave workers idle on a small raster."""
    return int(math.sqrt(grid["nx"] * grid["ny"] / (KALMAN_TASKS_PER_WORKER * THREADS)))


def task_ts_kalman(ctx: Ctx, path: str) -> None:
    """simdkalman runs in processes on both arms, because it is many small NumPy calls: under threads the GIL
    costs more than the threads give, and twenty are slower than one. A skilled user sees that and moves it,
    and moves only it: reads stay on threads, where the first would otherwise pay the process scheduler."""
    cube = annual_stack(ctx)
    if ctx.lazy:
        block = kalman_block(ctx.data["grid"])
        cube = cube.chunk({"y": block, "x": block}).persist()
        meta = np.empty((0, 0, 0), "float32")
        level = cube.data.map_blocks(smooth_block, params=ctx.params, dtype="float32", meta=meta)
        out = cube.copy(data=level.compute(scheduler="processes", pool=ctx.workers))
    else:
        blocks = np.array_split(cube.data, KALMAN_TASKS_PER_WORKER * THREADS, axis=1)
        out = cube.copy(data=np.concatenate(list(ctx.workers.map(smooth_block, blocks, repeat(ctx.params))), axis=1))
    write_tif(ctx, out.rename(t="band"), path)


def window_nanmean(block: np.ndarray, radius: int) -> np.ndarray:
    """Mean of the valid cells in a square window. uniform_filter is a running sum, O(1) in the radius, and
    runs on float64 so the running sum stays exact enough."""
    size = 2 * radius + 1
    valid = ~np.isnan(block)
    total = ndimage.uniform_filter(np.where(valid, block, 0.0).astype("float64"), size, mode="constant")
    count = np.rint(ndimage.uniform_filter(valid.astype("float64"), size, mode="constant") * size**2)
    with np.errstate(divide="ignore", invalid="ignore"):
        return (total * size**2 / count).astype("float32")


def task_focal(ctx: Ctx, path: str) -> None:
    p = ctx.params
    item = ctx.items[ctx.data["item_t"].index(p["t"])]
    slice_ = load_hls(ctx, [p["band"]], "float32", float("nan"), items=[item])[p["band"]].isel(time=0, drop=True)
    if ctx.lazy:
        # A NaN boundary: beyond the raster nothing is valid, the same answer as the padded single block.
        radius = p["radius"]
        data = slice_.data.map_overlap(window_nanmean, depth=radius, boundary=np.nan, radius=radius, dtype="float32")
        out = slice_.copy(data=data.compute())
    else:
        out = slice_.copy(data=window_nanmean(slice_.data, p["radius"]))
    write_tif(ctx, out.expand_dims(band=[1]), path)


def task_wide_write(ctx: Ctx, path: str) -> None:
    source = ctx.root / ctx.data["files"][0]["path"]
    if ctx.lazy:
        cube = rioxarray.open_rasterio(source, chunks={"band": 1, "y": ctx.chunk, "x": ctx.chunk}, lock=False)
    else:
        cube = rioxarray.open_rasterio(source, lock=False)
    write_tif(ctx, cube.compute(), path)


TASKS = {
    "median": task_median,
    "ndvi": task_ndvi,
    "geomedian": task_geomedian,
    "ts_hampel": task_ts_hampel,
    "ts_kalman": task_ts_kalman,
    "focal": task_focal,
    "wide_write": task_wide_write,
}


# ---- harness --------------------------------------------------------------------------------------


def versions() -> dict:
    return {
        "python": sys.version.split()[0],
        "numpy": np.__version__,
        "dask": dask.__version__,
        "xarray": xr.__version__,
        "numba": numba.__version__,
        "numbagg": numbagg.__version__ if hasattr(numbagg, "__version__") else None,
        "scipy": scipy.__version__,
        "odc_stac": odc.stac.__version__,
        "odc_algo": odc.algo.__version__,
        "geomad": geomad.__version__,
        "rasterio": rasterio.__version__,
        "rioxarray": rioxarray.__version__,
        "gdal": rasterio.__gdal_version__,
        "proj": pyproj.proj_version_str,
    }


def threading_layer() -> str | None:
    """Numba names the layer only after a parallel region has run."""
    try:
        return numba.threading_layer()
    except ValueError:
        return None


def env_record(ctx: Ctx) -> dict:
    return {
        "phase": "env",
        "arm": ctx.args.arm,
        **versions(),
        "bench_threads": THREADS,
        "dask_workers": dask.config.get("num_workers", None),
        "dask_scheduler": dask.config.get("scheduler", None),
        "dask_chunk": ctx.chunk if ctx.lazy else None,
        "read_pool": None if ctx.lazy else ctx.read_pool,
        "numba_threads": numba.get_num_threads(),
        "numba_layer": threading_layer(),
        "numbagg_calls": len(numbagg_calls),
        "geomad_eps": GEOMAD_EPS,
        "geomad_maxiters": GEOMAD_MAXITERS,
        "gdal_num_threads": os.environ["GDAL_NUM_THREADS"],
        "gdal_cachemax": os.environ.get("GDAL_CACHEMAX"),
    }


def emit(record: dict) -> None:
    print(json.dumps(record), flush=True)


def run_bench(ctx: Ctx, startup_s: float) -> None:
    task_id = ctx.args.task
    run = TASKS[task_id]
    phases = ["cold", "warm"] if ctx.args.warm else ["cold"]
    for phase in phases:
        path = os.path.join(ctx.args.out, f"{phase}.tif")
        calls = len(numbagg_calls)
        start = time.perf_counter()
        run(ctx, path)
        wall = time.perf_counter() - start
        calls = len(numbagg_calls) - calls
        if task_id in USES_NUMBAGG and calls == 0:
            raise SystemExit(f"odc.py: {task_id} did not reach numbagg")
        line = {"phase": phase, "wall_s": round(wall, 3), "startup_s": round(startup_s, 3), "numbagg_calls": calls}
        if phase == "cold" and numbagg_compile_s:
            line["jit_s"] = round(numbagg_compile_s[0], 3)
        emit(line)
        gc.collect()  # xarray holds cycles: the cold cube must not sit beside the warm one, or the peak doubles
    emit(env_record(ctx))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--task", required=True)
    parser.add_argument("--size", required=True)
    parser.add_argument("--variant", required=True)
    parser.add_argument("--out")
    parser.add_argument("--warm", action="store_true")
    parser.add_argument("--arm", choices=ARMS, default="odc-dask")
    parser.add_argument("--chunk", type=int)
    parser.add_argument("--read-pool", type=int)
    args = parser.parse_args()
    dask.config.set(scheduler="threads", num_workers=THREADS)
    ctx = make_ctx(args)
    if args.task == "ts_kalman":
        ctx.workers = start_workers()
    startup_s = time.perf_counter() - STARTED
    if args.task == "geomedian_ref":
        task_geomedian_ref(ctx)
        return 0
    if args.out is None:
        raise SystemExit("odc.py: --out is required")
    run_bench(ctx, startup_s)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
