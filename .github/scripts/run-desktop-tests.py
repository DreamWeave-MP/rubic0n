#!/usr/bin/env python3
"""Run CI-realistic desktop LuaJIT smoke tests for one built variant.

The optional Perl subset is intentionally tied to the repository build at
``<root>/src/luajit``. Those tests invoke that path themselves, so accepting an
arbitrary staged ``--luajit`` there would be a lie with a command-line flag.
"""

import argparse
import os
import platform
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple


LUA_TESTS: Tuple[Tuple[str, str], ...] = (
    (
        "core-language",
        r"""
local sum = 0
for i = 1, 100000 do sum = sum + i end
assert(sum == 5000050000, sum)
local t = {a = 1}
for i = 1, 1000 do t[i] = i end
assert(t.a == 1 and t[1000] == 1000)
print('ok core-language')
""",
    ),
    (
        "jit-table-loop",
        r"""
jit.opt.start('hotloop=1')
local t = {}
for i = 1, 20000 do t[i] = i end
local sum = 0
for r = 1, 20 do
  for i = 1, #t do sum = sum + t[i] end
end
assert(sum == 4000200000, sum)
print('ok jit-table-loop')
""",
    ),
    (
        "ffi-smoke",
        r"""
local ffi = require('ffi')
local a = ffi.new('uint32_t[4]', {1, 2, 3, 4})
local sum = 0
for i = 0, 3 do sum = sum + tonumber(a[i]) end
assert(sum == 10, sum)
print('ok ffi-smoke')
""",
    ),
)


COMMON_PERL_SUBSET_TESTS: Tuple[str, ...] = (
    "t/sandbox-bypass.t",
    "t/math-table-extensions.t",
    "t/math-color.t",
    "t/math-geometry.t",
    "t/math-geometry-noffi.t",
    "t/finalizers.t",
    "t/weak-finalizer-torture.t",
    "t/gc-stepsize.t",
)

# t/weak-finalizer-torture.t keeps generic weak-table coverage runnable on both
# Linux and Darwin, but quarantines Lua-closure/upvalue finalizer torture cases
# that are outside Rubic0n's mandatory native/nonresurrecting finalizer contract.
LINUX_PERL_SUBSET_TESTS: Tuple[str, ...] = COMMON_PERL_SUBSET_TESTS
DARWIN_PERL_SUBSET_TESTS: Tuple[str, ...] = COMMON_PERL_SUBSET_TESTS

# Windows CI does not request --perl-subset; keep that behavior explicit rather
# than growing a second Perl gate by accident.
WINDOWS_PERL_SUBSET_TESTS: Tuple[str, ...] = ()


def run(command: List[str], *, env: Optional[Dict[str, str]] = None) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, check=True, env=env)


def lua_eval(luajit: Path, code: str, *, env: Optional[Dict[str, str]] = None) -> None:
    run([str(luajit), "-e", code], env=env)


def run_lua_smokes(luajit: Path, *, expect_bypass: bool) -> None:
    lua_eval(luajit, "assert(jit and jit.version_num >= 20100); assert(jit.gcstats == nil); print(jit.version, jit.os, jit.arch)")
    if expect_bypass:
        lua_eval(luajit, "local b = select('sandbox.bypass'); assert(type(b) == 'table'); assert(type(b.require) == 'function')")
    else:
        lua_eval(luajit, "local ok = pcall(select, 'sandbox.bypass'); assert(not ok)")
    for name, code in LUA_TESTS:
        print(f"running Lua smoke: {name}", flush=True)
        lua_eval(luajit, code)


def expected_repo_luajit(root: Path) -> Path:
    executable = "luajit.exe" if sys.platform == "win32" else "luajit"
    return (root / "src" / executable).resolve()


def normalize_system_name(system_name: str) -> str:
    value = system_name.strip()
    if not value:
        value = platform.system()

    lowered = value.lower()
    if lowered in {"darwin", "mac", "macos", "mac os", "mac os x", "osx"}:
        return "Darwin"
    if lowered in {"linux", "linux2"}:
        return "Linux"
    if lowered in {"windows", "win32", "cygwin", "msys"}:
        return "Windows"
    return value


def resolve_system_name(override: str) -> str:
    return normalize_system_name(override or platform.system())


def perl_subset_tests_for_platform(system_name: str) -> Tuple[str, ...]:
    if system_name == "Linux":
        return LINUX_PERL_SUBSET_TESTS
    if system_name == "Darwin":
        return DARWIN_PERL_SUBSET_TESTS
    if system_name == "Windows":
        return WINDOWS_PERL_SUBSET_TESTS
    return COMMON_PERL_SUBSET_TESTS


def describe_perl_subset(root: Path, system_name: str, tests: Tuple[str, ...]) -> List[str]:
    print(f"Perl focused subset platform: {system_name}", flush=True)
    if not tests:
        print(f"Perl focused subset is not configured for {system_name}; skipped", flush=True)
        return []

    existing = []
    missing = []
    print("Perl focused subset selected tests:", flush=True)
    for test in tests:
        if (root / test).is_file():
            existing.append(test)
            status = "present"
        else:
            missing.append(test)
            status = "missing"
        print(f"  {test} ({status})", flush=True)

    if missing:
        print(f"Perl focused subset missing tests: {', '.join(missing)}", flush=True)
    return existing


def run_perl_subset(root: Path, luajit: Path, variant: str, system_name: str) -> None:
    expected_luajit = expected_repo_luajit(root)
    if luajit != expected_luajit:
        raise SystemExit(
            "--perl-subset runs tests against the repository LuaJIT at "
            f"{expected_luajit}, not arbitrary --luajit {luajit}"
        )

    tests = perl_subset_tests_for_platform(system_name)
    existing = describe_perl_subset(root, system_name, tests)
    if not existing:
        return

    prove = shutil_which("prove")
    if prove is None:
        print("prove is unavailable; Perl focused subset skipped", flush=True)
        return
    env = os.environ.copy()
    if variant == "unsandboxed":
        env["LUAJIT_TEST_SANDBOX_BYPASS"] = "1"
    else:
        env.pop("LUAJIT_TEST_SANDBOX_BYPASS", None)
    run([prove, "-I.", *existing], env=env)


def shutil_which(name: str) -> Optional[str]:
    from shutil import which

    return which(name)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--luajit", type=Path)
    parser.add_argument("--variant", choices=("sandboxed", "unsandboxed"))
    parser.add_argument("--root", default=".", type=Path)
    parser.add_argument("--perl-subset", action="store_true")
    parser.add_argument(
        "--test-platform",
        default="",
        help="override platform selection for the focused Perl subset (e.g. Linux, macOS, Darwin, Windows)",
    )
    parser.add_argument(
        "--list-tests",
        action="store_true",
        help="print the focused Perl subset selected for --test-platform and exit",
    )
    args = parser.parse_args()

    root = args.root.resolve()
    system_name = resolve_system_name(args.test_platform)

    if args.list_tests:
        describe_perl_subset(root, system_name, perl_subset_tests_for_platform(system_name))
        return 0

    if args.luajit is None:
        parser.error("--luajit is required unless --list-tests is used")
    if args.variant is None:
        parser.error("--variant is required unless --list-tests is used")

    luajit = args.luajit.resolve()
    if not luajit.is_file():
        raise SystemExit(f"LuaJIT executable is missing: {luajit}")

    run_lua_smokes(luajit, expect_bypass=args.variant == "unsandboxed")
    if args.perl_subset:
        run_perl_subset(root, luajit, args.variant, system_name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
