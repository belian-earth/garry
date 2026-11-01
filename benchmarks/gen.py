#!/usr/bin/env python3
"""The only data generator. Writes synthetic rasters into $GARRY_BENCH_DATA, never into git.

Every array is a pure function of the seed and a key (dataset, tile, t, band), so worker count and
job order cannot change a pixel. The scene lives on one frame, the target grid, so tiles in other
CRSs and both hls variants sample the same world. Fields are Gaussian random fields with a power-law
spectrum; clouds are thresholded fields, so they cluster.

    python gen.py --size small [--datasets hls-warp,hls-aligned,embed,annual] [--force]
    python gen.py --size medium --estimate

Run it through `run.py gen`, which applies the memory cap.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import shutil
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from functools import lru_cache
from pathlib import Path

import numpy as np
import rasterio
from rasterio.transform import Affine
from rasterio.warp import transform as warp_transform
from rasterio.warp import transform_bounds
from scipy import fft, ndimage, special

HERE = Path(__file__).resolve().parent
ALL_DATASETS = ["hls-warp", "hls-aligned", "embed", "annual", "hls-zarr"]
DEFAULT_DATASETS = ["hls-warp", "hls-aligned", "embed", "annual"]
FRAME_MARGIN = 0.05  # the world extends past the target, so tile margins have data

# Reflectance model per band, in digital numbers: offset, gains on the vegetation and soil fields,
# seasonal swing, persistent 30 m texture, per-pixel sensor noise, cloud top, open water.
BAND_MODEL = {
    "B02": dict(base=320, veg=-140, soil=180, season=-30, tex=22, noise=16, cloud=6200, water=260),
    "B03": dict(base=520, veg=-120, soil=320, season=40, tex=26, noise=16, cloud=6000, water=340),
    "B04": dict(base=470, veg=-300, soil=620, season=-60, tex=34, noise=18, cloud=5800, water=220),
    "B08": dict(base=1500, veg=2600, soil=900, season=320, tex=70, noise=26, cloud=6100, water=120),
    "B11": dict(base=1300, veg=-350, soil=1700, season=-90, tex=48, noise=24, cloud=4300, water=70),
    "B12": dict(base=760, veg=-420, soil=1250, season=-80, tex=40, noise=22, cloud=3100, water=40),
}


def load_spec() -> dict:
    return json.loads((HERE / "spec" / "data.json").read_text())


def spec_hash() -> str:
    return hashlib.sha256((HERE / "spec" / "data.json").read_bytes()).hexdigest()


def rng_for(seed: int, *key) -> np.random.Generator:
    digest = hashlib.sha256("/".join(map(str, (seed, *key))).encode()).digest()
    return np.random.default_rng(int.from_bytes(digest[:16], "little"))


def grf(seed: int, key: tuple, shape: tuple, beta: float, scale_px: float) -> np.ndarray:
    """Unit-variance Gaussian random field: power spectrum (k0^2 + k^2)^(-beta/2), k0 = 1/scale_px."""
    h, w = shape
    white = rng_for(seed, *key).standard_normal(shape, dtype=np.float32)
    spectrum = fft.rfft2(white)
    fy = fft.fftfreq(h).astype(np.float32)[:, None]
    fx = fft.rfftfreq(w).astype(np.float32)[None, :]
    spectrum *= (fy * fy + fx * fx + 1.0 / (scale_px * scale_px)) ** (-beta / 4.0)
    field = fft.irfft2(spectrum, s=shape)
    field -= field.mean()
    field /= field.std()
    return field.astype(np.float32)


# ---- plan ---------------------------------------------------------------------------------------


def item_plan(hls: dict, variant: str) -> list[tuple[int, str]]:
    """(t, tile) pairs of a variant: most dates cover every tile, some only one, as a real orbit does."""
    v = hls["variants"][variant]
    every = v.get("single_tile_every")
    single = v.get("single_tile", {})
    plan = []
    for t in range(hls["t"]):
        only = single.get(str(t % every)) if every else None
        plan += [(t, tile) for tile in v["tiles"] if only in (None, tile)]
    return plan


def hls_dates(hls: dict) -> list[dt.date]:
    first = dt.date.fromisoformat(hls["first_date"])
    return [first + dt.timedelta(days=round(i * hls["span_days"] / hls["t"])) for i in range(hls["t"])]


def target_grid(target: dict, nx: int, ny: int) -> dict:
    res = target["res"]
    return {
        "crs": target["crs"],
        "res": res,
        "nx": nx,
        "ny": ny,
        "xmin": target["xmin"],
        "ymin": target["ymax"] - ny * res,
        "xmax": target["xmin"] + nx * res,
        "ymax": target["ymax"],
    }


def tile_grid(grid: dict, tile: dict) -> tuple[Affine, int, int]:
    """A tile's transform and shape: the frame in target fractions, snapped to the grid of its CRS."""
    res = grid["res"]
    span_x, span_y = grid["xmax"] - grid["xmin"], grid["ymax"] - grid["ymin"]
    left, right = (grid["xmin"] + f * span_x for f in tile["x"])
    bottom, top = (grid["ymin"] + f * span_y for f in tile["y"])
    if tile["crs"] != grid["crs"]:
        left, bottom, right, top = transform_bounds(grid["crs"], tile["crs"], left, bottom, right, top, densify_pts=21)
        left, bottom = math.floor(left / res) * res, math.floor(bottom / res) * res
        right, top = math.ceil(right / res) * res, math.ceil(top / res) * res
    width, height = round((right - left) / res), round((top - bottom) / res)
    return Affine(res, 0, left, 0, -res, top), width, height


# ---- the world ----------------------------------------------------------------------------------


class World:
    """Fields on one frame around the target grid, sampled at tile pixels. One per worker."""

    def __init__(self, spec: dict, size: str):
        self.seed = spec["seed"]
        self.hls = spec["datasets"]["hls"]
        self.size = size
        self.nx, self.ny = spec["sizes"][size]["hls"]
        self.grid = target_grid(self.hls["target"], self.nx, self.ny)
        self.mx = math.ceil(self.nx * FRAME_MARGIN)
        self.my = math.ceil(self.ny * FRAME_MARGIN)
        self.shape = (self.ny + 2 * self.my, self.nx + 2 * self.mx)
        self.field = lru_cache(maxsize=16)(self._field)
        self.tile_rowcol = lru_cache(maxsize=2)(self._tile_rowcol)
        self.tile_base = lru_cache(maxsize=2)(self._tile_base)
        self.cloud_state = lru_cache(maxsize=4)(self._cloud_state)

    def _field(self, key: tuple, beta: float, scale_m: float, step: int) -> np.ndarray:
        shape = tuple(math.ceil(n / step) for n in self.shape)
        return grf(self.seed, key, shape, beta, scale_m / (self.grid["res"] * step))

    def _tile_rowcol(self, variant: str, tile: str) -> tuple[np.ndarray, np.ndarray]:
        """Fractional world pixel of each tile pixel. A coarse lattice of exact transforms is enough."""
        spec_tile = self.hls["variants"][variant]["tiles"][tile]
        affine, width, height = tile_grid(self.grid, spec_tile)
        rows, cols = np.mgrid[0:height, 0:width].astype(np.float32)
        if spec_tile["crs"] == self.grid["crs"]:
            x = affine.c + (cols + 0.5) * affine.a
            y = affine.f + (rows + 0.5) * affine.e
            res = self.grid["res"]
            return (self.grid["ymax"] - y) / res + self.my - 0.5, (x - self.grid["xmin"]) / res + self.mx - 0.5
        step = 64
        lat_r = np.arange(0, height + step, step, dtype=np.float64)
        lat_c = np.arange(0, width + step, step, dtype=np.float64)
        gr, gc = np.meshgrid(lat_r, lat_c, indexing="ij")
        xs = affine.c + (gc + 0.5) * affine.a
        ys = affine.f + (gr + 0.5) * affine.e
        tx, ty = warp_transform(spec_tile["crs"], self.grid["crs"], xs.ravel().tolist(), ys.ravel().tolist())
        tx = np.asarray(tx).reshape(gr.shape)
        ty = np.asarray(ty).reshape(gr.shape)
        res = self.grid["res"]
        world_c = (tx - self.grid["xmin"]) / res + self.mx - 0.5
        world_r = (self.grid["ymax"] - ty) / res + self.my - 0.5
        coords = [rows / step, cols / step]
        return (
            ndimage.map_coordinates(world_r, coords, order=1, output=np.float32),
            ndimage.map_coordinates(world_c, coords, order=1, output=np.float32),
        )

    def sample(self, field: np.ndarray, step: int, rows: np.ndarray, cols: np.ndarray) -> np.ndarray:
        return ndimage.map_coordinates(field, [rows / step, cols / step], order=1, mode="nearest", output=np.float32)

    def _tile_base(self, variant: str, tile: str) -> dict:
        """Time-invariant surface fields at the tile's pixels."""
        rows, cols = self.tile_rowcol(variant, tile)
        veg = self.sample(self.field(("hls", "veg"), 2.6, 9000.0, 2), 2, rows, cols)
        soil = self.sample(self.field(("hls", "soil"), 2.4, 6000.0, 2), 2, rows, cols)
        phase = self.sample(self.field(("hls", "phase"), 3.0, 20000.0, 2), 2, rows, cols)
        tex = self.sample(self.field(("hls", "texture"), 1.4, 500.0, 1), 1, rows, cols)
        water = self.sample(self.field(("hls", "water"), 3.0, 5000.0, 2), 2, rows, cols) > 2.0
        return {"veg": special.ndtr(veg), "soil": special.ndtr(soil), "phase": phase, "tex": tex, "water": water}

    def _cloud_state(self, t: int) -> dict:
        rng = rng_for(self.seed, "hls", "cloud-state", t)
        cover = float(np.clip(rng.beta(2.2, 1.6), 0.03, 0.97))
        cloud = self.field(("hls", "cloud", t), 3.2, 9000.0, 2)
        cirrus = self.field(("hls", "cirrus", t), 3.0, 15000.0, 2)
        return {
            "cloud": cloud,
            "cirrus": cirrus,
            "thr": float(np.quantile(cloud[::4, ::4], 1.0 - cover)),
            "cirrus_thr": float(np.quantile(cirrus[::4, ::4], 1.0 - 0.3 * cover)),
            "shadow_shift": rng.uniform(8.0, 22.0, size=2),
            "swath": rng.uniform(0.04, 0.22) if rng.random() < 0.3 else None,
            "gain": rng.normal(1.0, 0.05, size=len(self.hls["bands"])),
        }


def build_hls_item(world: World, root: Path, variant: str, tile: str, t: int) -> dict:
    """All assets of one item, and its STAC Feature."""
    hls = world.hls
    seed = world.seed
    date = hls_dates(hls)[t]
    tiles = hls["variants"][variant]["tiles"]
    spec_tile = tiles[tile]
    affine, width, height = tile_grid(world.grid, spec_tile)
    rows, cols = world.tile_rowcol(variant, tile)
    base = world.tile_base(variant, tile)
    state = world.cloud_state(t)
    shape = (height, width)

    cloud_field = world.sample(state["cloud"], 2, rows, cols)
    cloud = cloud_field > state["thr"]
    adjacent = (cloud_field > state["thr"] - 0.15) & ~cloud
    depth = np.clip((cloud_field - state["thr"]) / 0.8, 0.0, 1.0)
    shifted = world.sample(state["cloud"], 2, rows + state["shadow_shift"][0], cols + state["shadow_shift"][1])
    shadow = (shifted > state["thr"]) & ~cloud
    cirrus = world.sample(state["cirrus"], 2, rows, cols) > state["cirrus_thr"]
    haze = world.sample(world.field(("hls", "haze", t), 3.0, 12000.0, 2), 2, rows, cols)
    # Isolated false detections: what the opening step of a mask cleanup exists to remove.
    specks = rng_for(seed, "hls", tile, t, "specks").random(shape, dtype=np.float32) < 0.002
    # Swath edge: a slanted nodata wedge on some dates, fixed in world coordinates.
    nodata = np.zeros(shape, bool)
    if state["swath"] is not None:
        nodata = (cols - world.mx) / world.nx - 0.12 * (rows - world.my) / world.ny < state["swath"]

    doy = date.timetuple().tm_yday
    season = np.sin(2.0 * np.pi * doy / 365.0 + 0.8 * base["phase"])
    paths = {}
    item_id = f"HLS.S30.{tile}.{date:%Y%j}.v2.0"
    folder = root / f"hls-{variant}" / item_id
    folder.mkdir(parents=True, exist_ok=True)
    creation = hls["creation"]
    common = dict(
        driver="GTiff",
        crs=spec_tile["crs"],
        transform=affine,
        width=width,
        height=height,
        count=1,
        tiled=True,
        blockxsize=creation["blocksize"],
        blockysize=creation["blocksize"],
        compress=creation["compress"],
        predictor=creation["predictor"],
        zlevel=creation["zlevel"],
        num_threads=1,
    )
    for b, band in enumerate(hls["bands"]):
        m = BAND_MODEL[band]
        noise = rng_for(seed, "hls", tile, t, band).standard_normal(shape, dtype=np.float32) * m["noise"]
        value = m["base"] + m["veg"] * base["veg"] + m["soil"] * base["soil"]
        value = value + m["season"] * season * base["veg"] + m["tex"] * base["tex"]
        value = value * state["gain"][b] + 60.0 * haze
        value = np.where(base["water"], m["water"], value) + noise
        value = np.where(adjacent, value + 220.0, value)
        value = np.where(cirrus, value + 340.0, value)
        value = np.where(shadow, value * 0.45, value)
        value = np.where(cloud, m["cloud"] * (0.7 + 0.5 * depth) + noise, value)
        out = np.clip(np.rint(value), 1, 12000).astype(np.int16)
        out[nodata] = hls["nodata"]
        path = folder / f"{item_id}.{band}.tif"
        with rasterio.open(path, "w", dtype="int16", nodata=hls["nodata"], **common) as dst:
            dst.write(out, 1)
        paths[band] = path

    bits = hls["fmask_bits"]
    fmask = np.full(shape, 64, np.uint8)  # aerosol level low: bits 6-7 hold 01 on real HLS
    fmask[base["water"]] |= 1 << bits["water"]
    fmask[cirrus] |= 1 << bits["cirrus"]
    fmask[cloud | specks] |= 1 << bits["cloud"]
    fmask[adjacent] |= 1 << bits["adjacent"]
    fmask[shadow] |= 1 << bits["shadow"]
    fmask[nodata] = hls["mask_nodata"]
    path = folder / f"{item_id}.{hls['mask_band']}.tif"
    with rasterio.open(path, "w", dtype="uint8", nodata=hls["mask_nodata"], **common) as dst:
        dst.write(fmask, 1)
    paths[hls["mask_band"]] = path

    stem = list(tiles).index(tile)
    stamp = f"{date.isoformat()}T{hls['utc_time']}:{10 + 5 * stem:02d}Z"
    return {
        "id": item_id,
        "t": t,
        "tile": tile,
        "feature": stac_feature(hls, item_id, stamp, spec_tile["crs"], affine, width, height, paths, cloud),
        "files": [file_entry(p, root) for p in paths.values()],
    }


def stac_feature(hls, item_id, stamp, crs, affine, width, height, paths, cloud) -> dict:
    left, top = affine.c, affine.f
    right, bottom = left + width * affine.a, top + height * affine.e
    xs = [left, right, right, left, left]
    ys = [top, top, bottom, bottom, top]
    lon, lat = warp_transform(crs, "EPSG:4326", xs, ys)
    transform = [affine.a, affine.b, affine.c, affine.d, affine.e, affine.f]
    assets = {}
    for band, path in paths.items():
        is_mask = band == hls["mask_band"]
        assets[band] = {
            "href": str(path),
            "type": "image/tiff; application=geotiff",
            "roles": ["cloud-mask" if is_mask else "data"],
            "raster:bands": [
                {
                    "data_type": hls["mask_dtype"] if is_mask else hls["dtype"],
                    "nodata": hls["mask_nodata"] if is_mask else hls["nodata"],
                    "spatial_resolution": abs(affine.a),
                }
            ],
        }
    return {
        "type": "Feature",
        "stac_version": "1.1.0",
        "stac_extensions": [
            "https://stac-extensions.github.io/projection/v2.0.0/schema.json",
            "https://stac-extensions.github.io/raster/v1.1.0/schema.json",
            "https://stac-extensions.github.io/eo/v2.0.0/schema.json",
        ],
        "id": item_id,
        "collection": "garry-bench-hls",
        "geometry": {"type": "Polygon", "coordinates": [[[round(a, 7), round(b, 7)] for a, b in zip(lon, lat)]]},
        "bbox": [round(min(lon), 7), round(min(lat), 7), round(max(lon), 7), round(max(lat), 7)],
        "properties": {
            "datetime": stamp,
            "eo:cloud_cover": round(100.0 * float(cloud.mean()), 2),
            "proj:code": crs,
            "proj:shape": [height, width],
            "proj:transform": transform,
        },
        "links": [],
        "assets": assets,
    }


def file_entry(path: Path, root: Path) -> dict:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            digest.update(chunk)
    return {"path": str(path.relative_to(root)), "bytes": path.stat().st_size, "sha256": digest.hexdigest()}


def dataset_digest(files: list[dict]) -> str:
    lines = sorted(f"{f['path']} {f['sha256']}" for f in files)
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()


# ---- workers ------------------------------------------------------------------------------------

_world: World | None = None


def _init_worker(spec: dict, size: str) -> None:
    global _world
    _world = World(spec, size)


def _item_job(job: tuple) -> dict:
    root, variant, tile, t = job
    return build_hls_item(_world, Path(root), variant, tile, t)


def generate_hls(spec: dict, size: str, root: Path, variant: str, workers: int) -> dict:
    hls = spec["datasets"]["hls"]
    jobs = [(str(root), variant, tile, t) for t, tile in item_plan(hls, variant)]
    # Tile order keeps each worker's per-tile surface cache useful. Order changes no pixel.
    jobs.sort(key=lambda j: (j[2], j[3]))
    with ProcessPoolExecutor(workers, initializer=_init_worker, initargs=(spec, size)) as pool:
        made = list(pool.map(_item_job, jobs, chunksize=max(1, len(jobs) // (workers * 4))))
    made.sort(key=lambda m: (m["t"], m["tile"]))
    folder = root / f"hls-{variant}"
    items = folder / "items.json"
    items.write_text(json.dumps({"type": "FeatureCollection", "features": [m["feature"] for m in made]}, indent=1))
    files = [f for m in made for f in m["files"]] + [file_entry(items, root)]
    nx, ny = spec["sizes"][size]["hls"]
    return {
        "kind": "hls",
        "variant": variant,
        "items": str(items.relative_to(root)),
        "grid": target_grid(hls["target"], nx, ny),
        "bands": hls["bands"],
        "mask_band": hls["mask_band"],
        "nodata": hls["nodata"],
        "mask_nodata": hls["mask_nodata"],
        "dates": [d.isoformat() for d in hls_dates(hls)],
        "ids": [m["id"] for m in made],
        "item_t": [m["t"] for m in made],
        "files": files,
    }


def _annual_job(job: tuple) -> dict:
    spec, size, root, i = job
    d = spec["datasets"]["annual"]
    seed = spec["seed"]
    nx, ny = spec["sizes"][size]["annual"]
    shape = (ny, nx)
    year = d["first_year"] + i
    # Height-like signal: a smooth base, a smooth trend, then clearances that regrow.
    level = 5.0 + 30.0 * special.ndtr(grf(seed, ("annual", "base"), shape, 2.6, 300.0))
    trend = 0.3 * grf(seed, ("annual", "trend"), shape, 3.0, 400.0)
    value = level + i * trend
    for k, start in enumerate((5, 8, 11)):
        patch = grf(seed, ("annual", "break", k), shape, 3.0, 120.0)
        patch = patch > np.quantile(patch[::8, ::8], 0.93)
        if i >= start:
            value = np.where(patch, value - 14.0 + 1.1 * (i - start), value)
    rng = rng_for(seed, "annual", "T0", i, 0)
    value = value + rng.standard_normal(shape, dtype=np.float32) * 1.5
    # Outliers for a Hampel filter: small bright patches and single pixels.
    spike = grf(seed, ("annual", "spike", i), shape, 2.6, 30.0)
    value = np.where(spike > np.quantile(spike[::8, ::8], 0.985), value + 16.0, value)
    value = np.where(rng.random(shape, dtype=np.float32) < 0.005, value - 18.0, value)
    # Gaps: clustered like a persistent cloud bank, with a few single pixels.
    gap_rate = float(rng.uniform(0.05, 0.25))
    gap = grf(seed, ("annual", "gap", i), shape, 3.2, 200.0)
    missing = (gap > np.quantile(gap[::8, ::8], 1.0 - gap_rate)) | (rng.random(shape, dtype=np.float32) < 0.01)
    out = np.where(missing, np.nan, value).astype(np.float32)
    grid = target_grid(d["target"], nx, ny)
    path = Path(root) / "annual" / f"annual_{year}.tif"
    c = d["creation"]
    with rasterio.open(
        path,
        "w",
        driver="GTiff",
        dtype="float32",
        nodata=float("nan"),
        crs=grid["crs"],
        transform=Affine(grid["res"], 0, grid["xmin"], 0, -grid["res"], grid["ymax"]),
        width=nx,
        height=ny,
        count=1,
        tiled=True,
        blockxsize=c["blocksize"],
        blockysize=c["blocksize"],
        compress=c["compress"],
        predictor=c["predictor"],
        zlevel=c["zlevel"],
        num_threads=1,
    ) as dst:
        dst.write(out, 1)
    return file_entry(path, Path(root))


def generate_annual(spec: dict, size: str, root: Path, workers: int) -> dict:
    d = spec["datasets"]["annual"]
    (root / "annual").mkdir(parents=True, exist_ok=True)
    jobs = [(spec, size, str(root), i) for i in range(d["t"])]
    with ProcessPoolExecutor(workers) as pool:
        files = list(pool.map(_annual_job, jobs))
    nx, ny = spec["sizes"][size]["annual"]
    return {
        "kind": "annual",
        "grid": target_grid(d["target"], nx, ny),
        "years": [d["first_year"] + i for i in range(d["t"])],
        "nodata": "nan",
        "files": files,
    }


def generate_embed(spec: dict, size: str, root: Path) -> dict:
    d = spec["datasets"]["embed"]
    seed = spec["seed"]
    nx, ny = spec["sizes"][size]["embed"]
    shape = (ny, nx)
    latents = [grf(seed, ("embed", "latent", k), shape, 2.6, 256.0) for k in range(8)]
    hole = grf(seed, ("embed", "hole"), shape, 3.2, 300.0)
    hole = hole > np.quantile(hole[::8, ::8], 0.98)
    grid = target_grid(d["target"], nx, ny)
    c = d["creation"]
    path = root / "embed" / "embed.tif"
    path.parent.mkdir(parents=True, exist_ok=True)
    with rasterio.open(
        path,
        "w",
        driver="GTiff",
        dtype="int8",
        nodata=d["nodata"],
        crs=grid["crs"],
        transform=Affine(grid["res"], 0, grid["xmin"], 0, -grid["res"], grid["ymax"]),
        width=nx,
        height=ny,
        count=d["bands"],
        tiled=True,
        blockxsize=c["blocksize"],
        blockysize=c["blocksize"],
        compress=c["compress"],
        interleave=c["interleave"],
        bigtiff="if_safer",
        num_threads="all_cpus",
    ) as dst:
        for b in range(d["bands"]):
            rng = rng_for(seed, "embed", "T0", 0, b)
            weights = rng.standard_normal(len(latents))
            weights /= np.linalg.norm(weights)
            value = np.zeros(shape, np.float32)
            for w, latent in zip(weights, latents):
                value += float(w) * latent
            value = 50.0 * value + rng.standard_normal(shape, dtype=np.float32) * 3.0
            out = np.clip(np.rint(value), -127, 127).astype(np.int8)
            out[hole] = d["nodata"]
            dst.write(out, b + 1)
    return {"kind": "embed", "grid": grid, "bands": d["bands"], "nodata": d["nodata"], "files": [file_entry(path, root)]}


def generate_zarr(spec: dict, size: str, root: Path, manifest: dict) -> dict:
    """The aligned stack as Zarr with whole-t chunks, for the cubed memory track."""
    import zarr

    d = spec["datasets"]["hls-zarr"]
    hls = spec["datasets"]["hls"]
    source = manifest["datasets"].get(d["from"])
    if source is None:
        sys.exit(f"gen.py: hls-zarr needs {d['from']}; generate it first")
    nx, ny = source["grid"]["nx"], source["grid"]["ny"]
    store = root / "hls-zarr" / "store.zarr"
    group = zarr.open_group(store, mode="w")
    chunks = (hls["t"], min(d["chunks"], ny), min(d["chunks"], nx))
    for band in [*hls["bands"], hls["mask_band"]]:
        is_mask = band == hls["mask_band"]
        dtype = hls["mask_dtype"] if is_mask else hls["dtype"]
        fill = hls["mask_nodata"] if is_mask else hls["nodata"]
        stack = np.empty((hls["t"], ny, nx), dtype)
        for t, item_id in zip(source["item_t"], source["ids"]):
            with rasterio.open(root / f"hls-{source['variant']}" / item_id / f"{item_id}.{band}.tif") as src:
                src.read(1, out=stack[t])
        array = group.create_array(name=band, shape=stack.shape, chunks=chunks, dtype=dtype, fill_value=fill)
        array[:] = stack
        array.attrs["nodata"] = fill
    group.attrs["dates"] = source["dates"]
    group.attrs["grid"] = source["grid"]
    zarr.consolidate_metadata(store)
    files = [file_entry(p, root) for p in sorted(store.rglob("*")) if p.is_file()]
    return {
        "kind": "hls-zarr",
        "store": str(store.relative_to(root)),
        "grid": source["grid"],
        "bands": hls["bands"],
        "mask_band": hls["mask_band"],
        "nodata": hls["nodata"],
        "mask_nodata": hls["mask_nodata"],
        "dates": source["dates"],
        "files": files,
    }


# ---- disk ---------------------------------------------------------------------------------------


def estimate_bytes(spec: dict, size: str, datasets: list[str]) -> dict:
    """Estimated bytes per dataset, from raw size and the compression seen on small."""
    sizes = spec["sizes"][size]
    data = spec["datasets"]
    hls = data["hls"]
    nx, ny = sizes["hls"]
    out = {}
    for name in datasets:
        if name.startswith("hls-") and name != "hls-zarr":
            variant = name.split("-", 1)[1]
            tiles = hls["variants"][variant]["tiles"]
            px = 0.0
            for t, tile in item_plan(hls, variant):
                frame = tiles[tile]
                px += nx * ny * (frame["x"][1] - frame["x"][0]) * (frame["y"][1] - frame["y"][0])
            ratio = hls["disk_ratio"]
            out[name] = px * (2 * len(hls["bands"]) * ratio["reflectance"] + ratio["fmask"])
        elif name == "hls-zarr":
            out[name] = nx * ny * hls["t"] * (2 * len(hls["bands"]) + 1) * data[name]["disk_ratio"]
        elif name == "embed":
            ex, ey = sizes["embed"]
            out[name] = ex * ey * data[name]["bands"] * data[name]["disk_ratio"]
        elif name == "annual":
            ax, ay = sizes["annual"]
            out[name] = ax * ay * 4 * data[name]["t"] * data[name]["disk_ratio"]
    return {k: int(v) for k, v in out.items()}


def check_disk(path: Path, need: int) -> None:
    probe = path
    while not probe.exists():
        probe = probe.parent
    free = shutil.disk_usage(probe).free
    if free < 2 * need:
        sys.exit(f"gen.py: refusing: estimate {need / 1e9:.1f} GB needs {2 * need / 1e9:.1f} GB free, {free / 1e9:.1f} GB free")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--size", required=True)
    parser.add_argument("--datasets", default=",".join(DEFAULT_DATASETS), help=f"comma list from {ALL_DATASETS}")
    parser.add_argument("--workers", type=int, default=min(os.cpu_count() or 1, 12))
    parser.add_argument("--force", action="store_true", help="regenerate these datasets")
    parser.add_argument("--estimate", action="store_true", help="print the disk estimate and stop")
    args = parser.parse_args()

    spec = load_spec()
    if args.size not in spec["sizes"]:
        sys.exit(f"gen.py: unknown size {args.size}; spec has {list(spec['sizes'])}")
    if "refused" in spec["sizes"][args.size]:
        sys.exit(f"gen.py: refusing size {args.size}: {spec['sizes'][args.size]['refused']}")
    names = args.datasets.split(",")
    unknown = sorted(set(names) - set(ALL_DATASETS))
    if unknown:
        sys.exit(f"gen.py: unknown datasets {unknown}")
    if "GARRY_BENCH_DATA" not in os.environ:
        sys.exit("gen.py: set GARRY_BENCH_DATA")

    root = Path(os.environ["GARRY_BENCH_DATA"]).resolve() / args.size
    estimate = estimate_bytes(spec, args.size, names)
    if args.estimate:
        print(json.dumps({"size": args.size, "estimate_bytes": estimate, "total_gb": round(sum(estimate.values()) / 1e9, 2)}))
        return 0

    manifest_path = root / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else None
    generator = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    if manifest is None or (manifest["spec_hash"], manifest["generator_sha256"]) != (spec_hash(), generator):
        if root.exists():
            shutil.rmtree(root)  # an unfinished or stale tree
        manifest = {
            "version": spec["version"],
            "size": args.size,
            "root": str(root),
            "seed": spec["seed"],
            "spec_hash": spec_hash(),
            "generator_sha256": generator,
            "datasets": {},
        }
    todo = [n for n in names if args.force or n not in manifest["datasets"]]
    if not todo:
        print(json.dumps({"size": args.size, "generated": [], "note": "all present; --force regenerates"}))
        return 0
    check_disk(root, sum(v for k, v in estimate.items() if k in todo))

    root.mkdir(parents=True, exist_ok=True)
    timings = {}
    for name in todo:
        start = time.perf_counter()
        target = root / name
        if target.exists():
            shutil.rmtree(target)
        manifest["datasets"].pop(name, None)
        if name.startswith("hls-") and name != "hls-zarr":
            entry = generate_hls(spec, args.size, root, name.split("-", 1)[1], args.workers)
        elif name == "hls-zarr":
            entry = generate_zarr(spec, args.size, root, manifest)
        elif name == "embed":
            entry = generate_embed(spec, args.size, root)
        else:
            entry = generate_annual(spec, args.size, root, args.workers)
        entry["bytes"] = sum(f["bytes"] for f in entry["files"])
        entry["digest"] = dataset_digest(entry["files"])
        manifest["datasets"][name] = entry
        manifest_path.write_text(json.dumps(manifest, indent=1))
        timings[name] = round(time.perf_counter() - start, 2)
        print(f"gen.py: {name}: {entry['bytes'] / 1e6:.0f} MB, {len(entry['files'])} files, {timings[name]} s", file=sys.stderr)
    os.sync()  # posix_fadvise drops clean pages only
    print(
        json.dumps(
            {
                "size": args.size,
                "generated": todo,
                "seconds": timings,
                "bytes": {k: manifest["datasets"][k]["bytes"] for k in manifest["datasets"]},
                "estimate_bytes": estimate,
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
