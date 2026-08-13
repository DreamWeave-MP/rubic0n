# OpenMW Sol userdata benchmark

This standalone harness reproduces the small value-userdata path used by
OpenMW's `openmw.util` vectors without starting or linking the OpenMW engine.
It uses OpenMW's vendored Sol configuration, vendored Sol headers, and actual
OpenSceneGraph `Vec2f`, `Vec3f`, and `Vec4f` value types.

The relevant path remains real:

```text
Sol-bound C++ value return
  -> sol::detail::usertype_allocate<T>
  -> lua_newuserdata
  -> inline C++ value construction
  -> Sol's zero-upvalue C __gc function
```

The registrations are adapted from
`components/lua/utilpackage.cpp`. They include OpenMW-style explicit immutable
usertypes, vector operators and methods, and the complete eager swizzle key
space. `PositionSource` is deliberately fake engine state whose properties
return vectors by value, allowing `source.position.x` and
`(source.position - target):length()` to retain the allocation shape of common
OpenMW APIs without pulling in world, physics, or rendering systems.

## Pinned source identities

The harness was introduced against:

- Rubic0n/LuaJIT: `a88da62d6518919bbd8fe51ef1e2ae5980212de2`
- OpenMW checkout: `58b566377ec47ed5750ec78e1656e129e09bdd5e`
- Vendored Sol source identified by OpenMW as
  `c1f95a773c6f8f4fde8ca3efe872e7286afe4444`, plus the patches listed in
  `openmw/extern/sol3/README.md`
- OpenSceneGraph checkout: `638f0a1e73687633fd99bf110d04226e78ff69c6`

The OpenMW tree is a build dependency and is not modified by this benchmark.

## Build

Build LuaJIT first, then build the harness:

```bash
make
make -C bench/openmw_userdata
```

The defaults assume sibling checkouts at `GitHub/luajit2` and `GitHub/openmw`.
Override paths when needed:

```bash
make -C bench/openmw_userdata \
  LUAJIT_ROOT=/path/to/luajit2 \
  OPENMW_ROOT=/path/to/openmw
```

The executable links the selected LuaJIT tree's static library. Rebuild both
LuaJIT and the harness when changing allocator build flags.

## Validate and run

```bash
make -C bench/openmw_userdata self-test
bench/openmw_userdata/build/openmw_userdata_bench --list
bench/openmw_userdata/build/openmw_userdata_bench \
  --iterations 10000 --bursts 20
bench/openmw_userdata/build/openmw_userdata_bench \
  --filter normalize --iterations 50000 --bursts 50
bench/openmw_userdata/build/openmw_userdata_bench \
  --jit off --iterations 10000 --bursts 20
```

Output is comment-prefixed CSV with separate allocation, collection, and
combined timings. Every workload contributes results to a numeric sink so the
work remains observable. Each scenario receives an untimed warmup before
measurement. Allocation timing runs with GC stopped; the following GC phase
restarts the collector and performs two full collections. This deliberately
isolates bulk allocation and reclamation. It does not claim to reproduce
OpenMW's incremental per-frame GC pacing. `control-empty` exposes the full-GC
cost of the harness's permanent registered heap.

If LuaJIT was built with `LUAJIT_ENABLE_GCSTATS`, `total` rows include
whole-scenario allocation and finalizer counters. Phase rows leave those fields
blank rather than mislabel scenario-wide telemetry. A GCStats build has
instrumentation overhead:
compare telemetry builds only with other telemetry builds, and use no-GCStats
builds for allocator performance claims.

## Workload groups

- Nonallocating controls: persistent-vector properties and dot products.
- Constructor churn: Vec2, Vec3, and Vec4 returned through Sol.
- Returned temporaries: normalize, arithmetic, cross products, and swizzles.
- Producer chains: fake engine properties returning Vec3 by value.
- Retention: a rotating frame-like set that remains rooted while each measured
  collection runs.
- Mixed churn: Lua tables containing multiple Sol userdata values.
- OpenMW-like chain: value producers, vector arithmetic, and distance methods.

This first harness intentionally omits transforms, colors, boxes, world state,
ray casting, and frame integration. Those should be added as distinct workload
layers after the vector allocator experiment is stable.
