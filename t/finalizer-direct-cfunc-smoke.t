# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

my $luajit = abs_path("$Bin/../src/luajit");

plan skip_all => "src/luajit is not built" unless defined $luajit && -x $luajit;

my $cc = $ENV{CC} || "cc";
system("$cc --version >/dev/null 2>&1");
plan skip_all => "C compiler '$cc' is not available" if $? == -1 || ($? >> 8) == 127;

my $cwd = cwd;
my $dir = tempdir "testlj_finalizer_direct_cfunc_smoke_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $c, '>', 'findirectsmoke.c' or die "Cannot open findirectsmoke.c: $!";
print $c <<'C';
#include "lua.h"
#include "lauxlib.h"

static int finalizer_count;
static int stack_error_count;

static int ud_finalizer(lua_State *L)
{
  int ok = lua_gettop(L) == 1 && lua_type(L, 1) == LUA_TUSERDATA;
  lua_pushboolean(L, 1);
  ok = ok && lua_gettop(L) == 2;
  lua_pop(L, 1);
  ok = ok && lua_gettop(L) == 1;
  if (!ok) stack_error_count++;
  finalizer_count++;
  return 0;
}

static int new_udata(lua_State *L)
{
  lua_newuserdata(L, 1);
  luaL_getmetatable(L, "findirectsmoke.udata");
  lua_setmetatable(L, -2);
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

LUALIB_API int luaopen_findirectsmoke(lua_State *L)
{
  luaL_newmetatable(L, "findirectsmoke.udata");
  lua_pushcfunction(L, ud_finalizer);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);

  lua_newtable(L);
  lua_pushcfunction(L, new_udata);
  lua_setfield(L, -2, "new_udata");
  lua_pushcfunction(L, counters);
  lua_setfield(L, -2, "counters");
  lua_pushcfunction(L, reset);
  lua_setfield(L, -2, "reset");
  return 1;
}
C
close $c;

my @compile = ($cc, "-shared", "-fPIC", "-I$Bin/../src", "-o",
               "findirectsmoke.so", "findirectsmoke.c");
my $compile_out = `@compile 2>&1`;
my $compile_rc = $? >> 8;
if ($compile_rc != 0 && $compile_out =~ /not found|No such file|command not found/i) {
    plan skip_all => "C compiler '$cc' is not available";
}
die "Cannot compile findirectsmoke.so with '@compile':\n$compile_out" if $compile_rc != 0;

plan tests => 1;

$ENV{LUA_CPATH} = "$dir/?.so;$Bin/../?.so;;";
$ENV{LUA_PATH} = "$Bin/../lua/?.lua;;";

open my $lua, '>', 'test.lua' or die "Cannot open test.lua: $!";
print $lua <<'LUA';
-- This fork branch always includes the narrow direct zero-upvalue C finalizer
-- ABI. This smoke test also remains valid for stock-like protected paths.
local m = require "findirectsmoke"
local n = 2000

m.reset()
collectgarbage("stop")
for _ = 1, n do
  m.new_udata()
end
collectgarbage("restart")

for _ = 1, 64 do
  collectgarbage("collect")
  local count = m.counters()
  if count >= n then break end
end

local count, stack_errors = m.counters()
assert(count == n, count .. " != " .. n)
assert(stack_errors == 0, stack_errors)
print("ok")
LUA
close $lua;

system qq{"$luajit" test.lua >stdout.txt 2>stderr.txt};
my $rc = $? >> 8;

open my $outfh, '<', 'stdout.txt' or die "Cannot open stdout.txt: $!";
my $out = do { local $/; <$outfh> };
close $outfh;

open my $errfh, '<', 'stderr.txt' or die "Cannot open stderr.txt: $!";
my $err = do { local $/; <$errfh> };
close $errfh;

chdir $cwd or die $!;

is "$rc:$out$err", "0:ok\n", 'zero-upvalue C userdata finalizers complete exactly once';
