# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

my $luajit = abs_path("$Bin/../src/luajit");

plan skip_all => "src/luajit is not built" unless defined $luajit && -x $luajit;

system $luajit, '-e', 'local s = jit and jit.gcstats and jit.gcstats(); if not (s and s.sweep_udata_preserve_udata) then os.exit(77) end';

plan skip_all => 'LuaJIT built without sweep_udata stats fields'
    if (($? >> 8) == 77);

my $cc = $ENV{CC} || "cc";
system("$cc --version >/dev/null 2>&1");
plan skip_all => "C compiler '$cc' is not available" if $? == -1 || ($? >> 8) == 127;

my $cwd = cwd;
my $dir = tempdir "testlj_sweep_udata_preserve_skips_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $c, '>', 'sweeppreserve.c' or die "Cannot open sweeppreserve.c: $!";
print $c <<'C';
#include "lua.h"

static int finalizer_count;
static int stack_error_count;

static int leaf_finalizer(lua_State *L)
{
  if (lua_gettop(L) != 1 || lua_type(L, 1) != LUA_TUSERDATA ||
      lua_touserdata(L, 1) == NULL)
    stack_error_count++;
  finalizer_count++;
  return 0;
}

static int fresh_finalizer(lua_State *L)
{
  lua_pushcfunction(L, leaf_finalizer);
  return 1;
}

static int counters(lua_State *L)
{
  lua_pushinteger(L, finalizer_count);
  lua_pushinteger(L, stack_error_count);
  return 2;
}

static int reset(lua_State *L)
{
  finalizer_count = 0;
  stack_error_count = 0;
  return 0;
}

LUALIB_API int luaopen_sweeppreserve(lua_State *L)
{
  lua_newtable(L);
  lua_pushcfunction(L, leaf_finalizer);
  lua_setfield(L, -2, "leaf_finalizer");
  lua_pushcfunction(L, fresh_finalizer);
  lua_setfield(L, -2, "fresh_finalizer");
  lua_pushcfunction(L, counters);
  lua_setfield(L, -2, "counters");
  lua_pushcfunction(L, reset);
  lua_setfield(L, -2, "reset");
  return 1;
}
C
close $c;

my @compile = ($cc, "-shared", "-fPIC", "-I$Bin/../src", "-o", "sweeppreserve.so", "sweeppreserve.c");
my $compile_out = `@compile 2>&1`;
my $compile_rc = $? >> 8;
if ($compile_rc != 0 && $compile_out =~ /not found|No such file|command not found/i) {
    plan skip_all => "C compiler '$cc' is not available";
}
die "Cannot compile sweeppreserve.so with '@compile':\n$compile_out" if $compile_rc != 0;

$ENV{LUA_CPATH} = "$dir/?.so;$Bin/../?.so;;";
$ENV{LUA_PATH} = "$Bin/../lua/?.lua;;";

open my $lua, '>', 'test.lua' or die "Cannot open test.lua: $!";
print $lua <<'LUA';
if jit then jit.off() end
local m = require "sweeppreserve"

local function check_sweep_stats(s)
  local fields = {
    "sweep_udata_preserved",
    "sweep_udata_preserve_udata",
    "sweep_udata_preserve_mt_dead",
    "sweep_udata_preserve_mt_alive_skip",
    "sweep_udata_preserve_callable_dead",
    "sweep_udata_preserve_callable_alive_skip",
    "sweep_udata_preserve_callable_nongc",
  }
  for _, name in ipairs(fields) do
    assert(type(s[name]) == "number", name)
    assert(s[name] >= 0, name)
  end
  assert(s.sweep_udata_preserved ==
         s.sweep_udata_preserve_udata +
         s.sweep_udata_preserve_mt_dead +
         s.sweep_udata_preserve_callable_dead,
         "preserved makewhite counter mismatch")
end

local function reset_case()
  collectgarbage("collect")
  m.reset()
  jit.gcstats(true)
end

local function collect_case()
  collectgarbage("collect")
  local s = jit.gcstats()
  local calls, stack_errors = m.counters()
  check_sweep_stats(s)
  assert(stack_errors == 0, stack_errors)
  return s, calls
end

do
  local anchors = {}
  reset_case()
  do
    local u = newproxy(true)
    local mt = getmetatable(u)
    anchors.mt = mt
    anchors.fn = m.leaf_finalizer
    mt.__gc = anchors.fn
    u = nil
  end
  local s, calls = collect_case()
  assert(calls == 1, calls)
  assert(s.sweep_udata_preserve_udata >= 1, s.sweep_udata_preserve_udata)
  assert(s.sweep_udata_preserve_mt_alive_skip >= 1, s.sweep_udata_preserve_mt_alive_skip)
  assert(s.sweep_udata_preserve_callable_alive_skip >= 1,
         s.sweep_udata_preserve_callable_alive_skip)
end

do
  reset_case()
  do
    local u = newproxy(true)
    getmetatable(u).__gc = m.fresh_finalizer()
    u = nil
  end
  local s, calls = collect_case()
  assert(calls == 1, calls)
  assert(s.sweep_udata_preserve_mt_dead >= 1, s.sweep_udata_preserve_mt_dead)
  assert(s.sweep_udata_preserve_callable_dead >= 1,
         s.sweep_udata_preserve_callable_dead)
  assert(s.sweep_udata_preserved >= 3, s.sweep_udata_preserved)
end

do
  reset_case()
  do
    local u = newproxy(true)
    getmetatable(u).__gc = false
    u = nil
  end
  collectgarbage("collect")
  local s = jit.gcstats()
  check_sweep_stats(s)
  assert(s.sweep_udata_preserve_callable_nongc >= 1,
         s.sweep_udata_preserve_callable_nongc)
  assert(s.finalizer_other_calls >= 1, s.finalizer_other_calls)
  assert(s.finalizer_error_calls >= 1, s.finalizer_error_calls)
end

print("ok")
LUA
close $lua;

my $out = `"$luajit" test.lua 2>&1`;
my $rc = $? >> 8;

chdir $cwd or die $!;

plan tests => 2;
is $rc, 0, 'sweep preserve skip counter test exits successfully';
like $out, qr/ok\n\z/, 'sweep preserve skip counters behave as expected';
