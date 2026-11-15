// Luau driver: a tagged userdata with a destructor registered for its tag,
// which is how an embedder gives Luau userdata a native finalizer.
#include "lua.h"
#include "lualib.h"
#include "h2h.h"

static void ud_dtor(lua_State *L, void *p)
{
  (void)L;
  (void)p;
  dtor_calls++;
}

// By default the metatable is set with the same three calls LuaJIT needs.
// -DH2H_ONECALL uses Luau's single call for a tagged userdata with metatable.
#ifdef H2H_ONECALL
#define NAME "luau-onecall"
#define NEWUD(L) lua_newuserdatataggedwithmetatable(L, PAYLOAD, 7)
#else
#define NAME "luau"
#define NEWUD(L) \
  do { \
    lua_newuserdatatagged(L, PAYLOAD, 7); \
    lua_pushvalue(L, 1); \
    lua_setmetatable(L, -2); \
  } while (0)
#endif
#define SETUP(L) \
  do { \
    lua_setuserdatadtor(L, 7, ud_dtor); \
    lua_newtable(L); \
    lua_pushvalue(L, -1); \
    lua_setuserdatametatable(L, 7); \
  } while (0)

#include "h2h_main.h"
