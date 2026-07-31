/* Return freed heap pages to the OS.
 *
 * Scan daemons churn multi-hundred-MB transients per chunk; glibc
 * retains the freed arenas (the scan-retention spike measured 475 of
 * 774 retained MB as trimmable), so a daemon "stands" at gigabytes it
 * is not using and wide scan pools OOM on memory nobody holds.
 * MALLOC_TRIM_THRESHOLD_ only covers the top-of-heap free() path;
 * malloc_trim(0) walks every arena. Glibc-only; elsewhere a no-op
 * returning FALSE.
 */
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#ifdef __GLIBC__
#include <malloc.h>
#endif

SEXP garry_malloc_trim(void) {
#ifdef __GLIBC__
  malloc_trim(0);
  return ScalarLogical(1);
#else
  return ScalarLogical(0);
#endif
}

static const R_CallMethodDef CallEntries[] = {
  {"garry_malloc_trim", (DL_FUNC) &garry_malloc_trim, 0},
  {NULL, NULL, 0}
};

void R_init_garry(DllInfo *dll) {
  R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
}
