#!/bin/sh

# Conservative local validation matrix for GC-sensitive changes.
# Run from anywhere inside this checkout; builds and tests run at repo root.

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TESTS="t/gcstats.t t/gc-stepsize.t t/finalizers.t"
SWEEP_UDATA_STATS_TESTS="t/gcstats.t t/gc-stepsize.t t/sweep-udata-finalizers.t"
RESTORE=${GC_MATRIX_RESTORE:-1}
NEED_RESTORE=0

# Passing XCFLAGS on the make command line replaces src/Makefile's XCFLAGS
# assignments. This is intentional for selected matrix legs: the plain repo
# build scripts default-enable sweep-time userdata finalizer discovery, while
# explicit XCFLAGS legs may omit it to exercise stock userdata-finalizer behavior.
# Preserve the repo's documented Lua 5.2 compatibility flag when replacing
# XCFLAGS for those focused legs.
DEFAULT_XCFLAGS="-DLUAJIT_ENABLE_LUA52COMPAT"

info() {
  printf '\n==> %s\n' "$*"
}

run_make_clean_build() {
  desc=$1
  xcflags=$2

  info "$desc"
  if [ -n "$xcflags" ]; then
    (cd "$ROOT" && make clean && make XCFLAGS="$xcflags")
  else
    (cd "$ROOT" && make clean && make)
  fi
  NEED_RESTORE=1
}

with_default_xcflags() {
  printf '%s %s' "$DEFAULT_XCFLAGS" "$1"
}

try_make_clean_build() {
  desc=$1
  xcflags=$2

  info "$desc"
  if (cd "$ROOT" && make clean && make XCFLAGS="$xcflags"); then
    NEED_RESTORE=1
    return 0
  fi

  NEED_RESTORE=1
  info "Skipping tests for unsupported build flags: $xcflags"
  return 1
}

run_focused_tests() {
  desc=$1
  tests=${2:-$TESTS}

  info "$desc"
  (cd "$ROOT" && prove $tests)
}

restore_normal_build() {
  rc=$?

  if [ "$RESTORE" = 1 ] && [ "$NEED_RESTORE" = 1 ]; then
    info "Restoring normal build"
    (cd "$ROOT" && make clean && make) || rc=$?
  fi

  exit "$rc"
}

trap restore_normal_build EXIT
trap 'trap - INT TERM; exit 130' INT TERM

info "Manual matrix legs not run locally: 32-bit builds and MSVC/Windows builds"

# Default repository build and tests. The Unix/MSVC build scripts intentionally
# enable sweep-time userdata finalizer discovery by default; gcstats.t should
# still skip because statistics are not enabled in this leg.
run_make_clean_build "Default repo build" ""
run_focused_tests "Focused GC tests on default repo build"

# Stock GC statistics instrumentation build. Command-line XCFLAGS
# replace the Makefile defaults here, intentionally omitting sweep-time userdata
# finalizer discovery while keeping Lua 5.2 compatibility enabled.
run_make_clean_build "Stock GC stats build without sweep-udata finalizer mode" "$(with_default_xcflags "-DLUAJIT_ENABLE_GCSTATS")"
run_focused_tests "Focused GC tests on stock GC stats build without sweep-udata finalizer mode"

# Sweep-udata + stats leg. This keeps the default-enabled mode covered while
# adding stats so the sweep_udata_* counters and semantic tests run.
# t/finalizers.t covers legacy Lua closure userdata-finalizer behavior outside
# the native/leaf-finalizer contract.
run_make_clean_build "Sweep-udata + stats leg" "$(with_default_xcflags "-DLUAJIT_ENABLE_GCSTATS -DLUAJIT_ENABLE_SWEEP_UDATA_FINALIZERS")"
run_focused_tests "Focused GC tests on sweep-udata + stats leg" "$SWEEP_UDATA_STATS_TESTS"

# Interpreter-only build. This Makefile documents LUAJIT_DISABLE_JIT, but it is
# currently unsupported in this OpenResty/DW tree, so only this leg is optional.
if try_make_clean_build "No-JIT build" "$(with_default_xcflags "-DLUAJIT_DISABLE_JIT")"; then
  run_focused_tests "Focused GC tests on no-JIT build"
fi

# FFI-disabled build. finalizers.t treats missing FFI as a supported case.
run_make_clean_build "No-FFI build" "$(with_default_xcflags "-DLUAJIT_DISABLE_FFI")"
run_focused_tests "Focused GC tests on no-FFI build"

# Assertion/API-check build for internal GC invariants.
run_make_clean_build "Assertion/API-check build" "$(with_default_xcflags "-DLUA_USE_ASSERT -DLUA_USE_APICHECK")"
run_focused_tests "Focused GC tests on assertion/API-check build"

info "GC validation matrix passed"
