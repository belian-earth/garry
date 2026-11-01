#!/usr/bin/env python3
"""Compares outputs, untimed. Run it through run.py, which applies the memory cap.

    check.py hash FILE... --task ID --size SIZE --variant VARIANT
    check.py compare A B --task ID --variant VARIANT

`hash` prints one JSON line per file: a canonical f32 hash that guards one engine across commits,
summary statistics, departures from the output spec, and for geomedian the objective gap. `compare`
prints one JSON line of the difference between two engines, judged against the task's tolerance.
Declared nodata reads as NaN, so an integer output and a float output of the same values agree.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path

import numpy as np
import rasterio

HERE = Path(__file__).resolve().parent
CANON_NAN = np.frombuffer(b"\x00\x00\xc0\x7f", np.float32)[0]


def find_task(task_id: str) -> tuple[dict, dict]:
    spec = json.loads((HERE / "spec" / "tasks.json").read_text())
    for task in spec["tasks"]:
        if task["id"] == task_id:
            return spec, task
    raise SystemExit(f"check.py: no task {task_id}")


def read_band(src, band: int) -> np.ndarray:
    raw = src.read(band)
    out = raw.astype(np.float32)
    nodata = src.nodatavals[band - 1]
    if nodata is not None and not math.isnan(nodata):
        out[raw == nodata] = np.nan
    return out


def format_issues(src, spec: dict, task: dict) -> list[str]:
    want = {**spec["output"], **task.get("output", {})}
    issues = []
    if src.driver != want["driver"]:
        issues.append(f"driver {src.driver}")
    if src.dtypes[0] != want["dtype"]:
        issues.append(f"dtype {src.dtypes[0]}, spec {want['dtype']}")
    compress = src.compression.value.lower() if src.compression else "none"
    if compress != want["compress"]:
        issues.append(f"compress {compress}, spec {want['compress']}")
    if src.overviews(1):
        issues.append("has overviews")
    if src.block_shapes[0] != (want["blocksize"], want["blocksize"]):
        issues.append(f"blocks {src.block_shapes[0]}, spec {want['blocksize']}")
    declared = src.nodata
    expected = want["nodata"]
    if expected == "nan":
        # NaN is nodata in a float file, tagged or not. Only a numeric sentinel departs from the spec.
        if declared is not None and not math.isnan(declared):
            issues.append(f"nodata {declared}, spec nan")
    elif declared != expected:
        issues.append(f"nodata {declared}, spec {expected}")
    return issues


def objective_gap(path: str, task: dict, size: str, variant: str) -> tuple[float | None, str | None]:
    """Relative gap to the tight reference on the sampled pixels, then why there is none."""
    if task["id"] != "geomedian":
        return None, None
    root = Path(os.environ["GARRY_BENCH_DATA"]) / size
    ref_path = root / "ref" / f"geomedian-{variant}.npz"
    if not ref_path.exists():
        return None, "no reference: run.py ref"
    digest = json.loads((root / "manifest.json").read_text())["datasets"][f"hls-{variant}"]["digest"]
    with np.load(ref_path) as z:
        if "digest" not in z or str(z["digest"]) != digest:
            return None, "reference is of other data: run.py ref"
        cube, ref, rows, cols = z["cube"], z["ref"], z["rows"], z["cols"]
    with rasterio.open(path) as src:
        est = np.stack([read_band(src, b + 1)[rows, cols] for b in range(src.count)])

    def objective(m: np.ndarray) -> np.ndarray:
        dist = np.sqrt(((cube - m[:, None, :]) ** 2).sum(axis=0))
        return np.nansum(dist, axis=0)

    good = np.isfinite(est).all(axis=0) & np.isfinite(ref).all(axis=0)
    fm, fr = objective(est)[good].sum(), objective(ref)[good].sum()
    return float((fm - fr) / fr), None


def hash_file(path: str, spec: dict, task: dict, size: str, variant: str) -> dict:
    digest = hashlib.sha256()
    with rasterio.open(path) as src:
        digest.update(json.dumps([src.count, src.height, src.width]).encode())
        n = finite = 0
        low, high, total = math.inf, -math.inf, 0.0
        for band in range(1, src.count + 1):
            a = read_band(src, band) + 0.0  # -0 and +0 are one value
            valid = np.isfinite(a)
            n += a.size
            count = int(valid.sum())
            if count:
                finite += count
                low = min(low, float(a[valid].min()))
                high = max(high, float(a[valid].max()))
                total += float(a[valid].sum(dtype=np.float64))
            a[np.isnan(a)] = CANON_NAN
            digest.update(a.astype("<f4").tobytes())
        issues = format_issues(src, spec, task)
        shape = [src.count, src.height, src.width]
    gap, gap_note = objective_gap(path, task, size, variant)
    return {
        "file": path,
        "hash": digest.hexdigest(),
        "shape": shape,
        "nan_frac": round(1.0 - finite / n, 6),
        "min": low if finite else None,
        "max": high if finite else None,
        "mean": total / finite if finite else None,
        "format_issues": issues,
        "objective_gap": gap,
        "gap_note": gap_note,
    }


def compare(a_path: str, b_path: str, tolerance: dict) -> dict:
    with rasterio.open(a_path) as a, rasterio.open(b_path) as b:
        same_grid = (a.count, a.height, a.width) == (b.count, b.height, b.width) and a.crs == b.crs and a.transform.almost_equals(b.transform)
        if not same_grid:
            return {"pass": False, "note": "grids differ", "a": [a.count, a.height, a.width, str(a.transform)], "b": [b.count, b.height, b.width, str(b.transform)]}
        worst_max = worst_p99 = 0.0
        mismatch = cells = 0
        cors = []
        for band in range(1, a.count + 1):
            x, y = read_band(a, band), read_band(b, band)
            nx, ny = np.isnan(x), np.isnan(y)
            mismatch += int((nx != ny).sum())
            cells += x.size
            both = ~(nx | ny)
            if both.any():
                diff = np.abs(x[both].astype(np.float64) - y[both].astype(np.float64))
                worst_max = max(worst_max, float(diff.max()))
                worst_p99 = max(worst_p99, float(np.percentile(diff, 99)))
                if x[both].std() > 0 and y[both].std() > 0:
                    cors.append(float(np.corrcoef(x[both], y[both])[0, 1]))
    out = {
        "max_abs": worst_max,
        "p99_abs": worst_p99,
        "nan_mismatch_frac": mismatch / cells,
        "cor": min(cors) if cors else None,
        "tolerance": tolerance,
    }
    failed = []
    if "max_abs" in tolerance and worst_max > tolerance["max_abs"]:
        failed.append("max_abs")
    if "p99_abs" in tolerance and worst_p99 > tolerance["p99_abs"]:
        failed.append("p99_abs")
    if "nan_mismatch_frac" in tolerance and out["nan_mismatch_frac"] > tolerance["nan_mismatch_frac"]:
        failed.append("nan_mismatch_frac")
    if "cor_min" in tolerance and (out["cor"] is None or out["cor"] < tolerance["cor_min"]):
        failed.append("cor_min")
    out["pass"] = not failed
    out["failed"] = failed
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=["hash", "compare"])
    parser.add_argument("files", nargs="+")
    parser.add_argument("--task", required=True)
    parser.add_argument("--variant", default="default")
    parser.add_argument("--size", default="small")
    args = parser.parse_args()
    spec, task = find_task(args.task)
    if args.mode == "hash":
        for path in args.files:
            print(json.dumps(hash_file(path, spec, task, args.size, args.variant)), flush=True)
        return 0
    if len(args.files) != 2:
        raise SystemExit("check.py compare takes two files")
    print(json.dumps(compare(args.files[0], args.files[1], task["check"][args.variant])))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
