#!/usr/bin/env python3
"""Compare LuaJIT builds with batched direct C finalizers disabled/enabled."""

import argparse
import csv
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


LATENCY_FIELDS = [
    "avg_ms",
    "median_ms",
    "p90_ms",
    "p95_ms",
    "p99_ms",
    "p999_ms",
    "max_ms",
    "worst_0_1pct_avg_ms",
]

PHASE_ORDER = {"alloc": 0, "gc_finalizer": 1, "total": 2}


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Run bench/batched_finalizers.lua for batched-finalizer-off and "
            "batched-finalizer-on LuaJIT variants and print side-by-side stats."
        )
    )
    parser.add_argument("--enabled-bin", help="batched-finalizer-enabled luajit binary")
    parser.add_argument("--disabled-bin", help="batched-finalizer-disabled luajit binary")
    parser.add_argument("--xcflags", default="", help="base XCFLAGS for serial builds")
    parser.add_argument("--cap", default="", help="optional LUAJIT_BATCHED_FINALIZER_MAX value")
    parser.add_argument("--make", default="make", help="make executable (default: %(default)s)")
    parser.add_argument(
        "--no-restore",
        action="store_true",
        help="do not rebuild the default tree after serial build comparison",
    )
    parser.add_argument("--objects", default="10000", help="objects per burst")
    parser.add_argument("--bursts", default="50", help="measured bursts")
    parser.add_argument("--k", default="1,2,4,8", help="metatable counts")
    parser.add_argument("--functions", default="4", help="distinct C finalizer function identities")
    parser.add_argument("--ineligible-every", default="0", help="C-closure finalizer interval")
    parser.add_argument("--mode", default="collect", choices=("collect", "step"))
    parser.add_argument("--step", default="0", help='collectgarbage("step", N) argument')
    parser.add_argument(
        "--keep-temp",
        action="store_true",
        help="keep temporary copied binaries/helper build directories",
    )
    return parser.parse_args()


def repo_root():
    return Path(__file__).resolve().parents[1]


def run(cmd, cwd, env=None):
    print("# run=", " ".join(str(c) for c in cmd), sep="", flush=True)
    subprocess.run(cmd, cwd=str(cwd), env=env, check=True)


def serial_build(repo, make, xcflags, label, tmpdir):
    flags = xcflags.strip()
    print(f"# building {label} variant with XCFLAGS={flags}", flush=True)
    run([make, "clean"], repo)
    if flags:
        run([make, f"XCFLAGS={flags}"], repo)
    else:
        run([make], repo)
    outdir = tmpdir / label
    outdir.mkdir(parents=True, exist_ok=True)
    out = outdir / "luajit"
    shutil.copy2(repo / "src" / "luajit", out)
    out.chmod(0o755)
    return out


def restore_default(repo, make):
    print("# restoring default build", flush=True)
    run([make, "clean"], repo)
    run([make], repo)


def benchmark_args(args, build_dir):
    return [
        "--objects", str(args.objects),
        "--bursts", str(args.bursts),
        "--k", str(args.k),
        "--functions", str(args.functions),
        "--ineligible-every", str(args.ineligible_every),
        "--mode", str(args.mode),
        "--step", str(args.step),
        "--build-dir", str(build_dir),
    ]


def run_benchmark(repo, luajit, label, args, tmpdir):
    build_dir = tmpdir / f"helper-{label}"
    script = repo / "bench" / "batched_finalizers.lua"
    cmd = [str(luajit), str(script)] + benchmark_args(args, build_dir)
    print("# benchmark=", " ".join(cmd), sep="", flush=True)
    proc = subprocess.run(
        cmd,
        cwd=str(repo),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        sys.stdout.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise subprocess.CalledProcessError(proc.returncode, cmd)
    return parse_benchmark_output(proc.stdout)


def parse_benchmark_output(output):
    meta = {}
    csv_lines = []
    for line in output.splitlines():
        if line.startswith("# "):
            body = line[2:]
            if "=" in body:
                key, value = body.split("=", 1)
                meta[key.strip()] = value.strip()
        elif line.strip():
            csv_lines.append(line)
    rows = list(csv.DictReader(csv_lines)) if csv_lines else []
    return meta, rows


def row_key(row):
    return row.get("k", ""), row.get("phase", "")


def sort_key(key):
    k, phase = key
    try:
        kn = int(k)
    except ValueError:
        kn = 0
    return kn, PHASE_ORDER.get(phase, 99), phase


def fmt(value):
    return value if value not in (None, "") else ""


def counter(row, name):
    if row is None:
        return None
    value = row.get(name)
    if value in (None, ""):
        return None
    try:
        return int(float(value))
    except ValueError:
        return None


def print_latency_table(enabled_rows, disabled_rows):
    enabled = {row_key(row): row for row in enabled_rows}
    disabled = {row_key(row): row for row in disabled_rows}
    keys = sorted(set(enabled) | set(disabled), key=sort_key)
    header = ["k", "phase", "enabled_samples", "disabled_samples"]
    for field in LATENCY_FIELDS:
        header.append("enabled_" + field)
        header.append("disabled_" + field)
    print(",".join(header))
    for key in keys:
        erow = enabled.get(key, {})
        drow = disabled.get(key, {})
        out = [key[0], key[1], fmt(erow.get("samples")), fmt(drow.get("samples"))]
        for field in LATENCY_FIELDS:
            out.append(fmt(erow.get(field)))
            out.append(fmt(drow.get(field)))
        print(",".join(out))


def print_counter_table(enabled_rows, disabled_rows):
    enabled = {row_key(row): row for row in enabled_rows}
    disabled = {row_key(row): row for row in disabled_rows}
    keys = sorted(set(enabled) | set(disabled), key=sort_key)
    print(
        "k,phase,enabled_batches,enabled_batched_calls,enabled_batch_max,"
        "disabled_batches,enabled_function_counts,disabled_function_counts"
    )
    any_disabled_batch_counter = False
    disabled_batches_ok = True
    for key in keys:
        erow = enabled.get(key)
        drow = disabled.get(key)
        ebatches = counter(erow, "direct_cfunc_batches")
        ebatched = counter(erow, "direct_cfunc_batched_calls")
        emax = counter(erow, "direct_cfunc_batch_max")
        dbatches = counter(drow, "direct_cfunc_batches")
        if dbatches is not None:
            any_disabled_batch_counter = True
            if dbatches != 0:
                disabled_batches_ok = False
        print(
            ",".join(
                [
                    key[0], key[1],
                    "" if ebatches is None else str(ebatches),
                    "" if ebatched is None else str(ebatched),
                    "" if emax is None else str(emax),
                    "" if dbatches is None else str(dbatches),
                    fmt(erow.get("function_counts") if erow else None),
                    fmt(drow.get("function_counts") if drow else None),
                ]
            )
        )
    return any_disabled_batch_counter, disabled_batches_ok


def main():
    args = parse_args()
    repo = repo_root()
    tmp = Path(tempfile.mkdtemp(prefix="luajit-batched-finalizers-compare-"))
    built = False
    rc = 0
    try:
        if args.enabled_bin or args.disabled_bin:
            if not args.enabled_bin or not args.disabled_bin:
                raise SystemExit("--enabled-bin and --disabled-bin must be supplied together")
            enabled_bin = Path(args.enabled_bin).resolve()
            disabled_bin = Path(args.disabled_bin).resolve()
        else:
            built = True
            cap_flag = f" -DLUAJIT_BATCHED_FINALIZER_MAX={args.cap}" if args.cap else ""
            disabled_bin = serial_build(repo, args.make, args.xcflags, "disabled", tmp)
            enabled_flags = (args.xcflags + " -DLUAJIT_ENABLE_BATCHED_FINALIZERS" + cap_flag).strip()
            enabled_bin = serial_build(repo, args.make, enabled_flags, "enabled", tmp)

        disabled_meta, disabled_rows = run_benchmark(repo, disabled_bin, "disabled", args, tmp)
        enabled_meta, enabled_rows = run_benchmark(repo, enabled_bin, "enabled", args, tmp)

        print("# enabled_bin=", enabled_bin, sep="")
        print("# disabled_bin=", disabled_bin, sep="")
        print("# enabled_batched_finalizers=", enabled_meta.get("batched_finalizers", "unknown"), sep="")
        print("# disabled_batched_finalizers=", disabled_meta.get("batched_finalizers", "unknown"), sep="")
        print("# enabled_gcstats=", enabled_meta.get("gcstats", "unknown"), sep="")
        print("# disabled_gcstats=", disabled_meta.get("gcstats", "unknown"), sep="")
        print("# enabled_finalizer_functions=", enabled_meta.get("finalizer_functions", "unknown"), sep="")
        print("# disabled_finalizer_functions=", disabled_meta.get("finalizer_functions", "unknown"), sep="")
        print("# ineligible_every=", enabled_meta.get("ineligible_every", "unknown"), sep="")

        print("# latency_stats")
        print_latency_table(enabled_rows, disabled_rows)
        print("# batch_counters")
        have_disabled_counters, disabled_batches_ok = print_counter_table(enabled_rows, disabled_rows)
        if have_disabled_counters and not disabled_batches_ok:
            print("# disabled_batch_counter_check=fail")
            rc = 3
        elif have_disabled_counters:
            print("# disabled_batch_counter_check=pass")
        else:
            print("# disabled_batch_counter_check=unavailable")
    finally:
        if built and not args.no_restore:
            restore_default(repo, args.make)
        if args.keep_temp:
            print("# temp_dir=", tmp, sep="")
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
