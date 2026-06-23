#!/usr/bin/env python3
"""Package a LuaJIT CI build into the DreamWeave release artifact shape."""

import argparse
import json
import shutil
import sys
import zipfile
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, NoReturn


LINUX_SONAME_ALIASES = (
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


def package_windows(src_dir: Path, package_dir: Path) -> None:
    bin_dir = package_dir / "bin"
    lib_dir = package_dir / "lib"
    copy_required_file(src_dir / "luajit.exe", bin_dir)
    copy_required_file(src_dir / "lua51.dll", lib_dir)


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


def package_posix(src_dir: Path, package_dir: Path, *, os_name: str) -> None:
    bin_dir = package_dir / "bin"
    lib_dir = package_dir / "lib"

    shared_library = src_dir / "libluajit.so"

    if os_name == "macOS":
        package_macos(src_dir, package_dir)
    elif os_name == "Linux":
        for alias in LINUX_SONAME_ALIASES:
            copy_required_file_as(shared_library, lib_dir / alias)
    else:
        copy_required_file(shared_library, lib_dir)

    copy_required_file(src_dir / "luajit", bin_dir)



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
    bin_dir = variant_dir / "bin"
    jit_dir = variant_dir / "jit"
    lib_dir = variant_dir / "lib"

    if not jit_dir.is_dir():
        fail(f"packaged {variant_name}/jit directory is missing: {jit_dir}")
    if not sorted(jit_dir.glob("*.lua")):
        fail(f"packaged {variant_name}/jit directory has no Lua modules: {jit_dir}")
    if not (jit_dir / "vmdef.lua").is_file():
        fail(f"packaged {variant_name}/jit/vmdef.lua is missing: {jit_dir / 'vmdef.lua'}")
    jit_files = files_under(jit_dir)
    bad_jit_files = [name for name in jit_files if not name.endswith(".lua")]
    if bad_jit_files:
        fail(f"packaged {variant_name}/jit contains non-Lua files: {', '.join(bad_jit_files)}")
    if not lib_dir.is_dir():
        fail(f"packaged {variant_name}/lib directory is missing: {lib_dir}")

    expected_libraries = sorted(name.removeprefix("lib/") for name in packaged_runtime_libraries(os_name))
    actual_libraries = files_under(lib_dir)
    if actual_libraries != expected_libraries:
        fail(
            f"packaged {variant_name}/lib contains {actual_libraries!r}, "
            f"expected runtime libraries {expected_libraries!r}"
        )

    expected_executables = sorted(name.removeprefix("bin/") for name in packaged_runtime_executables(os_name))
    actual_executables = files_under(bin_dir)
    if actual_executables != expected_executables:
        fail(
            f"packaged {variant_name}/bin contains {actual_executables!r}, "
            f"expected runtime executables {expected_executables!r}"
        )


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

    allowed_root_files = {ARTIFACT_README, ARTIFACT_MANIFEST, "COPYRIGHT"}
    allowed_root_dirs = {*VARIANTS, "benchmarks"}
    for name in names:
        if name in allowed_root_files:
            continue
        root_name = name.split("/", 1)[0]
        if root_name in allowed_root_dirs:
            continue
        fail(f"archive contains unexpected top-level payload {name!r}: {archive_path}")

    for required_doc in (ARTIFACT_README, ARTIFACT_MANIFEST, "COPYRIGHT"):
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
        bin_prefix = f"{variant_prefix}bin/"
        jit_prefix = f"{variant_prefix}jit/"
        lib_prefix = f"{variant_prefix}lib/"
        expected_variant_dirs = {"bin", "jit", "lib"}

        if not any(name.startswith(variant_prefix) for name in names):
            fail(f"archive {variant_name}/ directory is missing: {archive_path}")
        for name in names:
            if not name.startswith(variant_prefix) or name == variant_prefix:
                continue
            remainder = name.removeprefix(variant_prefix)
            child = remainder.split("/", 1)[0]
            if child not in expected_variant_dirs:
                fail(f"archive contains unexpected {variant_name}/ payload {remainder!r}: {archive_path}")
        if not any(name.startswith(jit_prefix) for name in names):
            fail(f"archive {variant_name}/jit/ directory is missing: {archive_path}")
        if f"{jit_prefix}vmdef.lua" not in names:
            fail(f"archive {variant_name}/jit/vmdef.lua is missing: {archive_path}")
        if not any(name.startswith(lib_prefix) for name in names):
            fail(f"archive {variant_name}/lib/ directory is missing: {archive_path}")
        for name in names:
            if name.startswith(jit_prefix) and not name.endswith("/") and not name.endswith(".lua"):
                fail(f"archive contains non-Lua JIT module {name}: {archive_path}")

        expected_libraries = sorted(name.removeprefix("lib/") for name in packaged_runtime_libraries(os_name))
        actual_libraries = sorted(
            name.removeprefix(lib_prefix)
            for name in names
            if name.startswith(lib_prefix) and not name.endswith("/")
        )
        if actual_libraries != expected_libraries:
            fail(
                f"archive {variant_name}/lib contains {actual_libraries!r}, "
                f"expected runtime libraries {expected_libraries!r}: {archive_path}"
            )

        expected_executables = sorted(name.removeprefix("bin/") for name in packaged_runtime_executables(os_name))
        actual_executables = sorted(
            name.removeprefix(bin_prefix)
            for name in names
            if name.startswith(bin_prefix) and not name.endswith("/")
        )
        if actual_executables != expected_executables:
            fail(
                f"archive {variant_name}/bin contains {actual_executables!r}, "
                f"expected runtime executables {expected_executables!r}: {archive_path}"
            )

        for name in packaged_runtime_libraries(os_name) + packaged_runtime_executables(os_name):
            archive_member = f"{variant_prefix}{name}"
            if archive_member not in names:
                fail(f"archive required file is missing: {archive_member} in {archive_path}")

        variant_manifest = manifest_variants.get(variant_name)
        if not isinstance(variant_manifest, dict):
            fail(f"archive manifest is missing variant {variant_name!r}: {archive_path}")
        expected_library_files = sorted(packaged_runtime_libraries(os_name))
        expected_executable_files = sorted(packaged_runtime_executables(os_name))
        if sorted(variant_manifest.get("library_files", [])) != expected_library_files:
            fail(f"archive manifest library_files is wrong for {variant_name}: {archive_path}")
        if sorted(variant_manifest.get("runtime_executable_files", [])) != expected_executable_files:
            fail(f"archive manifest runtime_executable_files is wrong for {variant_name}: {archive_path}")
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


def packaged_runtime_libraries(os_name: str) -> List[str]:
    key = platform_key(os_name)
    if key == "windows":
        return ["lib/lua51.dll"]
    if key == "linux":
        return ["lib/libluajit-5.1.so.2"]
    if key == "macos":
        return [f"lib/{name}" for name in MACOS_DYLIBS]
    if key in {"android", "portmaster"}:
        return ["lib/libluajit.so"]
    return []


def packaged_runtime_executables(os_name: str) -> List[str]:
    key = platform_key(os_name)
    if key == "windows":
        return ["bin/luajit.exe"]
    if key in {"linux", "macos", "portmaster"}:
        return ["bin/luajit"]
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
            "runtime_executable_files": [f"bin/{name}" for name in files_under(variant_dir / "bin")],
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
            "matching runtime files plus jit/ directory. Do not mix payloads between variants."
        ),
        "support_payload_policy": (
            "Published archives intentionally omit developer support payloads such as "
            "headers, import/static libraries, debug symbols, and copied upstream source docs."
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
    runtime_executables = ", ".join(
        f"`{executable}`" for executable in packaged_runtime_executables(os_name)
    )
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
        "`jit/` modules with its runtime files. If your packaging layout cannot preserve the "
        "root verbatim, copy at minimum that same variant's runtime payload plus "
        "its `jit/` directory. Do not mix payloads between variants.",
        "",
        "## Runtime files to copy",
        "",
        f"Runtime library from the selected variant: {primary or '`lib/` payload'}.",
        (
            f"Runtime executable/tool from the selected variant: {runtime_executables}."
            if runtime_executables
            else "This platform artifact does not include a standalone LuaJIT executable."
        ),
        "Developer support payloads are not part of the published archive; build from "
        "source if you need headers, import/static libraries, debug symbols, or upstream "
        "source documentation.",
        "",
        "Platform table:",
        "",
        "| Artifact | Runtime files | Example destination / loader contract |",
        "| --- | --- | --- |",
        "| Windows X64 | `lib/lua51.dll`, `bin/luajit.exe` | DLL in the application binary directory or another DLL search path; executable wherever you want the CLI tool. |",
        "| Linux X64 | `lib/libluajit-5.1.so.2`, `bin/luajit` | Library in a directory resolved by `rpath`, `runpath`, `ldconfig`, or `LD_LIBRARY_PATH`; executable wherever you want the CLI tool. |",
        f"| macOS ARM64/X64 | `lib/{MACOS_DYLIB_NAME}` "
        f"(install id `{MACOS_INSTALL_ID}`; also includes `lib/{MACOS_DYLIB_ALIAS}`), `bin/luajit` "
        "| App bundle `Contents/Frameworks` or equivalent, with rpath resolving "
        f"`{MACOS_INSTALL_ID}`. |",
        "| Android ARM64 | `lib/libluajit.so` | `app/src/main/jniLibs/arm64-v8a/libluajit.so` or equivalent native-lib ABI location. |",
        "| PortMaster ARM64 | `lib/libluajit.so`, `bin/luajit` | Place `libluajit.so` where the launcher/runtime `LD_LIBRARY_PATH` can find it; executable wherever you want the CLI tool. |",
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


def copy_common_payload(root: Path, package_dir: Path, *, variant_sources: Mapping[str, Path]) -> None:
    copy_required_file(root / "COPYRIGHT", package_dir)

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
