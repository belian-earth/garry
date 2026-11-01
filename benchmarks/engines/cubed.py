#!/usr/bin/env python3
"""Cubed, the memory track: median, ndvi and geomedian on the pre-warped Zarr store, on the processes
executor, with allowed_mem at RAM over workers. Completion and peak come first, wall second, and the arm
stays out of the headline table. The engine contract is at the top of ../README.md.

Cubed has no reader, no warp and, at 0.28.0, no median, so this arm starts from `hls-zarr`, whose chunks
hold whole time series, and brings its kernels through map_blocks. RAM is the run's own memory cap when
it has one, because that is what the workers share. Each kernel declares its working arrays through
extra_projected_mem: Cubed cannot see inside a map_blocks function, and the bound under test is worth
nothing if the plan omits the largest allocation. A refused plan raises, which is the arm's result.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

ENGINE = Path(__file__).resolve().parent
# This file has the package's name: its folder must leave the path before `import cubed` finds it instead.
sys.path[:] = [p for p in sys.path if Path(p).resolve() != ENGINE]
SPEC = ENGINE.parent / "spec" / "tasks.json"

STARTED = time.perf_counter()
THREADS = int(os.environ.get("BENCH_THREADS") or os.cpu_count())
# One single-threaded worker per thread of the budget. Threaded kernels inside a pool would oversubscribe.
os.environ["NUMBA_NUM_THREADS"] = "1"
os.environ.setdefault("GDAL_CACHEMAX", "256")

import cubed  # noqa: E402
import numpy as np  # noqa: E402
from cubed.runtime.executors.local import ProcessesExecutor  # noqa: E402


def note_worker(folder: str, kernel: str, **facts) -> None:
    """Leave one note per worker and kernel: proof of what ran there, read back for the env record."""
    path = Path(folder) / f"{kernel}-{os.getpid()}.json"
    if not path.exists():
        path.write_text(json.dumps({"pid": os.getpid(), "kernel": kernel, **facts}))


def clean_block(fmask: np.ndarray, bits: int, nodata: int, opening: int, dilation: int, halo: int, proof: str) -> np.ndarray:
    """Bad pixels of one (t, y, x) block with its halo, cleaned slice by slice and cut back to the block.
    odc-algo's isotropic opening then dilation; Fmask fill and the world's edge both read as clear, as in
    garry's qa_bits() and Dask's boundary=False. A distance transform with no background measures from a
    phantom corner, which stays inside the halo: it reaches `dilation + opening` pixels and the halo is
    wider."""
    from scipy.ndimage import distance_transform_edt as edt

    note_worker(proof, "clean")
    flagged = (fmask != nodata) & ((fmask & bits) != 0)
    nt, ny, nx = fmask.shape[0], fmask.shape[1] - 2 * halo, fmask.shape[2] - 2 * halo
    out = np.empty((nt, ny, nx), np.bool_)
    for t, mask in enumerate(flagged):
        mask = edt(mask) > opening  # erosion
        mask = edt(~mask) <= opening  # dilation, ending the opening
        mask = edt(~mask) <= dilation
        out[t] = mask[halo : halo + ny, halo : halo + nx]
    return out


def median_block(values: np.ndarray, bad: np.ndarray, nodata: int, proof: str) -> np.ndarray:
    """Masked median over t of one whole-t block, the kernel Dask's nanmedian selects."""
    import numba
    import numbagg

    x = values.astype(np.float32)
    x[bad | (values == nodata)] = np.nan
    out = numbagg.nanmedian(x, axis=0).astype(np.float32)
    note_worker(proof, "median", numbagg=numbagg.__version__, threading_layer=numba.threading_layer(), numba_threads=numba.get_num_threads())
    return out


def geomedian_block(*blocks: np.ndarray, nodata: int, eps: float, maxiters: int, proof: str) -> np.ndarray:
    """Geometric median over t of one whole-t block per band, with the mask last. Bands first on the way
    out. geomad drops a date from a pixel when any band is NaN, as garry does. eps and maxiters are what
    geomedian_with_mads() passes for float input."""
    import geomad

    note_worker(proof, "geomedian", geomad=geomad.__version__)
    *bands, bad = blocks
    nt, ny, nx = bad.shape
    cube = np.empty((ny, nx, len(bands), nt), np.float32)
    bad = np.moveaxis(bad, 0, -1)
    for b, values in enumerate(bands):
        plane = cube[:, :, b, :]
        plane[...] = np.moveaxis(values, 0, -1)
        plane[bad | (plane == nodata)] = np.nan
    return np.moveaxis(geomad.nangeomedian_pcm(cube, num_threads=1, nocheck=True, eps=eps, maxiters=maxiters), -1, 0)


class Stack:
    """The lazy inputs of one phase: value bands from the store, and the cleaned mask they share."""

    def __init__(self, entry: dict, root: str, mask: dict, spec: cubed.Spec, proof: str):
        self.store = str(Path(root) / entry["store"])
        self.spec = spec
        self.nodata = entry["nodata"]
        self.proof = proof
        fmask = self.band(entry["mask_band"])
        # Erode, dilate, dilate: each widens what a pixel depends on. odc-algo's sum of radii is `open` short.
        halo = 2 * mask["open"] + mask["dilate"]
        self.bad = cubed.map_overlap(
            clean_block,
            fmask,
            dtype=np.bool_,
            chunks=fmask.chunks,
            depth={0: 0, 1: halo, 2: halo},
            boundary={0: "none", 1: 0, 2: 0},
            extra_projected_mem=fmask.chunkmem,  # the flags before cleaning
            bits=sum(1 << bit for bit in mask["bits"]),
            nodata=entry["mask_nodata"],
            opening=mask["open"],
            dilation=mask["dilate"],
            halo=halo,
            proof=proof,
        )

    def band(self, name: str):
        return cubed.from_zarr(self.store, path=name, spec=self.spec)

    def median(self, name: str):
        values = self.band(name)
        return cubed.map_blocks(
            median_block,
            values,
            self.bad,
            dtype=np.float32,
            drop_axis=0,
            # The f32 copy of an int16 chunk. numba's compile is not data, so it stays out: tasks_over_allowed shows it.
            extra_projected_mem=2 * values.chunkmem,
            nodata=self.nodata,
            proof=self.proof,
        )


def median(stack: Stack, params: dict) -> list:
    return [stack.median(band) for band in params["bands"]]


def ndvi(stack: Stack, params: dict) -> list:
    red, nir = stack.median(params["red"]), stack.median(params["nir"])
    return [(nir - red) / (nir + red)]


def geomedian(stack: Stack, params: dict) -> list:
    bands = [stack.band(band) for band in params["bands"]]
    return [
        cubed.map_blocks(
            geomedian_block,
            *bands,
            stack.bad,
            dtype=np.float32,
            chunks=((len(bands),), *stack.bad.chunks[1:]),
            extra_projected_mem=sum(2 * b.chunkmem for b in bands),  # the f32 cube geomad takes
            nodata=stack.nodata,
            eps=1e-4,
            maxiters=1000,
            proof=stack.proof,
        )
    ]


TASKS = {"median": median, "ndvi": ndvi, "geomedian": geomedian}


class TaskLog(cubed.Callback):
    """What the workers report: tasks, busy seconds, the first start, and the highest process peak."""

    def __init__(self, allowed: int):
        self.allowed = allowed
        self.tasks = self.over = self.peak = 0
        self.busy = 0.0
        self.first = float("inf")

    def on_task_end(self, event) -> None:
        self.tasks += event.num_tasks
        self.busy += event.function_end_tstamp - event.function_start_tstamp
        self.first = min(self.first, event.function_start_tstamp)
        self.peak = max(self.peak, event.peak_measured_mem_end)
        self.over += event.peak_measured_mem_end > self.allowed


def available_ram() -> tuple[int, str]:
    """The tightest of the machine and every memory.max on this process's cgroup path."""
    ram, source = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES"), "physical"
    relative = Path("/proc/self/cgroup").read_text().strip().rpartition("::")[2].lstrip("/")
    node = Path("/sys/fs/cgroup") / relative
    for folder in [node, *node.parents]:
        limit = folder / "memory.max"
        if limit.exists() and limit.read_text().strip() != "max":
            if int(limit.read_text()) < ram:
                ram, source = int(limit.read_text()), "cgroup"
    return ram, source


def folder_mb(path: Path) -> float:
    return round(sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) / 2**20, 1)


def write_tif(path: Path, grid: dict, stores: list[Path]) -> None:
    """One plain GeoTIFF, as spec/tasks.json says, streamed chunk by chunk so the driver stays small."""
    import rasterio
    import zarr
    from rasterio.transform import from_origin
    from rasterio.windows import Window

    arrays = [zarr.open_array(store, mode="r") for store in stores]
    counts = [a.shape[0] if a.ndim == 3 else 1 for a in arrays]
    profile = {
        "driver": "GTiff",
        "width": grid["nx"],
        "height": grid["ny"],
        "count": sum(counts),
        "dtype": "float32",
        "nodata": float("nan"),
        "crs": grid["crs"],
        "transform": from_origin(grid["xmin"], grid["ymax"], grid["res"], grid["res"]),
        "tiled": True,
        "blockxsize": 256,
        "blockysize": 256,
        "compress": "deflate",
        "interleave": "band",
        "bigtiff": "if_safer",
        "num_threads": THREADS,
    }
    chunk_y, chunk_x = arrays[0].chunks[-2:]
    with rasterio.open(path, "w", **profile) as dst:
        for y in range(0, grid["ny"], chunk_y):
            for x in range(0, grid["nx"], chunk_x):
                ny, nx = min(chunk_y, grid["ny"] - y), min(chunk_x, grid["nx"] - x)
                window = Window(x, y, nx, ny)
                first = 1
                for array, count in zip(arrays, counts):
                    block = array[..., y : y + ny, x : x + nx]
                    block = block if block.ndim == 3 else block[np.newaxis]
                    dst.write(block, indexes=list(range(first, first + count)), window=window)
                    first += count


def run_phase(phase: str, args: argparse.Namespace, task: dict, entry: dict, root: str, mask: dict, memory: dict, startup_s: float, proof: Path) -> None:
    out = Path(args.out).resolve()
    work = Path(tempfile.mkdtemp(prefix=f"cubed-{phase}-", dir=out))
    try:
        spec = cubed.Spec(
            work_dir=str(work / "intermediate"),
            allowed_mem=memory["allowed_mem"],
            reserved_mem=memory["reserved_mem"],
            executor=ProcessesExecutor(max_workers=THREADS),
        )
        stack = Stack(entry, root, mask, spec, str(proof))
        targets = [work / f"output-{i}.zarr" for i in range(3)]
        outputs = TASKS[task["id"]](stack, task["params"])
        arrays = cubed.store(outputs, [str(t) for t in targets[: len(outputs)]], compute=False)
        plan = cubed.plan(*arrays)
        log = TaskLog(memory["allowed_mem"])

        begin, clock = time.time(), time.perf_counter()
        cubed.compute(*arrays, callbacks=[log], _return_in_memory_array=False)
        computed = time.perf_counter()
        write_tif(out / f"{phase}.tif", entry["grid"], targets[: len(outputs)])
        ended = time.perf_counter()

        # Cubed builds its pool inside compute and spawns workers on demand, so only the wait for the
        # first can leave wall. Later workers, and each one's numba compile, stay in it.
        pool_s = max(log.first - begin, 0.0)
        line = {
            "phase": phase,
            "wall_s": round(ended - clock - pool_s, 3),
            "startup_s": round(startup_s + pool_s, 3),
            "pool_s": round(pool_s, 3),
            "compute_s": round(computed - clock - pool_s, 3),
            "write_s": round(ended - computed, 3),
            "tasks": log.tasks,
            "busy_s": round(log.busy, 1),
            "projected_mem_mb": round(plan.max_projected_mem / 2**20, 1),
            "allowed_mem_mb": round(memory["allowed_mem"] / 2**20, 1),
            "task_peak_mb": round(log.peak / 2**20, 1),
            "tasks_over_allowed": int(log.over),
            "spill_mb": folder_mb(work / "intermediate"),
            "output_zarr_mb": sum(folder_mb(t) for t in targets[: len(outputs)]),
        }
        print(json.dumps(line), flush=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def env_line(memory: dict, proof: Path) -> dict:
    import rasterio
    import zarr

    notes = [json.loads(p.read_text()) for p in proof.glob("*.json")]
    facts = [n for n in notes if "numbagg" in n]
    return {
        "phase": "env",
        "cubed": cubed.__version__,
        "zarr": zarr.__version__,
        "numpy": np.__version__,
        "gdal": rasterio.__gdal_version__,
        "proj": rasterio.__proj_version__,
        "executor": "processes",
        "workers": THREADS,
        "ram_mb": round(memory["ram"] / 2**20),
        "ram_source": memory["ram_source"],
        "allowed_mem_mb": round(memory["allowed_mem"] / 2**20, 1),
        "reserved_mem_mb": round(memory["reserved_mem"] / 2**20, 1),
        "gdal_cachemax": os.environ["GDAL_CACHEMAX"],
        "worker_processes_seen": len({n["pid"] for n in notes}),
        "workers_ran_numbagg": len(facts),
        "numbagg": facts[0]["numbagg"] if facts else None,
        "numba_threading_layer": facts[0]["threading_layer"] if facts else None,
        "numba_threads": facts[0]["numba_threads"] if facts else None,
        "geomad": next((n["geomad"] for n in notes if "geomad" in n), None),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--task", required=True, choices=sorted(TASKS))
    parser.add_argument("--size", required=True)
    parser.add_argument("--variant", default="aligned", choices=["aligned"], help="the store holds the aligned stack only")
    parser.add_argument("--out", required=True)
    parser.add_argument("--warm", action="store_true")
    parser.add_argument("--arm", default="cubed")
    parser.add_argument("--chunk", type=int, help="ignored: the store fixes the chunks")
    parser.add_argument("--read-pool", type=int, help="ignored: the Zarr store has no warp reader")
    args = parser.parse_args()

    spec = json.loads(SPEC.read_text())
    task = next(t for t in spec["tasks"] if t["id"] == args.task)
    data = Path(os.environ["GARRY_BENCH_DATA"]) / args.size
    manifest = json.loads((data / "manifest.json").read_text())
    entry = manifest["datasets"]["hls-zarr"]

    Path(args.out).mkdir(parents=True, exist_ok=True)
    proof = Path(tempfile.mkdtemp(prefix="cubed-proof-", dir=args.out))
    try:
        ram, ram_source = available_ram()
        measure = tempfile.mkdtemp(prefix="cubed-reserved-", dir=args.out)
        try:
            reserved = cubed.measure_reserved_mem(ProcessesExecutor(max_workers=1), work_dir=measure)
        finally:
            shutil.rmtree(measure, ignore_errors=True)
        memory = {"ram": ram, "ram_source": ram_source, "allowed_mem": ram // THREADS, "reserved_mem": reserved}
        startup_s = time.perf_counter() - STARTED
        for phase in ["cold", "warm"] if args.warm else ["cold"]:
            run_phase(phase, args, task, entry, manifest["root"], spec["hls_mask"], memory, startup_s, proof)
        print(json.dumps(env_line(memory, proof)), flush=True)
    finally:
        shutil.rmtree(proof, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
