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

/* Total, available and used space of the filesystem holding `path`, in
 * MB, as df reports them (available to unprivileged users; used =
 * blocks - free). NA where statvfs is missing or fails. The memory
 * sweep reads /dev/shm this way every few seconds: shelling out to df
 * forked the host R process each time. */
#ifndef _WIN32
#include <sys/statvfs.h>
#endif

SEXP garry_statvfs_mb(SEXP path) {
  SEXP out = PROTECT(allocVector(REALSXP, 3));
  double *o = REAL(out);
  o[0] = o[1] = o[2] = NA_REAL;
#ifndef _WIN32
  struct statvfs st;
  if (statvfs(CHAR(STRING_ELT(path, 0)), &st) == 0) {
    const double mb = (double) st.f_frsize / 1048576.0;
    o[0] = (double) st.f_blocks * mb;
    o[1] = (double) st.f_bavail * mb;
    o[2] = (double) (st.f_blocks - st.f_bfree) * mb;
  }
#endif
  UNPROTECT(1);
  return out;
}
