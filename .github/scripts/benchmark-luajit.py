#!/usr/bin/env python3
"""Compare this fork's sandboxed LuaJIT against upstream LuaJIT for CI."""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
import subprocess
import sys
from pathlib import Path


BENCHMARKS: dict[str, str] = {
    "numeric-loop": r"""
local n = tonumber(arg[1]) or 12000000
if n <= 0 then n = 12000000 end
local x = 0
local start = os.clock()
for i = 1, n do x = (x + i) % 1000000007 end
local elapsed = os.clock() - start
print(string.format('RESULT numeric-loop %.9f %d', elapsed, x))
""",
    "table-index": r"""
local n = tonumber(arg[1]) or 5000000
if n <= 0 then n = 5000000 end
local t = {x = 7, y = 11, z = 13}
local x = 0
local start = os.clock()
for i = 1, n do x = x + t.x + t.y + t.z end
local elapsed = os.clock() - start
print(string.format('RESULT table-index %.9f %d', elapsed, x))
""",
    "ffi-array": r"""
local ffi = require('ffi')
local n = tonumber(arg[1]) or 3500000
if n <= 0 then n = 3500000 end
local a = ffi.new('uint32_t[?]', 256)
for i = 0, 255 do a[i] = i end
local x = 0ULL
local start = os.clock()
for i = 1, n do x = x + a[i % 256] end
local elapsed = os.clock() - start
print(string.format('RESULT ffi-array %.9f %s', elapsed, tostring(x)))
""",
}


AUDITED_ENV_KEYS: tuple[str, ...] = (
    "MACOSX_DEPLOYMENT_TARGET",
    "CL",
    "TARGET_CFLAGS",
    "TARGET_DYLIBPATH",
)


def run_lua(luajit: Path, script: Path, iterations: int) -> tuple[float, str]:
    completed = subprocess.run(
        [str(luajit), str(script), str(iterations)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    lines = [line.strip() for line in completed.stdout.splitlines() if line.strip()]
    if len(lines) != 1 or not lines[0].startswith("RESULT "):
        raise SystemExit(f"malformed benchmark output from {luajit} {script.name}: {completed.stdout!r} {completed.stderr!r}")
    _, name, seconds, checksum = lines[0].split(maxsplit=3)
    if name != script.stem:
        raise SystemExit(f"benchmark name mismatch: script {script.stem}, output {name}")
    return float(seconds), checksum


def median(values: list[float]) -> float:
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2.0


def nullable(value: str | None) -> str | None:
    if value is None:
        return None
    value = value.strip()
    return value if value else None


def parse_key_values(values: list[str]) -> dict[str, str | None]:
    result: dict[str, str | None] = {}
    for value in values:
        if "=" not in value:
            raise SystemExit(f"expected KEY=VALUE metadata entry, got {value!r}")
        key, item = value.split("=", 1)
        if not key:
            raise SystemExit(f"empty metadata key in {value!r}")
        result[key] = nullable(item)
    return result


def collect_relevant_env(extra_env: list[str]) -> dict[str, str | None]:
    env = {key: nullable(os.environ.get(key)) for key in AUDITED_ENV_KEYS}
    env.update(parse_key_values(extra_env))
    return env


def build_metadata(command: str | None, version: str | None, description: str | None = None) -> dict[str, str | None]:
    return {
        "command": nullable(command),
        "version": nullable(version),
        "description": nullable(description),
    }


def format_nullable(value: object) -> str:
    if value is None or value == "":
        return "`null`"
    text = str(value).replace("|", "\\|").replace("\r\n", "\n").replace("\r", "\n").replace("\n", "<br>")
    return f"`{text}`"


def write_svg(path: Path, rows: list[dict[str, object]]) -> None:
    width = 900
    row_height = 42
    left = 160
    top = 50
    height = top + row_height * len(rows) + 50
    max_seconds = max(float(row["fork_median_seconds"]) for row in rows)
    max_seconds = max(max_seconds, *(float(row["upstream_median_seconds"]) for row in rows))
    scale = (width - left - 80) / max_seconds if max_seconds > 0 else 1.0
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<style>text{font-family:system-ui,sans-serif;font-size:13px}.title{font-size:18px;font-weight:700}.note{font-size:11px;fill:#555}</style>',
        '<text class="title" x="20" y="28">LuaJIT CI benchmark medians (lower is better)</text>',
    ]
    for index, row in enumerate(rows):
        y = top + index * row_height
        name = str(row["benchmark"])
        upstream = float(row["upstream_median_seconds"])
        fork = float(row["fork_median_seconds"])
        parts.append(f'<text x="20" y="{y + 16}">{name}</text>')
        parts.append(f'<rect x="{left}" y="{y}" width="{upstream * scale:.1f}" height="14" fill="#8888cc"><title>upstream {upstream:.6f}s</title></rect>')
        parts.append(f'<rect x="{left}" y="{y + 18}" width="{fork * scale:.1f}" height="14" fill="#55aa55"><title>fork {fork:.6f}s</title></rect>')
        parts.append(f'<text x="{left + max(upstream, fork) * scale + 8:.1f}" y="{y + 27}">ratio {float(row["fork_vs_upstream_ratio"]):.3f}</text>')
    parts.append(f'<text class="note" x="20" y="{height - 18}">CI-hosted runner timings are noisy and not authoritative. Use local controlled runs before believing tiny deltas.</text>')
    parts.append('</svg>')
    path.write_text("\n".join(parts) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fork-luajit", required=True, type=Path)
    parser.add_argument("--upstream-luajit", required=True, type=Path)
    parser.add_argument("--upstream-repo", default="https://github.com/LuaJIT/LuaJIT.git")
    parser.add_argument("--upstream-ref", required=True)
    parser.add_argument("--upstream-sha", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--arch", required=True)
    parser.add_argument("--fork-build-description", default="sandboxed release build")
    parser.add_argument("--fork-build-command")
    parser.add_argument("--fork-compiler-command")
    parser.add_argument("--fork-compiler-version")
    parser.add_argument("--upstream-build-command")
    parser.add_argument("--upstream-compiler-command")
    parser.add_argument("--upstream-compiler-version")
    parser.add_argument(
        "--env",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="record a relevant build environment value; empty VALUE is recorded as null",
    )
    parser.add_argument("--output-dir", default="benchmarks-output", type=Path)
    parser.add_argument("--samples", default=5, type=int)
    args = parser.parse_args()

    if args.samples < 1:
        raise SystemExit("--samples must be positive")

    output = args.output_dir.resolve()
    scripts = output / "scripts"
    scripts.mkdir(parents=True, exist_ok=True)
    for name, source in BENCHMARKS.items():
        (scripts / f"{name}.lua").write_text(source.strip() + "\n", encoding="utf-8")

    rows: list[dict[str, object]] = []
    raw: list[dict[str, object]] = []
    for name in BENCHMARKS:
        script = scripts / f"{name}.lua"
        fork_times: list[float] = []
        upstream_times: list[float] = []
        checksum: str | None = None
        for sample in range(1, args.samples + 1):
            upstream_seconds, upstream_checksum = run_lua(args.upstream_luajit.resolve(), script, 0)
            fork_seconds, fork_checksum = run_lua(args.fork_luajit.resolve(), script, 0)
            if upstream_checksum != fork_checksum:
                raise SystemExit(f"checksum mismatch for {name}: upstream={upstream_checksum} fork={fork_checksum}")
            checksum = upstream_checksum
            upstream_times.append(upstream_seconds)
            fork_times.append(fork_seconds)
            raw.append({"benchmark": name, "sample": sample, "build": "upstream", "seconds": upstream_seconds, "checksum": checksum})
            raw.append({"benchmark": name, "sample": sample, "build": "fork-sandboxed", "seconds": fork_seconds, "checksum": checksum})
        upstream_median = median(upstream_times)
        fork_median = median(fork_times)
        ratio = fork_median / upstream_median if upstream_median > 0 else math.inf
        rows.append({
            "benchmark": name,
            "checksum": checksum,
            "upstream_median_seconds": upstream_median,
            "fork_median_seconds": fork_median,
            "fork_vs_upstream_ratio": ratio,
        })

    metadata = {
        "schema_version": 1,
        "platform": args.platform,
        "arch": args.arch,
        "fork_build": {
            "variant": "sandboxed",
            "description": nullable(args.fork_build_description),
            "command": nullable(args.fork_build_command),
            "compiler": build_metadata(args.fork_compiler_command, args.fork_compiler_version),
        },
        "upstream_repo": args.upstream_repo,
        "upstream_ref": args.upstream_ref,
        "upstream_sha": args.upstream_sha,
        "upstream_ref_is_moving": not re.fullmatch(r"[0-9a-fA-F]{40}", args.upstream_ref),
        "upstream_build": {
            "command": nullable(args.upstream_build_command),
            "compiler": build_metadata(args.upstream_compiler_command, args.upstream_compiler_version),
        },
        "environment": collect_relevant_env(args.env),
        "gcstats_enabled": False,
        "caveat": "CI-hosted runner timings are noisy and not authoritative.",
    }
    (output / "benchmark-summary.json").write_text(json.dumps({"metadata": metadata, "results": rows, "raw": raw}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    with (output / "benchmark-summary.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["benchmark", "checksum", "upstream_median_seconds", "fork_median_seconds", "fork_vs_upstream_ratio"])
        writer.writeheader()
        writer.writerows(rows)
    with (output / "benchmark-raw.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["benchmark", "sample", "build", "seconds", "checksum"])
        writer.writeheader()
        writer.writerows(raw)
    lines = [
        f"# LuaJIT benchmark comparison: {args.platform} {args.arch}",
        "",
        "This compares this fork's `sandboxed` release build against upstream LuaJIT.",
        "The `unsandboxed` sandbox-bypass build is deliberately not benchmarked.",
        "GCStats telemetry is not enabled.",
        "",
        "## Build provenance",
        "",
        f"Platform: `{args.platform}`",
        f"Architecture: `{args.arch}`",
        f"Upstream repository: {args.upstream_repo}",
        f"Upstream ref: `{args.upstream_ref}`",
        f"Resolved upstream SHA: `{args.upstream_sha}`",
        "Upstream ref mutability: "
        + ("moving ref; use the resolved SHA for exact reproduction." if metadata["upstream_ref_is_moving"] else "pinned commit SHA."),
        "",
        "| Field | Fork sandboxed | Upstream |",
        "| --- | --- | --- |",
        f"| Build command/args | {format_nullable(metadata['fork_build']['command'])} | {format_nullable(metadata['upstream_build']['command'])} |",
        f"| Build description | {format_nullable(metadata['fork_build']['description'])} | `upstream LuaJIT` |",
        f"| Compiler command | {format_nullable(metadata['fork_build']['compiler']['command'])} | {format_nullable(metadata['upstream_build']['compiler']['command'])} |",
        f"| Compiler version | {format_nullable(metadata['fork_build']['compiler']['version'])} | {format_nullable(metadata['upstream_build']['compiler']['version'])} |",
        "",
        "Relevant build environment:",
        "",
        "| Variable | Value |",
        "| --- | --- |",
        *[f"| `{key}` | {format_nullable(value)} |" for key, value in sorted(metadata["environment"].items())],
        "",
        "## Results",
        "",
        "> CI-hosted runner timings are noisy and not authoritative; use controlled local runs before treating small ratios as signal.",
        "",
        "| Benchmark | Checksum | Upstream median (s) | Fork sandboxed median (s) | Fork/upstream |",
        "| --- | --- | ---: | ---: | ---: |",
    ]
    for row in rows:
        lines.append(f"| {row['benchmark']} | `{row['checksum']}` | {float(row['upstream_median_seconds']):.6f} | {float(row['fork_median_seconds']):.6f} | {float(row['fork_vs_upstream_ratio']):.3f} |")
    (output / "README.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    write_svg(output / "benchmark-summary.svg", rows)
    print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
