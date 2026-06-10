use v5.10.1;
use strict;
use warnings;
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

my $cc = $ENV{CC} || 'cc';
system "$cc --version >/dev/null 2>&1";
plan skip_all => "C compiler '$cc' is not available"
    if $? == -1 || ($? >> 8) == 127;

my $cwd = cwd;
my $dir = tempdir 'testlj_udata_cache_XXXXXXX', CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $c, '>', 'udcache.c' or die "Cannot open udcache.c: $!";
print $c <<'C';
#include <string.h>
#include "lua.h"
#include "lauxlib.h"

static int finalized;

static int udcache_gc(lua_State *L)
{
  luaL_checktype(L, 1, LUA_TUSERDATA);
  finalized++;
  return 0;
}

static int udcache_new(lua_State *L)
{
  size_t sz = (size_t)luaL_checkinteger(L, 1);
  int finalizable = lua_toboolean(L, 2);
  void *ud = lua_newuserdata(L, sz);
  if (sz != 0)
    memset(ud, 0xa5, sz);
  if (finalizable) {
    luaL_getmetatable(L, "udcache.finalizable");
    lua_setmetatable(L, -2);
  }
  return 1;
}

static int udcache_reset(lua_State *L)
{
  finalized = 0;
  return 0;
}

static int udcache_finalized(lua_State *L)
{
  lua_pushinteger(L, finalized);
  return 1;
}

LUALIB_API int luaopen_udcache(lua_State *L)
{
  luaL_newmetatable(L, "udcache.finalizable");
  lua_pushcfunction(L, udcache_gc);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);

  lua_newtable(L);
  lua_pushcfunction(L, udcache_new);
  lua_setfield(L, -2, "new");
  lua_pushcfunction(L, udcache_reset);
  lua_setfield(L, -2, "reset");
  lua_pushcfunction(L, udcache_finalized);
  lua_setfield(L, -2, "finalized");
  return 1;
}
C
close $c;

my @compile = ($cc, '-shared', '-fPIC', "-I$Bin/../src", '-o', 'udcache.so', 'udcache.c');
my $compile_out = `@compile 2>&1`;
my $compile_rc = $? >> 8;
if ($compile_rc != 0 && $compile_out =~ /not found|No such file|command not found/i) {
  chdir $cwd or die $!;
  plan skip_all => "C compiler '$cc' is not available";
}
die "Cannot compile udcache.so with '@compile':\n$compile_out" if $compile_rc != 0;

$ENV{LUA_CPATH} = "$dir/?.so;$Bin/../?.so;;";

my $script = <<'LUA';
local s = jit.gcstats()
if s.udata_cache_hits == nil then
  print("SKIP no udata cache stats")
  os.exit(77)
end

local fields = {
  "udata_cache_hits",
  "udata_cache_misses",
  "udata_cache_puts",
  "udata_cache_drops",
  "udata_cache_hit_0_calls",
  "udata_cache_hit_17_32_calls",
  "udata_cache_hit_65_128_calls",
  "udata_cache_bytes",
}
for _, name in ipairs(fields) do
  assert(type(s[name]) == "number", name)
end

local n = 6000
local finalized = 0
local mt = { __gc = function() finalized = finalized + 1 end }

local function collect_until_finalized(want)
  for _ = 1, 40 do
    collectgarbage("collect")
    if finalized == want then return end
  end
end

local function make_finalizable(count)
  collectgarbage("stop")
  local u
  for i = 1, count do
    u = newproxy(true)
    getmetatable(u).__gc = mt.__gc
  end
  u = nil
  collectgarbage("restart")
end

local function make_plain(count)
  local refs = {}
  for i = 1, count do refs[i] = newproxy(false) end
end

collectgarbage("collect")
jit.gcstats(true)

make_finalizable(n)

collect_until_finalized(n)
assert(finalized == n, finalized)
for _ = 1, 4 do collectgarbage("collect") end

local warm = jit.gcstats()
assert(warm.udata_cache_puts >= n * 0.8, warm.udata_cache_puts)
assert(warm.udata_cache_bytes > 0, warm.udata_cache_bytes)

jit.gcstats(true)
local before = jit.gcstats()
make_plain(n)
local after = jit.gcstats()

local logical = after.new_udata_calls - before.new_udata_calls
local allocs = after.alloc_calls - before.alloc_calls
local hits = after.udata_cache_hits - before.udata_cache_hits
local hit0 = after.udata_cache_hit_0_calls - before.udata_cache_hit_0_calls

assert(logical == n, logical)
assert(hits >= n * 0.8, hits)
assert(hit0 >= n * 0.8, hit0)
assert(allocs < logical / 5, allocs .. ":" .. logical)

make_finalizable(n)
collect_until_finalized(n * 2)
assert(finalized == n * 2, finalized)
for _ = 1, 4 do collectgarbage("collect") end

local c = require "udcache"
local boundary_sizes = { 0, 1, 16, 17, 32, 33, 64, 65, 128, 129, 256 }
local boundary_count = 640

local function collect_until_c_finalized(want)
  for _ = 1, 80 do
    collectgarbage("collect")
    if c.finalized() == want then return end
  end
end

local function c_make(size, count, finalizable)
  collectgarbage("stop")
  for _ = 1, count do c.new(size, finalizable) end
  collectgarbage("restart")
end

local function delta(after, before, name)
  return after[name] - before[name]
end

local function hit_bucket(size)
  if size == 0 then
    return "udata_cache_hit_0_calls"
  elseif size <= 16 then
    return "udata_cache_hit_1_16_calls"
  elseif size <= 32 then
    return "udata_cache_hit_17_32_calls"
  elseif size <= 64 then
    return "udata_cache_hit_33_64_calls"
  elseif size <= 128 then
    return "udata_cache_hit_65_128_calls"
  else
    return "udata_cache_hit_129_256_calls"
  end
end

local function warm_c_size(size, count)
  c.reset()
  c_make(size, count, true)
  collect_until_c_finalized(count)
  assert(c.finalized() == count, "finalized " .. size .. ":" .. c.finalized())
  for _ = 1, 6 do collectgarbage("collect") end
  assert(c.finalized() == count, "finalized " .. size .. ":" .. c.finalized())
end

local function check_c_hits(size, count)
  jit.gcstats(true)
  local before = jit.gcstats()
  c_make(size, count, false)
  local after = jit.gcstats()
  local logical = delta(after, before, "new_udata_calls")
  local allocs = delta(after, before, "alloc_calls")
  local hits = delta(after, before, "udata_cache_hits")
  local bucket_hits = delta(after, before, hit_bucket(size))

  assert(logical == count, "logical " .. size .. ":" .. logical)
  assert(hits >= count * 0.8, "hits " .. size .. ":" .. hits)
  assert(bucket_hits >= count * 0.8, "bucket " .. size .. ":" .. bucket_hits)
  assert(allocs < logical / 5, "allocs " .. size .. ":" .. allocs .. ":" .. logical)
end

collectgarbage("collect")
jit.gcstats(true)
warm_c_size(17, boundary_count)

jit.gcstats(true)
local before18 = jit.gcstats()
c_make(18, boundary_count, false)
local after18 = jit.gcstats()
assert(delta(after18, before18, "new_udata_calls") == boundary_count,
       delta(after18, before18, "new_udata_calls"))
assert(delta(after18, before18, "udata_cache_hits") == 0,
       "size 18 reused another exact-size cache bucket")
assert(delta(after18, before18, "udata_cache_misses") == boundary_count,
       delta(after18, before18, "udata_cache_misses"))

for _, size in ipairs(boundary_sizes) do
  warm_c_size(size, boundary_count)
  check_c_hits(size, boundary_count)
end

jit.gcstats(true)
warm_c_size(257, boundary_count)

jit.gcstats(true)
local before257 = jit.gcstats()
c_make(257, boundary_count, false)
local after257 = jit.gcstats()
assert(delta(after257, before257, "new_udata_calls") == boundary_count,
       delta(after257, before257, "new_udata_calls"))
assert(delta(after257, before257, "udata_cache_hits") == 0,
       "size 257 should not hit userdata cache")
assert(delta(after257, before257, "udata_cache_misses") == boundary_count,
       delta(after257, before257, "udata_cache_misses"))

if io and io.tmpfile then
  collectgarbage("collect")
  jit.gcstats(true)
  local ok_tmpfile, tmpfile = pcall(io.tmpfile)
  if ok_tmpfile and tmpfile then
    tmpfile:close()
    for _ = 1, 8 do collectgarbage("collect") end
    local after_tmpfile_free = jit.gcstats()
    assert(after_tmpfile_free.udata_cache_puts == 0,
           "io userdata must not be cached after udtype change")
  end
end

print("ok")
LUA

open my $lua, '>', 'test.lua' or die "Cannot open test.lua: $!";
print $lua $script;
close $lua;

my $out = `"$luajit" test.lua 2>&1`;
my $rc = $? >> 8;

chdir $cwd or die $!;

plan skip_all => 'LuaJIT built without LUAJIT_ENABLE_UDATA_CACHE'
    if $rc == 77;

plan tests => 1;
is "$rc:$out", "0:ok\n", 'full userdata exact-size cache works across payload boundaries';
