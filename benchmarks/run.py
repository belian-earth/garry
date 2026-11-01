#!/usr/bin/env python3
"""Runs arms, alternating, into results/<date>-<sha>.jsonl. Standard library only: all work happens in
capped scopes, so this process stays small and uncapped work never starts here.

    run.py gen --size small [gen.py arguments]
    run.py ref --size small --variant aligned
    run.py bench --size small [--tasks median,ndvi] [--arms garry,odc-dask] [--reps 3]

The engine contract is at the top of README.md. A failed arm is a result: run.py records it and carries
on. It exits 1 when garry's route differs from the spec, and 0 otherwise.
"""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import hashlib
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCOPE = HERE / "scope.sh"
CHECK_LIMIT_S = 900
LIBC = ctypes.CDLL(None, use_errno=True)


def die(message: str) -> None:
    sys.exit(f"run.py: {message}")


def data_root() -> Path:
    if "GARRY_BENCH_DATA" not in os.environ:
        die("set GARRY_BENCH_DATA")
    return Path(os.environ["GARRY_BENCH_DATA"]).resolve()


def capped(cmd: list[str], cap: str, limit: int, logs: Path, env: dict | None = None) -> dict:
    """One capped run: the brief's command line, with the scope record, exit and logs."""
    logs.mkdir(parents=True, exist_ok=True)
    record = logs / "scope.json"
    argv = [
        "timeout", "-k", "10", str(limit),
        "systemd-run", "--user", "--scope", "--collect", "-q",
        "-p", f"MemoryMax={cap}", "-p", "MemorySwapMax=0",
        str(SCOPE), str(record), "--", *cmd,
    ]  # fmt: skip
    with open(logs / "stdout", "wb") as out, open(logs / "stderr", "wb") as err:
        done = subprocess.run(argv, stdout=out, stderr=err, stdin=subprocess.DEVNULL, cwd=HERE, env=env)
    scope = json.loads(record.read_text()) if record.exists() and record.stat().st_size else None
    return {
        "scope": scope,
        "outer_exit": done.returncode,
        "stdout": (logs / "stdout").read_text(errors="replace"),
        "stderr": (logs / "stderr").read_text(errors="replace"),
    }


def classify(result: dict) -> str:
    scope, outer = result["scope"], result["outer_exit"]
    if scope is None:
        # timeout's -k stage killed the scope, or the scope died before it could write
        return "timeout" if outer == 137 else "no_scope_record"
    if scope["oom_kill"] > 0:
        return "oom"
    if outer == 124:
        return "timeout"
    if scope["exit"] != 0:
        return "crash"
    return "ok"


def phase_fates(status: str, phases: list[str], by_phase: dict) -> dict:
    """A scope has one fate, a phase its own. A phase that printed its line finished, so a later kill leaves
    its wall alone: the failure goes to the first phase with no line, or the last if all printed, and any
    phase after that never ran."""
    if status == "ok":
        return {p: "ok" if p in by_phase else "no_record" for p in phases}
    died = next((i for i, p in enumerate(phases) if p not in by_phase), len(phases) - 1)
    return {p: "ok" if i < died else status if i == died else "not_reached" for i, p in enumerate(phases)}


def phase_peaks(trace: Path, scope: dict | None, phases: list[str], by_phase: dict) -> dict:
    """Sampled peak per phase, in MB, from scope.sh's trace. A phase ends where its own clock says: the scope's
    start, plus startup, plus the walls so far. Good to a sample or two, which is what a peak needs. The last
    phase runs to the end of the scope, so what a dying phase reached stays on that phase."""
    if scope is None or not trace.exists():
        return {}
    samples = []
    for line in trace.read_text().splitlines():
        words = line.split()
        if len(words) == 2:  # a kill can cut the last line
            samples.append((float(words[0]), float(words[1])))
    peaks, begin = {}, scope["start"]
    for i, phase in enumerate(phases):
        line = by_phase.get(phase)
        if line is None or line.get("wall_s") is None or i == len(phases) - 1:
            end = float("inf")
        else:
            end = begin + (line.get("startup_s") or 0 if i == 0 else 0) + line["wall_s"]
        window = [value for at, value in samples if begin <= at < end]
        if window:
            peaks[phase] = round(max(window) / 2**20, 1)
        begin = end
    return peaks


def json_lines(text: str) -> list[dict]:
    lines = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                lines.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return lines


def drop_pages(paths: list[Path]) -> float:
    """Evict source pages so a cold run reads the disk. Returns MB still resident."""
    os.sync()
    for path in paths:
        fd = os.open(path, os.O_RDONLY)
        try:
            os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        finally:
            os.close(fd)
    return round(sum(resident_pages(p) for p in paths) * os.sysconf("SC_PAGE_SIZE") / 1e6, 1)


class CacheStatRange(ctypes.Structure):
    _fields_ = [("off", ctypes.c_uint64), ("len", ctypes.c_uint64)]


class CacheStat(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint64) for name in ("cache", "dirty", "writeback", "evicted", "recently_evicted")]


def resident_pages(path: Path) -> int:
    """Pages of a file in the page cache, from the cachestat syscall (Linux 6.5)."""
    fd = os.open(path, os.O_RDONLY)
    try:
        stat = CacheStat()
        if LIBC.syscall(451, fd, ctypes.byref(CacheStatRange(0, 0)), ctypes.byref(stat), 0) != 0:
            raise OSError(ctypes.get_errno(), "cachestat")
        return stat.cache
    finally:
        os.close(fd)


def reap_shm() -> dict:
    """Unlink shared memory whose creator is dead, the rule of mori::prune_shared(). A killed run cannot
    free its store: the pages outlive the scope, in RAM and counted by nothing, and would starve later
    runs. Covers mori regions, named for the creator's pid in hex, and garry's gdirect-<pid>- folders."""
    freed = files = 0
    if not os.path.isdir("/dev/shm"):
        return {"files": 0, "mb": 0.0}

    def dead(pid: int) -> bool:
        return pid > 0 and not os.path.exists(f"/proc/{pid}")

    for entry in os.scandir("/dev/shm"):
        name = entry.name
        try:
            if name.startswith("mori_") and dead(int(name.split("_")[1], 16)):
                freed += entry.stat().st_size
                files += 1
                os.unlink(entry.path)
            elif name.startswith("gdirect-") and dead(int(name.split("-")[1])):
                freed += sum(f.stat().st_size for f in Path(entry.path).rglob("*") if f.is_file())
                files += 1
                shutil.rmtree(entry.path, ignore_errors=True)
        except (OSError, ValueError, IndexError):
            continue  # another reaper won the race, or a name that only looks like ours
    return {"files": files, "mb": round(freed / 1e6, 1)}


def git(*args: str) -> str:
    done = subprocess.run(["git", "--no-optional-locks", *args], cwd=HERE, capture_output=True, text=True)
    return done.stdout.strip()


class Session:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.tasks_spec = json.loads((HERE / "spec" / "tasks.json").read_text())
        self.data_spec = json.loads((HERE / "spec" / "data.json").read_text())
        spec_bytes = (HERE / "spec" / "tasks.json").read_bytes() + (HERE / "spec" / "data.json").read_bytes()
        self.spec_hash = hashlib.sha256(spec_bytes).hexdigest()[:16]
        if args.size not in self.data_spec["sizes"]:
            die(f"unknown size {args.size}")
        self.size_spec = self.data_spec["sizes"][args.size]
        self.cap = args.cap or self.size_spec["cap"]
        self.limit = args.limit or self.size_spec["limit_s"]
        self.root = data_root()
        manifest = self.root / args.size / "manifest.json"
        if not manifest.exists():
            die(f"no data for size {args.size}: run `run.py gen --size {args.size}`")
        self.manifest = json.loads(manifest.read_text())
        self.commit = git("rev-parse", "HEAD")
        self.dirty = bool(git("status", "--porcelain"))
        day = dt.date.today().isoformat()
        results = Path(args.results) if args.results else HERE / "results" / f"{day}-{self.commit[:8]}.jsonl"
        results.parent.mkdir(parents=True, exist_ok=True)
        self.results = results
        self.out_root = self.root / "out" / uuid.uuid4().hex[:12]
        self.arms = dict(self.tasks_spec["arms"])
        for item in args.arm_cmd:
            name, _, command = item.partition("=")
            self.arms[name] = {**self.arms.get(name, {}), "cmd": shlex.split(command)}
            if "engines/garry.R" in command:
                self.arms[name]["route_check"] = True
        self.seen_env = set()
        self.route_failures = 0
        self.write(
            {
                "kind": "session",
                "ts": now(),
                "argv": sys.argv[1:],
                "host": platform.node(),
                "kernel": platform.release(),
                "cores": os.cpu_count(),
                "mem_total_gb": round(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30, 1),
                "commit": self.commit,
                "dirty": self.dirty,
                "spec_hash": self.spec_hash,
                "size": args.size,
                "cap": self.cap,
                "limit_s": self.limit,
            }
        )

    def write(self, record: dict) -> None:
        with open(self.results, "a") as f:
            f.write(json.dumps(record) + "\n")

    def arm_cmd(self, arm: str) -> list[str]:
        if arm not in self.arms:
            die(f"unknown arm {arm}; spec has {list(self.arms)}")
        return [sys.executable if word == "{python}" else word for word in self.arms[arm]["cmd"]]

    def env(self, arm: str | None = None) -> dict:
        env = {**os.environ, **(self.arms[arm].get("env", {}) if arm else {})}
        env.setdefault("BENCH_THREADS", str(os.cpu_count()))
        return env

    def dataset(self, task: dict, arm: str, variant: str) -> str:
        if "dataset" in self.arms[arm]:
            return self.arms[arm]["dataset"]
        return f"hls-{variant}" if task["data"] == "hls" else task["data"]

    def run_arm(self, task: dict, arm: str, variant: str, rep: int) -> dict | None:
        """One engine process in a new scope. Returns the arm's cold output if it is worth comparing."""
        dataset = self.dataset(task, arm, variant)
        entry = self.manifest["datasets"].get(dataset)
        size_root = Path(self.manifest["root"])
        base = {
            "kind": "run",
            "ts": now(),
            "task": task["id"],
            "size": self.args.size,
            "variant": variant,
            "arm": arm,
            "tag": self.args.tag,
            "rep": rep,
            "commit": self.commit,
            "dirty": self.dirty,
            "spec_hash": self.spec_hash,
            "data_hash": entry["digest"][:16] if entry else None,
            "cap": self.cap,
        }
        if entry is None:
            self.write({**base, "phase": "cold", "status": "no_data", "note": f"{dataset} not generated"})
            return None
        run_id = uuid.uuid4().hex[:8]
        run_dir = self.out_root / run_id
        logs = run_dir / "logs"
        out_dir = run_dir / "out"
        tmp_dir = run_dir / "tmp"  # a killed R leaves its tempdir: this one goes with the run
        out_dir.mkdir(parents=True)
        tmp_dir.mkdir()
        base["cold_resident_mb"] = drop_pages([size_root / f["path"] for f in entry["files"]])
        cmd = [*self.arm_cmd(arm), "--task", task["id"], "--size", self.args.size, "--variant", variant, "--out", str(out_dir)]
        phases = ["cold"]
        if not self.args.no_warm:
            cmd.append("--warm")
            phases.append("warm")
        cmd += shlex.split(self.args.engine_args)
        load_start = os.getloadavg()[0]
        result = capped(cmd, self.cap, self.limit, logs, {**self.env(arm), "TMPDIR": str(tmp_dir)})
        load_end = os.getloadavg()[0]
        status = classify(result)
        base["shm_orphans"] = reap_shm()
        scope = result["scope"] or {}
        base.update(
            {
                "exit": scope.get("exit"),
                "outer_exit": result["outer_exit"],
                "oom_kill": scope.get("oom_kill"),
                "memory_max_events": scope.get("memory_max_events"),
                "scope_status": status,
                "run_peak_anon_shmem_mb": round(scope["sampled_peak_bytes"] / 2**20, 1) if scope else None,
                "memory_peak_mb": round(scope["memory_peak_bytes"] / 2**20, 1) if scope else None,
                "samples": scope.get("samples"),
                "scope_wall_s": round(scope["end"] - scope["start"], 3) if scope else None,
                "load": load_start,
                "load_end": load_end,
            }
        )
        lines = json_lines(result["stdout"])
        for line in lines:
            if line.get("phase") == "env":
                base["build"] = (line.get("build") or {}).get("hash")
                if (arm, base["build"]) not in self.seen_env:
                    self.seen_env.add((arm, base["build"]))
                    self.write({"kind": "env", "arm": arm, "ts": now(), **{k: v for k, v in line.items() if k != "phase"}})
        by_phase = {line["phase"]: line for line in lines if "phase" in line and line["phase"] != "env"}
        hashes = self.hash_outputs(task, variant, out_dir, [p for p in phases if p in by_phase], logs)
        fates = phase_fates(status, phases, by_phase)
        peaks = phase_peaks(logs / "scope.json.trace", result["scope"], phases, by_phase)

        keep = None
        for phase in phases:
            line = by_phase.get(phase)
            record = {**base, "phase": phase, "ts": now(), "status": fates[phase], "peak_anon_shmem_mb": peaks.get(phase)}
            if line is None:
                if record["status"] != "not_reached":
                    record["log_tail"] = (result["stderr"] or result["stdout"])[-1500:]
                self.write(record)
                print(f"run.py: {task['id']} {variant} {arm} rep {rep} {phase}: {record['status']}", file=sys.stderr)
                continue
            extras = {k: v for k, v in line.items() if k not in ("phase", "wall_s", "startup_s", "route", "task")}
            record.update({"wall_s": line.get("wall_s"), "startup_s": line.get("startup_s"), "route": line.get("route")})
            if extras:
                record["extra"] = extras
            digest = hashes.get(phase)
            if digest is None:
                if record["status"] == "ok":
                    record["status"] = "no_output"
            else:
                record["out_hash"] = digest["hash"][:16]
                record["out_stats"] = {k: digest[k] for k in ("shape", "nan_frac", "min", "max", "mean")}
                record["objective_gap"] = digest["objective_gap"]
                if digest["gap_note"]:
                    record["gap_note"] = digest["gap_note"]
                if digest["format_issues"]:
                    record["format_issues"] = digest["format_issues"]
                    if record["status"] == "ok":
                        record["status"] = "bad_output"
                cold = hashes.get("cold")
                if phase == "warm" and cold is not None:
                    record["warm_equals_cold"] = digest["hash"] == cold["hash"]
                    if not record["warm_equals_cold"] and record["status"] == "ok":
                        record["status"] = "warm_differs"
            if self.arms[arm].get("route_check") and record["route"] != task["route"]:
                record["route_expected"] = task["route"]
                if record["status"] == "ok":
                    record["status"] = "route_mismatch"
                self.route_failures += 1
                print(f"run.py: ROUTE: {task['id']} {arm} took {record['route']}, spec {task['route']}", file=sys.stderr)
            if record["status"] != "ok":
                record["log_tail"] = (result["stderr"] or result["stdout"])[-1500:]
            self.write(record)
            print(f"run.py: {task['id']} {variant} {arm} rep {rep} {phase}: {record['status']} wall {record['wall_s']}", file=sys.stderr)
            if phase == "cold" and record["status"] == "ok" and digest is not None:
                keep = out_dir / "cold.tif"
        if keep is not None:
            saved = self.out_root / f"{task['id']}-{variant}-{arm}-{rep}.tif"
            keep.rename(saved)
            keep = saved
        if not self.args.keep_outputs:
            shutil.rmtree(run_dir, ignore_errors=True)
        return keep

    def hash_outputs(self, task: dict, variant: str, out_dir: Path, phases: list[str], logs: Path) -> dict:
        files = {p: out_dir / f"{p}.tif" for p in phases if (out_dir / f"{p}.tif").exists()}
        if not files:
            return {}
        cmd = [sys.executable, str(HERE / "check.py"), "hash", *map(str, files.values())]
        cmd += ["--task", task["id"], "--size", self.args.size, "--variant", variant]
        result = capped(cmd, self.cap, CHECK_LIMIT_S, logs / "check", self.env())
        status = classify(result)
        if status != "ok":
            print(f"run.py: check.py hash: {status}: {result['stderr'][-400:]}", file=sys.stderr)
        lines = {line["file"]: line for line in json_lines(result["stdout"])}
        return {p: lines[str(f)] for p, f in files.items() if str(f) in lines}

    def compare(self, task: dict, variant: str, outputs: dict) -> None:
        arms = list(outputs)
        reference = self.tasks_spec["reference_arm"] if self.tasks_spec["reference_arm"] in outputs else (arms[0] if arms else None)
        for arm in arms:
            if arm == reference:
                continue
            cmd = [sys.executable, str(HERE / "check.py"), "compare", str(outputs[reference]), str(outputs[arm])]
            cmd += ["--task", task["id"], "--variant", variant]
            result = capped(cmd, self.cap, CHECK_LIMIT_S, self.out_root / f"cmp-{uuid.uuid4().hex[:8]}", self.env())
            status = classify(result)
            record = {
                "kind": "check",
                "ts": now(),
                "task": task["id"],
                "size": self.args.size,
                "variant": variant,
                "tag": self.args.tag,
                "a": reference,
                "b": arm,
                "status": status,
                "commit": self.commit,
                "spec_hash": self.spec_hash,
            }
            lines = json_lines(result["stdout"])
            if lines:
                record.update(lines[-1])
            self.write(record)
        if not self.args.keep_outputs:
            for path in outputs.values():
                path.unlink(missing_ok=True)


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def bench(args: argparse.Namespace) -> int:
    session = Session(args)
    wanted_tasks = args.tasks.split(",") if args.tasks else None
    wanted_arms = args.arms.split(",") if args.arms else None
    tasks = [t for t in session.tasks_spec["tasks"] if wanted_tasks is None or t["id"] in wanted_tasks]
    if wanted_tasks and len(tasks) != len(wanted_tasks):
        die(f"unknown task in {wanted_tasks}")
    variants_filter = args.variants.split(",") if args.variants else None
    custom = {item.split("=", 1)[0] for item in args.arm_cmd}
    swept = session.tasks_spec["arms"]["odc-dask"]["chunk"]
    if (wanted_arms is None or "odc-dask" in wanted_arms) and args.size not in swept and "--chunk" not in args.engine_args:
        die(f"no odc-dask chunk swept at size {args.size}: see Sweeps in README.md")
    if args.reps < 3:
        print(f"run.py: {args.reps} repeats is below the suite's minimum of 3: a test, not a result", file=sys.stderr)
    for task in tasks:
        chosen = [a for a in wanted_arms if a in task["arms"] or a in custom] if wanted_arms else task["arms"]
        for variant in task["variants"]:
            if variants_filter and variant not in variants_filter:
                continue
            arms = [a for a in chosen if session.arms.get(a, {}).get("only_variant") in (None, variant)]
            outputs = {}
            for rep in range(args.reps):
                order = arms if rep % 2 == 0 else arms[::-1]
                for arm in order:
                    kept = session.run_arm(task, arm, variant, rep)
                    if kept is None:
                        continue
                    if arm in outputs:
                        kept.unlink(missing_ok=True)
                    else:
                        outputs[arm] = kept
            session.compare(task, variant, outputs)
    if not args.keep_outputs:
        shutil.rmtree(session.out_root, ignore_errors=True)
    print(session.results)
    if session.route_failures:
        print(f"run.py: {session.route_failures} route failures against the spec", file=sys.stderr)
        return 1
    return 0


def one_off(args: argparse.Namespace, cmd: list[str]) -> int:
    """A capped run that is not a benchmark: data or the geomedian reference."""
    spec = json.loads((HERE / "spec" / "data.json").read_text())
    if args.size not in spec["sizes"]:
        die(f"unknown size {args.size}")
    size = spec["sizes"][args.size]
    logs = data_root() / "logs" / uuid.uuid4().hex[:12]
    result = capped(cmd, args.cap or size["cap"], args.limit or size["gen_limit_s"], logs, dict(os.environ))
    sys.stderr.write(result["stderr"])
    sys.stdout.write(result["stdout"])
    status = classify(result)
    scope = result["scope"] or {}
    print(
        json.dumps(
            {
                "status": status,
                "exit": scope.get("exit"),
                "oom_kill": scope.get("oom_kill"),
                "wall_s": round(scope["end"] - scope["start"], 2) if scope else None,
                "peak_anon_shmem_mb": round(scope["sampled_peak_bytes"] / 2**20, 1) if scope else None,
                "memory_peak_mb": round(scope["memory_peak_bytes"] / 2**20, 1) if scope else None,
            }
        )
    )
    shutil.rmtree(logs, ignore_errors=True)
    return 0 if status == "ok" else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    g = sub.add_parser("gen", help="generate data in a capped scope; other arguments go to gen.py")
    g.add_argument("--size", required=True)
    g.add_argument("--cap")
    g.add_argument("--limit", type=int)
    r = sub.add_parser("ref", help="compute the tight geomedian reference once, with geomad")
    r.add_argument("--size", required=True)
    r.add_argument("--variant", required=True)
    r.add_argument("--cap")
    r.add_argument("--limit", type=int)
    b = sub.add_parser("bench", help="run arms")
    b.add_argument("--size", default="small")
    b.add_argument("--tasks", help="comma list; default all")
    b.add_argument("--arms", help="comma list; default each task's arms")
    b.add_argument("--variants", help="comma list; default each task's variants")
    b.add_argument("--reps", type=int, default=3)
    b.add_argument("--no-warm", action="store_true", help="skip the warm phase")
    b.add_argument("--cap", help="override the size's memory cap")
    b.add_argument("--limit", type=int, help="override the size's time limit, seconds")
    b.add_argument("--tag", help="label on every record, for a sweep")
    b.add_argument("--engine-args", default="", help="extra engine arguments, one quoted string")
    b.add_argument("--arm-cmd", action="append", default=[], metavar="NAME=CMD", help="add or replace an arm, say a garry built elsewhere")
    b.add_argument("--keep-outputs", action="store_true", help="leave outputs and logs under $GARRY_BENCH_DATA/out")
    b.add_argument("--results", help="results file; default results/<date>-<sha>.jsonl")
    args, rest = parser.parse_known_args()
    if args.command == "gen":
        return one_off(args, [sys.executable, str(HERE / "gen.py"), "--size", args.size, *rest])
    if rest:
        die(f"unknown arguments {rest}")
    if args.command == "ref":
        engine = [sys.executable, str(HERE / "engines" / "odc.py"), "--task", "geomedian_ref"]
        return one_off(args, [*engine, "--size", args.size, "--variant", args.variant])
    return bench(args)


if __name__ == "__main__":
    raise SystemExit(main())
