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

To leave the collector running during the workload, as a game frame loop
does, add `--gc incremental`:

```bash
bench/openmw_userdata/build/openmw_userdata_bench \
  --gc incremental --iterations 20000 --bursts 50
```

That mode only reports `total` rows. Each burst pays for the share of
collection its own allocation triggers, and garbage carries over from one
burst to the next.

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

## Results for the paged-heap series

Linux x86-64, GCC 13.3, default `make`, Xeon at 2.3 GHz, 2 cores, JIT on,
20,000 iterations and 15 bursts per scenario. Each figure is the lowest of 7
interleaved runs of the per-scenario median, in milliseconds per burst.
"before" is 71f6728e. Both sides ran this harness and this workload file.

With `--gc incremental`:

| scenario             | before |  after | change |
|----------------------|-------:|-------:|-------:|
| control-property     |  4.504 |  3.405 | -24.4% |
| control-dot          |  3.048 |  2.303 | -24.4% |
| construct-vec2       |  3.526 |  2.301 | -34.7% |
| construct-vec3       |  3.748 |  2.471 | -34.1% |
| construct-vec4       |  4.025 |  2.662 | -33.9% |
| normalize-vec3       |  5.542 |  3.833 | -30.8% |
| arithmetic-vec3      | 12.632 |  8.109 | -35.8% |
| cross-vec3           |  6.550 |  4.314 | -34.1% |
| swizzle-mixed        | 14.721 | 10.005 | -32.0% |
| producer-position    |  4.569 |  2.950 | -35.4% |
| producer-chain       |  9.539 |  6.180 | -35.2% |
| retained-frames      |  5.851 |  3.975 | -32.1% |
| mixed-table-userdata | 14.265 | 10.683 | -25.1% |
| openmw-like-chain    | 32.683 | 21.378 | -34.6% |
| sum                  | 125.24 |  84.61 | -32.4% |

In the default mode the sum of the totals goes from 117.32 to 81.08 (-30.9%).
The collection phase alone drops by 46% to 60% in every allocating scenario,
the allocation phase by 22% to 29%.

Where the allocation phase went: these loops are not compiled as loops. A
userdata metamethod that is a C function ends the trace, so every `.x`, `+`
and method call runs through the interpreter and Sol. Per bound call that is
about 2,400 instructions before this series, of which roughly a quarter was
`luaL_getmetatable` alone. The allocator was under 5%.
