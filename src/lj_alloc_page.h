/*
** Experimental segregated page allocator front end.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#ifndef _LJ_ALLOC_PAGE_H
#define _LJ_ALLOC_PAGE_H

#include "lj_def.h"

#if defined(LUAJIT_USE_PAGEALLOC) && defined(LUAJIT_USE_SYSMALLOC)
#error "LUAJIT_USE_PAGEALLOC requires LuaJIT's bundled allocator"
#endif

#if defined(LUAJIT_USE_PAGEALLOC) && !defined(LUAJIT_USE_SYSMALLOC)
LJ_FUNC void *lj_page_alloc_create(PRNGState *rs);
LJ_FUNC void lj_page_alloc_setprng(void *pas, PRNGState *rs);
LJ_FUNC void lj_page_alloc_destroy(void *pas);
LJ_FUNC void *lj_page_alloc_f(void *pas, void *ptr, size_t osize,
			      size_t nsize);

#ifdef LUAJIT_PAGEALLOC_TEST
typedef struct LJPageAllocTestStats {
  int backing_created;
  int backing_destroyed;
  int wrapper_created;
  int wrapper_destroyed;
  int setprng_calls;
  int request_calls;
  int pages_created;
  int pages_destroyed;
  int pooled_allocations;
  int pooled_frees;
} LJPageAllocTestStats;

LJ_FUNC void lj_page_alloc_test_reset(void);
LJ_FUNC void lj_page_alloc_test_fail_at(int request);
LJ_FUNC void lj_page_alloc_test_reject_pointer(int reject);
LJ_FUNC int lj_page_alloc_test_should_reject_pointer(void);
LJ_FUNC void lj_page_alloc_test_get_stats(LJPageAllocTestStats *stats);
#endif
#endif

#endif
