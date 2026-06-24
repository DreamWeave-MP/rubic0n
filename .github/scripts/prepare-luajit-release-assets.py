#!/usr/bin/env python3
"""Validate LuaJIT release archives and produce publisher metadata.

Both the GitHub and NexusMods publish jobs run this. That keeps the checksum and
VirusTotal chain-of-custody checks identical instead of hoping two bits of shell
remember to be the same. Hope is not a serialization format.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn


SHA256SUMS_ASSET = "SHA256SUMS.txt"
VT_SUBMISSIONS_ASSET = "virustotal-submissions.tsv"
CHANGELOG_ASSET = "CHANGELOG.md"
RELEASE_NOTES = "release-notes.md"
VT_HEADER = ("archive", "sha256", "analysis_id", "analysis_url")
NEXUS_NAME_PATTERN_TEXT = r"^[a-zA-Z0-9 _'().-]+$"
NEXUS_NAME_PATTERN = re.compile(NEXUS_NAME_PATTERN_TEXT)
INSTALL_DIR = "extract into your OpenMW install"
INTERPRETER_DIR = "interpreter"
JIT_DIR = "jit"
RESOURCES_DIR = "resources"
REQUIRED_RESOURCE_FILE = "resources/lua_libs/content.lua"


@dataclass(frozen=True)
class ArchiveSpec:
    name: str
    os_name: str
    arch: str
    platform: str
    runtime_names: tuple[str, ...]
    benchmarks_expected: bool
    nexus_output: str
    nexus_title: str
    nexus_platform_meaning: str
    nexus_runtime_payload: str
    nexus_caveats: tuple[str, ...] = ()


EXPECTED_ARCHIVES: tuple[ArchiveSpec, ...] = (
    ArchiveSpec(
        name="LuaJIT-Windows-X64.zip",
        os_name="Windows",
        arch="X64",
        platform="windows",
        runtime_names=(f"{INSTALL_DIR}/lua51.dll", f"{INTERPRETER_DIR}/luajit.exe"),
        benchmarks_expected=True,
        nexus_output="windows_x64",
        nexus_title="LuaJIT Windows X64",
        nexus_platform_meaning="Windows x86_64 / 64-bit desktop build.",
        nexus_runtime_payload=f"Selected variant [code]{INSTALL_DIR}/lua51.dll[/code] and [code]{INTERPRETER_DIR}/luajit.exe[/code].",
    ),
    ArchiveSpec(
        name="LuaJIT-Linux-X64.zip",
        os_name="Linux",
        arch="X64",
        platform="linux",
        runtime_names=(f"{INSTALL_DIR}/lib/libluajit-5.1.so.2", f"{INTERPRETER_DIR}/luajit"),
        benchmarks_expected=True,
        nexus_output="linux_x64",
        nexus_title="LuaJIT Linux X64",
        nexus_platform_meaning="Linux x86_64 / AMD64 build.",
        nexus_runtime_payload=f"Selected variant [code]{INSTALL_DIR}/lib/libluajit-5.1.so.2[/code] and [code]{INTERPRETER_DIR}/luajit[/code].",
    ),
    ArchiveSpec(
        name="LuaJIT-macOS-ARM64.zip",
        os_name="macOS",
        arch="ARM64",
        platform="macos",
        runtime_names=(f"{INSTALL_DIR}/libluajit-5.1.2.dylib", f"{INSTALL_DIR}/libluajit-5.1.dylib", f"{INTERPRETER_DIR}/luajit"),
        benchmarks_expected=True,
        nexus_output="macos_arm64",
        nexus_title="LuaJIT macOS ARM64",
        nexus_platform_meaning="macOS Apple Silicon ARM64 build.",
        nexus_runtime_payload=f"Selected variant [code]{INSTALL_DIR}/libluajit-5.1.2.dylib[/code], alias [code]{INSTALL_DIR}/libluajit-5.1.dylib[/code], and [code]{INTERPRETER_DIR}/luajit[/code].",
        nexus_caveats=("This is separate from the macOS Intel/X64 download; do not use it for x86_64-only macOS runtimes.",),
    ),
    ArchiveSpec(
        name="LuaJIT-macOS-X64.zip",
        os_name="macOS",
        arch="X64",
        platform="macos",
        runtime_names=(f"{INSTALL_DIR}/libluajit-5.1.2.dylib", f"{INSTALL_DIR}/libluajit-5.1.dylib", f"{INTERPRETER_DIR}/luajit"),
        benchmarks_expected=True,
        nexus_output="macos_x64",
        nexus_title="LuaJIT macOS Intel X64",
        nexus_platform_meaning="macOS Intel x86_64 build.",
        nexus_runtime_payload=f"Selected variant [code]{INSTALL_DIR}/libluajit-5.1.2.dylib[/code], alias [code]{INSTALL_DIR}/libluajit-5.1.dylib[/code], and [code]{INTERPRETER_DIR}/luajit[/code].",
        nexus_caveats=("This is separate from the macOS ARM64 / Apple Silicon download; do not use it for arm64-only macOS runtimes.",),
    ),
    ArchiveSpec(
        name="LuaJIT-Android-ARM64.zip",
        os_name="Android",
        arch="ARM64",
        platform="android",
        runtime_names=(f"{INSTALL_DIR}/libluajit.so",),
        benchmarks_expected=False,
        nexus_output="android_arm64",
        nexus_title="LuaJIT Android ARM64",
        nexus_platform_meaning="Android ARM64 / AArch64 ([code]arm64-v8a[/code]) native-library payload.",
        nexus_runtime_payload=f"Selected variant [code]{INSTALL_DIR}/libluajit.so[/code]; place it in the app's ARM64 native library location or equivalent engine-managed loader path.",
        nexus_caveats=("This is a raw [code]libluajit.so[/code] runtime library, not an APK or installable Android application.",),
    ),
    ArchiveSpec(
        name="LuaJIT-PortMaster-ARM64.zip",
        os_name="PortMaster",
        arch="ARM64",
        platform="portmaster",
        runtime_names=(f"{INSTALL_DIR}/libluajit.so", f"{INTERPRETER_DIR}/luajit"),
        benchmarks_expected=False,
        nexus_output="portmaster_arm64",
        nexus_title="LuaJIT PortMaster ARM64",
        nexus_platform_meaning="PortMaster Linux AArch64 / arm64 payload.",
        nexus_runtime_payload=f"Selected variant [code]{INSTALL_DIR}/libluajit.so[/code] and [code]{INTERPRETER_DIR}/luajit[/code]; place the library where the PortMaster launcher/runtime library path can load it.",
        nexus_caveats=("This is Linux AArch64 for PortMaster devices, not Android and not ARMv7/armhf.",),
    ),
)
EXPECTED_NAMES = {spec.name for spec in EXPECTED_ARCHIVES}
VARIANTS = ("sandboxed", "unsandboxed")


def fail(message: str) -> NoReturn:
    raise SystemExit(f"prepare-luajit-release-assets: {message}")


def remove_prefix(value: str, prefix: str) -> str:
    if not value.startswith(prefix):
        fail(f"internal error: {value!r} does not start with {prefix!r}")
    return value[len(prefix):]


def sanitize_nexus_name(name: str) -> str:
    # Nexus validates upload/version names with ^[a-zA-Z0-9 _'().-]+$.
    # Human platform labels tend to grow slash-separated synonyms; turn those
    # into spaces, then fail if anything else still violates the API contract.
    return " ".join(name.replace("/", " ").split())


def nexus_display_name(spec: ArchiveSpec) -> str:
    name = sanitize_nexus_name(spec.nexus_title)
    if not name:
        fail(f"{spec.name} has an empty Nexus display name")
    if NEXUS_NAME_PATTERN.fullmatch(name) is None:
        fail(f"{spec.name} Nexus display name {name!r} does not match {NEXUS_NAME_PATTERN_TEXT}")
    return name


def nexus_archive_name(spec: ArchiveSpec) -> str:
    return f"{spec.os_name}-{spec.arch}.zip"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_exact_archives(archive_dir: Path) -> dict[str, Path]:
    if not archive_dir.is_dir():
        fail(f"archive directory is missing: {archive_dir}")
    archives = {path.name: path for path in archive_dir.glob("*.zip")}
    found = set(archives)
    if found != EXPECTED_NAMES:
        missing = sorted(EXPECTED_NAMES - found)
        extra = sorted(found - EXPECTED_NAMES)
        details = []
        if missing:
            details.append(f"missing: {', '.join(missing)}")
        if extra:
            details.append(f"unexpected: {', '.join(extra)}")
        fail("expected exactly six release zip archives (" + "; ".join(details) + ")")
    for path in archives.values():
        if not path.is_file() or path.stat().st_size <= 0:
            fail(f"archive is empty or missing: {path}")
    return archives


def archive_files_under(names: set[str], prefix: str) -> list[str]:
    return sorted(
        remove_prefix(name, prefix)
        for name in names
        if name.startswith(prefix) and not name.endswith("/")
    )


def validate_archive_layout(path: Path, spec: ArchiveSpec) -> None:
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
        if "manifest.json" not in names:
            fail(f"{path.name} is missing manifest.json")
        if "README-LuaJIT-artifact.md" not in names:
            fail(f"{path.name} is missing README-LuaJIT-artifact.md")
        if "COPYRIGHT" not in names:
            fail(f"{path.name} is missing COPYRIGHT")
        manifest = json.loads(archive.read("manifest.json").decode("utf-8"))

    nested_prefix = f"{path.stem}/"
    if any(name.startswith(nested_prefix) for name in names):
        fail(f"{path.name} contains nested {path.stem}/; expected variant dirs at zip root")
    allowed_root_files = {"README-LuaJIT-artifact.md", "manifest.json", "COPYRIGHT"}
    allowed_root_dirs = {*VARIANTS, "benchmarks"}
    for name in names:
        if name in allowed_root_files:
            continue
        root_name = name.split("/", 1)[0]
        if root_name in allowed_root_dirs:
            continue
        fail(f"{path.name} contains unexpected top-level payload {name!r}")
    if manifest.get("os_name") != spec.os_name:
        fail(f"{path.name} manifest os_name is {manifest.get('os_name')!r}, expected {spec.os_name!r}")
    if manifest.get("arch") != spec.arch:
        fail(f"{path.name} manifest arch is {manifest.get('arch')!r}, expected {spec.arch!r}")
    if manifest.get("platform") != spec.platform:
        fail(f"{path.name} manifest platform is {manifest.get('platform')!r}, expected {spec.platform!r}")
    if manifest.get("benchmarks_included") is not spec.benchmarks_expected:
        fail(f"{path.name} manifest has wrong benchmark inclusion state")
    has_benchmarks = any(name.startswith("benchmarks/") for name in names)
    if has_benchmarks is not spec.benchmarks_expected:
        fail(f"{path.name} benchmark payload presence is wrong")
    if spec.benchmarks_expected:
        for benchmark_file in (
            "benchmarks/README.md",
            "benchmarks/benchmark-summary.json",
            "benchmarks/benchmark-summary.csv",
            "benchmarks/benchmark-raw.csv",
            "benchmarks/benchmark-summary.svg",
        ):
            if benchmark_file not in names:
                fail(f"{path.name} is missing {benchmark_file}")
    if manifest.get("gcstats_enabled") is not False:
        fail(f"{path.name} manifest must declare that GCStats is disabled")
    if not manifest.get("package_path_root"):
        fail(f"{path.name} manifest is missing package_path_root")
    resource_files = manifest.get("resource_files")
    if not isinstance(resource_files, list):
        fail(f"{path.name} manifest is missing resource_files")
    security = manifest.get("security")
    if not isinstance(security, dict):
        fail(f"{path.name} manifest is missing security")
    if not isinstance(security.get("virustotal"), dict):
        fail(f"{path.name} manifest is missing security.virustotal")
    if security.get("sha256sums_asset") != SHA256SUMS_ASSET:
        fail(f"{path.name} manifest has wrong security.sha256sums_asset")
    if not security.get("nexusmods_note"):
        fail(f"{path.name} manifest is missing security.nexusmods_note")

    for variant in VARIANTS:
        variant_prefix = f"{variant}/"
        interpreter_prefix = f"{variant_prefix}{INTERPRETER_DIR}/"
        jit_prefix = f"{interpreter_prefix}{JIT_DIR}/"
        install_prefix = f"{variant_prefix}{INSTALL_DIR}/"
        expected_variant_dirs = {INSTALL_DIR, INTERPRETER_DIR}
        required_resource_file = f"{install_prefix}{REQUIRED_RESOURCE_FILE}"

        if not any(name.startswith(variant_prefix) for name in names):
            fail(f"{path.name} is missing {variant}/")
        for name in names:
            if not name.startswith(variant_prefix) or name == variant_prefix:
                continue
            remainder = remove_prefix(name, variant_prefix)
            child = remainder.split("/", 1)[0]
            if child not in expected_variant_dirs:
                fail(f"{path.name} contains unexpected {variant}/ payload {remainder!r}")
        if not any(name.startswith(jit_prefix) for name in names):
            fail(f"{path.name} is missing {variant}/{INTERPRETER_DIR}/{JIT_DIR}/")
        if f"{jit_prefix}vmdef.lua" not in names:
            fail(f"{path.name} is missing {variant}/{INTERPRETER_DIR}/{JIT_DIR}/vmdef.lua")
        if not any(name.startswith(install_prefix) for name in names):
            fail(f"{path.name} is missing {variant}/{INSTALL_DIR}/")
        if required_resource_file not in names:
            fail(f"{path.name} is missing {required_resource_file}")
        actual_runtime_names = sorted(
            [f"{INTERPRETER_DIR}/{name}" for name in archive_files_under(names, interpreter_prefix) if "/" not in name]
            + [
                f"{INSTALL_DIR}/{name}"
                for name in archive_files_under(names, install_prefix)
                if f"{INSTALL_DIR}/{name}" in spec.runtime_names
            ]
        )
        if actual_runtime_names != sorted(spec.runtime_names):
            fail(
                f"{path.name} {variant}/ runtime payload is {actual_runtime_names!r}, "
                f"expected {sorted(spec.runtime_names)!r}"
            )
        for jit_file in archive_files_under(names, jit_prefix):
            if not jit_file.endswith(".lua"):
                fail(f"{path.name} contains non-Lua JIT module {variant}/{INTERPRETER_DIR}/{JIT_DIR}/{jit_file}")
        for runtime_name in spec.runtime_names:
            archive_member = f"{variant_prefix}{runtime_name}"
            if archive_member not in names:
                fail(f"{path.name} is missing {archive_member}")

        variant_manifest = manifest.get("variants", {}).get(variant)
        if not isinstance(variant_manifest, dict):
            fail(f"{path.name} manifest is missing {variant}")
        expected_library_files = sorted(name for name in spec.runtime_names if name.startswith(f"{INSTALL_DIR}/"))
        expected_executable_files = sorted(name for name in spec.runtime_names if name.startswith(f"{INTERPRETER_DIR}/"))
        expected_install_files = sorted(
            expected_library_files
            + [f"{INSTALL_DIR}/{RESOURCES_DIR}/{name}" for name in archive_files_under(names, f"{install_prefix}{RESOURCES_DIR}/")]
        )
        if sorted(variant_manifest.get("install_files", [])) != expected_install_files:
            fail(f"{path.name} manifest has wrong install_files for {variant}")
        if sorted(variant_manifest.get("library_files", [])) != expected_library_files:
            fail(f"{path.name} manifest has wrong library_files for {variant}")
        if sorted(variant_manifest.get("runtime_executable_files", [])) != expected_executable_files:
            fail(f"{path.name} manifest has wrong runtime_executable_files for {variant}")
        expected_jit_files = sorted(
            remove_prefix(name, variant_prefix)
            for name in names
            if name.startswith(jit_prefix) and not name.endswith("/")
        )
        if sorted(variant_manifest.get("jit_module_files", [])) != expected_jit_files:
            fail(f"{path.name} manifest has wrong jit_module_files for {variant}")
        if required_resource_file not in resource_files:
            fail(f"{path.name} manifest resource_files is missing {required_resource_file}")
        expected_bypass = variant == "unsandboxed"
        if variant_manifest.get("sandbox_bypass_enabled") is not expected_bypass:
            fail(f"{path.name} manifest has wrong sandbox bypass state for {variant}")
        if variant == "unsandboxed" and not variant_manifest.get("trusted_engine_dev_only"):
            fail(f"{path.name} manifest lacks trusted/dev-only warning for unsandboxed")


def read_vt_rows(vt_dir: Path) -> dict[str, dict[str, str]]:
    if not vt_dir.is_dir():
        fail(f"VirusTotal metadata directory is missing: {vt_dir}")
    rows: dict[str, dict[str, str]] = {}
    tsv_paths = sorted(vt_dir.rglob("*.tsv"))
    if not tsv_paths:
        fail(f"no VirusTotal TSV metadata files found in {vt_dir}")

    for path in tsv_paths:
        with path.open(newline="", encoding="utf-8") as handle:
            reader = csv.DictReader(handle, delimiter="\t")
            if tuple(reader.fieldnames or ()) != VT_HEADER:
                fail(f"{path} has wrong TSV header: {reader.fieldnames!r}")
            for row in reader:
                archive = (row.get("archive") or "").strip()
                if archive not in EXPECTED_NAMES:
                    fail(f"{path} contains unexpected archive row: {archive!r}")
                if archive in rows:
                    fail(f"duplicate VirusTotal metadata row for {archive}")
                for field in VT_HEADER:
                    if not (row.get(field) or "").strip():
                        fail(f"{path} row for {archive} is missing {field}")
                rows[archive] = {field: row[field].strip() for field in VT_HEADER}

    if set(rows) != EXPECTED_NAMES:
        missing = sorted(EXPECTED_NAMES - set(rows))
        extra = sorted(set(rows) - EXPECTED_NAMES)
        details = []
        if missing:
            details.append(f"missing: {', '.join(missing)}")
        if extra:
            details.append(f"unexpected: {', '.join(extra)}")
        fail("expected exactly six VirusTotal metadata rows (" + "; ".join(details) + ")")
    return rows


def verify_hashes(archives: dict[str, Path], vt_rows: dict[str, dict[str, str]]) -> dict[str, str]:
    hashes: dict[str, str] = {}
    for spec in EXPECTED_ARCHIVES:
        actual = sha256_file(archives[spec.name])
        recorded = vt_rows[spec.name]["sha256"]
        if actual != recorded:
            fail(f"{spec.name} SHA256 mismatch: archive={actual}, VirusTotal metadata={recorded}")
        hashes[spec.name] = actual
    return hashes


def write_sha256sums(output_dir: Path, hashes: dict[str, str]) -> Path:
    path = output_dir / SHA256SUMS_ASSET
    with path.open("w", encoding="utf-8") as handle:
        for spec in EXPECTED_ARCHIVES:
            handle.write(f"{hashes[spec.name]}  {spec.name}\n")
    return path


def write_vt_aggregate(output_dir: Path, vt_rows: dict[str, dict[str, str]]) -> Path:
    path = output_dir / VT_SUBMISSIONS_ASSET
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=VT_HEADER, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for spec in EXPECTED_ARCHIVES:
            writer.writerow(vt_rows[spec.name])
    return path


def release_url(repository: str, release_name: str) -> str:
    return f"https://github.com/{repository}/releases/tag/{release_name}"


def changelog_url(repository: str, release_name: str) -> str:
    return f"https://github.com/{repository}/releases/download/{release_name}/{CHANGELOG_ASSET}"


def commit_url(repository: str, sha: str) -> str:
    return f"https://github.com/{repository}/commit/{sha}"


def workflow_url(repository: str, run_id: str) -> str:
    return f"https://github.com/{repository}/actions/runs/{run_id}"


def write_release_notes(
    output_dir: Path,
    *,
    release_name: str,
    release_is_tag: bool,
    repository: str,
    workflow_run_id: str,
    target_sha: str,
    hashes: dict[str, str],
    vt_rows: dict[str, dict[str, str]],
) -> Path:
    path = output_dir / RELEASE_NOTES
    with path.open("w", encoding="utf-8") as handle:
        handle.write("CI Build for Dreamweave LuaJIT Fork\n\n")
        handle.write(f"Generated by workflow run: [{workflow_run_id}]({workflow_url(repository, workflow_run_id)})\n")
        handle.write(f"Source commit: [`{target_sha}`]({commit_url(repository, target_sha)})\n\n")
        handle.write("Artifacts contain two variant roots:\n")
        handle.write("- sandboxed/: default build, no LUAJIT_ENABLE_SANDBOX_BYPASS, select(\"sandbox.bypass\") unavailable.\n")
        handle.write("- unsandboxed/: WARNING: trusted engine/dev use only; enables LUAJIT_ENABLE_SANDBOX_BYPASS and exposes select(\"sandbox.bypass\").\n\n")
        handle.write("Each zip includes README-LuaJIT-artifact.md, manifest.json, COPYRIGHT, and resources/ inside each variant's OpenMW install payload. No GCStats telemetry build is included. Desktop zips include benchmarks/ comparing the sandboxed build against upstream LuaJIT; Android and PortMaster omit benchmarks because they are cross targets.\n")
        if release_is_tag:
            handle.write("This is a tag release stable snapshot; CI refuses to overwrite existing release assets.\n")
        else:
            handle.write("This is the moving development release; CI may move the development tag and clobber assets.\n")

        handle.write("\n## Changelog\n\n")
        handle.write(f"A generated changelog/context asset is uploaded as [`{CHANGELOG_ASSET}`]({changelog_url(repository, release_name)}).\n")

        handle.write("\n## Security / chain of custody\n\n")
        handle.write(
            "Each platform build submitted its final zip archive to VirusTotal before uploading "
            "that same path as a workflow artifact. This publisher downloaded those artifacts, "
            "recomputed SHA256, and compared the hashes against the per-platform VirusTotal TSV "
            "metadata before uploading anything to the GitHub release. Each VirusTotal submit "
            "job waited for analysis completion and failed if malicious/suspicious verdict "
            "counts exceeded the configured thresholds; follow the analysis link for vendor details.\n\n"
        )
        handle.write(f"Checksums are uploaded as `{SHA256SUMS_ASSET}`; VirusTotal submission metadata is uploaded as `{VT_SUBMISSIONS_ASSET}`.\n\n")
        handle.write("| Archive | SHA256 | VirusTotal analysis |\n")
        handle.write("| --- | --- | --- |\n")
        for spec in EXPECTED_ARCHIVES:
            row = vt_rows[spec.name]
            handle.write(f"| `{spec.name}` | `{hashes[spec.name]}` | [{row['analysis_id']}]({row['analysis_url']}) |\n")
        handle.write("\nIf you obtained these files through NexusMods, compare SHA256 values with the GitHub release assets. NexusMods may run its own scanner/cache, which is a separate chain of custody.\n")
    return path


def write_changelog(
    output_dir: Path,
    *,
    release_name: str,
    release_is_tag: bool,
    repository: str,
    workflow_run_id: str,
    target_sha: str,
    ref_name: str,
    hashes: dict[str, str],
    vt_rows: dict[str, dict[str, str]],
) -> Path:
    path = output_dir / CHANGELOG_ASSET
    release_kind = "tag" if release_is_tag else "development"
    with path.open("w", encoding="utf-8") as handle:
        handle.write(f"# LuaJIT {release_name} changelog\n\n")
        handle.write("This is generated release context for downstream mirrors such as NexusMods. It is intentionally small; the release notes carry the full archive table too.\n\n")
        handle.write(f"- Release type: {release_kind}\n")
        handle.write(f"- GitHub release: {release_url(repository, release_name)}\n")
        handle.write(f"- Workflow run: {workflow_url(repository, workflow_run_id)}\n")
        handle.write(f"- Source commit: [{target_sha}]({commit_url(repository, target_sha)})\n")
        handle.write(f"- Source ref: `{ref_name}`\n")
        handle.write(f"- Commit history for this ref: https://github.com/{repository}/commits/{ref_name}\n\n")
        handle.write("## Archives\n\n")
        handle.write("| Archive | SHA256 | VirusTotal analysis |\n")
        handle.write("| --- | --- | --- |\n")
        for spec in EXPECTED_ARCHIVES:
            row = vt_rows[spec.name]
            handle.write(f"| `{spec.name}` | `{hashes[spec.name]}` | [{row['analysis_id']}]({row['analysis_url']}) |\n")
        handle.write("\nAll archives contain `sandboxed/` and `unsandboxed/` variant roots plus shared `resources/`. No GCStats telemetry build or developer support payload is included.\n")
    return path


def bbcode_url(url: str, text: str) -> str:
    return f"[URL={url}]{text}[/URL]"


def write_nexus_metadata(
    metadata_dir: Path,
    *,
    release_name: str,
    repository: str,
    workflow_run_id: str,
    target_sha: str,
    hashes: dict[str, str],
    vt_rows: dict[str, dict[str, str]],
) -> None:
    metadata_dir.mkdir(parents=True, exist_ok=True)
    github_run = workflow_url(repository, workflow_run_id)
    github_commit = commit_url(repository, target_sha)
    for spec in EXPECTED_ARCHIVES:
        display_name = nexus_display_name(spec)
        row = vt_rows[spec.name]
        name_path = metadata_dir / f"{spec.nexus_output}.name"
        name_path.write_text(f"{display_name}\n", encoding="utf-8")

        path = metadata_dir / f"{spec.nexus_output}.bbcode"
        with path.open("w", encoding="utf-8") as handle:
            handle.write("[b]Install[/b]\n")
            handle.write("Pick [code]sandboxed/[/code] or [code]unsandboxed/[/code], then copy the contents of that variant's:\n\n")
            handle.write(f"[code]{INSTALL_DIR}/[/code]\n\n")
            handle.write("into your OpenMW install folder.\n\n")
            handle.write("Use [code]sandboxed/[/code] unless you were directed here by a mod that requires the unsandboxed build.\n\n")
            handle.write("[b]Provenance and verification[/b]\n")
            handle.write(f"Changelog/provenance: generated from {bbcode_url(github_run, 'this workflow run')} and the source commit below\n")
            handle.write(f"Workflow run: {bbcode_url(github_run, 'GitHub Actions')}\n")
            handle.write(f"Source commit: {bbcode_url(github_commit, target_sha)}\n")
            handle.write(f"Archive filename: [code]{nexus_archive_name(spec)}[/code]\n")
            handle.write(f"SHA256: [code]{hashes[spec.name]}[/code]\n")
            handle.write(f"VirusTotal: {bbcode_url(row['analysis_url'], 'analysis report')}\n")


def append_step_summary(path: Path, vt_rows: dict[str, dict[str, str]], hashes: dict[str, str]) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write("### Release archive verification\n\n")
        handle.write("| Archive | SHA256 | VirusTotal analysis |\n")
        handle.write("| --- | --- | --- |\n")
        for spec in EXPECTED_ARCHIVES:
            row = vt_rows[spec.name]
            handle.write(f"| `{spec.name}` | `{hashes[spec.name]}` | [{row['analysis_id']}]({row['analysis_url']}) |\n")
        handle.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-dir", required=True, type=Path)
    parser.add_argument("--vt-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--release-name", required=True)
    parser.add_argument("--release-is-tag", action="store_true")
    parser.add_argument("--repository", required=True)
    parser.add_argument("--workflow-run-id", required=True)
    parser.add_argument("--target-sha", required=True)
    parser.add_argument("--ref-name", required=True)
    parser.add_argument("--nexus-metadata-dir", type=Path)
    parser.add_argument("--nexus-description-dir", type=Path, help=argparse.SUPPRESS)
    parser.add_argument(
        "--skip-github-release-assets",
        action="store_true",
        help="Skip GitHub release notes and changelog assets; archive, hash, VirusTotal, and Nexus metadata validation still run.",
    )
    args = parser.parse_args()

    archive_dir = args.archive_dir.resolve()
    vt_dir = args.vt_dir.resolve()
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    archives = require_exact_archives(archive_dir)
    for spec in EXPECTED_ARCHIVES:
        validate_archive_layout(archives[spec.name], spec)
    vt_rows = read_vt_rows(vt_dir)
    hashes = verify_hashes(archives, vt_rows)

    write_sha256sums(output_dir, hashes)
    write_vt_aggregate(output_dir, vt_rows)
    if not args.skip_github_release_assets:
        write_changelog(
            output_dir,
            release_name=args.release_name,
            release_is_tag=args.release_is_tag,
            repository=args.repository,
            workflow_run_id=args.workflow_run_id,
            target_sha=args.target_sha,
            ref_name=args.ref_name,
            hashes=hashes,
            vt_rows=vt_rows,
        )
        write_release_notes(
            output_dir,
            release_name=args.release_name,
            release_is_tag=args.release_is_tag,
            repository=args.repository,
            workflow_run_id=args.workflow_run_id,
            target_sha=args.target_sha,
            hashes=hashes,
            vt_rows=vt_rows,
        )

    nexus_metadata_dir = args.nexus_metadata_dir
    if args.nexus_description_dir is not None:
        if nexus_metadata_dir is not None and args.nexus_description_dir != nexus_metadata_dir:
            fail("--nexus-description-dir and --nexus-metadata-dir must not point to different directories")
        nexus_metadata_dir = args.nexus_description_dir

    if nexus_metadata_dir is not None:
        write_nexus_metadata(
            nexus_metadata_dir.resolve(),
            release_name=args.release_name,
            repository=args.repository,
            workflow_run_id=args.workflow_run_id,
            target_sha=args.target_sha,
            hashes=hashes,
            vt_rows=vt_rows,
        )

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY", "")
    if summary_path:
        append_step_summary(Path(summary_path), vt_rows, hashes)

    print(f"validated {len(EXPECTED_ARCHIVES)} archives and {len(vt_rows)} VirusTotal rows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
