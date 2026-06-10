/*
** Userdata handling.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#define lj_udata_c
#define LUA_CORE

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_err.h"
#include "lj_udata.h"

#if LJ_HAS_UDATA_CACHE
#ifndef LUAJIT_UDATA_CACHE_MAXBYTES
#define LUAJIT_UDATA_CACHE_MAXBYTES	((GCSize)16u << 20)
#endif
#define UDATA_CACHE_MAX_PAYLOAD	256u

static LJ_AINLINE GCudata *udata_cache_get(global_State *g, MSize sz,
					   MSize size)
{
  GCudata *ud;
  if (sz > UDATA_CACHE_MAX_PAYLOAD) return NULL;
  ud = (GCudata *)gcref(g->gc.udata_cache[sz]);
  if (ud == NULL) return NULL;
  /* Cached blocks are detached raw allocator blocks, not GC roots. */
  lj_assertG(ud->udtype == UDTYPE_USERDATA && ud->len == sz,
	     "userdata cache exact-size invariant failed");
  setgcrefr(g->gc.udata_cache[sz], ud->nextgc);
  g->gc.udata_cache_bytes -= size;
  g->gc.total += size;
  lj_gc_stats_inc(g, udata_cache_hits);
  if (sz == 0)
    lj_gc_stats_inc(g, udata_cache_hit_0_calls);
  else if (sz <= 16)
    lj_gc_stats_inc(g, udata_cache_hit_1_16_calls);
  else if (sz <= 32)
    lj_gc_stats_inc(g, udata_cache_hit_17_32_calls);
  else if (sz <= 64)
    lj_gc_stats_inc(g, udata_cache_hit_33_64_calls);
  else if (sz <= 128)
    lj_gc_stats_inc(g, udata_cache_hit_65_128_calls);
  else
    lj_gc_stats_inc(g, udata_cache_hit_129_256_calls);
  return ud;
}
#endif

GCudata *lj_udata_new(lua_State *L, MSize sz, GCtab *env)
{
  MSize size = sizeof(GCudata) + sz;
  global_State *g = G(L);
  GCudata *ud;
#if LJ_HAS_UDATA_CACHE
  ud = udata_cache_get(g, sz, size);
  if (ud == NULL) {
    lj_gc_stats_inc(g, udata_cache_misses);
    ud = lj_mem_newt(L, size, GCudata);
  }
#else
  ud = lj_mem_newt(L, size, GCudata);
#endif
  lj_gc_stats_inc(g, new_udata_calls);
  lj_gc_stats_add(g, new_udata_bytes, size);
  lj_gc_stats_add(g, new_udata_payload_bytes, sz);
#ifdef LUAJIT_ENABLE_GCSTATS
  if (sz == 0)
    lj_gc_stats_inc(g, new_udata_payload_0_calls);
  else if (sz <= 16)
    lj_gc_stats_inc(g, new_udata_payload_1_16_calls);
  else if (sz <= 32)
    lj_gc_stats_inc(g, new_udata_payload_17_32_calls);
  else if (sz <= 64)
    lj_gc_stats_inc(g, new_udata_payload_33_64_calls);
  else if (sz <= 128)
    lj_gc_stats_inc(g, new_udata_payload_65_128_calls);
  else if (sz <= 256)
    lj_gc_stats_inc(g, new_udata_payload_129_256_calls);
  else
    lj_gc_stats_inc(g, new_udata_payload_gt_256_calls);
#endif
  newwhite(g, ud);  /* Not finalized. */
  ud->gct = ~LJ_TUDATA;
  ud->udtype = UDTYPE_USERDATA;
  ud->len = sz;
  /* NOBARRIER: The GCudata is new (marked white). */
  setgcrefnull(ud->metatable);
  setgcref(ud->env, obj2gco(env));
  /* Chain to userdata list (after main thread). */
  setgcrefr(ud->nextgc, mainthread(g)->nextgc);
  setgcref(mainthread(g)->nextgc, obj2gco(ud));
  return ud;
}

void LJ_FASTCALL lj_udata_free(global_State *g, GCudata *ud)
{
#if LJ_HAS_UDATA_CACHE
  MSize sz = ud->len;
  MSize size = sizeudata(ud);
  if (ud->udtype == UDTYPE_USERDATA && sz <= UDATA_CACHE_MAX_PAYLOAD &&
      g->gc.udata_cache_bytes + size <= LUAJIT_UDATA_CACHE_MAXBYTES) {
    /* lj_udata_free() is reached only after finalizers have run and sweep has
    ** detached the object. Reuse nextgc as a raw freelist link; the GC must not
    ** traverse cache lists because cached blocks are no longer live objects.
    */
    lj_assertG(size == sizeof(GCudata) + sz,
	       "userdata cache exact-size invariant failed");
    setgcrefr(ud->nextgc, g->gc.udata_cache[sz]);
    setgcref(g->gc.udata_cache[sz], obj2gco(ud));
    g->gc.udata_cache_bytes += size;
    g->gc.total -= size;
    lj_gc_stats_inc(g, udata_cache_puts);
    return;
  }
  lj_gc_stats_inc(g, udata_cache_drops);
#endif
  lj_mem_free(g, ud, sizeudata(ud));
}

#if LJ_HAS_UDATA_CACHE
void lj_udata_cache_freeall(global_State *g)
{
  MSize sz;
  for (sz = 0; sz <= UDATA_CACHE_MAX_PAYLOAD; sz++) {
    GCudata *ud = (GCudata *)gcref(g->gc.udata_cache[sz]);
    setgcrefnull(g->gc.udata_cache[sz]);
    while (ud) {
      GCudata *next = (GCudata *)gcref(ud->nextgc);
      MSize size = sizeudata(ud);
      lj_assertG(ud->udtype == UDTYPE_USERDATA && ud->len == sz &&
		 size == sizeof(GCudata) + sz,
		 "userdata cache exact-size invariant failed");
      g->allocf(g->allocd, ud, size, 0);
      ud = next;
    }
  }
  g->gc.udata_cache_bytes = 0;
}
#endif

#if LJ_64
void *lj_lightud_intern(lua_State *L, void *p)
{
  global_State *g = G(L);
  uint64_t u = (uint64_t)p;
  uint32_t up = lightudup(u);
  uint32_t *segmap = mref(g->gc.lightudseg, uint32_t);
  MSize segnum = g->gc.lightudnum;
  if (segmap) {
    MSize seg;
    for (seg = 0; seg <= segnum; seg++)
      if (segmap[seg] == up)  /* Fast path. */
	return (void *)(((uint64_t)seg << LJ_LIGHTUD_BITS_LO) | lightudlo(u));
    segnum++;
    /* Leave last segment unused to avoid clash with ITERN key. */
    if (segnum >= (1 << LJ_LIGHTUD_BITS_SEG)-1) lj_err_msg(L, LJ_ERR_BADLU);
  }
  if (!((segnum-1) & segnum) && segnum != 1) {
    lj_mem_reallocvec(L, segmap, segnum, segnum ? 2*segnum : 2u, uint32_t);
    setmref(g->gc.lightudseg, segmap);
  }
  g->gc.lightudnum = segnum;
  segmap[segnum] = up;
  return (void *)(((uint64_t)segnum << LJ_LIGHTUD_BITS_LO) | lightudlo(u));
}
#endif
