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
my $dir = tempdir "testlj_sweep_udata_inline_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $c, '>', 'sweepinline.c' or die "Cannot open sweepinline.c: $!";
print $c <<'C';
#include "lua.h"
#include "lauxlib.h"

#include <string.h>

#define MAXID 400000

/* Per-object finalization counts catch double and missed finalization. */
static unsigned char seen[MAXID];
static int count_leaf, count_closure, count_spawn, count_errors;

typedef struct Box { int id; int magic; } Box;

static Box *checkbox(lua_State *L)
{
  Box *b;
  if (lua_gettop(L) != 1 || lua_type(L, 1) != LUA_TUSERDATA) {
    count_errors++;
    return NULL;
  }
  b = (Box *)lua_touserdata(L, 1);
  if (b == NULL || b->magic != 0x600DF00D || b->id < 0 || b->id >= MAXID) {
    count_errors++;
    return NULL;
  }
  if (seen[b->id]++) count_errors++;
  b->magic = 0;
  return b;
}

/* Zero-upvalue C finalizer: finalized and freed by the sweep itself. */
static int leaf_gc(lua_State *L)
{
  if (checkbox(L)) count_leaf++;
  return 0;
}

/* C closure with an upvalue: queued for the finalize phase. */
static int closure_gc(lua_State *L)
{
  if (checkbox(L)) count_closure++;
  return 0;
}

/*
** Zero-upvalue C finalizer that creates a finalizable userdata of its own
** while the sweep holds its position in the list it links into, and that
** uses more stack than a destructor usually would.
*/
static int spawn_gc(lua_State *L)
{
  Box *b = checkbox(L);
  if (b != NULL) {
    Box *n;
    int i;
    count_spawn++;
    if (!lua_checkstack(L, 64)) { count_errors++; return 0; }
    for (i = 0; i < 48; i++) lua_pushinteger(L, i);
    lua_pop(L, 48);
    if (b->id + MAXID/2 < MAXID) {
      n = (Box *)lua_newuserdata(L, sizeof(Box));
      n->id = b->id + MAXID/2;
      n->magic = 0x600DF00D;
      luaL_getmetatable(L, "sweepinline.leaf");
      lua_setmetatable(L, -2);
      lua_pop(L, 1);
    }
  }
  return 0;
}

static int newbox(lua_State *L)
{
  const char *kind = luaL_checkstring(L, 1);
  int id = (int)luaL_checkinteger(L, 2);
  Box *b;
  luaL_argcheck(L, id >= 0 && id < MAXID, 2, "id out of range");
  /* Fetch the metatable first: see the static finalizer scan contract. */
  if (strcmp(kind, "none") != 0) luaL_getmetatable(L, kind);
  b = (Box *)lua_newuserdata(L, sizeof(Box));
  b->id = id;
  b->magic = 0x600DF00D;
  if (strcmp(kind, "none") != 0) {
    lua_pushvalue(L, -2);
    lua_setmetatable(L, -2);
  }
  return 1;
}

static int counters(lua_State *L)
{
  lua_pushinteger(L, count_leaf);
  lua_pushinteger(L, count_closure);
  lua_pushinteger(L, count_spawn);
  lua_pushinteger(L, count_errors);
  return 4;
}

static int seencount(lua_State *L)
{
  int lo = (int)luaL_checkinteger(L, 1), hi = (int)luaL_checkinteger(L, 2);
  int i, n = 0;
  for (i = lo; i < hi; i++) n += seen[i];
  lua_pushinteger(L, n);
  return 1;
}

static int reset(lua_State *L)
{
  (void)L;
  memset(seen, 0, sizeof(seen));
  count_leaf = count_closure = count_spawn = count_errors = 0;
  return 0;
}

static void newmeta(lua_State *L, const char *name, lua_CFunction gc, int nup)
{
  luaL_newmetatable(L, name);
  if (nup) lua_pushinteger(L, 1);
  lua_pushcclosure(L, gc, nup);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
}

LUALIB_API int luaopen_sweepinline(lua_State *L)
{
  newmeta(L, "sweepinline.leaf", leaf_gc, 0);
  newmeta(L, "sweepinline.leaf2", leaf_gc, 0);
  newmeta(L, "sweepinline.closure", closure_gc, 1);
  newmeta(L, "sweepinline.spawn", spawn_gc, 0);
  luaL_newmetatable(L, "sweepinline.plain");  /* No __gc. */
  lua_pop(L, 1);
  lua_newtable(L);
  lua_pushcfunction(L, newbox);
  lua_setfield(L, -2, "new");
  lua_pushcfunction(L, counters);
  lua_setfield(L, -2, "counters");
  lua_pushcfunction(L, seencount);
  lua_setfield(L, -2, "seen");
  lua_pushcfunction(L, reset);
  lua_setfield(L, -2, "reset");
  return 1;
}
C
close $c;

my @compile = ($cc, "-shared", "-fPIC", "-I$Bin/../src", "-o", "sweepinline.so", "sweepinline.c");
my $compile_out = `@compile 2>&1`;
my $compile_rc = $? >> 8;
if ($compile_rc != 0 && $compile_out =~ /not found|No such file|command not found/i) {
    plan skip_all => "C compiler '$cc' is not available";
}
die "Cannot compile sweepinline.so with '@compile':\n$compile_out" if $compile_rc != 0;

$ENV{LUA_CPATH} = "$dir/?.so;$Bin/../?.so;;";
$ENV{LUA_PATH} = "$Bin/../lua/?.lua;;";

open my $lua, '>', 'test.lua' or die "Cannot open test.lua: $!";
print $lua <<'LUA';
local m = require "sweepinline"
local new = m.new
local stats = jit.gcstats

local function full()
  collectgarbage("collect")
  collectgarbage("collect")
end

local function check(leaf, closure, spawn)
  local l, c, s, e = m.counters()
  assert(e == 0, "finalizer saw a bad object or ran twice: " .. e)
  assert(l == leaf, "leaf finalizers: " .. l .. " ~= " .. leaf)
  assert(c == closure, "closure finalizers: " .. c .. " ~= " .. closure)
  assert(s == spawn, "spawn finalizers: " .. s .. " ~= " .. spawn)
end

-- 1. Runs of one metatable, exactly once each, with nothing queued.
do
  full(); m.reset()
  if stats then stats(true) end
  for i = 0, 9999 do new("sweepinline.leaf", i) end
  full()
  check(10000, 0, 0)
  assert(m.seen(0, 10000) == 10000)
  if stats then
    local s = stats()
    assert(s.sweep_udata_finalized == 10000, s.sweep_udata_finalized)
    assert(s.finalizer_queued == 0, s.finalizer_queued)
    assert(s.finalizer_nonresurrecting_cfunc_frees == 10000)
  end
end

-- 2. Metatables change from one object to the next within a sweep step:
-- direct, another direct, queued, no finalizer, no metatable, and survivors
-- of each kind in between.
do
  local kinds = { "sweepinline.leaf", "sweepinline.closure", "sweepinline.plain",
		  "none", "sweepinline.leaf2", "sweepinline.closure",
		  "sweepinline.leaf" }
  local keep = {}
  full(); m.reset()
  local leaf, closure = 0, 0
  for i = 0, 20999 do
    local kind = kinds[i % #kinds + 1]
    local u = new(kind, i)
    if i % 3 == 0 then
      keep[#keep+1] = u
    elseif kind == "sweepinline.leaf" or kind == "sweepinline.leaf2" then
      leaf = leaf + 1
    elseif kind == "sweepinline.closure" then
      closure = closure + 1
    end
  end
  full()
  check(leaf, closure, 0)
  -- Survivors are untouched and get finalized once they die.
  local l2, c2 = 0, 0
  for i = 1, #keep do
    local mt = getmetatable(keep[i])
    local reg = debug.getregistry()
    if mt == reg["sweepinline.leaf"] or mt == reg["sweepinline.leaf2"] then
      l2 = l2 + 1
    elseif mt == reg["sweepinline.closure"] then
      c2 = c2 + 1
    end
  end
  keep = nil
  full()
  check(leaf + l2, closure + c2, 0)
end

-- 3. A finalizer that allocates finalizable userdata and uses the stack.
do
  full(); m.reset()
  for i = 0, 2999 do new("sweepinline.spawn", i) end
  full()  -- Finalizes the spawners. Their children die in the same call.
  full()
  check(3000, 0, 3000)
  assert(m.seen(0, 3000) == 3000)
  assert(m.seen(200000, 203000) == 3000)
end

-- 4. Incremental collection in small steps while allocation continues.
do
  full(); m.reset()
  local live = {}
  local dead = 0
  for i = 0, 59999 do
    local u = new(i % 5 == 0 and "sweepinline.closure" or "sweepinline.leaf", i)
    if i % 16 == 0 then
      live[#live+1] = u
      if #live > 64 then table.remove(live, 1); dead = dead + 1 end
    else
      dead = dead + 1
    end
    if i % 7 == 0 then collectgarbage("step", 0) end
  end
  dead = dead + #live
  live = nil
  full()
  local l, c, s, e = m.counters()
  assert(e == 0, e)
  assert(l + c == dead and s == 0, (l + c) .. " ~= " .. dead)
  assert(m.seen(0, 60000) == 60000)
end

-- 5. GC steps taken from compiled code: finalizers never run on a trace, so
-- dead userdata met by such a step go through the queue instead.
do
  full(); m.reset()
  if stats then stats(true) end
  jit.opt.start("hotloop=2")
  local n = 0
  for round = 1, 40 do
    for i = 1, 500 do new("sweepinline.leaf", n); n = n + 1 end
    local t
    for i = 1, 3000 do t = { i, i + 1, tostring(i % 7) } end
  end
  full()
  check(n, 0, 0)
  assert(m.seen(0, n) == n)
end

-- 6. Memory accounting returns to where it started.
do
  full(); m.reset()
  local before = collectgarbage("count")
  collectgarbage("stop")
  for i = 0, 49999 do new("sweepinline.leaf", i) end
  assert(collectgarbage("count") > before + 2000)
  collectgarbage("restart")
  full()
  local after = collectgarbage("count")
  assert(after < before + 64, after - before)
  check(50000, 0, 0)
end

print("ok")
LUA
close $lua;

my $out = `"$luajit" test.lua 2>&1`;
my $rc = $? >> 8;

chdir $cwd or die $!;

is "$rc:$out", "0:ok\n",
    'userdata finalized by the sweep step run exactly once and stay consistent';
done_testing();
