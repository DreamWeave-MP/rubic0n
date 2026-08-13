/*
** Experimental segregated page allocator front end.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
**
** Small allocations use segregated pages backed by LuaJIT's bundled
** allocator. Larger allocations remain delegated to the bundled allocator.
*/

#define lj_alloc_page_c
#define LUA_CORE

#include "lj_def.h"
#include "lj_alloc.h"
#include "lj_alloc_page.h"
#include "lj_prng.h"

#if defined(LUAJIT_USE_PAGEALLOC) && !defined(LUAJIT_USE_SYSMALLOC)

#define LJ_PAGE_ALLOC_MAX_SIZE	1024u
#define LJ_PAGE_CLASS_COUNT	36u
#define LJ_PAGE_SMALL_SIZE	(16u * 1024u)
#define LJ_PAGE_LARGE_SIZE	(32u * 1024u)
#define LJ_PAGE_SMALL_MAX_PAYLOAD 512u
#define LJ_PAGE_ALIGNMENT	8u
#define LJ_PAGE_PREFIX_SIZE	8u
#define LJ_PAGE_MAGIC		0x4c4a5047u

typedef struct LJPage LJPage;

struct LJPage {
  LJPage *nonfull_prev;
  LJPage *nonfull_next;
  LJPage *all_prev;
  LJPage *all_next;
  struct LJPageAllocState *owner;
  void *free_head;
  uint32_t magic;
  uint32_t page_size;
  uint32_t stride;
  uint32_t block_count;
  uint32_t bump_index;
  uint32_t busy_count;
  uint16_t payload_size;
  uint8_t class_index;
  uint8_t on_nonfull;
  LJ_ALIGN(LJ_PAGE_ALIGNMENT) uint8_t data[1];
};

typedef struct LJPageAllocState {
  void *backing;
  LJPage *nonfull_pages[LJ_PAGE_CLASS_COUNT];
  LJPage *allpages;
} LJPageAllocState;

static const uint16_t page_class_size[LJ_PAGE_CLASS_COUNT] = {
  8, 16, 24, 32, 40, 48, 56,
  64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224, 240,
  256, 288, 320, 352, 384, 416, 448, 480,
  512, 576, 640, 704, 768, 832, 896, 960, 1024
};

LJ_STATIC_ASSERT(sizeof(void *) == 4 || sizeof(void *) == 8);
LJ_STATIC_ASSERT(LJ_PAGE_PREFIX_SIZE >= sizeof(void *));
LJ_STATIC_ASSERT((offsetof(LJPage, data) & (LJ_PAGE_ALIGNMENT-1)) == 0);
LJ_STATIC_ASSERT((LJ_PAGE_ALIGNMENT & (LJ_PAGE_ALIGNMENT-1)) == 0);

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

static uint32_t page_size_class(size_t size)
{
  lj_assertX(size > 0 && size <= LJ_PAGE_ALLOC_MAX_SIZE,
	     "bad page allocation size %d", (int)size);
  if (size <= 56)
    return (uint32_t)((size + 7) >> 3) - 1;
  if (size <= 240)
    return 7u + (uint32_t)((size - 49) >> 4);
  if (size <= 480)
    return 19u + (uint32_t)((size - 225) >> 5);
  return 27u + (uint32_t)((size - 449) >> 6);
}

static uint8_t *page_data(LJPage *page)
{
  return (uint8_t *)page + offsetof(LJPage, data);
}

static void page_nonfull_insert(LJPageAllocState *pas, LJPage *page)
{
  LJPage **head = &pas->nonfull_pages[page->class_index];
  lj_assertX(!page->on_nonfull, "page already on non-full list");
  page->nonfull_prev = NULL;
  page->nonfull_next = *head;
  if (*head != NULL) (*head)->nonfull_prev = page;
  *head = page;
  page->on_nonfull = 1;
}

static void page_nonfull_remove(LJPageAllocState *pas, LJPage *page)
{
  lj_assertX(page->on_nonfull, "page missing from non-full list");
  if (page->nonfull_prev != NULL)
    page->nonfull_prev->nonfull_next = page->nonfull_next;
  else
    pas->nonfull_pages[page->class_index] = page->nonfull_next;
  if (page->nonfull_next != NULL)
    page->nonfull_next->nonfull_prev = page->nonfull_prev;
  page->nonfull_prev = page->nonfull_next = NULL;
  page->on_nonfull = 0;
}

static void page_all_insert(LJPageAllocState *pas, LJPage *page)
{
  page->all_prev = NULL;
  page->all_next = pas->allpages;
  if (pas->allpages != NULL) pas->allpages->all_prev = page;
  pas->allpages = page;
}

static void page_all_remove(LJPageAllocState *pas, LJPage *page)
{
  if (page->all_prev != NULL)
    page->all_prev->all_next = page->all_next;
  else
    pas->allpages = page->all_next;
  if (page->all_next != NULL) page->all_next->all_prev = page->all_prev;
  page->all_prev = page->all_next = NULL;
}

static LJPage *page_new(LJPageAllocState *pas, uint32_t class_index)
{
  uint32_t payload_size = page_class_size[class_index];
  uint32_t page_size = payload_size > LJ_PAGE_SMALL_MAX_PAYLOAD ?
		       LJ_PAGE_LARGE_SIZE : LJ_PAGE_SMALL_SIZE;
  uint32_t stride = LJ_PAGE_PREFIX_SIZE + payload_size;
  uint32_t data_offset = (uint32_t)offsetof(LJPage, data);
  LJPage *page = (LJPage *)lj_alloc_f(pas->backing, NULL, 0, page_size);
  if (page == NULL) return NULL;
  memset(page, 0, data_offset);
  page->owner = pas;
  page->magic = LJ_PAGE_MAGIC;
  page->page_size = page_size;
  page->stride = stride;
  page->block_count = (page_size - data_offset) / stride;
  page->payload_size = (uint16_t)payload_size;
  page->class_index = (uint8_t)class_index;
  lj_assertX((stride & (LJ_PAGE_ALIGNMENT-1)) == 0,
	     "unaligned page stride");
  lj_assertX(page->block_count > 0, "empty allocation page");
  page_all_insert(pas, page);
  page_nonfull_insert(pas, page);
#ifdef LUAJIT_PAGEALLOC_TEST
  page_alloc_test_stats.pages_created++;
#endif
  return page;
}

static void page_release(LJPageAllocState *pas, LJPage *page)
{
  uint32_t page_size = page->page_size;
  lj_assertX(page->busy_count == 0, "releasing busy allocation page");
  if (page->on_nonfull) page_nonfull_remove(pas, page);
  page_all_remove(pas, page);
  page->magic = 0;
#ifdef LUAJIT_PAGEALLOC_TEST
  page_alloc_test_stats.pages_destroyed++;
#endif
  lj_alloc_f(pas->backing, page, page_size, 0);
}

static void *page_alloc_small(LJPageAllocState *pas, size_t size)
{
  uint32_t class_index = page_size_class(size);
  LJPage *page = pas->nonfull_pages[class_index];
  uint8_t *block;
  void *ptr;
  if (page == NULL) {
    page = page_new(pas, class_index);
    if (page == NULL) return NULL;
  }
  if (page->bump_index < page->block_count) {
    block = page_data(page) + page->bump_index * page->stride;
    page->bump_index++;
    ptr = block + LJ_PAGE_PREFIX_SIZE;
  } else {
    ptr = page->free_head;
    lj_assertX(ptr != NULL, "non-full page has no available block");
    page->free_head = *(void **)ptr;
    block = (uint8_t *)ptr - LJ_PAGE_PREFIX_SIZE;
  }
  *(LJPage **)block = page;
  page->busy_count++;
  if (page->busy_count == page->block_count)
    page_nonfull_remove(pas, page);
  lj_assertX(((uintptr_t)ptr & (LJ_PAGE_ALIGNMENT-1)) == 0,
	     "unaligned page allocation");
#ifdef LUAJIT_PAGEALLOC_TEST
  page_alloc_test_stats.pooled_allocations++;
#endif
  return ptr;
}

static LJPage *page_from_ptr(LJPageAllocState *pas, void *ptr)
{
  LJPage *page = *(LJPage **)((uint8_t *)ptr - LJ_PAGE_PREFIX_SIZE);
  lj_assertX(page != NULL && page->magic == LJ_PAGE_MAGIC,
	     "invalid page allocation prefix");
  lj_assertX(page->owner == pas, "page allocation belongs to another state");
  lj_assertX((uint8_t *)ptr >= page_data(page) + LJ_PAGE_PREFIX_SIZE &&
	     (uint8_t *)ptr < (uint8_t *)page + page->page_size,
	     "page allocation outside owning page");
  lj_assertX((((uint8_t *)ptr - LJ_PAGE_PREFIX_SIZE - page_data(page)) % page->stride) == 0,
	     "page allocation not on block boundary");
  return page;
}

static void page_free_small(LJPageAllocState *pas, void *ptr, size_t osize)
{
  LJPage *page = page_from_ptr(pas, ptr);
  lj_assertX(osize <= page->payload_size,
	     "old size exceeds pooled block capacity");
  UNUSED(osize);
  lj_assertX(page->busy_count > 0, "free from empty allocation page");
  if (page->busy_count == page->block_count)
    page_nonfull_insert(pas, page);
  *(void **)ptr = page->free_head;
  page->free_head = ptr;
  page->busy_count--;
#ifdef LUAJIT_PAGEALLOC_TEST
  page_alloc_test_stats.pooled_frees++;
#endif
  if (page->busy_count == 0) page_release(pas, page);
}

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
  memset(pas, 0, sizeof(LJPageAllocState));
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
  LJPage *page = pas->allpages;
  while (page != NULL) {
    LJPage *next = page->all_next;
#ifdef LUAJIT_PAGEALLOC_TEST
    page_alloc_test_stats.pages_destroyed++;
#endif
    lj_alloc_f(backing, page, page->page_size, 0);
    page = next;
  }
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
  /* A non-NULL pointer must be returned with its current logical size.
  ** osize selects pooled-prefix ownership versus bundled allocation. */
  if (ptr == NULL) {
    if (nsize == 0) return NULL;
    if (page_alloc_test_request_fails()) return NULL;
    if (nsize <= LJ_PAGE_ALLOC_MAX_SIZE)
      return page_alloc_small(pas, nsize);
    return lj_alloc_f(pas->backing, NULL, 0, nsize);
  }
  lj_assertX(osize > 0, "missing old size for page allocator pointer");
  if (nsize == 0) {
    if (osize <= LJ_PAGE_ALLOC_MAX_SIZE) {
      page_free_small(pas, ptr, osize);
    } else {
      lj_alloc_f(pas->backing, ptr, osize, 0);
    }
    return NULL;
  }
  if (osize <= LJ_PAGE_ALLOC_MAX_SIZE) {
    LJPage *page = page_from_ptr(pas, ptr);
    void *newptr;
    size_t copysize;
    lj_assertX(osize <= page->payload_size,
	       "old size exceeds pooled block capacity");
    if (nsize <= page->payload_size) return ptr;
    if (page_alloc_test_request_fails()) return NULL;
    newptr = nsize <= LJ_PAGE_ALLOC_MAX_SIZE ?
	     page_alloc_small(pas, nsize) :
	     lj_alloc_f(pas->backing, NULL, 0, nsize);
    if (newptr == NULL) return NULL;
    copysize = osize < nsize ? osize : nsize;
    memcpy(newptr, ptr, copysize);
    page_free_small(pas, ptr, osize);
    return newptr;
  } else if (nsize <= LJ_PAGE_ALLOC_MAX_SIZE) {
    void *newptr;
    size_t copysize;
    if (page_alloc_test_request_fails()) return NULL;
    newptr = page_alloc_small(pas, nsize);
    if (newptr == NULL) return NULL;
    copysize = osize < nsize ? osize : nsize;
    memcpy(newptr, ptr, copysize);
    lj_alloc_f(pas->backing, ptr, osize, 0);
    return newptr;
  }
  if (page_alloc_test_request_fails()) return NULL;
  return lj_alloc_f(pas->backing, ptr, osize, nsize);
}

#endif
