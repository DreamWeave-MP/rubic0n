local function fail(message)
  io.stderr:write("openmw userdata benchmark: ", message, "\n")
  os.exit(1)
end

local function positive_integer(value, name)
  local number = tonumber(value)
  if not number or number < 1 or number % 1 ~= 0 then
    fail(name .. " must be a positive integer")
  end
  return number
end

local function required_value(index, option)
  local value = arg[index + 1]
  if not value or value == "" then fail(option .. " requires a value") end
  return value
end

local iterations = 10000
local bursts = 20
local filter = nil
local retain = 256
local jit_mode = "on"
local self_test = false
local list_only = false

local index = 1
while index <= #arg do
  local option = arg[index]
  if option == "--iterations" or option == "-n" then
    iterations = positive_integer(required_value(index, option), "iterations")
    index = index + 1
  elseif option == "--bursts" or option == "-b" then
    bursts = positive_integer(required_value(index, option), "bursts")
    index = index + 1
  elseif option == "--filter" or option == "-f" then
    filter = required_value(index, option)
    index = index + 1
  elseif option == "--retain" then
    retain = positive_integer(required_value(index, option), "retain")
    index = index + 1
  elseif option == "--jit" then
    jit_mode = required_value(index, option)
    index = index + 1
  elseif option == "--self-test" then
    self_test = true
  elseif option == "--list" then
    list_only = true
  elseif option == "--help" or option == "-h" then
    io.write([[
usage: bench/openmw_userdata/build/openmw_userdata_bench [options]

  -n, --iterations N  operations per measured burst (default: 10000)
  -b, --bursts N      measured bursts per scenario (default: 20)
  -f, --filter TEXT   run scenarios whose names contain TEXT
      --retain N      retained values in frame-retention scenario (default: 256)
      --jit on|off    select LuaJIT mode (default: on)
      --self-test     validate bindings and exit
      --list          list scenario names and exit
]])
    os.exit(0)
  else
    fail("unknown option: " .. tostring(option))
  end
  index = index + 1
end

if jit_mode == "on" then
  jit.on()
elseif jit_mode == "off" then
  jit.off()
else
  fail("--jit must be on or off")
end

local function full_gc()
  collectgarbage("restart")
  collectgarbage("collect")
  collectgarbage("collect")
end

local function close(left, right, epsilon)
  return math.abs(left - right) <= (epsilon or 1e-5)
end

local function run_self_test()
  assert(bench.cpp_vec2_size == 8)
  assert(bench.cpp_vec3_size == 12)
  assert(bench.cpp_vec4_size == 16)
  assert(bench.userdata_vec2_payload >= bench.cpp_vec2_size)
  assert(bench.userdata_vec3_payload >= bench.cpp_vec3_size)
  assert(bench.userdata_vec4_payload >= bench.cpp_vec4_size)
  assert(bench.vector_finalizer_is_zero_upvalue_cfunc)

  local v2 = util.vector2(3, 4)
  assert(v2.x == 3 and v2.y == 4 and close(v2:length(), 5))
  local v3 = util.vector3(1, 2, 3)
  assert(v3.xyz == v3 and v3.zyx == util.vector3(3, 2, 1))
  assert(v3:cross(util.vector3(0, 1, 0)) == util.vector3(-3, 0, 1))
  local normalized, length = util.vector3(3, 4, 0):normalize()
  assert(close(length, 5) and normalized == util.vector3(0.6, 0.8, 0))
  assert(source.position == util.vector3(11, 22, 33))
  assert(source:samplePosition(4) == util.vector3(15, 20, 34))

  full_gc()
  bench.reset_finalizer_probe()
  local probes = {}
  for i = 1, 128 do probes[i] = bench.new_finalizer_probe(i) end
  assert(bench.finalizer_probe_count() == 0)
  probes = nil
  full_gc()
  assert(bench.finalizer_probe_count() == 128)
  io.write("ok openmw userdata harness\n")
end

if self_test then
  run_self_test()
  return
end

local scenarios = {}
local function scenario(name, operation, cleanup)
  scenarios[#scenarios + 1] = {name = name, operation = operation, cleanup = cleanup}
end

local vector2 = util.vector2
local vector3 = util.vector3
local vector4 = util.vector4

scenario("control-empty", function(n)
  local sink = 0
  for i = 1, n do sink = sink + i % 17 end
  return sink
end)

local control_property_value = vector3(3, 4, 12)

scenario("control-property", function(n)
  local sink = 0
  for _ = 1, n do
    sink = sink + control_property_value.x + control_property_value.y + control_property_value.z
  end
  return sink
end)

local control_dot_left = vector3(1, 2, 3)
local control_dot_right = vector3(4, 5, 6)
scenario("control-dot", function(n)
  local sink = 0
  for _ = 1, n do sink = sink + control_dot_left:dot(control_dot_right) end
  return sink
end)

scenario("construct-vec2", function(n)
  local sink = 0
  for i = 1, n do sink = sink + vector2(i % 31, i % 17).x end
  return sink
end)

scenario("construct-vec3", function(n)
  local sink = 0
  for i = 1, n do sink = sink + vector3(i % 31, i % 17, i % 13).z end
  return sink
end)

scenario("construct-vec4", function(n)
  local sink = 0
  for i = 1, n do sink = sink + vector4(i % 31, i % 17, i % 13, i % 7).w end
  return sink
end)

local normalize_value = vector3(3, 4, 12)
scenario("normalize-vec3", function(n)
  local sink = 0
  for _ = 1, n do
    local result, length = normalize_value:normalize()
    sink = sink + result.x + length
  end
  return sink
end)

local arithmetic_left = vector3(1, 2, 3)
local arithmetic_right = vector3(4, 5, 6)
scenario("arithmetic-vec3", function(n)
  local sink = 0
  for i = 1, n do
    local result = (arithmetic_left + arithmetic_right) * ((i % 7) + 1) - arithmetic_left
    sink = sink + result.z
  end
  return sink
end)

local cross_left = vector3(1, 2, 3)
local cross_right = vector3(4, 5, 6)
scenario("cross-vec3", function(n)
  local sink = 0
  for _ = 1, n do sink = sink + cross_left:cross(cross_right).y end
  return sink
end)

local swizzle_value = vector4(1, 2, 3, 4)
scenario("swizzle-mixed", function(n)
  local sink = 0
  for _ = 1, n do
    sink = sink + swizzle_value.xy.x + swizzle_value.zyx.z + swizzle_value.wzyx.w
  end
  return sink
end)

scenario("producer-position", function(n)
  local sink = 0
  for _ = 1, n do sink = sink + source.position.x end
  return sink
end)

local producer_target = vector3(1, 2, 3)
scenario("producer-chain", function(n)
  local sink = 0
  for _ = 1, n do sink = sink + (source.position - producer_target):length() end
  return sink
end)

local retained_frames = {}
scenario("retained-frames", function(n)
  local sink = 0
  for i = 1, n do
    local slot = ((i - 1) % retain) + 1
    retained_frames[slot] = source:samplePosition(i % 97)
    sink = sink + retained_frames[slot].z
  end
  return sink + #retained_frames
end, function() retained_frames = {} end)

scenario("mixed-table-userdata", function(n)
  local sink = 0
  for i = 1, n do
    local record = {
      position = source:samplePosition(i % 43),
      velocity = vector3(i % 11, i % 13, i % 17),
      id = i,
      active = i % 2 == 0,
    }
    sink = sink + (record.position + record.velocity).x + record.id
  end
  return sink
end)

local chain_left_offset = vector3(-30, -65, 0)
local chain_right_offset = vector3(30, -65, 0)
scenario("openmw-like-chain", function(n)
  local sink = 0
  for i = 1, n do
    local from = source:samplePosition(i % 19)
    local scale = ((i % 5) + 1) * 0.2
    local leftTarget = from + chain_left_offset * scale
    local rightTarget = from + chain_right_offset * scale
    sink = sink + (leftTarget - from):length() + (rightTarget - from):length()
  end
  return sink
end)

if list_only then
  for _, item in ipairs(scenarios) do io.write(item.name, "\n") end
  return
end

local function percentile(sorted, fraction)
  local position = math.ceil(#sorted * fraction)
  if position < 1 then position = 1 end
  return sorted[position]
end

local function summarize(samples)
  table.sort(samples)
  local sum = 0
  for _, value in ipairs(samples) do sum = sum + value end
  local p99 = #samples >= 100 and percentile(samples, 0.99) or nil
  return sum / #samples, percentile(samples, 0.50), percentile(samples, 0.95),
      p99, samples[#samples]
end

local has_gcstats = jit.gcstats ~= nil
io.write("# benchmark=openmw_userdata\n")
io.write("# iterations=", iterations, "\n")
io.write("# bursts=", bursts, "\n")
io.write("# jit=", jit_mode, "\n")
io.write("# gc_mode=stopped-during-workload,then-two-full-collections\n")
io.write("# warmup_iterations=", math.min(iterations, 2000), "\n")
io.write("# gcstats=", has_gcstats and "available" or "unavailable", "\n")
io.write("# cpp_sizes=", bench.cpp_vec2_size, ";", bench.cpp_vec3_size, ";", bench.cpp_vec4_size, "\n")
io.write("# userdata_payloads=", bench.userdata_vec2_payload, ";", bench.userdata_vec3_payload, ";",
    bench.userdata_vec4_payload, "\n")
if has_gcstats then
  io.write("# note=GCStats adds overhead; compare only like-for-like telemetry builds.\n")
end
io.write("scenario,phase,samples,avg_ms,median_ms,p95_ms,p99_ms,max_ms,sink,alloc_calls,free_calls,alloc_bytes,free_bytes,finalizer_calls\n")

local matched = 0
for _, item in ipairs(scenarios) do
  if not filter or item.name:find(filter, 1, true) then
    matched = matched + 1
    full_gc()
    item.operation(math.min(iterations, 2000))
    full_gc()
    if has_gcstats then jit.gcstats(true) end
    local allocation, collection, total = {}, {}, {}
    local sink = 0
    for burst = 1, bursts do
      collectgarbage("stop")
      local started = bench.now()
      sink = sink + item.operation(iterations)
      local allocated = bench.now()
      collectgarbage("restart")
      full_gc()
      local collected = bench.now()
      allocation[burst] = allocated - started
      collection[burst] = collected - allocated
      total[burst] = collected - started
    end
    local stats = has_gcstats and jit.gcstats() or nil
    local function delta(name)
      if not stats or stats[name] == nil then return "" end
      return tostring(stats[name])
    end
    local function print_phase(name, samples)
      local average, median, p95, p99, maximum = summarize(samples)
      local function milliseconds(value)
        return value and string.format("%.6f", value * 1000) or ""
      end
      local scenario_counters = name == "total"
      io.write(table.concat({item.name, name, tostring(#samples), string.format("%.6f", average * 1000),
        string.format("%.6f", median * 1000), string.format("%.6f", p95 * 1000),
        milliseconds(p99), string.format("%.6f", maximum * 1000), string.format("%.9g", sink),
        scenario_counters and delta("alloc_calls") or "", scenario_counters and delta("free_calls") or "",
        scenario_counters and delta("alloc_bytes") or "", scenario_counters and delta("free_bytes") or "",
        scenario_counters and delta("finalizer_calls") or ""}, ","), "\n")
    end
    print_phase("alloc", allocation)
    print_phase("gc", collection)
    print_phase("total", total)
    if item.cleanup then
      item.cleanup()
      full_gc()
    end
  end
end

if matched == 0 then fail("filter matched no scenarios") end
