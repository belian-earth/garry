#!/usr/bin/env python3
"""One table from results files: failures first, then wall per arm and phase, ratio, peak, value check.
Standard library only.

    report.py results/2026-11-01-abcd1234.jsonl [more.jsonl]

Ratio is the arm's median wall over the primary arm's, at the same cap, commit and spec. Rows never pool
across cap, commit, spec or build. Cubed is the memory track: it stays out of the headline table, with
completion and peak first.
"""

from __future__ import annotations

import json
import math
import statistics
import sys
from collections import defaultdict, namedtuple
from pathlib import Path

HERE = Path(__file__).resolve().parent
CENSOR_FRACTION = 0.9  # anon plus shmem this near the cap, with the cgroup at memory.max, is the cap's number
GAP_FLOOR = 1e-9  # gaps below this are one number: rounding in the objective, not convergence
Key = namedtuple("Key", "task size variant phase tag arm cap commit spec build")


def fmt(value, digits: int = 2) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def table(header: list[str], rows: list[list[str]]) -> str:
    lines = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    lines += ["| " + " | ".join(row) + " |" for row in rows]
    return "\n".join(lines)


def load(paths: list[str]) -> list[dict]:
    records = []
    for path in paths:
        for line in Path(path).read_text().splitlines():
            if line.strip():
                records.append(json.loads(line))
    return records


def cap_mb(cap: str) -> float:
    units = {"K": 2**-10, "M": 1, "G": 2**10, "T": 2**20}
    return float(cap[:-1]) * units[cap[-1]] if cap[-1] in units else float(cap) / 2**20


def peak_cell(runs: list[dict], cap: str) -> str:
    """The highest peak of every repeat, the failed ones first of all. A peak the cap cut short reads >=: it is
    a floor on what the run wanted, not a measured need."""
    peaks = [r["peak_anon_shmem_mb"] for r in runs if r.get("peak_anon_shmem_mb") is not None]
    if not peaks:
        return "-"
    limit = CENSOR_FRACTION * cap_mb(cap)
    censored = any(
        r["status"] == "oom" or (r.get("memory_max_events") and (r.get("peak_anon_shmem_mb") or 0) >= limit) for r in runs
    )
    return f"{'>=' if censored else ''}{max(peaks):.0f}"


def check_cell(c: dict | None, reference: str | None = None) -> str:
    """A check against any arm but `reference` says so: with the reference failed, run.py compares the others."""
    if c is None:
        return "-"
    if "pass" not in c:
        return f"not checked ({c.get('status')})"
    if "max_abs" not in c:
        return f"fail: {c.get('note')}"
    verdict = "pass" if c["pass"] else "FAIL " + ",".join(c.get("failed", []))
    against = f" against {c['a']}" if reference and c["a"] != reference else ""
    cor = f" cor {c['cor']:.5f}" if c.get("cor") is not None else ""
    return f"{verdict}{against}: max {c['max_abs']:.3g}, p99 {c['p99_abs']:.3g}, NaN {c['nan_mismatch_frac']:.2g}{cor}"


def failure_note(r: dict) -> str:
    """Why a run failed: its own note, or a crash's last log line, which for Cubed is the refused plan."""
    if r.get("note"):
        return r["note"]
    lines = [line.strip() for line in (r.get("log_tail") or "").splitlines() if line.strip()]
    if r["status"] == "crash" and lines:
        return lines[-1].replace("|", "/")
    return r.get("route") or "-"


def warm_cell(runs: list[dict]) -> str:
    """The cross-engine check reads cold outputs only. A warm run answers for itself, against its own cold."""
    flags = [r["warm_equals_cold"] for r in runs if "warm_equals_cold" in r]
    if not flags:
        return "-"
    return "same as cold" if all(flags) else f"DIFFERS from cold in {flags.count(False)}/{len(flags)}"


def stable_hash(runs: list[dict]) -> str:
    hashes = {r.get("out_hash") for r in runs if r.get("out_hash")}
    if not hashes:
        return "-"
    return "stable" if len(hashes) == 1 else f"{len(hashes)} hashes"


def median_gap(runs: list[dict]) -> float | None:
    gaps = [r["objective_gap"] for r in runs if r.get("objective_gap") is not None]
    return statistics.median(gaps) if gaps else None


def gap_problem(rule: dict | None, variant: str, arm: str, gap: float | None, base: float | None) -> str | None:
    """Why two walls of an iterative task are not at equal convergence, or None when they are."""
    if rule is None:
        return None
    if arm in rule["not_comparable"].get(variant, {}):
        return rule["not_comparable"][variant][arm]
    if gap is None or base is None:
        return "an objective gap is missing"
    low, high = sorted((max(gap, GAP_FLOOR), max(base, GAP_FLOOR)))
    if high > rule["max_ratio"] * low:
        return f"gaps {gap:.2e} and {base:.2e} differ by more than {rule['max_ratio']}x"
    return None


def sweep_rows(runs: list[dict], groups: dict) -> list[list[str]]:
    """Each swept value against the best value on each task: the geometric mean, so a long task has one vote."""
    swept = defaultdict(dict)
    for key, members in groups.items():
        walls = [r["wall_s"] for r in members if r["status"] == "ok" and r.get("wall_s") is not None]
        if key.tag and "=" in key.tag and walls:
            name, value = key.tag.split("=", 1)
            swept[(key.arm, key.size, name, key.phase)].setdefault((key.task, key.variant), {})[value] = statistics.median(walls)
    rows = []
    for (arm, size, name, phase), cells in sorted(swept.items()):
        values = sorted({v for by_value in cells.values() for v in by_value}, key=lambda v: (len(v), v))
        for value in values:
            ratios = [by_value[value] / min(by_value.values()) for by_value in cells.values() if value in by_value]
            mean = math.exp(sum(map(math.log, ratios)) / len(ratios))
            rows.append([arm, size, f"{name}={value}", phase, str(len(ratios)), f"{mean:.3f}", f"{max(ratios):.2f}"])
    return rows


def main() -> int:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    records = load(sys.argv[1:])
    tasks_spec = json.loads((HERE / "spec" / "tasks.json").read_text())
    task_specs = {t["id"]: t for t in tasks_spec["tasks"]}
    memory_arms = {name for name, arm in tasks_spec["arms"].items() if arm.get("track") == "memory"}
    primary = tasks_spec["primary_arm"]
    reference = tasks_spec["reference_arm"]
    runs = [r for r in records if r["kind"] == "run"]
    sessions = {(s["commit"], s["dirty"], s["spec_hash"]): s for s in records if s["kind"] == "session"}
    envs = {(r["arm"], (r.get("build") or {}).get("hash")): r for r in records if r["kind"] == "env"}
    checks = {
        (c["task"], c["size"], c["variant"], c.get("tag"), c["b"], c.get("commit"), c.get("spec_hash")): c
        for c in records
        if c["kind"] == "check"
    }

    groups = defaultdict(list)
    for r in runs:
        groups[Key(r["task"], r["size"], r["variant"], r["phase"], r.get("tag"), r["arm"], r["cap"], r["commit"], r["spec_hash"], r.get("build"))].append(r)
    several_builds = len({(k.commit, k.spec, k.build) for k in groups if k.arm == reference}) > 1 or len(sessions) > 1

    def walls(members: list[dict]) -> list[float]:
        return [r["wall_s"] for r in members if r["status"] == "ok" and r.get("wall_s") is not None]

    def primary_runs(key: Key) -> list[dict]:
        same = [r for k, members in groups.items() if k.arm == primary and k._replace(arm=key.arm, build=key.build) == key for r in members]
        return same

    def check_of(key: Key) -> dict | None:
        return checks.get((key.task, key.size, key.variant, key.tag, key.arm, key.commit, key.spec))

    print("# Benchmark report\n")
    for (commit, dirty, spec), s in sessions.items():
        print(f"Commit {commit[:8]}{' (dirty)' if dirty else ''}, spec {spec}, {s['cores']} cores, {s['mem_total_gb']} GB, kernel {s['kernel']}.")
    print()

    failed = [r for r in runs if r["status"] != "ok"]
    failed_checks = [(k, c) for k, c in checks.items() if not c.get("pass")]
    print(f"## Failures: {len(failed)} runs, {len(failed_checks)} value checks\n")
    if failed:
        rows = [
            [
                r["task"],
                r["size"],
                r["variant"],
                r["arm"],
                str(r["rep"]),
                r["phase"],
                r["status"],
                r["cap"],
                fmt(r.get("exit")),
                fmt(r.get("oom_kill")),
                fmt(r.get("peak_anon_shmem_mb"), 0),
                fmt(r.get("memory_peak_mb"), 0),
                fmt((r.get("shm_orphans") or {}).get("mb"), 0),
                failure_note(r),
            ]
            for r in failed
        ]
        print(table(["task", "size", "variant", "arm", "rep", "phase", "status", "cap", "exit", "oom_kill", "peak MB", "memory.peak MB", "orphan shm MB", "note"], rows) + "\n")
    if failed_checks:
        rows = [[c["task"], c["size"], c["variant"], f"{c['a']} vs {c['b']}", check_cell(c)] for _, c in failed_checks]
        print(table(["task", "size", "variant", "pair", "check"], rows) + "\n")

    not_comparable = {}
    print("## Results\n")
    print(
        "Wall is the median of completed repeats, with the fastest in brackets; it excludes pool start. Peak is sampled anon plus shmem "
        "for that phase, over every repeat, failed ones included; >= marks a peak the cap cut short. memory.peak covers the whole run "
        "and counts page cache. max events is the cgroup's count of reaching the cap. Ratio is against " + primary + " at the same cap: "
        "n/c means the two walls are not at equal convergence. Value check compares each arm's first cold output with " + reference + ", "
        "or names the arm it used where " + reference + " left no output.\n"
    )
    rows = []
    for key in sorted(groups, key=lambda k: (k.task, k.size, k.variant, k.phase, str(k.tag), k.arm != reference, k.arm, k.cap, k.commit, str(k.build))):
        if key.arm in memory_arms:
            continue
        members = groups[key]
        done = walls(members)
        good = [r for r in members if r["status"] == "ok"]
        base_runs = primary_runs(key)
        base = walls(base_runs)
        gap = median_gap(good)
        problem = gap_problem(task_specs.get(key.task, {}).get("gap"), key.variant, key.arm, gap, median_gap(base_runs))
        if problem and key.arm != primary:
            not_comparable[(key.task, key.size, key.variant, key.tag, key.arm, key.cap)] = problem
        if problem:
            ratio = "n/c"
        else:
            ratio = f"{statistics.median(done) / statistics.median(base):.2f}" if done and base else "-"
        startup = [r["startup_s"] for r in good if r.get("startup_s") is not None]
        memory_peaks = [r["memory_peak_mb"] for r in members if r.get("memory_peak_mb") is not None]
        loads = [r["load"] for r in members if r.get("load") is not None]
        row = [
            key.task + (f" [{key.tag}]" if key.tag else ""),
            key.size,
            key.variant,
            key.phase,
            key.arm,
            f"{len(done)}/{len(members)}",
            f"{statistics.median(done):.2f} ({min(done):.2f})" if done else "-",
            ratio,
            fmt(statistics.median(startup) if startup else None),
            key.cap,
            peak_cell(members, key.cap),
            fmt(max(memory_peaks) if memory_peaks else None, 0),
            fmt(max((r.get("memory_max_events") or 0) for r in members)),
            fmt(max(loads) if loads else None, 1),
            f"{gap:.2e}" if gap is not None else "-",
            stable_hash(good),
            check_cell(check_of(key), reference) if key.phase == "cold" else warm_cell(members),
        ]
        if several_builds:
            row.insert(5, f"{key.commit[:8]}/{key.spec[:6]}/{key.build or '-'}")
        rows.append(row)
    header = ["task", "size", "variant", "phase", "arm", "done", "wall s", "ratio", "startup s", "cap", "peak MB", "memory.peak MB", "max events", "load", "gap", "hash", "value check"]
    if several_builds:
        header.insert(5, "commit/spec/build")
    print(table(header, rows) + "\n")

    compile_s = defaultdict(list)
    for r in runs:
        if (r.get("extra") or {}).get("jit_s") is not None:
            compile_s[r["arm"]].append(r["extra"]["jit_s"])
    for arm, seconds in sorted(compile_s.items()):
        print(f"- {arm}: cold wall includes numba's compile of numbagg, median {statistics.median(seconds):.1f} s, once per process, as garry's includes XLA's. The cost is fixed, so its share falls with data size.")
    seen = {k.task for k in groups}
    for task in tasks_spec["tasks"]:
        if task["id"] in seen:
            for note in task.get("notes", []):
                print(f"- {task['id']}: {note}")
    print()

    if not_comparable:
        print("## Not at equal convergence\n")
        rows = [[task, size, variant, arm, cap, why] for (task, size, variant, _, arm, cap), why in not_comparable.items()]
        print(table(["task", "size", "variant", "arm", "cap", "why"], rows) + "\n")

    swept = sweep_rows(runs, groups)
    if swept:
        print("## Sweeps\n")
        print("Each value's wall over the best value's, per task and variant: geometric mean, then the worst.\n")
        print(table(["arm", "size", "value", "phase", "tasks", "mean", "worst"], swept) + "\n")

    memory_rows = []
    for key in sorted(k for k in groups if k.arm in memory_arms):
        members = groups[key]
        done = walls(members)
        statuses = sorted({r["status"] for r in members})
        memory_rows.append([key.task, key.size, key.phase, key.arm, f"{len(done)}/{len(members)}", ",".join(statuses), key.cap, peak_cell(members, key.cap), f"{statistics.median(done):.2f}" if done else "-"])
    if memory_rows:
        print("## Memory track\n")
        print(table(["task", "size", "phase", "arm", "completed", "status", "cap", "peak MB", "wall s"], memory_rows) + "\n")

    if envs:
        print("## Environment\n")
        for (arm, _), env in sorted(envs.items(), key=str):
            keys = {k: v for k, v in env.items() if k not in ("kind", "arm", "ts")}
            print(f"- {arm}: {json.dumps(keys)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
