/*
** Segregated page allocator front end.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
**
** Small allocations use size-segregated pages carved out of segments that
** are backed by LuaJIT's bundled allocator. Larger allocations remain
** delegated to the bundled allocator. See lj_alloc_page.h for the layout.
*/

#define lj_alloc_page_c
#define LUA_CORE

#include "lj_obj.h"
#include "lj_alloc.h"
#include "lj_alloc_page.h"
#include "lj_prng.h"

#if LJ_HASPAGEALLOC

/* Number of pages per segment. A segment is one request to the backing
** allocator, large enough to always be a direct OS mapping there. */
#define LJ_PAGE_SEG_PAGES	16u

typedef struct LJPageSeg {
  struct LJPageSeg *prev;	/* Available or unused list, see below. */
  struct LJPageSeg *next;
  struct LJPageSeg *all_prev;	/* List of all segments. */
  struct LJPageSeg *all_next;
  LJPage *free_pages;		/* Pages returned to this segment. */
  uint8_t *base;		/* First aligned page. */
  void *mem;			/* Memory obtained from the backing allocator. */
  size_t memsize;
  uint32_t npages;		/* Number of whole aligned pages. */
  uint32_t bump;		/* Next page that was never handed out. */
  uint32_t used;		/* Number of pages in use. */
  uint32_t where;		/* Which list the segment is on. */
} LJPageSeg;

/* A segment with all pages in use is on no list. */
#define SEG_FULL	0
#define SEG_AVAIL	1	/* Some pages in use, some not. */
#define SEG_UNUSED	2	/* No page in use. */

/* Upper limit for the number of segments given back per GC cycle. */
#define LJ_PAGE_TRIM_MAX	16u

/*
** Size classes: multiples of 8 below 64, multiples of 16 below 256, multiples
** of 32 below 512 and multiples of 64 up to 1024. This is the progression
** Luau uses. Blocks are aligned to 8 bytes and to 16 bytes for every class
** that is a multiple of 16.
*/
static const uint16_t page_class_size[LJ_PAGE_CLASS_COUNT] = {
  8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128,
  144, 160, 176, 192, 208, 224, 240, 256, 288, 320, 352, 384,
  416, 448, 480, 512, 576, 640, 704, 768, 832, 896, 960, 1024
};

/* Indexed by (size+7)>>3. */
LJ_DATADEF const uint8_t lj_page_class[LJ_PAGE_ALLOC_MAX_SIZE/8+1] = {
  0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 8, 9, 9, 10, 10, 11,
  11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 18, 19,
  19, 20, 20, 20, 20, 21, 21, 21, 21, 22, 22, 22, 22, 23, 23, 23,
  23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26, 27, 27, 27,
  27, 28, 28, 28, 28, 28, 28, 28, 28, 29, 29, 29, 29, 29, 29, 29,
  29, 30, 30, 30, 30, 30, 30, 30, 30, 31, 31, 31, 31, 31, 31, 31,
  31, 32, 32, 32, 32, 32, 32, 32, 32, 33, 33, 33, 33, 33, 33, 33,
  33, 34, 34, 34, 34, 34, 34, 34, 34, 35, 35, 35, 35, 35, 35, 35,
  35
};

LJ_STATIC_ASSERT(sizeof(void *) == 4 || sizeof(void *) == 8);
LJ_STATIC_ASSERT((LJ_PAGE_ALIGNMENT & (LJ_PAGE_ALIGNMENT-1)) == 0);
LJ_STATIC_ASSERT((LJ_PAGE_ALLOC_MAX_SIZE & 7) == 0);
LJ_STATIC_ASSERT(LJ_PAGE_HDRSIZE + LJ_PAGE_ALLOC_MAX_SIZE*2 <= LJ_PAGE_SIZE);

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
#define page_test_inc(field)	(page_alloc_test_stats.field++)
#else
#define page_alloc_test_request_fails() 0
#define page_test_inc(field)	((void)0)
#endif

/* -- Segments ------------------------------------------------------------ */

static void seg_link(LJPageSeg **head, LJPageSeg *seg, uint32_t where)
{
  lj_assertX(seg->where == SEG_FULL, "segment already on a list");
  seg->prev = NULL;
  seg->next = *head;
  if (*head != NULL) (*head)->prev = seg;
  *head = seg;
  seg->where = where;
}

static void seg_unlink(LJPageSeg **head, LJPageSeg *seg)
{
  lj_assertX(seg->where != SEG_FULL, "segment missing from its list");
  if (seg->prev != NULL)
    seg->prev->next = seg->next;
  else
    *head = seg->next;
  if (seg->next != NULL) seg->next->prev = seg->prev;
  seg->prev = seg->next = NULL;
  seg->where = SEG_FULL;
}

static LJPageSeg *seg_new(LJPageAllocState *pas)
{
  size_t memsize = ((size_t)LJ_PAGE_SEG_PAGES + 1) << LJ_PAGE_SHIFT;
  LJPageSeg *seg;
  uint8_t *mem, *base;
  if (page_alloc_test_request_fails()) return NULL;
  seg = (LJPageSeg *)lj_alloc_f(pas->backing, NULL, 0, sizeof(LJPageSeg));
  if (seg == NULL) return NULL;
  mem = (uint8_t *)lj_alloc_f(pas->backing, NULL, 0, memsize);
  if (mem == NULL) {
    lj_alloc_f(pas->backing, seg, sizeof(LJPageSeg), 0);
    return NULL;
  }
  base = (uint8_t *)(((uintptr_t)mem + (LJ_PAGE_SIZE-1)) &
		     ~(uintptr_t)(LJ_PAGE_SIZE-1));
  memset(seg, 0, sizeof(LJPageSeg));
  seg->mem = mem;
  seg->memsize = memsize;
  seg->base = base;
  seg->npages = (uint32_t)((size_t)(mem + memsize - base) >> LJ_PAGE_SHIFT);
  lj_assertX(seg->npages >= LJ_PAGE_SEG_PAGES, "short page segment");
  seg->all_next = pas->seg_all;
  if (pas->seg_all != NULL) pas->seg_all->all_prev = seg;
  pas->seg_all = seg;
  page_test_inc(segments_created);
  return seg;
}

/* Give a segment that is on no list back to the backing allocator. */
static void seg_free(LJPageAllocState *pas, LJPageSeg *seg)
{
  void *backing = pas->backing;
  lj_assertX(seg->used == 0 && seg->where == SEG_FULL,
	     "releasing busy page segment");
  if (seg->all_prev != NULL)
    seg->all_prev->all_next = seg->all_next;
  else
    pas->seg_all = seg->all_next;
  if (seg->all_next != NULL) seg->all_next->all_prev = seg->all_prev;
  lj_alloc_f(backing, seg->mem, seg->memsize, 0);
  lj_alloc_f(backing, seg, sizeof(LJPageSeg), 0);
  page_test_inc(segments_destroyed);
}

/*
** Give back segments that went unused for a whole GC cycle. Called by the
** collector at the end of each cycle.
**
** The heap of a running program breathes with the collector: a cycle frees
** whole segments and the next one fills them again. Returning those to the
** operating system right away would make every cycle pay for mapping and
** faulting them back in. unused_low is the number of segments that stayed
** unused since the previous trim. Only these are surplus. One is kept.
**
** Cycles without allocation in between say nothing about demand, e.g. two
** full collections in a row. These are not counted.
*/
void lj_page_alloc_trim(void *ud)
{
  LJPageAllocState *pas = (LJPageAllocState *)ud;
  uint32_t n = pas->unused_low;
  if (pas->activity < LJ_PAGE_SEG_PAGES)
    return;
  pas->activity = 0;
  if (n != 0) {
    LJPageSeg *seg = pas->seg_unused;
    if (n == pas->unused_count) n--;
    if (n > LJ_PAGE_TRIM_MAX) n = LJ_PAGE_TRIM_MAX;
    if (n != 0) {
      /* The head of the list was used last. Release from the other end. */
      while (seg->next != NULL) seg = seg->next;
      do {
	LJPageSeg *prev = seg->prev;
	seg_unlink(&pas->seg_unused, seg);
	seg_free(pas, seg);
	pas->unused_count--;
	seg = prev;
      } while (--n != 0);
    }
  }
  pas->unused_low = pas->unused_count;
}

/* -- Pages --------------------------------------------------------------- */

#define page_data(page)		((uint8_t *)(page) + LJ_PAGE_HDRSIZE)

static void page_nonfull_insert(LJPageAllocState *pas, LJPage *page)
{
  LJPage **head = &pas->nonfull[page->cls];
  page->prev = NULL;
  page->next = *head;
  if (*head != NULL) (*head)->prev = page;
  *head = page;
}

static void page_nonfull_remove(LJPageAllocState *pas, LJPage *page)
{
  if (page->prev != NULL)
    page->prev->next = page->next;
  else
    pas->nonfull[page->cls] = page->next;
  if (page->next != NULL) page->next->prev = page->prev;
  page->prev = page->next = NULL;
}

/* Get an unused page and set it up for a size class. */
static LJPage *page_new(LJPageAllocState *pas, uint32_t cls)
{
  LJPageSeg *seg = pas->seg_avail;
  LJPage *page;
  uint32_t stride = page_class_size[cls];
  pas->activity++;
  if (seg == NULL) {  /* Prefer segments that are in use, so others drain. */
    seg = pas->seg_unused;
    if (seg != NULL) {
      seg_unlink(&pas->seg_unused, seg);
      if (--pas->unused_count < pas->unused_low)
	pas->unused_low = pas->unused_count;
    } else {
      seg = seg_new(pas);
      if (seg == NULL) return NULL;
    }
    seg_link(&pas->seg_avail, seg, SEG_AVAIL);
  }
  page = seg->free_pages;
  if (page != NULL) {
    seg->free_pages = page->next;
  } else {
    lj_assertX(seg->bump < seg->npages, "available segment has no page");
    page = (LJPage *)(seg->base + ((size_t)seg->bump++ << LJ_PAGE_SHIFT));
  }
  if (++seg->used == seg->npages)
    seg_unlink(&pas->seg_avail, seg);
  page->free_head = NULL;
  page->bump = page_data(page);
  page->busy = 0;
  page->cap = (uint32_t)((LJ_PAGE_SIZE - LJ_PAGE_HDRSIZE) / stride);
  page->seg = seg;
  page->stride = stride;
  page->cls = cls;
  page_nonfull_insert(pas, page);
  page_test_inc(pages_created);
  return page;
}

/* Return an empty page to its segment. */
static void page_release(LJPageAllocState *pas, LJPage *page)
{
  LJPageSeg *seg = page->seg;
  lj_assertX(page->busy == 0, "releasing busy allocation page");
  page_nonfull_remove(pas, page);
  page_test_inc(pages_destroyed);
  page->next = seg->free_pages;
  seg->free_pages = page;
  if (--seg->used == 0) {
    if (seg->where == SEG_AVAIL) seg_unlink(&pas->seg_avail, seg);
    seg_link(&pas->seg_unused, seg, SEG_UNUSED);
    pas->unused_count++;
  } else if (seg->where == SEG_FULL) {
    seg_link(&pas->seg_avail, seg, SEG_AVAIL);
  }
}

static LJ_AINLINE void *page_pop(LJPageAllocState *pas, LJPage *page)
{
  void *p = page->free_head;
  if (p != NULL) {
    page->free_head = *(void **)p;
  } else {
    p = page->bump;
    page->bump = (uint8_t *)p + page->stride;
  }
  lj_assertX((uint8_t *)p >= page_data(page) &&
	     (uint8_t *)p + page->stride <= (uint8_t *)page + LJ_PAGE_SIZE,
	     "page allocation outside owning page");
  if (++page->busy == page->cap)
    page_nonfull_remove(pas, page);
  return p;
}

/* The class has no page with room. Set up a new one and allocate from it. */
void * LJ_FASTCALL lj_page_alloc_refill(LJPageAllocState *pas, uint32_t cls)
{
  LJPage *page = page_new(pas, cls);
  if (page == NULL) return NULL;
  return page_pop(pas, page);
}

/* The last block of a page was just handed out. */
void LJ_FASTCALL lj_page_alloc_full(LJPageAllocState *pas, LJPage *page)
{
  page_nonfull_remove(pas, page);
}

/*
** A block was pushed onto the free list of a page that was full or that
** holds no other block. page->busy still has the count before the free.
*/
void LJ_FASTCALL lj_page_free_edge(LJPageAllocState *pas, LJPage *page)
{
  uint32_t busy = page->busy--;
  if (busy == page->cap) {
    page_nonfull_insert(pas, page);
  } else {
    lj_assertX(busy == 1, "bad page transition");
    page_release(pas, page);
  }
}

static LJ_AINLINE void *page_alloc_small(LJPageAllocState *pas, size_t size)
{
  uint32_t cls = lj_page_sizeclass(size);
  LJPage *page = pas->nonfull[cls];
  lj_assertX(size > 0 && size <= LJ_PAGE_ALLOC_MAX_SIZE,
	     "bad page allocation size %d", (int)size);
  if (page == NULL) {
    void *p = lj_page_alloc_refill(pas, cls);
#ifdef LUAJIT_PAGEALLOC_TEST
    if (p != NULL) page_alloc_test_stats.pooled_allocations++;
#endif
    return p;
  }
  page_test_inc(pooled_allocations);
  return page_pop(pas, page);
}

static LJ_AINLINE void page_free_small(LJPageAllocState *pas, void *ptr)
{
  LJPage *page = lj_page_of(ptr);
  uint32_t busy = page->busy;
  lj_assertX(busy > 0 && busy <= page->cap, "free from empty allocation page");
  lj_assertX((uint8_t *)ptr >= page_data(page) &&
	     (size_t)((uint8_t *)ptr - page_data(page)) % page->stride == 0,
	     "page allocation not on block boundary");
  page_test_inc(pooled_frees);
  *(void **)ptr = page->free_head;
  page->free_head = ptr;
  if (busy == page->cap || busy == 1)
    lj_page_free_edge(pas, page);
  else
    page->busy = busy - 1;
}

#ifdef LUAJIT_PAGEALLOC_TEST
void *lj_page_alloc_small(void *ud, size_t size)
{
  if (page_alloc_test_request_fails()) return NULL;
  return page_alloc_small((LJPageAllocState *)ud, size);
}

void lj_page_free_small(void *ud, void *ptr)
{
  page_free_small((LJPageAllocState *)ud, ptr);
}
#endif

/* -- Allocator interface ------------------------------------------------- */

void *lj_page_alloc_create(PRNGState *rs)
{
  void *backing = lj_alloc_create(rs);
  LJPageAllocState *pas;
  if (backing == NULL) return NULL;
  page_test_inc(backing_created);
  if (page_alloc_test_request_fails()) {
    pas = NULL;
  } else {
    pas = (LJPageAllocState *)lj_alloc_f(backing, NULL, 0,
					sizeof(LJPageAllocState));
  }
  if (pas == NULL) {
    page_test_inc(backing_destroyed);
    lj_alloc_destroy(backing);
    return NULL;
  }
  memset(pas, 0, sizeof(LJPageAllocState));
  pas->backing = backing;
  page_test_inc(wrapper_created);
  return pas;
}

void lj_page_alloc_setprng(void *ud, PRNGState *rs)
{
  LJPageAllocState *pas = (LJPageAllocState *)ud;
  page_test_inc(setprng_calls);
  lj_alloc_setprng(pas->backing, rs);
}

void lj_page_alloc_destroy(void *ud)
{
  LJPageAllocState *pas = (LJPageAllocState *)ud;
  void *backing = pas->backing;
  LJPageSeg *seg = pas->seg_all;
  while (seg != NULL) {
    LJPageSeg *next = seg->all_next;
#ifdef LUAJIT_PAGEALLOC_TEST
    page_alloc_test_stats.pages_destroyed += (int)seg->used;
    page_alloc_test_stats.segments_destroyed++;
#endif
    lj_alloc_f(backing, seg->mem, seg->memsize, 0);
    lj_alloc_f(backing, seg, sizeof(LJPageSeg), 0);
    seg = next;
  }
  page_test_inc(wrapper_destroyed);
  lj_alloc_f(backing, pas, sizeof(LJPageAllocState), 0);
  page_test_inc(backing_destroyed);
  lj_alloc_destroy(backing);
}

void *lj_page_alloc_f(void *ud, void *ptr, size_t osize, size_t nsize)
{
  LJPageAllocState *pas = (LJPageAllocState *)ud;
  /* A non-NULL pointer must be returned with its current logical size.
  ** osize tells pooled blocks from blocks of the bundled allocator. */
  if (ptr == NULL) {
    if (nsize == 0) return NULL;
    if (page_alloc_test_request_fails()) return NULL;
    if (nsize <= LJ_PAGE_ALLOC_MAX_SIZE)
      return page_alloc_small(pas, nsize);
    return lj_alloc_f(pas->backing, NULL, 0, nsize);
  }
  lj_assertX(osize > 0, "missing old size for page allocator pointer");
  if (nsize == 0) {
    if (osize <= LJ_PAGE_ALLOC_MAX_SIZE)
      page_free_small(pas, ptr);
    else
      lj_alloc_f(pas->backing, ptr, osize, 0);
    return NULL;
  }
  if (osize <= LJ_PAGE_ALLOC_MAX_SIZE) {
    LJPage *page = lj_page_of(ptr);
    void *newptr;
    lj_assertX(osize <= page->stride,
	       "old size exceeds pooled block capacity");
    if (nsize <= page->stride) {
      /* Fits. Only move when shrinking into a smaller size class. */
      if (nsize >= osize || lj_page_sizeclass(nsize) == page->cls)
	return ptr;
      if (page_alloc_test_request_fails()) return ptr;
      newptr = page_alloc_small(pas, nsize);
      if (newptr == NULL) return ptr;  /* Shrinking must not fail. */
      memcpy(newptr, ptr, nsize);
      page_free_small(pas, ptr);
      return newptr;
    }
    if (page_alloc_test_request_fails()) return NULL;
    newptr = nsize <= LJ_PAGE_ALLOC_MAX_SIZE ?
	     page_alloc_small(pas, nsize) :
	     lj_alloc_f(pas->backing, NULL, 0, nsize);
    if (newptr == NULL) return NULL;
    memcpy(newptr, ptr, osize);
    page_free_small(pas, ptr);
    return newptr;
  } else if (nsize <= LJ_PAGE_ALLOC_MAX_SIZE) {
    void *newptr;
    if (page_alloc_test_request_fails()) return NULL;
    newptr = page_alloc_small(pas, nsize);
    if (newptr == NULL) return NULL;
    memcpy(newptr, ptr, nsize);
    lj_alloc_f(pas->backing, ptr, osize, 0);
    return newptr;
  }
  if (page_alloc_test_request_fails()) return NULL;
  return lj_alloc_f(pas->backing, ptr, osize, nsize);
}

#endif
