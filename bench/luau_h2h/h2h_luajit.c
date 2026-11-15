/* LuaJIT driver: a zero-upvalue C __gc, as Sol installs for bound types. */
#include "lua.h"
#include "lauxlib.h"
#include "h2h.h"

static int ud_gc(lua_State *L)
{
  (void)L;
  dtor_calls++;
  return 0;
}

#define NAME "luajit"
#define SETUP(L) \
  do { \
    lua_newtable(L); \
    lua_pushcfunction(L, ud_gc); \
    lua_setfield(L, -2, "__gc"); \
  } while (0)
#define NEWUD(L) \
  do { \
    lua_newuserdata(L, PAYLOAD); \
    lua_pushvalue(L, 1); \
    lua_setmetatable(L, -2); \
  } while (0)

#include "h2h_main.h"
