# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

my $lib = abs_path("$Bin/../src/libluajit.a");
plan skip_all => 'src/libluajit.a is not built' unless defined $lib && -f $lib;

my $symbols = `nm "$lib" 2>/dev/null`;
plan skip_all => 'requires a page-allocator build with visible symbols'
    unless $symbols =~ /\b[TW]\s+lj_page_alloc_f\b/;
my $hooks = $symbols =~ /\b[TW]\s+lj_page_alloc_test_reset\b/ ? 1 : 0;

my $cc = $ENV{CC} || 'cc';
system("$cc --version >/dev/null 2>&1");
plan skip_all => "C compiler '$cc' is not available" if $? == -1 || ($? >> 8) == 127;

my $cwd = cwd;
my $dir = tempdir 'testlj_pagealloc_stress_XXXXXXX', CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $c, '>', 'pageallocstress.c' or die $!;
print $c <<'C';
#include "lj_arch.h"
#include "lj_alloc_page.h"
#include "lj_prng.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SLOTS 20000

typedef struct Slot { unsigned char *ptr; size_t size; unsigned seed; } Slot;

static Slot slots[SLOTS];
static uint64_t rng = 0x9e3779b97f4a7c15ull;

static unsigned rnd(void)
{
  rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
  return (unsigned)(rng >> 32);
}

static void fill(unsigned char *p, size_t n, unsigned seed)
{
  size_t i;
  for (i = 0; i < n; i++) p[i] = (unsigned char)(seed + i * 31u);
}

static int check(const unsigned char *p, size_t n, unsigned seed)
{
  size_t i;
  for (i = 0; i < n; i++)
    if (p[i] != (unsigned char)(seed + i * 31u)) return 0;
  return 1;
}

/* Mostly small sizes, with a tail that crosses into the delegated range. */
static size_t rndsize(void)
{
  unsigned r = rnd() % 100;
  if (r < 60) return 1 + rnd() % 128;
  if (r < 90) return 1 + rnd() % 1024;
  if (r < 97) return 1000 + rnd() % 64;
  return 1025 + rnd() % 6000;
}

static int fail(const char *what, int i)
{
  fprintf(stderr, "page allocator stress: %s (slot %d)\n", what, i);
  return 1;
}

int main(void)
{
  PRNGState prng;
  void *pas;
  int round, i;
#ifdef LUAJIT_PAGEALLOC_TEST
  LJPageAllocTestStats stats;
  lj_page_alloc_test_reset();
#endif
  lj_prng_seed_fixed(&prng);
  pas = lj_page_alloc_create(&prng);
  if (pas == NULL) return 1;
  lj_page_alloc_setprng(pas, &prng);

  for (round = 0; round < 400000; round++) {
    Slot *s;
    unsigned op = rnd() % 100;
    i = (int)(rnd() % SLOTS);
    s = &slots[i];
    if (s->ptr == NULL) {
      s->size = rndsize();
      s->seed = rnd();
      s->ptr = (unsigned char *)lj_page_alloc_f(pas, NULL, 0, s->size);
      if (s->ptr == NULL) return fail("allocation failed", i);
      if (((uintptr_t)s->ptr & 7u) ||
	  (s->size > 56 && s->size <= LJ_PAGE_ALLOC_MAX_SIZE &&
	   ((uintptr_t)s->ptr & 15u)))
	return fail("block is misaligned", i);
      fill(s->ptr, s->size, s->seed);
    } else if (op < 45) {
      if (!check(s->ptr, s->size, s->seed)) return fail("corrupt block", i);
      lj_page_alloc_f(pas, s->ptr, s->size, 0);
      s->ptr = NULL;
    } else if (op < 75) {
      size_t nsize = rndsize();
      size_t keep = nsize < s->size ? nsize : s->size;
      unsigned char *np;
      if (!check(s->ptr, s->size, s->seed)) return fail("corrupt block", i);
      np = (unsigned char *)lj_page_alloc_f(pas, s->ptr, s->size, nsize);
      if (np == NULL) return fail("reallocation failed", i);
      if (!check(np, keep, s->seed)) return fail("realloc lost data", i);
      s->ptr = np;
      s->size = nsize;
      s->seed = rnd();
      fill(s->ptr, s->size, s->seed);
    } else {
      if (!check(s->ptr, s->size, s->seed)) return fail("corrupt block", i);
    }
  }

  /* Drain in a scattered order, so pages and segments empty out unevenly. */
  for (round = 0; round < 7; round++) {
    for (i = round; i < SLOTS; i += 7) {
      Slot *s = &slots[i];
      if (s->ptr == NULL) continue;
      if (!check(s->ptr, s->size, s->seed)) return fail("corrupt block", i);
      lj_page_alloc_f(pas, s->ptr, s->size, 0);
      s->ptr = NULL;
    }
  }

  /* Fill many segments with one class, then free from the middle outwards. */
  {
    enum { N = 150000 };
    void **p = (void **)malloc(sizeof(void *) * N);
    if (p == NULL) return 1;
    for (i = 0; i < N; i++) {
      p[i] = lj_page_alloc_f(pas, NULL, 0, 80);
      if (p[i] == NULL) return fail("bulk allocation failed", i);
      *(int *)p[i] = i;
    }
    for (i = 0; i < N/2; i++) {
      int a = N/2 - 1 - i, b = N/2 + i;
      if (*(int *)p[a] != a || *(int *)p[b] != b)
	return fail("bulk block corrupt", i);
      lj_page_alloc_f(pas, p[a], 80, 0);
      lj_page_alloc_f(pas, p[b], 80, 0);
    }
    free(p);
  }

#ifdef LUAJIT_PAGEALLOC_TEST
  lj_page_alloc_test_get_stats(&stats);
  if (stats.pooled_allocations != stats.pooled_frees)
    return fail("pooled allocations and frees do not balance", 0);
  if (stats.pages_created != stats.pages_destroyed)
    return fail("empty pages were not returned", 0);
  /* Unused segments are kept until they sat out a whole GC cycle. */
  if (stats.segments_created < 40 || stats.segments_destroyed != 0)
    return fail("segments were returned without a trim", 0);
  lj_page_alloc_trim(pas);  /* Start of a cycle: everything was in use. */
  lj_page_alloc_test_get_stats(&stats);
  if (stats.segments_destroyed != 0)
    return fail("trim returned segments that were just in use", 0);
  lj_page_alloc_trim(pas);  /* No allocation since: says nothing. */
  lj_page_alloc_test_get_stats(&stats);
  if (stats.segments_destroyed != 0)
    return fail("trim without allocation returned segments", 0);
  for (round = 0; round < 64; round++) {
    /* A cycle that needs one segment leaves the others as surplus. */
    void *p[240];
    int before = stats.segments_destroyed;
    int left = stats.segments_created - stats.segments_destroyed;
    for (i = 0; i < 240; i++) {
      p[i] = lj_page_alloc_f(pas, NULL, 0, 1024);
      if (p[i] == NULL) return fail("allocation failed", i);
    }
    for (i = 0; i < 240; i++) lj_page_alloc_f(pas, p[i], 1024, 0);
    lj_page_alloc_trim(pas);
    lj_page_alloc_test_get_stats(&stats);
    if (stats.segments_destroyed - before !=
	(left - 1 > 16 ? 16 : left - 1))
      return fail("trim returned the wrong number of segments", round);
  }
  if (stats.segments_created - stats.segments_destroyed != 1)
    return fail("idle segments were not returned", 0);
#endif
  lj_page_alloc_destroy(pas);
#ifdef LUAJIT_PAGEALLOC_TEST
  lj_page_alloc_test_get_stats(&stats);
  if (stats.pages_created != stats.pages_destroyed ||
      stats.segments_created != stats.segments_destroyed ||
      stats.backing_created != stats.backing_destroyed)
    return fail("teardown accounting does not balance", 0);
#endif
  puts("ok");
  return 0;
}
C
close $c;

my @compile = ($cc, '-O1', "-I$Bin/../src", '-DLUAJIT_USE_PAGEALLOC',
               ($hooks ? ('-DLUAJIT_PAGEALLOC_TEST') : ()),
               '-o', 'pageallocstress', 'pageallocstress.c', $lib,
               '-lm', '-ldl');
my $compile_out = `@compile 2>&1`;
die "Cannot compile page allocator stress test:\n$compile_out" if $? != 0;

system './pageallocstress >stdout.txt 2>stderr.txt';
my $rc = $? >> 8;
open my $outfh, '<', 'stdout.txt' or die $!;
my $out = do { local $/; <$outfh> };
close $outfh;
open my $errfh, '<', 'stderr.txt' or die $!;
my $err = do { local $/; <$errfh> };
close $errfh;
chdir $cwd or die $!;

is "$rc:$out$err", "0:ok\n",
    'random allocate, resize and free keeps data intact and returns memory';
done_testing();
