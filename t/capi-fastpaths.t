# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

my $lib = abs_path("$Bin/../src/libluajit.a");
plan skip_all => 'src/libluajit.a is not built' unless defined $lib && -f $lib;

my $cc = $ENV{CC} || 'cc';
system("$cc --version >/dev/null 2>&1");
plan skip_all => "C compiler '$cc' is not available" if $? == -1 || ($? >> 8) == 127;

my $cwd = cwd;
my $dir = tempdir 'testlj_capi_fastpaths_XXXXXXX', CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $c, '>', 'capifast.c' or die $!;
print $c <<'C';
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(c) \
  do { if (!(c)) { failures++; \
       fprintf(stderr, "line %d: %s\n", __LINE__, #c); } } while (0)

static int index_calls;

static int count_index(lua_State *L)
{
  index_calls++;
  lua_pushfstring(L, "meta:%s", lua_tostring(L, 2));
  return 1;
}

/* One buffer, many contents: the cache is keyed by address only. */
static void same_address_different_contents(lua_State *L)
{
  static const char *const words[] = {
    "alpha", "alph", "alphabet", "", "a", "beta", "alpha", "", "alphabet"
  };
  char buf[64];
  size_t i, round;
  for (round = 0; round < 3; round++) {
    for (i = 0; i < sizeof(words)/sizeof(words[0]); i++) {
      size_t len;
      const char *s;
      strcpy(buf, words[i]);
      lua_pushstring(L, buf);
      s = lua_tolstring(L, -1, &len);
      CHECK(len == strlen(words[i]) && strcmp(s, words[i]) == 0);
      lua_pushstring(L, buf);  /* Same address, same contents. */
      CHECK(lua_rawequal(L, -1, -2));
      lua_pushlstring(L, words[i], strlen(words[i]));
      CHECK(lua_rawequal(L, -1, -2));
      lua_pop(L, 3);
    }
  }
}

/* Field access by name from one buffer, against plain and proxied tables. */
static void getfield_semantics(lua_State *L)
{
  char buf[32];
  int i;
  lua_newtable(L);  /* 1: plain table. */
  for (i = 0; i < 50; i++) {
    sprintf(buf, "key%d", i);
    lua_pushinteger(L, i);
    lua_setfield(L, 1, buf);
  }
  lua_pushboolean(L, 0);
  lua_setfield(L, 1, "falsy");
  for (i = 149; i >= 0; i--) {
    sprintf(buf, "key%d", i % 75);
    lua_getfield(L, 1, buf);
    if (i % 75 < 50)
      CHECK(lua_isnumber(L, -1) && lua_tointeger(L, -1) == i % 75);
    else
      CHECK(lua_isnil(L, -1));
    lua_pop(L, 1);
  }
  lua_getfield(L, 1, "falsy");  /* false is a hit, not a miss. */
  CHECK(lua_isboolean(L, -1) && !lua_toboolean(L, -1));
  lua_pop(L, 1);

  lua_newtable(L);  /* 2: metatable with an __index function. */
  lua_pushcfunction(L, count_index);
  lua_setfield(L, 2, "__index");
  lua_pushvalue(L, 2);
  lua_setmetatable(L, 1);
  index_calls = 0;
  lua_getfield(L, 1, "key7");  /* Raw hit: no metamethod call. */
  CHECK(lua_tointeger(L, -1) == 7 && index_calls == 0);
  lua_pop(L, 1);
  lua_getfield(L, 1, "missing");  /* Raw miss: metamethod call. */
  CHECK(index_calls == 1 && strcmp(lua_tostring(L, -1), "meta:missing") == 0);
  lua_pop(L, 1);
  lua_pushnil(L);
  lua_setfield(L, 1, "key7");  /* Removed: now a miss as well. */
  lua_getfield(L, 1, "key7");
  CHECK(index_calls == 2 && strcmp(lua_tostring(L, -1), "meta:key7") == 0);
  lua_pop(L, 1);

  lua_newuserdata(L, 8);  /* 3: userdata with the same metatable. */
  lua_pushvalue(L, 2);
  lua_setmetatable(L, 3);
  lua_getfield(L, 3, "field");
  CHECK(index_calls == 3 && strcmp(lua_tostring(L, -1), "meta:field") == 0);
  lua_pop(L, 1);

  lua_newtable(L);  /* 4: __index is a table: a chain of plain lookups. */
  lua_newtable(L);
  lua_pushvalue(L, 1);
  lua_setfield(L, -2, "__index");
  lua_setmetatable(L, 4);
  lua_getfield(L, 4, "key9");
  CHECK(lua_tointeger(L, -1) == 9);
  lua_pop(L, 1);

  lua_pushinteger(L, 42);  /* Globals and registry by pseudo-index. */
  lua_setfield(L, LUA_GLOBALSINDEX, "capifast_global");
  lua_getfield(L, LUA_GLOBALSINDEX, "capifast_global");
  CHECK(lua_tointeger(L, -1) == 42);
  lua_pop(L, 1);
  luaL_newmetatable(L, "capifast.meta");
  luaL_getmetatable(L, "capifast.meta");
  CHECK(lua_rawequal(L, -1, -2));
  lua_getfield(L, LUA_REGISTRYINDEX, "capifast.meta");
  CHECK(lua_rawequal(L, -1, -2));
  lua_settop(L, 0);
}

/*
** Strings that only the cache knows are collected like any other. Interning
** from the same address afterwards must not hand out the freed string.
*/
static void cache_is_not_a_root(lua_State *L)
{
  static char names[256][24];
  int i, round;
  int before, after;
  lua_gc(L, LUA_GCCOLLECT, 0);
  before = lua_gc(L, LUA_GCCOUNT, 0);
  for (round = 0; round < 400; round++) {
    for (i = 0; i < 256; i++) {
      const char *s;
      sprintf(names[i], "transient-%d-%d", round, i);
      lua_pushstring(L, names[i]);
      s = lua_tostring(L, -1);
      CHECK(strcmp(s, names[i]) == 0);
      lua_pop(L, 1);
      if ((i & 31) == 0) lua_gc(L, LUA_GCSTEP, 0);
    }
    if (round % 50 == 0) lua_gc(L, LUA_GCCOLLECT, 0);
    /* The contents changed under every cached address. Hit them all again. */
    for (i = 0; i < 256; i++) {
      lua_pushstring(L, names[i]);
      CHECK(strcmp(lua_tostring(L, -1), names[i]) == 0);
      lua_pop(L, 1);
    }
  }
  lua_gc(L, LUA_GCCOLLECT, 0);
  lua_gc(L, LUA_GCCOLLECT, 0);
  after = lua_gc(L, LUA_GCCOUNT, 0);
  CHECK(after <= before + 256);  /* 102400 distinct strings did not pile up. */
  /* A string interned once and then only reachable through the cache. */
  for (round = 0; round < 50; round++) {
    lua_pushstring(L, "capifast-kept-by-nobody");
    lua_pop(L, 1);
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_pushstring(L, "capifast-kept-by-nobody");
    CHECK(strcmp(lua_tostring(L, -1), "capifast-kept-by-nobody") == 0);
    lua_pushliteral(L, "capifast-kept-by-nobody");
    CHECK(lua_rawequal(L, -1, -2));
    lua_pop(L, 2);
  }
}

static void rawequal_semantics(lua_State *L)
{
  static int anchor1, anchor2;
  lua_settop(L, 0);
  lua_pushnumber(L, 1.5);			/* 1 */
  lua_pushnumber(L, 1.5);			/* 2 */
  lua_pushnumber(L, NAN);			/* 3 */
  lua_pushvalue(L, 3);				/* 4 */
  lua_pushnumber(L, 0.0);			/* 5 */
  lua_pushnumber(L, -0.0);			/* 6 */
  lua_pushliteral(L, "str");			/* 7 */
  lua_pushstring(L, "str");			/* 8 */
  lua_pushliteral(L, "other");			/* 9 */
  lua_newtable(L);				/* 10 */
  lua_pushvalue(L, 10);				/* 11 */
  lua_newtable(L);				/* 12 */
  lua_pushboolean(L, 1);			/* 13 */
  lua_pushboolean(L, 1);			/* 14 */
  lua_pushboolean(L, 0);			/* 15 */
  lua_pushnil(L);				/* 16 */
  lua_pushnil(L);				/* 17 */
  lua_pushlightuserdata(L, &anchor1);		/* 18 */
  lua_pushlightuserdata(L, &anchor1);		/* 19 */
  lua_pushlightuserdata(L, &anchor2);		/* 20 */
  lua_pushinteger(L, 1);			/* 21 */
  CHECK(lua_rawequal(L, 1, 2));
  CHECK(lua_rawequal(L, 1, 1));
  CHECK(!lua_rawequal(L, 3, 4));  /* NaN is not equal to itself. */
  CHECK(!lua_rawequal(L, 3, 3));
  CHECK(lua_rawequal(L, 5, 6));  /* But both zeros are equal. */
  CHECK(lua_rawequal(L, 7, 8));
  CHECK(!lua_rawequal(L, 7, 9));
  CHECK(lua_rawequal(L, 10, 11));
  CHECK(!lua_rawequal(L, 10, 12));
  CHECK(lua_rawequal(L, 13, 14));
  CHECK(!lua_rawequal(L, 13, 15));
  CHECK(lua_rawequal(L, 16, 17));
  CHECK(!lua_rawequal(L, 15, 16));
  CHECK(lua_rawequal(L, 18, 19));
  CHECK(!lua_rawequal(L, 18, 20));
  CHECK(!lua_rawequal(L, 13, 21));
  CHECK(!lua_rawequal(L, 1, 7));
  CHECK(!lua_rawequal(L, 16, 99));  /* Not an acceptable index. */
  CHECK(!lua_rawequal(L, 99, 98));
  CHECK(lua_rawequal(L, -1, 21));
  CHECK(lua_rawequal(L, LUA_REGISTRYINDEX, LUA_REGISTRYINDEX));
  CHECK(!lua_rawequal(L, LUA_REGISTRYINDEX, LUA_GLOBALSINDEX));
  lua_settop(L, 0);
}

/* Every kind of index still resolves, including upvalues and bad slots. */
static int index_kinds(lua_State *L)
{
  CHECK(lua_type(L, 1) == LUA_TNUMBER && lua_tointeger(L, 1) == 11);
  CHECK(lua_type(L, -1) == LUA_TSTRING);
  CHECK(lua_type(L, 3) == LUA_TNONE && lua_type(L, 40) == LUA_TNONE);
  CHECK(lua_tointeger(L, lua_upvalueindex(1)) == 101);
  CHECK(strcmp(lua_tostring(L, lua_upvalueindex(2)), "up2") == 0);
  CHECK(lua_type(L, lua_upvalueindex(3)) == LUA_TNONE);
  CHECK(lua_type(L, LUA_REGISTRYINDEX) == LUA_TTABLE);
  CHECK(lua_type(L, LUA_GLOBALSINDEX) == LUA_TTABLE);
  CHECK(lua_type(L, LUA_ENVIRONINDEX) == LUA_TTABLE);
  CHECK(lua_touserdata(L, 1) == NULL && lua_touserdata(L, 9) == NULL);
  CHECK(!lua_getmetatable(L, 1) && !lua_getmetatable(L, 9));
  return 0;
}

int main(void)
{
  lua_State *L = luaL_newstate();
  if (L == NULL) return 2;
  luaL_openlibs(L);
  same_address_different_contents(L);
  getfield_semantics(L);
  cache_is_not_a_root(L);
  rawequal_semantics(L);
  lua_pushinteger(L, 101);
  lua_pushliteral(L, "up2");
  lua_pushcclosure(L, index_kinds, 2);
  lua_pushinteger(L, 11);
  lua_pushliteral(L, "arg2");
  lua_call(L, 2, 0);
  lua_close(L);
  if (failures) return 1;
  puts("ok");
  return 0;
}
C
close $c;

my @compile = ($cc, '-O1', "-I$Bin/../src", '-o', 'capifast', 'capifast.c',
               $lib, '-lm', '-ldl');
my $compile_out = `@compile 2>&1`;
die "Cannot compile C API fast path test:\n$compile_out" if $? != 0;

system './capifast >stdout.txt 2>stderr.txt';
my $rc = $? >> 8;
open my $outfh, '<', 'stdout.txt' or die $!;
my $out = do { local $/; <$outfh> };
close $outfh;
open my $errfh, '<', 'stderr.txt' or die $!;
my $err = do { local $/; <$errfh> };
close $errfh;
chdir $cwd or die $!;

is "$rc:$out$err", "0:ok\n",
    'C string cache, lua_getfield, lua_rawequal and index resolution behave';
done_testing();
