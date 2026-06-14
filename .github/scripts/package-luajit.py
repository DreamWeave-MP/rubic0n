#!/usr/bin/env python3
"""Package a LuaJIT CI build into the DreamWeave release artifact shape."""

import argparse
import json
import shutil
import sys
import zipfile
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, NoReturn


HEADERS = (
    "lauxlib.h",
    "lua.h",
    "lua.hpp",
    "luaconf.h",
    "luajit.h",
    "lualib.h",
)

DOC_FILES = (
    "COPYRIGHT",
    "README",
    "README.md",
)

LINUX_SONAME_ALIASES = (
    "libluajit-5.1.so",
    "libluajit-5.1.so.2",
)

MACOS_DYLIB_NAME = "libluajit-5.1.2.dylib"
MACOS_DYLIB_ALIAS = "libluajit-5.1.dylib"
MACOS_DYLIBS = (MACOS_DYLIB_NAME, MACOS_DYLIB_ALIAS)
MACOS_INSTALL_ID = f"@rpath/{MACOS_DYLIB_NAME}"

VARIANTS = ("sandboxed", "unsandboxed")

ARTIFACT_README = "README-LuaJIT-artifact.md"
ARTIFACT_MANIFEST = "manifest.json"
SHA256SUMS_ASSET = "SHA256SUMS.txt"
VT_SUBMISSIONS_ASSET = "virustotal-submissions.tsv"


def fail(message: str) -> NoReturn:
    raise SystemExit(f"package-luajit: {message}")


def copy_required_file(source: Path, destination_dir: Path) -> None:
    if not source.is_file():
        fail(f"required file is missing: {source}")
    destination_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination_dir / source.name)


def copy_required_file_as(source: Path, destination: Path) -> None:
    if not source.is_file():
        fail(f"required file is missing: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def copy_tree_if_present(source: Path, destination: Path) -> None:
    if not source.exists():
        return
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination)


def write_zip(package_dir: Path, archive_path: Path) -> None:
    if archive_path.exists():
        archive_path.unlink()

    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(package_dir.rglob("*")):
            archive_name = path.relative_to(package_dir).as_posix()
            if path.is_dir():
                archive.writestr(f"{archive_name}/", b"")
            else:
                archive.write(path, archive_name)


def copy_optional_files(sources: Iterable[Path], destination_dir: Path) -> None:
    destination_dir.mkdir(parents=True, exist_ok=True)
    for source in sources:
        if source.is_file():
            shutil.copy2(source, destination_dir / source.name)


def copy_optional_libraries(
    src_dir: Path, lib_dir: Path, patterns: Iterable[str], *, exclude: Iterable[Path] = ()
) -> None:
    excluded = {path.absolute() for path in exclude}
    copied = set()
    for pattern in patterns:
        for source in sorted(src_dir.glob(pattern)):
            absolute = source.absolute()
            if not source.is_file() or absolute in excluded or absolute in copied:
                continue
            copied.add(absolute)
            shutil.copy2(source, lib_dir / source.name)


def package_windows(src_dir: Path, package_dir: Path) -> None:
    bin_dir = package_dir / "bin"
    lib_dir = package_dir / "lib"
    copy_required_file(src_dir / "luajit.exe", bin_dir)
    copy_required_file(src_dir / "lua51.dll", lib_dir)
    copy_required_file(src_dir / "lua51.lib", lib_dir)
    copy_optional_files(sorted(src_dir.glob("*.pdb")), bin_dir)


def package_android(src_dir: Path, package_dir: Path) -> None:
    # Android wants a runtime payload, not an APK/application wrapper. The jit/
    # runtime modules are copied by the common packaging path below.
    copy_required_file(src_dir / "libluajit.so", package_dir / "lib")


def find_macos_dylib_source(src_dir: Path) -> Path:
    # src/Makefile builds libluajit.so even on Darwin, but gives it the dylib
    # install name. The top-level install target then installs dylib names. For
    # a zip artifact we do the install-style naming here instead of shipping a
    # Darwin dynamic library pretending to be an ELF .so. Delightful, obviously.
    candidates = [
        src_dir / MACOS_DYLIB_NAME,
        src_dir / "libluajit.so",
        *sorted(src_dir.glob("libluajit*.dylib")),
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    fail(f"required macOS shared library is missing in {src_dir}")


def package_macos(src_dir: Path, package_dir: Path) -> None:
    lib_dir = package_dir / "lib"
    source = find_macos_dylib_source(src_dir)

    for dylib_name in MACOS_DYLIBS:
        copy_required_file_as(source, lib_dir / dylib_name)

    for dylib in sorted(src_dir.glob("libluajit*.dylib")):
        if dylib.name not in MACOS_DYLIBS:
            copy_required_file(dylib, lib_dir)


def package_posix(src_dir: Path, package_dir: Path, *, os_name: str) -> None:
    bin_dir = package_dir / "bin"
    lib_dir = package_dir / "lib"

    shared_library = src_dir / "libluajit.so"

    if os_name == "macOS":
        package_macos(src_dir, package_dir)
    else:
        copy_required_file(shared_library, lib_dir)
        copy_optional_libraries(
            src_dir, lib_dir, ("libluajit*.so*",), exclude=(shared_library,)
        )

    if os_name == "Linux":
        for alias in LINUX_SONAME_ALIASES:
            copy_required_file_as(shared_library, lib_dir / alias)

    copy_required_file(src_dir / "luajit", bin_dir)
    copy_required_file(src_dir / "libluajit.a", lib_dir)


def package_jit_modules(src_dir: Path, package_dir: Path) -> None:
    jit_dir = package_dir / "jit"
    jit_scripts = sorted((src_dir / "jit").glob("*.lua"))
    if not jit_scripts:
        fail(f"no JIT Lua scripts found in {src_dir / 'jit'}")
    if not (src_dir / "jit" / "vmdef.lua").is_file():
        fail(
            f"required generated JIT script is missing: "
            f"{src_dir / 'jit' / 'vmdef.lua'}"
        )
    copy_optional_files(jit_scripts, jit_dir)


def validate_variant_package_layout(
    variant_dir: Path, *, os_name: str, variant_name: str
) -> None:
    jit_dir = variant_dir / "jit"
    lib_dir = variant_dir / "lib"

    if not jit_dir.is_dir():
        fail(f"packaged {variant_name}/jit directory is missing: {jit_dir}")
    if not sorted(jit_dir.glob("*.lua")):
        fail(f"packaged {variant_name}/jit directory has no Lua modules: {jit_dir}")
    if not (jit_dir / "vmdef.lua").is_file():
        fail(f"packaged {variant_name}/jit/vmdef.lua is missing: {jit_dir / 'vmdef.lua'}")
    if not lib_dir.is_dir():
        fail(f"packaged {variant_name}/lib directory is missing: {lib_dir}")

    if os_name == "Linux":
        required = (lib_dir / "libluajit-5.1.so.2",)
    elif os_name in {"Android", "PortMaster", "Portmaster"}:
        required = (lib_dir / "libluajit.so",)
    elif os_name == "Windows":
        required = (lib_dir / "lua51.dll", lib_dir / "lua51.lib")
    elif os_name == "macOS":
        required = tuple(lib_dir / dylib for dylib in MACOS_DYLIBS)
    else:
        required = ()

    for path in required:
        if not path.is_file():
            fail(f"required packaged file is missing: {path}")


def validate_archive_layout(archive_path: Path, *, os_name: str, benchmarks_included: bool) -> None:
    with zipfile.ZipFile(archive_path) as archive:
        names = set(archive.namelist())
        if ARTIFACT_MANIFEST in names:
            manifest = json.loads(archive.read(ARTIFACT_MANIFEST).decode("utf-8"))
        else:
            manifest = None

    nested_prefix = f"{archive_path.stem}/"
    if any(name.startswith(nested_prefix) for name in names):
        fail(
            f"archive contains a nested {archive_path.stem}/ directory; "
            "expected sandboxed/ and unsandboxed/ at artifact root"
        )

    for required_doc in (ARTIFACT_README, ARTIFACT_MANIFEST):
        if required_doc not in names:
            fail(f"archive artifact metadata file is missing: {required_doc} in {archive_path}")

    if not isinstance(manifest, dict):
        fail(f"archive manifest is not a JSON object: {archive_path}")
    if manifest.get("os_name") != os_name:
        fail(
            f"archive manifest os_name mismatch: {manifest.get('os_name')!r}, "
            f"expected {os_name!r}"
        )
    if manifest.get("benchmarks_included") is not benchmarks_included:
        fail(f"archive manifest benchmark inclusion state is wrong: {archive_path}")
    has_benchmarks = any(name.startswith("benchmarks/") for name in names)
    if has_benchmarks is not benchmarks_included:
        fail(f"archive benchmark payload presence is wrong: {archive_path}")
    if manifest.get("gcstats_enabled") is not False:
        fail(f"archive manifest must say GCStats is disabled: {archive_path}")
    if not manifest.get("package_path_root"):
        fail(f"archive manifest package_path_root field is missing: {archive_path}")
    security = manifest.get("security")
    if not isinstance(security, dict):
        fail(f"archive manifest security field is missing or invalid: {archive_path}")
    if not isinstance(security.get("virustotal"), dict):
        fail(f"archive manifest security.virustotal field is missing or invalid: {archive_path}")
    if security.get("sha256sums_asset") != SHA256SUMS_ASSET:
        fail(f"archive manifest security.sha256sums_asset field is wrong: {archive_path}")
    if not security.get("nexusmods_note"):
        fail(f"archive manifest security.nexusmods_note field is missing: {archive_path}")
    manifest_variants = manifest.get("variants")
    if not isinstance(manifest_variants, dict):
        fail(f"archive manifest variants field is missing or invalid: {archive_path}")

    for variant_name in VARIANTS:
        variant_prefix = f"{variant_name}/"
        jit_prefix = f"{variant_prefix}jit/"
        lib_prefix = f"{variant_prefix}lib/"

        if not any(name.startswith(variant_prefix) for name in names):
            fail(f"archive {variant_name}/ directory is missing: {archive_path}")
        if not any(name.startswith(jit_prefix) for name in names):
            fail(f"archive {variant_name}/jit/ directory is missing: {archive_path}")
        if f"{jit_prefix}vmdef.lua" not in names:
            fail(f"archive {variant_name}/jit/vmdef.lua is missing: {archive_path}")
        if not any(name.startswith(lib_prefix) for name in names):
            fail(f"archive {variant_name}/lib/ directory is missing: {archive_path}")

        if os_name == "Linux":
            required_names = (f"{lib_prefix}libluajit-5.1.so.2",)
        elif os_name in {"Android", "PortMaster", "Portmaster"}:
            required_names = (f"{lib_prefix}libluajit.so",)
        elif os_name == "Windows":
            required_names = (f"{lib_prefix}lua51.dll", f"{lib_prefix}lua51.lib")
        elif os_name == "macOS":
            required_names = tuple(f"{lib_prefix}{dylib}" for dylib in MACOS_DYLIBS)
        else:
            required_names = ()

        for name in required_names:
            if name not in names:
                fail(f"archive required file is missing: {name} in {archive_path}")

        variant_manifest = manifest_variants.get(variant_name)
        if not isinstance(variant_manifest, dict):
            fail(f"archive manifest is missing variant {variant_name!r}: {archive_path}")
        expected_bypass = variant_name == "unsandboxed"
        if variant_manifest.get("sandbox_bypass_enabled") is not expected_bypass:
            fail(
                f"archive manifest sandbox bypass state is wrong for {variant_name}: "
                f"{archive_path}"
            )


def files_under(directory: Path) -> List[str]:
    if not directory.is_dir():
        return []
    return sorted(path.relative_to(directory).as_posix() for path in directory.rglob("*") if path.is_file())


def platform_key(os_name: str) -> str:
    if os_name == "macOS":
        return "macos"
    if os_name.lower() == "portmaster":
        return "portmaster"
    return os_name.lower()


def primary_runtime_libraries(os_name: str) -> List[str]:
    key = platform_key(os_name)
    if key == "windows":
        return ["lib/lua51.dll"]
    if key == "linux":
        return ["lib/libluajit-5.1.so.2"]
    if key == "macos":
        return [f"lib/{MACOS_DYLIB_NAME}"]
    if key in {"android", "portmaster"}:
        return ["lib/libluajit.so"]
    return []


def platform_description(os_name: str, arch: str) -> str:
    key = platform_key(os_name)
    if key == "android":
        return "Android ARM64 / AArch64 raw shared-library payload; this is not an APK."
    if key == "portmaster":
        return "PortMaster AArch64/arm64 Linux payload; this is not Android and not ARMv7/armhf."
    return f"{os_name} {arch}"


def platform_notes(os_name: str, *, benchmarks_included: bool) -> List[str]:
    key = platform_key(os_name)
    notes = [
        "No GCStats telemetry build is included.",
        (
            "Desktop CI benchmark payload is included under benchmarks/. Timings from "
            "hosted CI runners are noisy and not authoritative."
            if benchmarks_included
            else "Benchmarks are desktop-only and are omitted for cross-target artifacts."
        ),
        "Development releases are moving/mutable; tag releases are stable snapshots.",
        (
            "Release CI submits the exact GitHub release zip archives to VirusTotal "
            "and waits for analysis completion before uploading them."
        ),
        (
            "NexusMods may run its own scanner/cache; compare SHA256 values against the "
            "GitHub release assets."
        ),
    ]
    if key == "android":
        notes.append("Android is a raw ARM64 libluajit.so payload, not an APK.")
    elif key == "portmaster":
        notes.append("PortMaster is AArch64/arm64 Linux, not Android and not ARMv7/armhf.")
    elif key == "macos":
        notes.append(
            f"macOS packages the deployable dylib as lib/{MACOS_DYLIB_NAME}; "
            f"its install id is {MACOS_INSTALL_ID}. The CI build validates this "
            "with otool when available."
        )
    return notes


def make_manifest(
    package_dir: Path, *, binary_name: str, os_name: str, arch: str, benchmarks_included: bool
) -> dict:
    key = platform_key(os_name)
    variants = {}
    for variant_name in VARIANTS:
        variant_dir = package_dir / variant_name
        bypass_enabled = variant_name == "unsandboxed"
        variants[variant_name] = {
            "root": f"{variant_name}/",
            "package_path_root": f"{variant_name}/",
            "sandbox_bypass_enabled": bypass_enabled,
            "trusted_engine_dev_only": bypass_enabled,
            "warning": (
                "DANGEROUS: exposes select(\"sandbox.bypass\"); use only in trusted "
                "engine/development contexts."
                if bypass_enabled
                else "Default build; select(\"sandbox.bypass\") is unavailable."
            ),
            "library_files": [f"lib/{name}" for name in files_under(variant_dir / "lib")],
            "jit_module_files": [f"jit/{name}" for name in files_under(variant_dir / "jit")],
        }

    manifest = {
        "schema_version": 1,
        "binary_name": binary_name,
        "os_name": os_name,
        "arch": arch,
        "platform": key,
        "platform_description": platform_description(os_name, arch),
        "artifact_layout": "sandboxed/ and unsandboxed/ variant roots at zip root",
        "package_path_root": (
            "Use exactly one selected variant root (sandboxed/ or unsandboxed/) as the "
            "package.path root, or an equivalent parent directory containing jit/. Do "
            "not use the jit/ directory itself as the root."
        ),
        "copy_policy": (
            "Copy exactly one selected variant root, or at minimum that same variant's "
            "matching lib/ payload plus jit/ directory. Do not mix payloads between variants."
        ),
        "primary_runtime_libraries": primary_runtime_libraries(os_name),
        "jit_module_path_requirement": (
            "Add the selected variant root itself to package.path (or the embedding "
            "equivalent) so jit/*.lua resolves; do not add only the jit/ directory."
        ),
        "security": {
            "virustotal": {
                "release_archive_policy": (
                    "CI submits the exact GitHub release zip archives to VirusTotal before "
                    "uploading them as release assets."
                ),
                "analysis_completion_policy": (
                    "CI waits for VirusTotal analysis completion and fails the release job "
                    "if the verdict exceeds the configured malicious/suspicious thresholds."
                ),
                "development_mutability": (
                    "Development release assets are mutable; SHA256 values and VirusTotal "
                    "analysis links change per publishing run."
                ),
            },
            "sha256sums_asset": SHA256SUMS_ASSET,
            "virustotal_submissions_asset": VT_SUBMISSIONS_ASSET,
            "nexusmods_note": (
                "NexusMods may run its own scanner/cache; compare SHA256 values with the "
                "GitHub release assets."
            ),
        },
        "gcstats_enabled": False,
        "benchmarks_included": benchmarks_included,
        "benchmark_files": [f"benchmarks/{name}" for name in files_under(package_dir / "benchmarks")],
        "benchmark_policy": (
            "Desktop-only comparison of this fork's sandboxed build against upstream LuaJIT; "
            "CI-hosted runner timings are noisy and not authoritative."
            if benchmarks_included
            else "Benchmarks are run only for desktop CI jobs and omitted for cross-target artifacts."
        ),
        "development_release_policy": "development is moving/mutable and may be replaced by CI",
        "tag_release_policy": "tag releases are stable snapshots and existing assets are not overwritten",
        "notes": platform_notes(os_name, benchmarks_included=benchmarks_included),
        "variants": variants,
    }
    if key == "macos":
        manifest["macos_install_id"] = MACOS_INSTALL_ID
    return manifest


def write_manifest(
    package_dir: Path, *, binary_name: str, os_name: str, arch: str, benchmarks_included: bool
) -> None:
    manifest = make_manifest(
        package_dir,
        binary_name=binary_name,
        os_name=os_name,
        arch=arch,
        benchmarks_included=benchmarks_included,
    )
    with (package_dir / ARTIFACT_MANIFEST).open("w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")


def write_artifact_readme(
    package_dir: Path, *, binary_name: str, os_name: str, arch: str, benchmarks_included: bool
) -> None:
    primary = ", ".join(f"`{library}`" for library in primary_runtime_libraries(os_name))
    lines = [
        f"# {binary_name} {os_name} {arch} artifact",
        "",
        f"Platform/arch: {platform_description(os_name, arch)}",
        "",
        "## Variants",
        "",
        "- `sandboxed/`: default build. It does **not** define "
        "`LUAJIT_ENABLE_SANDBOX_BYPASS`; `select(\"sandbox.bypass\")` is unavailable.",
        "- `unsandboxed/`: **DANGEROUS, TRUSTED ENGINE/DEV USE ONLY**. It is built "
        "with `LUAJIT_ENABLE_SANDBOX_BYPASS` and exposes "
        "`select(\"sandbox.bypass\")`, which is a deliberate sandbox escape hatch.",
        "",
        "Choose exactly one variant root (`sandboxed/` or `unsandboxed/`) and keep its "
        "`jit/` modules with its library. If your packaging layout cannot preserve the "
        "root verbatim, copy at minimum that same variant's matching `lib/` payload plus "
        "its `jit/` directory. Do not mix payloads between variants.",
        "",
        "## Library to copy",
        "",
        f"For this artifact, copy from the selected variant: {primary or '`lib/` payload'}.",
        "",
        "Platform table:",
        "",
        "| Artifact | Runtime library to copy | Example destination / loader contract |",
        "| --- | --- | --- |",
        "| Windows X64 | `lib/lua51.dll` (`lib/lua51.lib` is the import library) | Application binary directory or another DLL search path. |",
        "| Linux X64 | `lib/libluajit-5.1.so.2` | A directory resolved by `rpath`, `runpath`, `ldconfig`, or `LD_LIBRARY_PATH`. |",
        f"| macOS ARM64/X64 | `lib/{MACOS_DYLIB_NAME}` "
        f"(install id `{MACOS_INSTALL_ID}`; also includes `lib/{MACOS_DYLIB_ALIAS}`) "
        "| App bundle `Contents/Frameworks` or equivalent, with rpath resolving "
        f"`{MACOS_INSTALL_ID}`. |",
        "| Android ARM64 | `lib/libluajit.so` | `app/src/main/jniLibs/arm64-v8a/libluajit.so` or equivalent native-lib ABI location. |",
        "| PortMaster ARM64 | `lib/libluajit.so` | Place `libluajit.so` where the launcher/runtime `LD_LIBRARY_PATH` can find it. |",
        "",
        "## JIT module path",
        "",
        "Consumers need the selected variant root on `package.path` (or an equivalent "
        "parent directory of `jit/` in the embedding), not the `jit/` directory itself. "
        "For example, use `/path/to/sandboxed/?.lua`; using "
        "`/path/to/sandboxed/jit/?.lua` makes `require(\"jit.vmdef\")` look in "
        "the wrong place.",
        "",
        "## Platform notes",
        "",
        "- Android is a raw ARM64 `.so` payload. It is not an APK.",
        "- PortMaster is AArch64/arm64 Linux. It is not Android and not ARMv7/armhf.",
        f"- macOS dylibs use install id `{MACOS_INSTALL_ID}`.",
        "- No GCStats telemetry build is included.",
        (
            "- Desktop benchmark payload is included under `benchmarks/`. It compares the "
            "sandboxed build against upstream LuaJIT only. CI-hosted runner timings are noisy "
            "and not authoritative."
            if benchmarks_included
            else "- Benchmarks are desktop-only and omitted for Android/PortMaster cross-target artifacts."
        ),
        "- The `development` release is moving/mutable. Tag releases are stable snapshots.",
        "",
        "## Security / VirusTotal / NexusMods",
        "",
        "- Release CI submits the exact GitHub release zip archives to VirusTotal before "
        "uploading them as release assets.",
        "- Release CI waits for VirusTotal analysis completion and fails if the verdict "
        "exceeds the configured malicious/suspicious thresholds.",
        f"- Check the release notes or `{VT_SUBMISSIONS_ASSET}` release asset for "
        "analysis links.",
        f"- `{SHA256SUMS_ASSET}` contains SHA256 hashes for the six release zips. The "
        "`development` release assets are mutable, so hashes and VirusTotal links change per run.",
        "- NexusMods may run its own scanner/cache; compare SHA256 values with the GitHub "
        "release assets if you fetch the files from there.",
        "",
        f"See `{ARTIFACT_MANIFEST}` for the same contract in machine-readable form.",
        "",
    ]
    (package_dir / ARTIFACT_README).write_text("\n".join(lines), encoding="utf-8")


def resolve_variant_sources(root: Path, entries: Iterable[str]) -> Dict[str, Path]:
    variant_sources: Dict[str, Path] = {}

    for entry in entries:
        if "=" not in entry:
            fail(f"--variant-src must be VARIANT=PATH, got: {entry}")
        variant_name, source = entry.split("=", 1)
        if variant_name not in VARIANTS:
            fail(
                f"unknown variant {variant_name!r}; expected one of: "
                f"{', '.join(VARIANTS)}"
            )
        if variant_name in variant_sources:
            fail(f"duplicate source for variant {variant_name!r}")

        source_path = Path(source)
        if not source_path.is_absolute():
            source_path = root / source_path
        variant_sources[variant_name] = source_path.resolve()

    missing = [variant_name for variant_name in VARIANTS if variant_name not in variant_sources]
    if missing:
        fail(f"missing --variant-src for: {', '.join(missing)}")

    for variant_name, source_path in variant_sources.items():
        if not source_path.is_dir():
            fail(f"source directory for {variant_name} is missing: {source_path}")

    return variant_sources


def package_variant(src_dir: Path, variant_dir: Path, *, os_name: str) -> None:
    if os_name == "Windows":
        package_windows(src_dir, variant_dir)
    elif os_name == "Android":
        package_android(src_dir, variant_dir)
    else:
        package_posix(src_dir, variant_dir, os_name=os_name)

    package_jit_modules(src_dir, variant_dir)
    validate_variant_package_layout(variant_dir, os_name=os_name, variant_name=variant_dir.name)


def copy_common_payload(
    root: Path, package_dir: Path, *, source_dir: Path, variant_sources: Mapping[str, Path]
) -> None:
    include_dir = package_dir / "include"

    for header in HEADERS:
        copy_required_file(source_dir / header, include_dir)

    for doc_file in DOC_FILES:
        source = root / doc_file
        if source.exists():
            copy_required_file(source, package_dir)

    if not (package_dir / "COPYRIGHT").is_file():
        fail("COPYRIGHT was not packaged")

    copy_tree_if_present(root / "doc", package_dir / "doc")

    for variant_name in VARIANTS:
        if variant_name not in variant_sources:
            fail(f"internal error: missing source for {variant_name}")


def copy_benchmarks_payload(source: Path, package_dir: Path) -> bool:
    if not source.is_dir():
        fail(f"benchmark payload directory is missing: {source}")
    destination = package_dir / "benchmarks"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination)
    if not files_under(destination):
        fail(f"benchmark payload directory is empty: {source}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary-name", default="LuaJIT")
    parser.add_argument("--os-name", required=True)
    parser.add_argument("--arch", required=True)
    parser.add_argument("--root", default=".")
    parser.add_argument(
        "--variant-src",
        action="append",
        required=True,
        metavar="VARIANT=PATH",
        help="build output root for a variant; required for sandboxed and unsandboxed",
    )
    parser.add_argument("--output-dir", default="release-artifact")
    parser.add_argument(
        "--benchmarks-dir",
        default="",
        help="optional desktop benchmark payload to copy to benchmarks/ at artifact root",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    variant_sources = resolve_variant_sources(root, args.variant_src)
    output_dir = (root / args.output_dir).resolve()
    archive_stem = f"{args.binary_name}-{args.os_name}-{args.arch}"

    package_parent = root / "dist"
    package_dir = package_parent / archive_stem
    if package_dir.exists():
        shutil.rmtree(package_dir)

    package_dir.mkdir(parents=True, exist_ok=True)

    for variant_name in VARIANTS:
        package_variant(
            variant_sources[variant_name],
            package_dir / variant_name,
            os_name=args.os_name,
        )

    copy_common_payload(
        root,
        package_dir,
        source_dir=variant_sources["sandboxed"],
        variant_sources=variant_sources,
    )
    benchmarks_included = False
    if args.benchmarks_dir:
        benchmarks_dir = Path(args.benchmarks_dir)
        if not benchmarks_dir.is_absolute():
            benchmarks_dir = root / benchmarks_dir
        benchmarks_included = copy_benchmarks_payload(benchmarks_dir.resolve(), package_dir)
    write_artifact_readme(
        package_dir,
        binary_name=args.binary_name,
        os_name=args.os_name,
        arch=args.arch,
        benchmarks_included=benchmarks_included,
    )
    write_manifest(
        package_dir,
        binary_name=args.binary_name,
        os_name=args.os_name,
        arch=args.arch,
        benchmarks_included=benchmarks_included,
    )

    output_dir.mkdir(parents=True, exist_ok=True)
    archive_path = output_dir / f"{archive_stem}.zip"
    write_zip(package_dir, archive_path)
    validate_archive_layout(archive_path, os_name=args.os_name, benchmarks_included=benchmarks_included)
    print(archive_path.relative_to(root).as_posix())
    return 0


if __name__ == "__main__":
    sys.exit(main())
