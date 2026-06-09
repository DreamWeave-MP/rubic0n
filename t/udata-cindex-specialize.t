# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

my $luajit = abs_path("$Bin/../src/luajit");

plan skip_all => "src/luajit is not built" unless defined $luajit && -x $luajit;

my $jit_status = `"$luajit" -e 'os.exit(jit and jit.status() and 0 or 1)' 2>&1`;
plan skip_all => "LuaJIT built without JIT support" if $? != 0;

my $cc = $ENV{CC} || "cc";
system("$cc --version >/dev/null 2>&1");
plan skip_all => "C compiler '$cc' is not available" if $? == -1 || ($? >> 8) == 127;

my $cwd = cwd;
my $dir = tempdir "testlj_udata_cindex_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $c, '>', 'cindexspec.c' or die "Cannot open cindexspec.c: $!";
print $c <<'C';
#include <string.h>
#include "lua.h"
#include "lauxlib.h"

typedef struct Obj {
  int position;
  int health;
} Obj;

static int index_count;

static int obj_index(lua_State *L)
{
  Obj *o = (Obj *)luaL_checkudata(L, 1, "cindexspec.obj");
  const char *key = luaL_checkstring(L, 2);
  index_count++;
  if (strcmp(key, "position") == 0) {
    lua_pushinteger(L, o->position);
  } else if (strcmp(key, "health") == 0) {
    lua_pushinteger(L, o->health);
  } else {
    lua_pushnil(L);
  }
  return 1;
}

static int new_obj(lua_State *L)
{
  Obj *o = (Obj *)lua_newuserdata(L, sizeof(Obj));
  o->position = luaL_checkinteger(L, 1);
  o->health = luaL_checkinteger(L, 2);
  luaL_getmetatable(L, "cindexspec.obj");
  lua_setmetatable(L, -2);
  return 1;
}

static int reset_count(lua_State *L)
{
  index_count = 0;
  return 0;
}

static int get_count(lua_State *L)
{
  lua_pushinteger(L, index_count);
  return 1;
}

static int set_index(lua_State *L)
{
  luaL_checkany(L, 1);
  luaL_getmetatable(L, "cindexspec.obj");
  lua_pushvalue(L, 1);
  lua_setfield(L, -2, "__index");
  return 0;
}

static int restore_index(lua_State *L)
{
  luaL_getmetatable(L, "cindexspec.obj");
  lua_pushcfunction(L, obj_index);
  lua_setfield(L, -2, "__index");
  return 0;
}

LUALIB_API int luaopen_cindexspec(lua_State *L)
{
  luaL_newmetatable(L, "cindexspec.obj");
  lua_pushcfunction(L, obj_index);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  lua_newtable(L);
  lua_pushcfunction(L, new_obj);
  lua_setfield(L, -2, "new");
  lua_pushcfunction(L, reset_count);
  lua_setfield(L, -2, "reset");
  lua_pushcfunction(L, get_count);
  lua_setfield(L, -2, "count");
  lua_pushcfunction(L, set_index);
  lua_setfield(L, -2, "set_index");
  lua_pushcfunction(L, restore_index);
  lua_setfield(L, -2, "restore_index");
  return 1;
}
C
close $c;

my @compile = ($cc, "-shared", "-fPIC", "-I$Bin/../src", "-o", "cindexspec.so", "cindexspec.c");
my $compile_out = `@compile 2>&1`;
my $compile_rc = $? >> 8;
if ($compile_rc != 0 && $compile_out =~ /not found|No such file|command not found/i) {
  plan skip_all => "C compiler '$cc' is not available";
}
die "Cannot compile cindexspec.so with '@compile':\n$compile_out" if $compile_rc != 0;

plan tests => 1;

$ENV{LUA_CPATH} = "$dir/?.so;$Bin/../?.so;;";
$ENV{LUA_PATH} = "$Bin/../lua/?.lua;;";

open my $lua, '>', 'test.lua' or die "Cannot open test.lua: $!";
print $lua <<'LUA';
local m = require "cindexspec"
local jutil = require "jit.util"

jit.opt.start("hotloop=1")

local o = m.new(7, 11)
local keys = { "position", "health" }

local function hot(n)
  local sum = 0
  for i = 1, n do
    local k = keys[i % 2 + 1]
    sum = sum + o[k]
  end
  return sum
end

m.reset()
jit.flush()
local before = jutil.traceinfo(1)
local sum = hot(120)
local after = jutil.traceinfo(1)
assert(sum == 1080, sum)
assert(m.count() == 120, m.count())
assert(before == nil and after ~= nil, "expected hot loop trace")

m.set_index(function(_, key)
  if key == "position" then
    return 101
  elseif key == "health" then
    return 103
  end
end)

m.reset()
local changed = hot(40)
assert(changed == 4080, changed)
assert(m.count() == 0, m.count())

m.set_index({ position = 5, health = 13 })
local table_index = hot(40)
assert(table_index == 360, table_index)

print("ok")
LUA
close $lua;

my $out = `"$luajit" test.lua 2>&1`;
my $rc = $? >> 8;
is "$rc:$out", "0:ok\n", "C __index userdata key specialization preserves calls and guards metatable changes";

chdir $cwd or die $!;
