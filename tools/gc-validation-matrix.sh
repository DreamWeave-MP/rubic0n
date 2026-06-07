#!/bin/sh

# Conservative local validation matrix for GC-sensitive changes.
# Run from anywhere inside this checkout; builds and tests run at repo root.

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TESTS="t/gcstats.t t/gc-stepsize.t t/finalizers.t"
RESTORE=${GC_MATRIX_RESTORE:-1}
NEED_RESTORE=0

# Passing XCFLAGS on the make command line replaces src/Makefile's XCFLAGS
# assignments. Preserve the repo's documented default feature flag when adding
# matrix-specific flags.
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

  info "$desc"
  (cd "$ROOT" && prove $TESTS)
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

# Baseline build and tests. gcstats.t should skip in this configuration.
run_make_clean_build "Baseline build" ""
run_focused_tests "Focused GC tests on baseline build"

# GC statistics instrumentation build and tests.
run_make_clean_build "GC stats build" "$(with_default_xcflags "-DLUAJIT_ENABLE_GCSTATS")"
run_focused_tests "Focused GC tests on GC stats build"

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
