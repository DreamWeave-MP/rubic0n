# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

my $lib = abs_path("$Bin/../src/libluajit.a");
plan skip_all => 'src/libluajit.a is not built' unless defined $lib && -f $lib;

my $symbols = `nm "$lib" 2>/dev/null`;
plan skip_all => 'requires a normal page-allocator build with test hooks'
    unless $symbols =~ /\b[TW]\s+lj_page_alloc_test_reset\b/;

my $cc = $ENV{CC} || 'cc';
my $cwd = cwd;
my $dir = tempdir 'testlj_pagealloc_boundary_XXXXXXX', CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $c, '>', 'pageallocboundary.c' or die $!;
print $c <<'C';
#include "lj_arch.h"
#include "lj_alloc_page.h"
#include "lj_prng.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fill_bytes(void *ptr, size_t size, unsigned seed)
{
  size_t i;
  for (i = 0; i < size; i++)
    ((unsigned char *)ptr)[i] = (unsigned char)(seed + i * 17u);
}

static int check_bytes(const void *ptr, size_t size, unsigned seed)
{
  size_t i;
  for (i = 0; i < size; i++)
    if (((const unsigned char *)ptr)[i] != (unsigned char)(seed + i * 17u))
      return 0;
  return 1;
}

static int boundary_requests(void *pas)
{
  void *ptrs[1100];
  size_t sizes[1100];
  int i;
  for (i = 0; i < 1100; i++) {
    sizes[i] = (size_t)i + 1;
    ptrs[i] = lj_page_alloc_f(pas, NULL, 0, sizes[i]);
    if (ptrs[i] == NULL || ((uintptr_t)ptrs[i] & 7u) != 0) return 0;
    fill_bytes(ptrs[i], sizes[i], (unsigned)i);
  }
  for (i = 1099; i >= 0; i--) {
    if (!check_bytes(ptrs[i], sizes[i], (unsigned)i)) return 0;
    lj_page_alloc_f(pas, ptrs[i], sizes[i], 0);
  }
  return 1;
}

static int class_page_transitions(void *pas)
{
  static const size_t sizes[] = {
    8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160,
    176, 192, 208, 224, 240, 256, 288, 320, 352, 384, 416, 448,
    480, 512, 576, 640, 704, 768, 832, 896, 960, 1024
  };
  void *ptrs[2048];
  void *replacement[3];
  size_t c;
  int i;
  for (c = 0; c < sizeof(sizes)/sizeof(sizes[0]); c++) {
    for (i = 0; i < 2048; i++) {
      ptrs[i] = lj_page_alloc_f(pas, NULL, 0, sizes[c]);
      if (ptrs[i] == NULL) return 0;
      fill_bytes(ptrs[i], sizes[c] < 32 ? sizes[c] : 32, (unsigned)(c+i));
    }
    lj_page_alloc_f(pas, ptrs[0], sizes[c], 0);
    lj_page_alloc_f(pas, ptrs[1], sizes[c], 0);
    lj_page_alloc_f(pas, ptrs[2], sizes[c], 0);
    replacement[0] = lj_page_alloc_f(pas, NULL, 0, sizes[c]);
    replacement[1] = lj_page_alloc_f(pas, NULL, 0, sizes[c]);
    replacement[2] = lj_page_alloc_f(pas, NULL, 0, sizes[c]);
    if (replacement[0] != ptrs[2] || replacement[1] != ptrs[1] ||
        replacement[2] != ptrs[0] ||
        !check_bytes(ptrs[3], sizes[c] < 32 ? sizes[c] : 32,
                     (unsigned)(c+3))) return 0;
    ptrs[0] = replacement[2];
    ptrs[1] = replacement[1];
    ptrs[2] = replacement[0];
    fill_bytes(ptrs[0], sizes[c] < 32 ? sizes[c] : 32, (unsigned)c);
    fill_bytes(ptrs[1], sizes[c] < 32 ? sizes[c] : 32, (unsigned)(c+1));
    fill_bytes(ptrs[2], sizes[c] < 32 ? sizes[c] : 32, (unsigned)(c+2));
    for (i = 0; i < 2048; i += 2) {
      if (!check_bytes(ptrs[i], sizes[c] < 32 ? sizes[c] : 32,
                       (unsigned)(c+i))) return 0;
      lj_page_alloc_f(pas, ptrs[i], sizes[c], 0);
    }
    for (i = 2047; i >= 1; i -= 2)
      lj_page_alloc_f(pas, ptrs[i], sizes[c], 0);
  }
  return 1;
}

static int realloc_transitions(void *pas)
{
  LJPageAllocTestStats stats;
  void *ptr, *next;

  ptr = lj_page_alloc_f(pas, NULL, 0, 57);
  if (ptr == NULL) return 0;
  fill_bytes(ptr, 57, 1);
  next = lj_page_alloc_f(pas, ptr, 57, 64);
  if (next != ptr || !check_bytes(next, 57, 1)) return 0;
  ptr = lj_page_alloc_f(pas, next, 64, 65);
  if (ptr == NULL || ptr == next || !check_bytes(ptr, 57, 1)) return 0;
  lj_page_alloc_f(pas, ptr, 65, 0);

  ptr = lj_page_alloc_f(pas, NULL, 0, 128);
  if (ptr == NULL) return 0;
  fill_bytes(ptr, 128, 2);
  ptr = lj_page_alloc_f(pas, ptr, 128, 2048);
  if (ptr == NULL || !check_bytes(ptr, 128, 2)) return 0;
  ptr = lj_page_alloc_f(pas, ptr, 2048, 96);
  if (ptr == NULL || !check_bytes(ptr, 96, 2)) return 0;
  lj_page_alloc_f(pas, ptr, 96, 0);

  ptr = lj_page_alloc_f(pas, NULL, 0, 2048);
  if (ptr == NULL) return 0;
  fill_bytes(ptr, 256, 3);
  ptr = lj_page_alloc_f(pas, ptr, 2048, 4096);
  if (ptr == NULL || !check_bytes(ptr, 256, 3)) return 0;
  lj_page_alloc_f(pas, ptr, 4096, 0);

  ptr = lj_page_alloc_f(pas, NULL, 0, 64);
  if (ptr == NULL) return 0;
  fill_bytes(ptr, 64, 4);
  lj_page_alloc_test_get_stats(&stats);
  lj_page_alloc_test_fail_at(stats.request_calls + 1);
  next = lj_page_alloc_f(pas, ptr, 64, 65);
  if (next != NULL || !check_bytes(ptr, 64, 4)) return 0;
  lj_page_alloc_test_fail_at(0);
  lj_page_alloc_f(pas, ptr, 64, 0);

  ptr = lj_page_alloc_f(pas, NULL, 0, 128);
  if (ptr == NULL) return 0;
  fill_bytes(ptr, 128, 5);
  lj_page_alloc_test_get_stats(&stats);
  lj_page_alloc_test_fail_at(stats.request_calls + 1);
  next = lj_page_alloc_f(pas, ptr, 128, 2048);
  if (next != NULL || !check_bytes(ptr, 128, 5)) return 0;
  lj_page_alloc_test_fail_at(0);
  lj_page_alloc_f(pas, ptr, 128, 0);

  ptr = lj_page_alloc_f(pas, NULL, 0, 2048);
  if (ptr == NULL) return 0;
  fill_bytes(ptr, 128, 6);
  lj_page_alloc_test_get_stats(&stats);
  lj_page_alloc_test_fail_at(stats.request_calls + 1);
  next = lj_page_alloc_f(pas, ptr, 2048, 128);
  if (next != NULL || !check_bytes(ptr, 128, 6)) return 0;
  lj_page_alloc_test_fail_at(0);
  lj_page_alloc_f(pas, ptr, 2048, 0);

  ptr = lj_page_alloc_f(pas, NULL, 0, 2048);
  if (ptr == NULL) return 0;
  fill_bytes(ptr, 128, 7);
  lj_page_alloc_test_get_stats(&stats);
  lj_page_alloc_test_fail_at(stats.request_calls + 1);
  next = lj_page_alloc_f(pas, ptr, 2048, 4096);
  if (next != NULL || !check_bytes(ptr, 128, 7)) return 0;
  lj_page_alloc_test_fail_at(0);
  lj_page_alloc_f(pas, ptr, 2048, 0);

  ptr = lj_page_alloc_f(pas, NULL, 0, 57);
  if (ptr == NULL) return 0;
  lj_page_alloc_test_get_stats(&stats);
  lj_page_alloc_test_fail_at(stats.request_calls + 1);
  next = lj_page_alloc_f(pas, ptr, 57, 64);
  if (next != ptr) return 0;
  lj_page_alloc_test_get_stats(&stats);
  lj_page_alloc_test_fail_at(0);
  lj_page_alloc_f(pas, ptr, 64, 0);
  return 1;
}

static int live_page_teardown(PRNGState *prng)
{
  LJPageAllocTestStats stats;
  void *pas;
  int i;
  lj_page_alloc_test_reset();
  pas = lj_page_alloc_create(prng);
  if (pas == NULL) return 0;
  lj_page_alloc_setprng(pas, prng);
  for (i = 0; i < 1500; i++) {
    if (lj_page_alloc_f(pas, NULL, 0, 8) == NULL) return 0;
  }
  for (i = 0; i < 40; i++) {
    if (lj_page_alloc_f(pas, NULL, 0, 1024) == NULL) return 0;
  }
  if (lj_page_alloc_f(pas, NULL, 0, 4096) == NULL) return 0;
  lj_page_alloc_destroy(pas);
  lj_page_alloc_test_get_stats(&stats);
  return stats.backing_created == stats.backing_destroyed &&
         stats.wrapper_created == stats.wrapper_destroyed &&
         stats.pages_created == stats.pages_destroyed &&
         stats.pooled_allocations > stats.pooled_frees;
}

int main(void)
{
  PRNGState prng;
  LJPageAllocTestStats stats;
  void *pas;
  lj_prng_seed_fixed(&prng);
  lj_page_alloc_test_reset();
  pas = lj_page_alloc_create(&prng);
  if (pas == NULL) return 1;
  lj_page_alloc_setprng(pas, &prng);
  {
    void *pooled;
    void *delegated;
    LJPageAllocTestStats before, after;
    lj_page_alloc_test_get_stats(&before);
    pooled = lj_page_alloc_f(pas, NULL, 0, 1024);
    delegated = lj_page_alloc_f(pas, NULL, 0, 1025);
    if (pooled == NULL || delegated == NULL) return 1;
    lj_page_alloc_test_get_stats(&after);
    if (after.pooled_allocations != before.pooled_allocations + 1 ||
        after.pages_created != before.pages_created + 1) return 1;
    lj_page_alloc_f(pas, pooled, 1024, 0);
    lj_page_alloc_f(pas, delegated, 1025, 0);
  }
  if (!boundary_requests(pas) || !class_page_transitions(pas) ||
      !realloc_transitions(pas)) {
    fprintf(stderr, "page allocator boundary test failed\n");
    return 1;
  }
  lj_page_alloc_destroy(pas);
  lj_page_alloc_test_get_stats(&stats);
  if (stats.backing_created != stats.backing_destroyed ||
      stats.wrapper_created != stats.wrapper_destroyed ||
      stats.pages_created != stats.pages_destroyed ||
      stats.pooled_allocations != stats.pooled_frees) {
    fprintf(stderr, "page allocator accounting did not balance\n");
    return 1;
  }
  if (!live_page_teardown(&prng)) {
    fprintf(stderr, "page allocator live teardown failed\n");
    return 1;
  }
  puts("ok");
  return 0;
}
C
close $c;

my @compile = ($cc, "-I$Bin/../src", '-DLUAJIT_USE_PAGEALLOC',
               '-DLUAJIT_PAGEALLOC_TEST', '-o', 'pageallocboundary',
               'pageallocboundary.c', $lib, '-lm', '-ldl');
my $compile_out = `@compile 2>&1`;
die "Cannot compile page allocator boundary test:\n$compile_out" if $? != 0;

system './pageallocboundary >stdout.txt 2>stderr.txt';
my $rc = $? >> 8;
open my $outfh, '<', 'stdout.txt' or die $!;
my $out = do { local $/; <$outfh> };
close $outfh;
open my $errfh, '<', 'stderr.txt' or die $!;
my $err = do { local $/; <$errfh> };
close $errfh;
chdir $cwd or die $!;

is "$rc:$out$err", "0:ok\n",
    'page classes, page transitions, and realloc boundaries preserve data';
done_testing();
