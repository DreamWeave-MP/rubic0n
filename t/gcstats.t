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

local function check_shape(t)
  assert(type(t) == "table")
  for _, name in ipairs(fields) do
    assert(type(t[name]) == "number", name)
    assert(t[name] >= 0, name)
  end
end

check_shape(jit.gcstats(true))

do
  local weak = setmetatable({}, { __mode = "v" })
  for i = 1, 100 do weak[i] = {} end
end

do
  local mt = { __gc = function() end }
  for i = 1, 20 do newproxy(false) end
  for i = 1, 5 do
    local u = newproxy(true)
    getmetatable(u).__gc = mt.__gc
  end
end

collectgarbage("collect")
local a = jit.gcstats()
check_shape(a)
assert(a.fullgc_calls >= 1)
assert(a.alloc_calls > 0)
assert(a.alloc_bytes > 0)
assert(a.new_gcobj_calls > 0)
assert(a.finalizer_scan_steps > 0)
assert(a.finalizer_queued >= 5)
assert(a.finalizer_calls >= 5)

local b = jit.gcstats()
check_shape(b)
for _, name in ipairs(fields) do
  assert(b[name] >= a[name], name)
end

local before_reset = jit.gcstats(true)
check_shape(before_reset)
local after_reset = jit.gcstats()
check_shape(after_reset)
assert(after_reset.fullgc_calls == 0)

do
  local n = 2000
  local resurrected = {}

  do
    for i = 1, n do
      local u = newproxy(true)
      getmetatable(u).__gc = function(self)
        resurrected[#resurrected + 1] = self
      end
      u = nil
    end
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
end

print("ok")
LUA
close $fh;

my $out = `"$luajit" test.lua 2>&1`;
my $rc = $? >> 8;

chdir $cwd or die $!;

is "$rc:$out", "0:ok\n", 'jit.gcstats counters and reset work';
