# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

my $lib = abs_path("$Bin/../src/libluajit.a");
my $luajit = abs_path("$Bin/../src/luajit");
plan skip_all => "LuaJIT is not built"
    unless defined $lib && -f $lib && defined $luajit && -x $luajit;

my $cc = $ENV{CC} || "cc";
system("$cc --version >/dev/null 2>&1");
plan skip_all => "C compiler '$cc' is not available" if $? == -1 || ($? >> 8) == 127;

my $expect_pagealloc = $ENV{LUAJIT_TEST_NO_PAGEALLOC} ? 0 : 1;
my $expect_faults = $ENV{LUAJIT_TEST_PAGEALLOC_FAULTS} ? 1 : 0;
my $symbols = `nm "$lib" 2>/dev/null`;
my $page_symbol_present = $symbols =~ /\b[TtWw]\s+lj_page_alloc_f\b/ ? 1 : 0;
my $bundled_symbol_present = $symbols =~ /\b[TtWw]\s+lj_alloc_f\b/ ? 1 : 0;
my $is_sysmalloc = !$page_symbol_present && !$bundled_symbol_present;
BAIL_OUT('page allocator was requested but is absent from the built library')
    if $expect_pagealloc && !$page_symbol_present;
BAIL_OUT('default build unexpectedly contains the page allocator')
    if !$expect_pagealloc && $page_symbol_present;
my $identity_symbol = $expect_pagealloc ? 'lj_page_alloc_f' : 'lj_alloc_f';
my $can_check_identity = $symbols =~ /\b[TW]\s+\Q$identity_symbol\E\b/ ? 1 : 0;
my $fault_hooks_present = $symbols =~ /\b[TtWw]\s+lj_page_alloc_test_reset\b/ ? 1 : 0;
my $can_call_fault_hooks = $symbols =~ /\b[TW]\s+lj_page_alloc_test_reset\b/ ? 1 : 0;
BAIL_OUT('page allocator fault hooks were requested but are absent')
    if $expect_faults && !$fault_hooks_present;
BAIL_OUT('page allocator fault hooks are amalgamation-private')
    if $expect_faults && !$can_call_fault_hooks;
my $abi = `"$luajit" -e 'io.write(jit.arch, ":", tostring(require("ffi").abi("gc64")))'`;
die "Cannot detect built LuaJIT ABI" if $? != 0 || $abi !~ /^(\w+):(true|false)$/;
my ($arch, $gc64) = ($1, $2 eq 'true');

my $cwd = cwd;
my $dir = tempdir "testlj_pagealloc_lifecycle_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $c, '>', 'pagealloclifecycle.c' or die $!;
print $c <<'C';
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lj_arch.h"
#include "lj_alloc.h"
#include "lj_alloc_page.h"

#include <stdio.h>
#include <stdlib.h>

typedef struct AllocStats {
  int alloc_calls;
  int free_calls;
  int live_allocations;
} AllocStats;

static void *counting_alloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
  AllocStats *stats = (AllocStats *)ud;
  void *result;
  (void)osize;
  if (nsize == 0) {
    if (ptr != NULL) {
      stats->free_calls++;
      stats->live_allocations--;
    }
    free(ptr);
    return NULL;
  }
  stats->alloc_calls++;
  result = realloc(ptr, nsize);
  if (ptr == NULL && result != NULL) stats->live_allocations++;
  return result;
}

static int allocator_identity(lua_State *T)
{
  void *allocd = NULL;
  lua_Alloc allocf = lua_getallocf(T, &allocd);
#ifndef SKIP_ALLOCATOR_IDENTITY
#ifdef EXPECT_PAGEALLOC
  return allocf == lj_page_alloc_f && allocd != NULL;
#else
  return allocf == lj_alloc_f && allocd != NULL;
#endif
#else
#ifdef EXPECT_SYSMALLOC
  return allocf != NULL && allocd == NULL;
#else
  return allocf != NULL && allocd != NULL;
#endif
#endif
}

static void allocate_state_work(lua_State *T, int seed)
{
  int j;
  lua_createtable(T, 2048, 8);
  for (j = 1; j <= 2048; j++) {
    lua_pushfstring(T, "%d:%d:abcdefghijklmnopqrstuvwxyz", seed, j);
    lua_rawseti(T, -2, j);
  }
  lua_pop(T, 1);
}

static int repeat_internal_states(int n)
{
  int i;
  for (i = 0; i < n; i++) {
    lua_State *T = luaL_newstate();
    if (T == NULL || !allocator_identity(T)) return 0;
    luaL_openlibs(T);
    allocate_state_work(T, i);
    lua_close(T);
  }
  return 1;
}

static int simultaneous_internal_states(void)
{
  lua_State *states[16];
  int i;
  for (i = 0; i < 16; i++) states[i] = NULL;
  for (i = 0; i < 16; i++) {
    states[i] = luaL_newstate();
    if (states[i] == NULL || !allocator_identity(states[i])) goto fail;
    luaL_openlibs(states[i]);
    allocate_state_work(states[i], i);
  }
  for (i = 15; i >= 0; i--) lua_close(states[i]);
  return 1;
fail:
  for (i = 15; i >= 0; i--)
    if (states[i] != NULL) lua_close(states[i]);
  return 0;
}

static int custom_allocator_bypass(void)
{
#if LJ_64 && !LJ_GC64
  return 1;  /* Public custom allocators are unsupported in this mode. */
#else
  AllocStats stats = { 0, 0, 0 };
  void *allocd = NULL;
  lua_State *T = lua_newstate(counting_alloc, &stats);
  lua_Alloc allocf;
  if (T == NULL) return 0;
  allocf = lua_getallocf(T, &allocd);
  if (allocf != counting_alloc || allocd != &stats) return 0;
  luaL_openlibs(T);
  allocate_state_work(T, 1);
  lua_close(T);
  return stats.alloc_calls > 0 && stats.free_calls > 0 &&
         stats.live_allocations == 0;
#endif
}

#ifdef RUN_PAGEALLOC_FAULT_TESTS
static int balanced(const LJPageAllocTestStats *stats)
{
  return stats->backing_created == stats->backing_destroyed &&
         stats->wrapper_created == stats->wrapper_destroyed;
}

static int rejected_construction(int request)
{
  LJPageAllocTestStats stats;
  lua_State *T;
  lj_page_alloc_test_reset();
  lj_page_alloc_test_fail_at(request);
  T = luaL_newstate();
  if (T != NULL) {
    lua_close(T);
    return 0;
  }
  lj_page_alloc_test_get_stats(&stats);
  return balanced(&stats) && stats.backing_created == 1;
}

static int rejected_pointer(void)
{
  LJPageAllocTestStats stats;
  lua_State *T;
  lj_page_alloc_test_reset();
  lj_page_alloc_test_reject_pointer(1);
  T = luaL_newstate();
  if (T != NULL) {
    lua_close(T);
    return 0;
  }
  lj_page_alloc_test_get_stats(&stats);
  return balanced(&stats) && stats.wrapper_created == 1 &&
         stats.setprng_calls == 0;
}

static int prng_forward_and_growth(void)
{
  LJPageAllocTestStats stats;
  lua_State *T;
  int i;
  lj_page_alloc_test_reset();
  T = luaL_newstate();
  if (T == NULL) return 0;
  lj_page_alloc_test_get_stats(&stats);
  if (stats.setprng_calls != 1 || stats.wrapper_created != 1) {
    lua_close(T);
    return 0;
  }
  lua_createtable(T, 32768, 0);
  for (i = 1; i <= 32768; i++) {
    lua_pushfstring(T, "%08d:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", i);
    lua_rawseti(T, -2, i);
  }
  lua_pop(T, 1);
  lua_close(T);
  lj_page_alloc_test_get_stats(&stats);
  return balanced(&stats) && stats.request_calls > 100;
}

static int pagealloc_fault_contracts(void)
{
  return rejected_construction(1) &&  /* Wrapper-state request. */
         rejected_construction(2) &&  /* GG_State request. */
         rejected_construction(3) &&  /* First protected-init request. */
         rejected_pointer() &&
         prng_forward_and_growth();
}
#endif

int main(void)
{
  if (!repeat_internal_states(100) || !simultaneous_internal_states()) {
    fprintf(stderr, "internal allocator identity or lifecycle failed\n");
    return 1;
  }
  if (!custom_allocator_bypass()) {
    fprintf(stderr, "custom allocator ownership failed\n");
    return 1;
  }
#ifdef RUN_PAGEALLOC_FAULT_TESTS
  if (!pagealloc_fault_contracts()) {
    fprintf(stderr, "page allocator fault contract failed\n");
    return 1;
  }
#endif
  puts("ok");
  return 0;
}
C
close $c;

my @compile = ($cc, "-I$Bin/../src");
if ($expect_pagealloc) {
    push @compile, "-DLUAJIT_USE_PAGEALLOC", "-DEXPECT_PAGEALLOC";
}
if ($can_call_fault_hooks) {
    push @compile, "-DLUAJIT_PAGEALLOC_TEST", "-DRUN_PAGEALLOC_FAULT_TESTS";
}
if ($arch eq 'x64' && !$gc64) {
    push @compile, "-DLUAJIT_DISABLE_GC64";
}
push @compile, "-DEXPECT_SYSMALLOC" if $is_sysmalloc;
push @compile, "-DSKIP_ALLOCATOR_IDENTITY" unless $can_check_identity;
push @compile, "-o", "pagealloclifecycle", "pagealloclifecycle.c", $lib,
               "-lm", "-ldl";
my $compile_out = `@compile 2>&1`;
my $compile_rc = $? >> 8;
die "Cannot compile lifecycle test with '@compile':\n$compile_out"
    if $compile_rc != 0;

system './pagealloclifecycle >stdout.txt 2>stderr.txt';
my $rc = $? >> 8;
open my $outfh, '<', 'stdout.txt' or die $!;
my $out = do { local $/; <$outfh> };
close $outfh;
open my $errfh, '<', 'stderr.txt' or die $!;
my $err = do { local $/; <$errfh> };
close $errfh;
chdir $cwd or die $!;

my $mode = $expect_pagealloc ? 'page allocator'
    : $is_sysmalloc ? 'system allocator'
    : 'bundled allocator';
my $custom = ($arch eq 'x64' && !$gc64)
    ? 'custom allocator unsupported by this ABI'
    : 'custom allocator ownership';
is "$rc:$out$err", "0:ok\n",
    "$mode repeated and simultaneous lifecycle; $custom";

SKIP: {
    my $reason = $is_sysmalloc
        ? 'system allocator has no bundled callback identity'
        : 'allocator callback has amalgamation-private linkage';
    skip $reason, 1
        unless $can_check_identity;
    pass "$mode callback identity verified";
}

SKIP: {
    my $reason = $fault_hooks_present
        ? 'page allocator fault hooks have amalgamation-private linkage'
        : 'page allocator fault hooks are not present in this build';
    skip $reason, 1 unless $can_call_fault_hooks;
    pass 'page allocator rollback, teardown, and PRNG forwarding verified';
}

done_testing();
