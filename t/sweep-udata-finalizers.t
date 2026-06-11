# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

$ENV{LUA_CPATH} = "$Bin/../?.so;;";
$ENV{LUA_PATH} = "$Bin/../lua/?.lua;;";

my $luajit = abs_path("$Bin/../src/luajit");

system $luajit, '-e', 'local s = jit and jit.gcstats and jit.gcstats(); if not (s and s.sweep_udata_steps) then os.exit(77) end';

plan skip_all => 'LuaJIT built without stats+LUAJIT_ENABLE_SWEEP_UDATA_FINALIZERS'
    if (($? >> 8) == 77);

plan tests => 2;

my $cwd = cwd;
my $dir = tempdir "testlj_sweep_udata_finalizers_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $fh, '>', 'test.lua' or die "Cannot open test.lua: $!";
print $fh <<'LUA';
jit.off()

local function check_stats(t)
  assert(type(t.sweep_udata_steps) == "number")
  assert(type(t.sweep_udata_queued) == "number")
  assert(type(t.sweep_udata_freed) == "number")
  assert(type(t.sweep_udata_parked) == "number")
  assert(type(t.finalizer_scan_steps) == "number")
end

check_stats(jit.gcstats(true))

do
  local n = 800
  local refs = {}
  for i = 1, n do
    local u = newproxy(true)
    getmetatable(u).__gc = tostring -- Native leaf finalizer; object stays live.
    refs[i] = u
  end

  collectgarbage("collect")
  local first = jit.gcstats(true)
  check_stats(first)
  assert(first.finalizer_scan_steps == 0, first.finalizer_scan_steps)
  assert(first.sweep_udata_steps >= n, first.sweep_udata_steps)
  assert(first.sweep_udata_queued == 0, first.sweep_udata_queued)

  collectgarbage("collect")
  local second = jit.gcstats(true)
  check_stats(second)
  assert(second.finalizer_scan_steps == 0, second.finalizer_scan_steps)
  assert(second.sweep_udata_steps >= n, second.sweep_udata_steps)
  assert(refs[n] ~= nil)
end

do
  local n = 6
  for i = 1, n do
    local u = newproxy(true)
    getmetatable(u).__gc = print -- Observable native finalizer output.
  end
  collectgarbage("collect")
  local s = jit.gcstats(true)
  check_stats(s)
  assert(s.finalizer_scan_steps == 0, s.finalizer_scan_steps)
  assert(s.sweep_udata_queued >= n, s.sweep_udata_queued)
  assert(s.finalizer_calls >= n, s.finalizer_calls)
end

do
  local weak = setmetatable({}, { __mode = "k" })

  do
    local u = newproxy(true)
    getmetatable(u).__gc = print -- Native finalizer; weak key may clear first.
    weak[u] = "value"
    u = nil
  end

  collectgarbage("collect")
  local s = jit.gcstats(true)
  check_stats(s)
  assert(s.finalizer_scan_steps == 0, s.finalizer_scan_steps)
  assert(s.sweep_udata_queued >= 1, s.sweep_udata_queued)
  assert(s.finalizer_calls >= 1, s.finalizer_calls)
  assert(next(weak) == nil)
end

do
  local live, live_n, dead_n = {}, 120, 90
  for i = 1, live_n do
    live[i] = newproxy(true)
  end
  for i = 1, dead_n do
    local u = newproxy(true)
  end
  collectgarbage("collect")
  local s = jit.gcstats(true)
  check_stats(s)
  assert(s.finalizer_scan_steps == 0, s.finalizer_scan_steps)
  assert(s.sweep_udata_parked >= live_n, s.sweep_udata_parked)
  assert(s.sweep_udata_freed >= dead_n, s.sweep_udata_freed)
  assert(live[live_n] ~= nil)
end

print("ok")
LUA
close $fh;

my $out = `"$luajit" test.lua 2>&1`;
my $rc = $? >> 8;
my $finalized = () = $out =~ /^userdata: /mg;
$out =~ s/^userdata: .*\n//mg;

chdir $cwd or die $!;

is "$rc:$finalized:$out", "0:7:ok\n", 'sweep-time userdata finalizer discovery works';
is "$rc:$out", "0:ok\n", 'weak keys for dying finalizable userdata can clear before finalizers';
