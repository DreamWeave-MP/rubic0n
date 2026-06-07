# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

$ENV{LUA_CPATH} = "$Bin/../?.so;;";
$ENV{LUA_PATH} = "$Bin/../lua/?.lua;;";

my $luajit = abs_path("$Bin/../src/luajit");

my $ffi_available = system $luajit, '-e', 'local ok = pcall(require, "ffi"); os.exit(ok and 0 or 77)';
$ffi_available = (($ffi_available >> 8) == 0);

plan tests => 18;

my $cwd = cwd;
my $dir = tempdir "testlj_weak_finalizer_torture_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

sub slurp {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot open $file: $!";
    local $/;
    return <$fh>;
}

sub run_lua {
    my ($name, $lua, %opts) = @_;
    open my $fh, '>', 'test.lua' or die "Cannot open test.lua: $!";
    print $fh $lua;
    close $fh;

    system qq{"$luajit" test.lua >stdout.txt 2>stderr.txt};
    my $rc = $? >> 8;
    my $out = slurp 'stdout.txt';
    my $err = slurp 'stderr.txt';

    is "$rc:$out", "0:ok\n", $name;

    if (my $re = $opts{stderr_like}) {
        like $err, $re, "$name stderr";
    } elsif (!$opts{allow_stderr}) {
        is $err, '', "$name stderr clean";
    }
}

run_lua 'weak-value table drops finalized userdata', <<'LUA';
jit.off()

local weak = setmetatable({}, { __mode = "v" })
local finalized = 0

do
  collectgarbage("stop")
  local u = newproxy(true)
  getmetatable(u).__gc = function(self)
    finalized = finalized + 1
    assert(weak.slot == nil)
  end
  collectgarbage("restart")
  weak.slot = u
  u = nil
end

for _ = 1, 8 do
  collectgarbage("collect")
  if finalized > 0 then break end
end

assert(finalized == 1, finalized)
assert(weak.slot == nil)

print("ok")
LUA

run_lua 'weak-key table drops collectable keys', <<'LUA';
jit.off()

local weak = setmetatable({}, { __mode = "k" })

do
  local key = {}
  weak[key] = "value"
  key = nil
end

for _ = 1, 8 do
  collectgarbage("collect")
  if next(weak) == nil then break end
end

assert(next(weak) == nil)

print("ok")
LUA

run_lua 'weak key-and-value table drops collectable entries', <<'LUA';
jit.off()

local weak = setmetatable({}, { __mode = "kv" })

do
  local key = {}
  weak[key] = {}
  collectgarbage("collect")
  assert(weak[key] == nil)
  key = nil
end

for _ = 1, 8 do
  collectgarbage("collect")
  if next(weak) == nil then break end
end

do
  local key = {}
  local val = {}
  weak[key] = val
  key, val = nil, nil
end

for _ = 1, 8 do
  collectgarbage("collect")
  if next(weak) == nil then break end
end

assert(next(weak) == nil)

print("ok")
LUA

run_lua 'finalizer resurrection is reachable once and later collectable', <<'LUA';
jit.off()

local weak = setmetatable({}, { __mode = "v" })
local resurrected
local finalized = 0

do
  collectgarbage("stop")
  local u = newproxy(true)
  getmetatable(u).__gc = function(self)
    finalized = finalized + 1
    assert(weak[1] == nil)
    resurrected = self
  end
  collectgarbage("restart")
  weak[1] = u
  u = nil
end

for _ = 1, 8 do
  collectgarbage("collect")
  if finalized > 0 then break end
end

assert(finalized == 1, finalized)
assert(resurrected ~= nil)

weak[1] = resurrected
resurrected = nil

for _ = 1, 8 do
  collectgarbage("collect")
  if weak[1] == nil then break end
end

assert(weak[1] == nil)
assert(finalized == 1, finalized)

print("ok")
LUA

run_lua 'finalizers can allocate without corrupting queue order', <<'LUA';
jit.off()

local events = {}
local child_finalized = 0

local function push(s)
  events[#events + 1] = s
end

local function make(name)
  collectgarbage("stop")
  local u = newproxy(true)
  getmetatable(u).__gc = function()
    push(name)
    collectgarbage("stop")
    local child = newproxy(true)
    getmetatable(child).__gc = function()
      child_finalized = child_finalized + 1
    end
    collectgarbage("restart")
    local junk = {}
    for i = 1, 20 do junk[i] = { i, name } end
    child = nil
  end
  collectgarbage("restart")
  return u
end

do
  local a = make("a")
  local b = make("b")
  local c = make("c")
  a, b, c = nil, nil, nil
end

for _ = 1, 8 do collectgarbage("collect") end

assert(events[1] == "c", table.concat(events, ","))
assert(events[2] == "b", table.concat(events, ","))
assert(events[3] == "a", table.concat(events, ","))
assert(child_finalized == 3, child_finalized)

print("ok")
LUA

run_lua 'finalizer errors are contained and warned', <<'LUA', stderr_like => qr/(expected finalizer error|__gc|finalizer)/i;
jit.off()

local ran = false

do
  collectgarbage("stop")
  local u = newproxy(true)
  getmetatable(u).__gc = function()
    ran = true
    error("expected finalizer error")
  end
  collectgarbage("restart")
  u = nil
end

for _ = 1, 8 do
  collectgarbage("collect")
  if ran then break end
end

assert(ran)

print("ok")
LUA

run_lua 'tiny GC steps interleaved with allocations and finalizers', <<'LUA';
jit.off()

local oldstepsize = collectgarbage("setstepsize", 1)
local weak = setmetatable({}, { __mode = "v" })
local made = 0
local finalized = 0

for i = 1, 120 do
  local junk = {}
  for j = 1, 8 do junk[j] = { i, j } end
  if i % 2 == 0 then
    collectgarbage("stop")
    local u = newproxy(true)
    made = made + 1
    getmetatable(u).__gc = function()
      finalized = finalized + 1
      local t = {}
      for j = 1, 6 do t[j] = tostring(j) end
    end
    collectgarbage("restart")
    weak[made] = u
    u = nil
  end
  collectgarbage("step", 1)
end

for _ = 1, 12 do collectgarbage("collect") end
collectgarbage("setstepsize", oldstepsize)

assert(finalized == made, finalized .. "/" .. made)
assert(next(weak) == nil)

print("ok")
LUA

SKIP: {
    skip 'FFI unavailable', 2 unless $ffi_available;

    run_lua 'cdata finalizer stress with weak values', <<'LUA';
jit.off()

local ffi = require "ffi"
local weak = setmetatable({}, { __mode = "v" })
local made = 0
local finalized = 0

for i = 1, 80 do
  local c = ffi.gc(ffi.new("int[1]", i), function()
    finalized = finalized + 1
    local t = {}
    for j = 1, 8 do t[j] = j end
  end)
  made = made + 1
  weak[i] = c
  c = nil
  collectgarbage("step", 1)
end

for _ = 1, 12 do collectgarbage("collect") end

assert(finalized == made, finalized .. "/" .. made)
assert(next(weak) == nil)

print("ok")
LUA
}

run_lua 'allocation pressure with weak tables and finalizers', <<'LUA';
if jit then
  local ok = pcall(jit.on)
  local status_ok, enabled = pcall(jit.status)
  enabled = ok and status_ok and enabled
  if enabled and jit.opt then
    jit.opt.start("hotloop=1")
  end
end

local weak = setmetatable({}, { __mode = "kv" })
local made = 0
local finalized = 0

local function churn(n)
  for i = 1, n do
    local key = { i }
    collectgarbage("stop")
    local u = newproxy(true)
    made = made + 1
    getmetatable(u).__gc = function()
      finalized = finalized + 1
    end
    collectgarbage("restart")
    weak[key] = u
    if i % 7 == 0 then collectgarbage("step", 1) end
  end
end

for _ = 1, 5 do churn(80) end
for _ = 1, 12 do collectgarbage("collect") end

assert(finalized == made, finalized .. "/" .. made)
assert(next(weak) == nil)

print("ok")
LUA

chdir $cwd or die $!;
