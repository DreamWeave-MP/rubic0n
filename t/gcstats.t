# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

$ENV{LUA_CPATH} = "$Bin/../?.so;;";
$ENV{LUA_PATH} = "$Bin/../lua/?.lua;;";

my $luajit = abs_path("$Bin/../src/luajit");

system $luajit, '-e', 'if not (jit and jit.gcstats) then os.exit(77) end';

plan skip_all => 'LuaJIT built without LUAJIT_ENABLE_GCSTATS'
    if (($? >> 8) == 77);

plan tests => 1;

my $cwd = cwd;
my $dir = tempdir "testlj_gcstats_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $fh, '>', 'test.lua' or die "Cannot open test.lua: $!";
print $fh <<'LUA';
local fields = {
  "alloc_calls",
  "free_calls",
  "realloc_calls",
  "alloc_bytes",
  "free_bytes",
  "realloc_bytes",
  "new_gcobj_calls",
  "new_str_calls",
  "new_str_bytes",
  "new_tab_calls",
  "new_tab_bytes",
  "new_tab_separate_array_calls",
  "new_tab_separate_array_bytes",
  "new_tab_hash_calls",
  "new_tab_hash_bytes",
  "new_udata_calls",
  "new_udata_bytes",
  "new_udata_payload_bytes",
  "new_udata_payload_0_calls",
  "new_udata_payload_1_16_calls",
  "new_udata_payload_17_32_calls",
  "new_udata_payload_33_64_calls",
  "new_udata_payload_65_128_calls",
  "new_udata_payload_129_256_calls",
  "new_udata_payload_gt_256_calls",
  "new_func_calls",
  "new_func_bytes",
  "new_cfunc_calls",
  "new_lfunc_calls",
  "new_proto_calls",
  "new_proto_bytes",
  "new_thread_calls",
  "new_thread_bytes",
  "new_upval_calls",
  "new_upval_bytes",
  "step_calls",
  "cycle_count",
  "fullgc_calls",
  "propagate_calls",
  "propagate_bytes",
  "atomic_calls",
  "sweep_string_steps",
  "sweep_root_steps",
  "finalizer_scan_steps",
  "finalizer_queued",
  "finalizer_calls",
  "weak_tables",
  "weak_slots_cleared",
  "barrier_forward",
  "barrier_back",
  "barrier_upvalue",
  "barrier_trace",
  "jit_forced_exits",
}

local sweep_udata_fields = {
  "sweep_udata_steps",
  "sweep_udata_queued",
  "sweep_udata_freed",
  "sweep_udata_parked",
  "sweep_udata_preserved",
  "sweep_udata_mmcache_hits",
  "sweep_udata_mmcache_misses",
  "sweep_udata_preserve_skips",
}

local cdata_fields = {
  "new_cdata_calls",
  "new_cdata_bytes",
  "new_cdata_payload_bytes",
}

local udata_cache_fields = {
  "udata_cache_hits",
  "udata_cache_misses",
  "udata_cache_puts",
  "udata_cache_drops",
  "udata_cache_hit_0_calls",
  "udata_cache_hit_1_16_calls",
  "udata_cache_hit_17_32_calls",
  "udata_cache_hit_33_64_calls",
  "udata_cache_hit_65_128_calls",
  "udata_cache_hit_129_256_calls",
  "udata_cache_bytes",
}

local function check_shape(t)
  assert(type(t) == "table")
  for _, name in ipairs(fields) do
    assert(type(t[name]) == "number", name)
    assert(t[name] >= 0, name)
  end
  if t.sweep_udata_steps ~= nil then
    for _, name in ipairs(sweep_udata_fields) do
      assert(type(t[name]) == "number", name)
      assert(t[name] >= 0, name)
    end
  end
  if t.new_cdata_calls ~= nil then
    for _, name in ipairs(cdata_fields) do
      assert(type(t[name]) == "number", name)
      assert(t[name] >= 0, name)
    end
  end
  if t.udata_cache_hits ~= nil then
    for _, name in ipairs(udata_cache_fields) do
      assert(type(t[name]) == "number", name)
      assert(t[name] >= 0, name)
    end
  end
end

local function assert_increased(after, before, name)
  assert(after[name] > before[name], name .. ": " .. after[name] .. " <= " .. before[name])
end

local function udata_payload_bucket_calls(t)
  return t.new_udata_payload_0_calls +
         t.new_udata_payload_1_16_calls +
         t.new_udata_payload_17_32_calls +
         t.new_udata_payload_33_64_calls +
         t.new_udata_payload_65_128_calls +
         t.new_udata_payload_129_256_calls +
         t.new_udata_payload_gt_256_calls
end

check_shape(jit.gcstats(true))
local has_sweep_udata = jit.gcstats().sweep_udata_steps ~= nil

do
  jit.gcstats(true)
  local before = jit.gcstats()
  local u = newproxy(false)
  local after = jit.gcstats()
  check_shape(after)
  assert(u ~= nil)
  assert_increased(after, before, "new_udata_calls")
  assert_increased(after, before, "new_udata_payload_0_calls")
  assert(udata_payload_bucket_calls(after) == udata_payload_bucket_calls(before) + 1)
end

do
  jit.gcstats(true)
  local before = jit.gcstats()
  local refs = {}

  refs.t = { 1, 2, 3, 4, a = 5, b = 6, c = 7 }
  refs.big = {}
  for i = 1, 32 do refs.big[i] = i end
  refs.u = newproxy(false)
  refs.s = "gcstats unique string " .. tostring({})
  refs.f = loadstring("return function(x) return function() return x end end")()(true)
  refs.co = coroutine.create(function() return refs.s end)

  local after = jit.gcstats()
  check_shape(after)
  assert_increased(after, before, "new_tab_calls")
  assert_increased(after, before, "new_tab_bytes")
  assert_increased(after, before, "new_tab_separate_array_calls")
  assert_increased(after, before, "new_tab_separate_array_bytes")
  assert_increased(after, before, "new_tab_hash_calls")
  assert_increased(after, before, "new_tab_hash_bytes")
  assert_increased(after, before, "new_udata_calls")
  assert_increased(after, before, "new_udata_bytes")
  assert_increased(after, before, "new_str_calls")
  assert_increased(after, before, "new_str_bytes")
  assert_increased(after, before, "new_func_calls")
  assert_increased(after, before, "new_func_bytes")
  assert_increased(after, before, "new_lfunc_calls")
  assert_increased(after, before, "new_proto_calls")
  assert_increased(after, before, "new_proto_bytes")
  assert_increased(after, before, "new_thread_calls")
  assert_increased(after, before, "new_thread_bytes")
  assert_increased(after, before, "new_upval_calls")
  assert_increased(after, before, "new_upval_bytes")

  if after.new_cdata_calls ~= nil then
    local ok, ffi = pcall(require, "ffi")
    if ok then
      jit.gcstats(true)
      before = jit.gcstats()
      refs.cd = ffi.new("int[?]", 16)
      after = jit.gcstats()
      check_shape(after)
      assert_increased(after, before, "new_cdata_calls")
      assert_increased(after, before, "new_cdata_bytes")
      assert_increased(after, before, "new_cdata_payload_bytes")
    end
  end
end

do
  local ok_tmpfile, tmpfile = false, nil
  if io and io.tmpfile then
    jit.gcstats(true)
    local before = jit.gcstats()
    ok_tmpfile, tmpfile = pcall(io.tmpfile)
    if ok_tmpfile and tmpfile then
      local after = jit.gcstats()
      assert(tmpfile ~= nil)
      assert_increased(after, before, "new_udata_payload_bytes")
      assert(udata_payload_bucket_calls(after) > udata_payload_bucket_calls(before))
      tmpfile:close()
    end
  end
end

do
  local weak = setmetatable({}, { __mode = "v" })
  for i = 1, 100 do weak[i] = {} end
end

if has_sweep_udata then
  collectgarbage("stop")
  for i = 1, 5 do
    local u = newproxy(true)
    getmetatable(u).__gc = tostring
  end
  collectgarbage("restart")
else
  local mt = { __gc = function() end }
  for i = 1, 20 do newproxy(false) end
  collectgarbage("stop")
  for i = 1, 5 do
    local u = newproxy(true)
    getmetatable(u).__gc = mt.__gc
  end
  collectgarbage("restart")
end

collectgarbage("collect")
local a = jit.gcstats()
check_shape(a)
assert(a.fullgc_calls >= 1)
assert(a.alloc_calls > 0)
assert(a.alloc_bytes > 0)
assert(a.new_gcobj_calls > 0)
if has_sweep_udata then
  assert(a.finalizer_scan_steps == 0, a.finalizer_scan_steps)
  assert(a.sweep_udata_steps > 0, a.sweep_udata_steps)
else
  assert(a.finalizer_scan_steps > 0)
end
assert(a.finalizer_queued >= 5)
assert(a.finalizer_calls >= 5)

local b = jit.gcstats()
check_shape(b)
for _, name in ipairs(fields) do
  assert(b[name] >= a[name], name)
end
if a.udata_cache_hits ~= nil then
  for _, name in ipairs(udata_cache_fields) do
    if name ~= "udata_cache_bytes" then
      assert(b[name] >= a[name], name)
    end
  end
end

local before_reset = jit.gcstats(true)
check_shape(before_reset)
local after_reset = jit.gcstats()
check_shape(after_reset)
assert(after_reset.fullgc_calls == 0)

do
  local n = 2000
  local refs = {}

  for i = 1, n do
    refs[i] = newproxy(true)
  end

  collectgarbage("collect")
  local first = jit.gcstats(true)
  check_shape(first)
  if has_sweep_udata then
    assert(first.finalizer_scan_steps == 0, first.finalizer_scan_steps)
    assert(first.sweep_udata_steps >= n, first.sweep_udata_steps)
    assert(first.sweep_udata_parked >= n, first.sweep_udata_parked)
  else
    assert(first.finalizer_scan_steps >= n, first.finalizer_scan_steps)
  end

  for _ = 1, 3 do collectgarbage("collect") end

  local second = jit.gcstats(true)
  check_shape(second)
  assert(second.finalizer_scan_steps < n / 10, second.finalizer_scan_steps)
  assert(refs[n] ~= nil)
end

if not has_sweep_udata then
  local n = 2000
  local resurrected = {}

  do
    collectgarbage("stop")
    for i = 1, n do
      local u = newproxy(true)
      getmetatable(u).__gc = function(self)
        resurrected[#resurrected + 1] = self
      end
      u = nil
    end
    collectgarbage("restart")
  end

  for _ = 1, 8 do
    collectgarbage("collect")
    if #resurrected == n then break end
  end

  assert(#resurrected == n, #resurrected)
  jit.gcstats(true)

  for _ = 1, 3 do collectgarbage("collect") end

  local c = jit.gcstats()
  check_shape(c)
  assert(c.finalizer_scan_steps < n / 4, c.finalizer_scan_steps)
  assert(#resurrected == n, #resurrected)
else
  local n = 2000

  do
    collectgarbage("stop")
    for i = 1, n do
      local u = newproxy(true)
      getmetatable(u).__gc = tostring
    end
    collectgarbage("restart")
  end

  for _ = 1, 8 do collectgarbage("collect") end

  local c = jit.gcstats()
  check_shape(c)
  assert(c.finalizer_scan_steps == 0, c.finalizer_scan_steps)
  assert(c.sweep_udata_queued >= n, c.sweep_udata_queued)
  assert(c.finalizer_calls >= n, c.finalizer_calls)
end

print("ok")
LUA
close $fh;

my $out = `"$luajit" test.lua 2>&1`;
my $rc = $? >> 8;

chdir $cwd or die $!;

is "$rc:$out", "0:ok\n", 'jit.gcstats counters and reset work';
