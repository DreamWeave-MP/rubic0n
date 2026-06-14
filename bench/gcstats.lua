-- Benchmark/diagnostic allocation patterns using jit.gcstats().
-- Requires a LuaJIT build with -DLUAJIT_ENABLE_GCSTATS.

local function fail(msg)
  io.stderr:write("gcstats benchmark: ", msg, "\n")
  os.exit(1)
end

if not (jit and jit.gcstats) then
  fail("jit.gcstats() is unavailable; rebuild with -DLUAJIT_ENABLE_GCSTATS")
end

local function getenv(name)
  return os.getenv("GCSTATS_" .. name) or os.getenv(name)
end

local function usage()
  io.write([[
usage: luajit bench/gcstats.lua [options]

options:
  -n, --iterations N       base iteration count (env: GCSTATS_ITERATIONS)
  -s, --stepsize KB        temporarily set GC step size in KB (env: GCSTATS_STEPSIZE_KB)
  -f, --filter PATTERN     run scenarios whose names contain PATTERN (env: GCSTATS_FILTER)
  -h, --help               show this help

This is a diagnostic benchmark. Compare deltas across builds/configurations;
do not treat one run as a performance claim.
]])
end

local function parse_positive_int(value, name)
  if value == nil or value == "" then return nil end
  local n = tonumber(value)
  if not n or n < 1 or n % 1 ~= 0 then
    fail(name .. " must be a positive integer")
  end
  return n
end

local function required_arg(value, name)
  if value == nil or value == "" then fail(name .. " requires a value") end
  return value
end

local iterations = parse_positive_int(getenv("ITERATIONS"), "iterations") or 10000
local stepsize_kb = parse_positive_int(getenv("STEPSIZE_KB"), "stepsize")
local filter = getenv("FILTER")
local iteration_warning_threshold = 10000000

local i = 1
while i <= #arg do
  local a = arg[i]
  if a == "-h" or a == "--help" then
    usage()
    os.exit(0)
  elseif a == "-n" or a == "--iterations" then
    i = i + 1
    iterations = parse_positive_int(required_arg(arg[i], a), "iterations")
  elseif a == "-s" or a == "--stepsize" then
    i = i + 1
    stepsize_kb = parse_positive_int(required_arg(arg[i], a), "stepsize")
  elseif a == "-f" or a == "--filter" then
    i = i + 1
    filter = required_arg(arg[i], a)
  else
    fail("unknown option: " .. tostring(a))
  end
  i = i + 1
end

local counters = {
  "alloc_calls",
  "free_calls",
  "realloc_calls",
  "alloc_bytes",
  "free_bytes",
  "realloc_bytes",
  "new_gcobj_calls",
  "step_calls",
  "cycle_count",
  "fullgc_calls",
  "finalizer_scan_steps",
  "sweep_udata_steps",
  "sweep_udata_queued",
  "sweep_udata_freed",
  "sweep_udata_parked",
  "sweep_udata_preserved",
  "sweep_udata_preserve_udata",
  "sweep_udata_preserve_mt_dead",
  "sweep_udata_preserve_mt_alive_skip",
  "sweep_udata_preserve_callable_dead",
  "sweep_udata_preserve_callable_alive_skip",
  "sweep_udata_preserve_callable_nongc",
  "finalizer_queued",
  "finalizer_calls",
  "weak_tables",
  "weak_slots_cleared",
}

local has_sweep_udata_counters = jit.gcstats().sweep_udata_steps ~= nil

local function full_gc()
  collectgarbage("collect")
  collectgarbage("collect")
end

local function delta(before, after, name)
  if before[name] == nil or after[name] == nil then
    return nil
  end
  return after[name] - before[name]
end

local function print_deltas(before, after)
  for _, name in ipairs(counters) do
    local d = delta(before, after, name)
    io.write(string.format("  %-20s %s\n", name, d == nil and "n/a" or tostring(d)))
  end
end

local function run_gc_work()
  collectgarbage("step", 0)
end

local function userdata_iterations(n)
  return math.max(1, math.min(n, 50000))
end

local scenarios = {}

local function add_scenario(name, fn)
  scenarios[#scenarios + 1] = { name = name, fn = fn }
end

add_scenario("table-short-lived", function(n)
  local sink = 0
  for j = 1, n do
    local t = { j, j + 1, j + 2, a = j % 17, b = j % 31 }
    sink = sink + t[1] + t.a
    if j % 256 == 0 then run_gc_work() end
  end
  return sink
end)

add_scenario("string-interning", function(n)
  local sink = 0
  for j = 1, n do
    local s = "gcstats:" .. tostring(j) .. ":" .. tostring((j * 1103515245) % 2147483647)
    sink = sink + #s
    if j % 256 == 0 then run_gc_work() end
  end
  return sink
end)

add_scenario("closure-upvalue", function(n)
  local sink = 0
  for j = 1, n do
    local x = j
    local y = j % 19
    local f = function(z) return x + y + z end
    sink = sink + f(3)
    if j % 256 == 0 then run_gc_work() end
  end
  return sink
end)

add_scenario("weak-table", function(n)
  local weak = setmetatable({}, { __mode = "kv" })
  for j = 1, n do
    local k = { j }
    local v = { j, j + 1 }
    weak[k] = v
    weak[j] = { v }
    if j % 128 == 0 then run_gc_work() end
  end
  full_gc()
  return weak
end)

add_scenario("userdata-finalizer", function(n)
  if has_sweep_udata_counters then
    return nil, "legacy Lua closure userdata finalizers are outside the sweep-udata finalizer mode contract"
  end
  if type(newproxy) ~= "function" then
    return nil, "newproxy unavailable"
  end
  local finalized = 0
  for j = 1, math.max(1, math.floor(n / 8)) do
    local u = newproxy(true)
    getmetatable(u).__gc = function() finalized = finalized + 1 end
    if j % 128 == 0 then run_gc_work() end
  end
  full_gc()
  return finalized
end)

add_scenario("sweep-udata-live-native-finalizer", function(n)
  if type(newproxy) ~= "function" then
    return nil, "newproxy unavailable"
  end
  local count = userdata_iterations(n)
  local refs = {}
  for j = 1, count do
    local u = newproxy(true)
    getmetatable(u).__gc = tostring
    refs[j] = u
    if j % 128 == 0 then run_gc_work() end
  end
  full_gc()
  return refs
end)

add_scenario("sweep-udata-dead-native-finalizer", function(n)
  if type(newproxy) ~= "function" then
    return nil, "newproxy unavailable"
  end
  local count = userdata_iterations(n)
  for j = 1, count do
    local u = newproxy(true)
    getmetatable(u).__gc = tostring
    if j % 128 == 0 then run_gc_work() end
  end
  full_gc()
  return count
end)

add_scenario("sweep-udata-mixed-finalizer", function(n)
  if type(newproxy) ~= "function" then
    return nil, "newproxy unavailable"
  end
  local count = userdata_iterations(n)
  local refs = {}
  for j = 1, count do
    local u = newproxy(true)
    if j % 2 == 0 then
      getmetatable(u).__gc = tostring
    end
    if j % 3 == 0 then
      refs[#refs + 1] = u
    end
    if j % 128 == 0 then run_gc_work() end
  end
  full_gc()
  return refs
end)

add_scenario("sweep-udata-weak-key-clears-before-finalizer", function(n)
  if type(newproxy) ~= "function" then
    return nil, "newproxy unavailable"
  end
  local count = math.max(1, math.min(userdata_iterations(n), 10000))
  local weak = setmetatable({}, { __mode = "k" })
  for j = 1, count do
    local u = newproxy(true)
    getmetatable(u).__gc = tostring
    weak[u] = j
    if j % 128 == 0 then run_gc_work() end
  end
  full_gc()
  return weak
end)

add_scenario("cdata-finalizer", function(n)
  local ok, ffi = pcall(require, "ffi")
  if not ok then
    return nil, "FFI unavailable"
  end
  ffi.cdef("typedef struct { int x; } gcstats_bench_finalizer_t;")
  local finalized = 0
  for j = 1, math.max(1, math.floor(n / 8)) do
    ffi.gc(ffi.new("gcstats_bench_finalizer_t"), function() finalized = finalized + 1 end)
    if j % 128 == 0 then run_gc_work() end
  end
  full_gc()
  return finalized
end)

local old_pause = collectgarbage("setpause", 200)
collectgarbage("setpause", old_pause)
local old_stepmul = collectgarbage("setstepmul", 200)
collectgarbage("setstepmul", old_stepmul)
local old_stepsize

if stepsize_kb then
  old_stepsize = collectgarbage("setstepsize", stepsize_kb)
end

local function restore_gc_controls()
  collectgarbage("setpause", old_pause)
  collectgarbage("setstepmul", old_stepmul)
  if old_stepsize then collectgarbage("setstepsize", old_stepsize) end
end

local ok, err = pcall(function()
  io.write("gcstats benchmark\n")
  io.write("iterations=", tostring(iterations), "\n")
  io.write("filter=", tostring(filter or "(none)"), "\n")
  io.write("gc_pause=", tostring(old_pause), "\n")
  io.write("gc_stepmul=", tostring(old_stepmul), "\n")
  io.write("gc_stepsize_kb=", tostring(stepsize_kb or old_stepsize or "unchanged"), "\n")
  io.write("note=tiny counter deltas include harness overhead from jit.gcstats() table snapshots and timing\n")
  if iterations > iteration_warning_threshold then
    io.stderr:write(string.format(
      "gcstats benchmark: warning: iterations=%d is very large; runs may allocate heavily and take a long time\n",
      iterations))
  end

  local ran = 0
  for _, scenario in ipairs(scenarios) do
    if not filter or scenario.name:find(filter, 1, true) then
      ran = ran + 1
      full_gc()
      jit.gcstats(true)
      local before = jit.gcstats()
      local start = os.clock()
      local results = { scenario.fn(iterations) }
      local elapsed = os.clock() - start
      full_gc()
      local after = jit.gcstats()

      io.write("\nscenario=", scenario.name, "\n")
      io.write(string.format("elapsed=%.6f\n", elapsed))
      if results[2] then
        io.write("status=skip reason=", tostring(results[2]), "\n")
      else
        io.write("status=ok\n")
        print_deltas(before, after)
      end
    end
  end
  if ran == 0 then error("no scenarios matched filter: " .. tostring(filter), 0) end
end)

restore_gc_controls()

if not ok then
  fail(err)
end
