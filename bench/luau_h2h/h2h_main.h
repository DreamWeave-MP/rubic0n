/* Benchmark body. See h2h.h. */

static void collect(lua_State *L)
{
  lua_gc(L, LUA_GCRESTART, 0);
  lua_gc(L, LUA_GCCOLLECT, 0);
  lua_gc(L, LUA_GCCOLLECT, 0);
}

int main(int argc, char **argv)
{
  int n = argc > 1 ? atoi(argv[1]) : 200000;
  int rounds = argc > 2 ? atoi(argv[2]) : 31;
  const char *name = argc > 3 ? argv[3] : NAME;
  static double ca[MAXROUNDS], cc[MAXROUNDS], fa[MAXROUNDS], fc[MAXROUNDS];
  static double ta[MAXROUNDS], tc[MAXROUNDS];
  lua_State *L = luaL_newstate();
  int r, i;
  if (L == NULL || n < 2 || rounds < 1) return 1;
  if (rounds > MAXROUNDS) rounds = MAXROUNDS;
  SETUP(L);  /* Leaves the userdata metatable at stack index 1. */
  for (r = -2; r < rounds; r++) {  /* Two warmup rounds. */
    double t0, t1, t2;

    lua_gc(L, LUA_GCSTOP, 0);
    t0 = now_s();
    for (i = 0; i < n; i++) { NEWUD(L); lua_pop(L, 1); }
    t1 = now_s();
    collect(L);
    t2 = now_s();
    if (r >= 0) { ca[r] = (t1-t0)*1e9/n; cc[r] = (t2-t1)*1e9/n; }

    lua_gc(L, LUA_GCSTOP, 0);
    lua_createtable(L, n/2, 0);
    t0 = now_s();
    for (i = 0; i < n; i++) {
      NEWUD(L);
      if (i & 1) lua_rawseti(L, -2, i/2+1); else lua_pop(L, 1);
    }
    t1 = now_s();
    collect(L);
    t2 = now_s();
    if (r >= 0) { fa[r] = (t1-t0)*1e9/n; fc[r] = (t2-t1)*1e9/n; }
    /* Refill the holes while the survivors are rooted, then drop it all. */
    lua_gc(L, LUA_GCSTOP, 0);
    for (i = 0; i < n/2; i++) { NEWUD(L); lua_pop(L, 1); }
    lua_pop(L, 1);
    collect(L);

    lua_gc(L, LUA_GCSTOP, 0);
    t0 = now_s();
    for (i = 0; i < n; i++) { lua_createtable(L, 0, 0); lua_pop(L, 1); }
    t1 = now_s();
    collect(L);
    t2 = now_s();
    if (r >= 0) { ta[r] = (t1-t0)*1e9/n; tc[r] = (t2-t1)*1e9/n; }
  }
  printf("%-14s n=%-7d churn %5.1f / %5.1f   half-retained %5.1f / %5.1f   "
	 "table %5.1f / %5.1f   (ns per object: allocate / collect)\n",
	 name, n, median(ca, rounds), median(cc, rounds),
	 median(fa, rounds), median(fc, rounds),
	 median(ta, rounds), median(tc, rounds));
  lua_close(L);
  if (dtor_calls == 0) { fprintf(stderr, "no destructor ran\n"); return 1; }
  return 0;
}
