/*
** Segregated page allocator front end.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#ifndef _LJ_ALLOC_PAGE_H
#define _LJ_ALLOC_PAGE_H

#include "lj_def.h"

#if defined(LUAJIT_USE_PAGEALLOC) && defined(LUAJIT_USE_SYSMALLOC)
#error "LUAJIT_USE_PAGEALLOC requires LuaJIT's bundled allocator"
#endif

#if defined(LUAJIT_USE_PAGEALLOC) && !defined(LUAJIT_USE_SYSMALLOC)
#define LJ_HASPAGEALLOC		1
#else
#define LJ_HASPAGEALLOC		0
#endif

#if LJ_HASPAGEALLOC

/*
** Layout
** ------
** Requests of up to LJ_PAGE_ALLOC_MAX_SIZE bytes are served from pages of
** LJ_PAGE_SIZE bytes. Every page holds blocks of one size class and starts
** with an LJPage header. Pages are aligned to their own size, so the page of
** a block is found by masking the block address. Blocks therefore carry no
** per-block header at all.
**
** Pages are carved out of segments obtained from LuaJIT's bundled allocator.
** Requests above the limit are delegated to the bundled allocator unchanged.
** The caller always passes the current logical size of a block, which is
** what tells pooled blocks from delegated ones.
*/

#define LJ_PAGE_ALLOC_MAX_SIZE	1024u
#define LJ_PAGE_SHIFT		14
#define LJ_PAGE_SIZE		((size_t)1 << LJ_PAGE_SHIFT)
#define LJ_PAGE_CLASS_COUNT	36u
#define LJ_PAGE_ALIGNMENT	8u

typedef struct LJPage LJPage;
struct LJPageSeg;

struct LJPage {
  void *free_head;		/* LIFO list of freed blocks. */
  uint8_t *bump;		/* Next block that was never handed out. */
  uint32_t busy;		/* Number of blocks in use. */
  uint32_t cap;			/* Number of blocks in this page. */
  LJPage *prev;			/* List of pages with room, per size class. */
  LJPage *next;			/* Ditto. Or free page list of a segment. */
  struct LJPageSeg *seg;	/* Owning segment. */
  uint32_t stride;		/* Block size. */
  uint32_t cls;			/* Size class. */
};

/* Size of the page header. A multiple of 16, so that blocks of a size class
** that is a multiple of 16 are aligned to 16 bytes. */
#define LJ_PAGE_HDRSIZE		((sizeof(LJPage) + 15u) & ~(size_t)15u)

typedef struct LJPageAllocState {
  LJPage *nonfull[LJ_PAGE_CLASS_COUNT];	/* Pages with room, per class. */
  void *backing;			/* Bundled allocator state. */
  struct LJPageSeg *seg_avail;		/* Segments with some pages in use. */
  struct LJPageSeg *seg_unused;		/* Segments with no page in use. */
  struct LJPageSeg *seg_all;		/* All segments. */
  uint32_t unused_count;		/* Number of unused segments. */
  uint32_t unused_low;			/* Lowest count since the last trim. */
  uint32_t activity;			/* Pages set up since the last trim. */
} LJPageAllocState;

/* Size class for 1 <= size <= LJ_PAGE_ALLOC_MAX_SIZE. */
LJ_DATA const uint8_t lj_page_class[LJ_PAGE_ALLOC_MAX_SIZE/8+1];
#define lj_page_sizeclass(size)	(lj_page_class[((size)+7u) >> 3])

#define lj_page_of(ptr) \
  ((LJPage *)((uintptr_t)(ptr) & ~(uintptr_t)(LJ_PAGE_SIZE-1)))

LJ_FUNC void *lj_page_alloc_create(PRNGState *rs);
LJ_FUNC void lj_page_alloc_setprng(void *pas, PRNGState *rs);
LJ_FUNC void lj_page_alloc_destroy(void *pas);
LJ_FUNC void *lj_page_alloc_f(void *pas, void *ptr, size_t osize,
			      size_t nsize);
LJ_FUNC void lj_page_alloc_trim(void *pas);

/* Out-of-line parts of the direct entry points below. */
LJ_FUNC void * LJ_FASTCALL lj_page_alloc_refill(LJPageAllocState *pas,
						uint32_t cls);
LJ_FUNC void LJ_FASTCALL lj_page_alloc_full(LJPageAllocState *pas,
					    LJPage *page);
LJ_FUNC void LJ_FASTCALL lj_page_free_edge(LJPageAllocState *pas,
					   LJPage *page);

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
  int segments_created;
  int segments_destroyed;
} LJPageAllocTestStats;

LJ_FUNC void lj_page_alloc_test_reset(void);
LJ_FUNC void lj_page_alloc_test_fail_at(int request);
LJ_FUNC void lj_page_alloc_test_reject_pointer(int reject);
LJ_FUNC int lj_page_alloc_test_should_reject_pointer(void);
LJ_FUNC void lj_page_alloc_test_get_stats(LJPageAllocTestStats *stats);

/* Test builds count and fault-inject every request, so nothing is inlined. */
LJ_FUNC void *lj_page_alloc_small(void *pas, size_t size);
LJ_FUNC void lj_page_free_small(void *pas, void *ptr);
#else

/*
** Direct entry points for the VM's own allocations. These skip the
** realloc-style dispatch of lj_page_alloc_f.
*/

/* Allocate 1 <= size <= LJ_PAGE_ALLOC_MAX_SIZE bytes. NULL if out of memory. */
static LJ_AINLINE void *lj_page_alloc_small(void *ud, size_t size)
{
  LJPageAllocState *pas = (LJPageAllocState *)ud;
  uint32_t cls = lj_page_sizeclass(size);
  LJPage *page = pas->nonfull[cls];
  void *p;
  if (LJ_UNLIKELY(page == NULL))
    return lj_page_alloc_refill(pas, cls);
  p = page->free_head;
  if (p != NULL) {
    page->free_head = *(void **)p;
  } else {
    p = page->bump;
    page->bump = (uint8_t *)p + page->stride;
  }
  if (LJ_UNLIKELY(++page->busy == page->cap))
    lj_page_alloc_full(pas, page);
  return p;
}

/* Free a block obtained for a size of at most LJ_PAGE_ALLOC_MAX_SIZE bytes. */
static LJ_AINLINE void lj_page_free_small(void *ud, void *ptr)
{
  LJPage *page = lj_page_of(ptr);
  uint32_t busy = page->busy;
  *(void **)ptr = page->free_head;
  page->free_head = ptr;
  /* The page was full or is about to become empty. */
  if (LJ_UNLIKELY(busy == page->cap || busy == 1))
    lj_page_free_edge((LJPageAllocState *)ud, page);
  else
    page->busy = busy - 1;
}
#endif

#endif

#endif
