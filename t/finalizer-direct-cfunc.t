# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

my $luajit = abs_path("$Bin/../src/luajit");

plan skip_all => "src/luajit is not built" unless defined $luajit && -x $luajit;

system $luajit, '-e', 'if not (jit and jit.gcstats) then os.exit(77) end; local s = jit.gcstats(); if s.finalizer_direct_cfunc_calls == nil then os.exit(78) end';
plan skip_all => 'LuaJIT built without LUAJIT_ENABLE_GCSTATS'
    if (($? >> 8) == 77);
plan skip_all => 'LuaJIT built without LUAJIT_ENABLE_UNPROTECTED_C_FINALIZERS'
    if (($? >> 8) == 78);

my $cc = $ENV{CC} || "cc";
system("$cc --version >/dev/null 2>&1");
plan skip_all => "C compiler '$cc' is not available" if $? == -1 || ($? >> 8) == 127;

my $cwd = cwd;
my $dir = tempdir "testlj_finalizer_direct_cfunc_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $c, '>', 'findirect.c' or die "Cannot open findirect.c: $!";
print $c <<'C';
#include "lua.h"
#include "lauxlib.h"

static int zero_count;
static int nonzero_count;
static int closure_count;
static int stack_ok_count;

static int zero_finalizer(lua_State *L)
{
  int stack_ok = lua_gettop(L) == 1 && lua_type(L, 1) == LUA_TUSERDATA;
  lua_pushboolean(L, 1);
  stack_ok = stack_ok && lua_gettop(L) == 2;
  lua_pop(L, 1);
  stack_ok = stack_ok && lua_gettop(L) == 1;
  if (stack_ok) stack_ok_count++;
  luaL_argcheck(L, lua_touserdata(L, 1) != NULL, 1, "userdata expected");
  zero_count++;
  return 0;
}

static int nonzero_finalizer(lua_State *L)
{
  luaL_argcheck(L, lua_touserdata(L, 1) != NULL, 1, "userdata expected");
  nonzero_count++;
  return 1;
}

static int closure_finalizer(lua_State *L)
{
  luaL_argcheck(L, lua_touserdata(L, 1) != NULL, 1, "userdata expected");
  luaL_checkany(L, lua_upvalueindex(1));
  closure_count++;
  return 0;
}

static int newproxy_with_gc(lua_State *L)
{
  luaL_checkany(L, 1);
  lua_newuserdata(L, 1);
  lua_newtable(L);
  lua_pushvalue(L, 1);
  lua_setfield(L, -2, "__gc");
  lua_setmetatable(L, -2);
  return 1;
}

static int counters(lua_State *L)
{
  lua_pushinteger(L, zero_count);
  lua_pushinteger(L, nonzero_count);
  lua_pushinteger(L, closure_count);
  lua_pushinteger(L, stack_ok_count);
  return 4;
}

static int reset(lua_State *L)
{
  zero_count = 0;
  nonzero_count = 0;
  closure_count = 0;
  stack_ok_count = 0;
  return 0;
}

LUALIB_API int luaopen_findirect(lua_State *L)
{
  luaL_newmetatable(L, "findirect.udata");
  lua_pop(L, 1);
  lua_newtable(L);
  lua_pushcfunction(L, zero_finalizer);
  lua_setfield(L, -2, "zero_finalizer");
  lua_pushcfunction(L, nonzero_finalizer);
  lua_setfield(L, -2, "nonzero_finalizer");
  lua_pushstring(L, "upvalue");
  lua_pushcclosure(L, closure_finalizer, 1);
  lua_setfield(L, -2, "closure_finalizer");
  lua_pushcfunction(L, newproxy_with_gc);
  lua_setfield(L, -2, "newproxy_with_gc");
  lua_pushcfunction(L, counters);
  lua_setfield(L, -2, "counters");
  lua_pushcfunction(L, reset);
  lua_setfield(L, -2, "reset");
  return 1;
}
C
close $c;

my @compile = ($cc, "-shared", "-fPIC", "-I$Bin/../src", "-o", "findirect.so", "findirect.c");
my $compile_out = `@compile 2>&1`;
my $compile_rc = $? >> 8;
if ($compile_rc != 0 && $compile_out =~ /not found|No such file|command not found/i) {
    plan skip_all => "C compiler '$cc' is not available";
}
die "Cannot compile findirect.so with '@compile':\n$compile_out" if $compile_rc != 0;

plan tests => 1;

$ENV{LUA_CPATH} = "$dir/?.so;$Bin/../?.so;;";
$ENV{LUA_PATH} = "$Bin/../lua/?.lua;;";

open my $lua, '>', 'test.lua' or die "Cannot open test.lua: $!";
print $lua <<'LUA';
local m = require "findirect"

local function stats()
  return jit.gcstats()
end

local function stat(name)
  return stats()[name]
end

local function force_until(name, before, delta)
  for _ = 1, 16 do
    collectgarbage("collect")
    if stat(name) >= before + delta then return end
  end
  error(name .. ": " .. stat(name) .. " < " .. before + delta)
end

local function assert_delta(before, name, delta)
  local after = stat(name)
  assert(after == before + delta, name .. ": " .. after .. " != " .. before + delta)
end

local kept = {}

m.reset()
collectgarbage("collect")
jit.gcstats(true)

do
  local before_direct = stat("finalizer_direct_cfunc_calls")
  local before_nup0 = stat("finalizer_cfunc_nup0_calls")
  local u = m.newproxy_with_gc(m.zero_finalizer)
  u = nil
  force_until("finalizer_direct_cfunc_calls", before_direct, 1)
  assert_delta(before_nup0, "finalizer_cfunc_nup0_calls", 1)
  local zero, nonzero, closure, stack_ok = m.counters()
  assert(zero == 1 and nonzero == 0 and closure == 0 and stack_ok == 1)
end

do
  local before_direct = stat("finalizer_direct_cfunc_calls")
  local before_nonzero = stat("finalizer_direct_cfunc_nonzero_results")
  local u = m.newproxy_with_gc(m.nonzero_finalizer)
  u = nil
  force_until("finalizer_direct_cfunc_calls", before_direct, 1)
  assert_delta(before_nonzero, "finalizer_direct_cfunc_nonzero_results", 1)
  local zero, nonzero, closure, stack_ok = m.counters()
  assert(zero == 1 and nonzero == 1 and closure == 0 and stack_ok == 1)
end

do
  local before_direct = stat("finalizer_direct_cfunc_calls")
  local before_upvalue = stat("finalizer_cfunc_upvalue_calls")
  local u = m.newproxy_with_gc(m.closure_finalizer)
  u = nil
  force_until("finalizer_cfunc_upvalue_calls", before_upvalue, 1)
  assert_delta(before_direct, "finalizer_direct_cfunc_calls", 0)
  local zero, nonzero, closure, stack_ok = m.counters()
  assert(zero == 1 and nonzero == 1 and closure == 1 and stack_ok == 1)
end

do
  local before_direct = stat("finalizer_direct_cfunc_calls")
  local before_lfunc = stat("finalizer_lfunc_calls")
  local u = newproxy(true)
  getmetatable(u).__gc = function() end
  u = nil
  force_until("finalizer_lfunc_calls", before_lfunc, 1)
  assert_delta(before_direct, "finalizer_direct_cfunc_calls", 0)
end

do
  local before_direct = stat("finalizer_direct_cfunc_calls")
  local before_ffunc = stat("finalizer_ffunc_calls")
  local u = newproxy(true)
  getmetatable(u).__gc = tostring
  u = nil
  force_until("finalizer_ffunc_calls", before_ffunc, 1)
  assert_delta(before_direct, "finalizer_direct_cfunc_calls", 0)
end

do
  local before_direct = stat("finalizer_direct_cfunc_calls")
  local before_other = stat("finalizer_other_calls")
  local callable = setmetatable({}, { __call = function() end })
  kept[#kept + 1] = callable
  local u = newproxy(true)
  getmetatable(u).__gc = callable
  u = nil
  force_until("finalizer_other_calls", before_other, 1)
  assert_delta(before_direct, "finalizer_direct_cfunc_calls", 0)
end

print("ok")
LUA
close $lua;

system qq{"$luajit" test.lua >stdout.txt 2>stderr.txt};
my $rc = $? >> 8;

open my $outfh, '<', 'stdout.txt' or die "Cannot open stdout.txt: $!";
my $out = do { local $/; <$outfh> };
close $outfh;

chdir $cwd or die $!;

is "$rc:$out", "0:ok\n", 'direct C finalizer path is guarded and counted';
