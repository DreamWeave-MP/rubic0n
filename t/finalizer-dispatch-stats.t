# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

my $luajit = abs_path("$Bin/../src/luajit");

plan skip_all => "src/luajit is not built" unless defined $luajit && -x $luajit;

system $luajit, '-e', 'if not (jit and jit.gcstats) then os.exit(77) end';
plan skip_all => 'LuaJIT built without LUAJIT_ENABLE_GCSTATS'
    if (($? >> 8) == 77);

my $cc = $ENV{CC} || "cc";
system("$cc --version >/dev/null 2>&1");
plan skip_all => "C compiler '$cc' is not available" if $? == -1 || ($? >> 8) == 127;

my $cwd = cwd;
my $dir = tempdir "testlj_finalizer_dispatch_stats_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $c, '>', 'findisp.c' or die "Cannot open findisp.c: $!";
print $c <<'C';
#include "lua.h"
#include "lauxlib.h"

static int finalizer(lua_State *L)
{
  luaL_checkany(L, 1);
  return 0;
}

static int closure_finalizer(lua_State *L)
{
  luaL_checkany(L, 1);
  luaL_checkany(L, lua_upvalueindex(1));
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

LUALIB_API int luaopen_findisp(lua_State *L)
{
  lua_newtable(L);
  lua_pushcfunction(L, finalizer);
  lua_setfield(L, -2, "finalizer");
  lua_pushstring(L, "upvalue");
  lua_pushcclosure(L, closure_finalizer, 1);
  lua_setfield(L, -2, "closure_finalizer");
  lua_pushcfunction(L, newproxy_with_gc);
  lua_setfield(L, -2, "newproxy_with_gc");
  return 1;
}
C
close $c;

my @compile = ($cc, "-shared", "-fPIC", "-I$Bin/../src", "-o", "findisp.so", "findisp.c");
my $compile_out = `@compile 2>&1`;
my $compile_rc = $? >> 8;
if ($compile_rc != 0 && $compile_out =~ /not found|No such file|command not found/i) {
    plan skip_all => "C compiler '$cc' is not available";
}
die "Cannot compile findisp.so with '@compile':\n$compile_out" if $compile_rc != 0;

plan tests => 1;

$ENV{LUA_CPATH} = "$dir/?.so;$Bin/../?.so;;";
$ENV{LUA_PATH} = "$Bin/../lua/?.lua;;";

open my $lua, '>', 'test.lua' or die "Cannot open test.lua: $!";
print $lua <<'LUA';
local m = require "findisp"

local function stat(name)
  return jit.gcstats()[name]
end

local function force_until(name, before, delta)
  for _ = 1, 16 do
    collectgarbage("collect")
    if stat(name) >= before + delta then return end
  end
  error(name .. ": " .. stat(name) .. " < " .. before + delta)
end

local function check_delta(name, expected, make)
  collectgarbage("collect")
  jit.gcstats(true)
  local before = stat(name)
  make()
  force_until(name, before, expected)
  local after = stat(name)
  assert(after == before + expected, name .. ": " .. after .. " != " .. before + expected)
end

local kept = {}

check_delta("finalizer_lfunc_calls", 1, function()
  local u = newproxy(true)
  getmetatable(u).__gc = function() end
  u = nil
end)

check_delta("finalizer_ffunc_calls", 1, function()
  local u = newproxy(true)
  getmetatable(u).__gc = tostring
  u = nil
end)

check_delta("finalizer_other_calls", 1, function()
  local callable = setmetatable({}, { __call = function() end })
  kept[#kept + 1] = callable
  local u = newproxy(true)
  getmetatable(u).__gc = callable
  u = nil
end)

do
  collectgarbage("collect")
  jit.gcstats(true)
  local before_error = stat("finalizer_error_calls")
  local before_lfunc = stat("finalizer_lfunc_calls")
  local u = newproxy(true)
  getmetatable(u).__gc = function() error("expected finalizer error") end
  u = nil
  force_until("finalizer_error_calls", before_error, 1)
  assert(stat("finalizer_lfunc_calls") == before_lfunc + 1)
end

do
  collectgarbage("collect")
  jit.gcstats(true)
  local before_cfunc = stat("finalizer_cfunc_calls")
  local before_nup0 = stat("finalizer_cfunc_nup0_calls")
  local before_upvalue = stat("finalizer_cfunc_upvalue_calls")
  local u = m.newproxy_with_gc(m.finalizer)
  u = nil
  force_until("finalizer_cfunc_nup0_calls", before_nup0, 1)
  assert(stat("finalizer_cfunc_calls") == before_cfunc + 1)
  assert(stat("finalizer_cfunc_upvalue_calls") == before_upvalue)
end

do
  collectgarbage("collect")
  jit.gcstats(true)
  local before_cfunc = stat("finalizer_cfunc_calls")
  local before_nup0 = stat("finalizer_cfunc_nup0_calls")
  local before_upvalue = stat("finalizer_cfunc_upvalue_calls")
  local u = m.newproxy_with_gc(m.closure_finalizer)
  u = nil
  force_until("finalizer_cfunc_upvalue_calls", before_upvalue, 1)
  assert(stat("finalizer_cfunc_calls") == before_cfunc + 1)
  assert(stat("finalizer_cfunc_nup0_calls") == before_nup0)
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

is "$rc:$out", "0:ok\n", 'finalizer dispatch gcstats counters classify calls';
