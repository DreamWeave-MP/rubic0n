/*
** Head-to-head allocation and collection benchmark: LuaJIT against Luau.
**
** Both runtimes are driven through their C API only, so this measures the
** allocator and the collector and nothing else: no compiler, no interpreter,
** no binding layer. Each driver includes this file, defines NAME, SETUP(L)
** and NEWUD(L) and then includes h2h_main.h.
**
** Three shapes, each timed as "allocate with the collector stopped" and
** "two full collections", in nanoseconds per object:
**
**   churn          N small userdata with a native destructor, all garbage.
**   half-retained  N of the same, every other one kept alive by a table.
**   table          N empty tables, all garbage.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define PAYLOAD		28	/* Sol's payload for an osg::Vec3f is 27. */
#define MAXROUNDS	128

static int dtor_calls;

static double now_s(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static int cmpd(const void *a, const void *b)
{
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}

static double median(double *v, int n)
{
  qsort(v, (size_t)n, sizeof(double), cmpd);
  return v[n/2];
}
