# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

$ENV{LUA_CPATH} = "$Bin/../?.so;;";
$ENV{LUA_PATH} = "$Bin/../lua/?.lua;;";

my $luajit = abs_path("$Bin/../src/luajit");

plan tests => 3;

my $cwd = cwd;
my $dir = tempdir "testlj_finalizers_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

sub run_lua {
    my ($name, $lua) = @_;
    open my $fh, '>', 'test.lua' or die "Cannot open test.lua: $!";
    print $fh $lua;
    close $fh;

    my $out = `"$luajit" test.lua 2>&1`;
    my $rc = $? >> 8;
    is "$rc:$out", "0:ok\n", $name;
}

run_lua 'userdata finalizer order and resurrection', <<'LUA';
jit.off()

local events = {}
local resurrected
local weak = setmetatable({}, { __mode = "v" })

local function push(s)
  events[#events + 1] = s
end

local function make(name, fin)
  local u = newproxy(true)
  getmetatable(u).__gc = fin or function() push(name) end
  return u
end

do
  local a = make("a")
  local b = make("b")
  local c = make("c")
  a, b, c = nil
end
collectgarbage("collect")
assert(table.concat(events, ",") == "c,b,a", table.concat(events, ","))

events = {}
do
  local u
  u = make("resurrect", function(self)
    push("resurrect")
    assert(weak[1] == nil)
    resurrected = self
  end)
  weak[1] = u
  u = nil
end
collectgarbage("collect")
assert(table.concat(events, ",") == "resurrect")
assert(resurrected ~= nil)
resurrected = nil
collectgarbage("collect")
assert(table.concat(events, ",") == "resurrect")

print("ok")
LUA

run_lua 'userdata finalizer can allocate finalizable userdata', <<'LUA';
jit.off()

local events = {}
local child_done = false

local function make(name, fin)
  local u = newproxy(true)
  getmetatable(u).__gc = fin or function() events[#events + 1] = name end
  return u
end

do
  local parent = make("parent", function()
    events[#events + 1] = "parent"
    local child = make("child", function()
      child_done = true
      events[#events + 1] = "child"
    end)
    child = nil
  end)
  parent = nil
end
for _ = 1, 4 do collectgarbage("collect") end
assert(events[1] == "parent")
assert(child_done)

print("ok")
LUA

run_lua 'cdata finalizers run when FFI is available', <<'LUA';
jit.off()

local ok, ffi = pcall(require, "ffi")
if not ok then
  print("ok")
  return
end

local n = 0
do
  local a = ffi.gc(ffi.new("int[1]"), function() n = n + 1 end)
  local b = ffi.gc(ffi.new("int[1]"), function() n = n + 1 end)
  a, b = nil
end
for _ = 1, 4 do collectgarbage("collect") end
assert(n == 2, n)

print("ok")
LUA

chdir $cwd or die $!;
