/*
** Experimental segregated page allocator front end.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
**
** Phase 1A deliberately forwards every request to the bundled allocator.
** This establishes allocator ownership, PRNG forwarding and state teardown
** before small allocations are moved onto segregated pages.
*/

#define lj_alloc_page_c
#define LUA_CORE

#include "lj_def.h"
#include "lj_alloc.h"
#include "lj_alloc_page.h"
#include "lj_prng.h"

#if defined(LUAJIT_USE_PAGEALLOC) && !defined(LUAJIT_USE_SYSMALLOC)

typedef struct LJPageAllocState {
  void *backing;
} LJPageAllocState;

#ifdef LUAJIT_PAGEALLOC_TEST
static LJPageAllocTestStats page_alloc_test_stats;
static int page_alloc_test_fail_request;
static int page_alloc_test_reject;

static int page_alloc_test_request_fails(void)
{
  page_alloc_test_stats.request_calls++;
  return page_alloc_test_fail_request > 0 &&
         page_alloc_test_stats.request_calls == page_alloc_test_fail_request;
}

void lj_page_alloc_test_reset(void)
{
  memset(&page_alloc_test_stats, 0, sizeof(page_alloc_test_stats));
  page_alloc_test_fail_request = 0;
  page_alloc_test_reject = 0;
}

void lj_page_alloc_test_fail_at(int request)
{
  page_alloc_test_fail_request = request;
}

void lj_page_alloc_test_reject_pointer(int reject)
{
  page_alloc_test_reject = reject;
}

int lj_page_alloc_test_should_reject_pointer(void)
{
  int reject = page_alloc_test_reject;
  page_alloc_test_reject = 0;
  return reject;
}

void lj_page_alloc_test_get_stats(LJPageAllocTestStats *stats)
{
  *stats = page_alloc_test_stats;
}
#else
#define page_alloc_test_request_fails() 0
#endif

void *lj_page_alloc_create(PRNGState *rs)
{
  void *backing = lj_alloc_create(rs);
  LJPageAllocState *pas;
  if (backing == NULL) return NULL;
#ifdef LUAJIT_PAGEALLOC_TEST
  page_alloc_test_stats.backing_created++;
#endif
  if (page_alloc_test_request_fails()) {
    pas = NULL;
  } else {
    pas = (LJPageAllocState *)lj_alloc_f(backing, NULL, 0,
					sizeof(LJPageAllocState));
  }
  if (pas == NULL) {
#ifdef LUAJIT_PAGEALLOC_TEST
    page_alloc_test_stats.backing_destroyed++;
#endif
    lj_alloc_destroy(backing);
    return NULL;
  }
  pas->backing = backing;
#ifdef LUAJIT_PAGEALLOC_TEST
  page_alloc_test_stats.wrapper_created++;
#endif
  return pas;
}

void lj_page_alloc_setprng(void *ud, PRNGState *rs)
{
  LJPageAllocState *pas = (LJPageAllocState *)ud;
#ifdef LUAJIT_PAGEALLOC_TEST
  page_alloc_test_stats.setprng_calls++;
#endif
  lj_alloc_setprng(pas->backing, rs);
}

void lj_page_alloc_destroy(void *ud)
{
  LJPageAllocState *pas = (LJPageAllocState *)ud;
  void *backing = pas->backing;
#ifdef LUAJIT_PAGEALLOC_TEST
  page_alloc_test_stats.wrapper_destroyed++;
#endif
  lj_alloc_f(backing, pas, sizeof(LJPageAllocState), 0);
#ifdef LUAJIT_PAGEALLOC_TEST
  page_alloc_test_stats.backing_destroyed++;
#endif
  lj_alloc_destroy(backing);
}

void *lj_page_alloc_f(void *ud, void *ptr, size_t osize, size_t nsize)
{
  LJPageAllocState *pas = (LJPageAllocState *)ud;
#ifdef LUAJIT_PAGEALLOC_TEST
  if (page_alloc_test_request_fails()) return NULL;
#endif
  return lj_alloc_f(pas->backing, ptr, osize, nsize);
}

#endif
