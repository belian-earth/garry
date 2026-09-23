/* Raw store payload byte work (design/f64-store.md, D19-D21).
 *
 * A store value is a raw vector of row-major element bytes tagged with
 * `gdim`/`gdt`. Taking a plane out of one with an R index vector walks
 * one integer per BYTE (a 17 M element index for a 2 M pixel f64
 * plane, 41 ms), and the read tail (sentinel -> NaN, band affine,
 * pack to f32) made five passes over doubles. Everything here is one
 * pass over the payload with no index vector, so a writer daemon does
 * IO rather than R vector arithmetic.
 *
 * FP contraction is off (src/Makevars): `v * scale + offset` must
 * round twice, exactly as the R expression it replaces, or the f32
 * store stops being byte-identical to the doubles oracle on FMA hosts.
 */
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

SEXP garry_malloc_trim(void);

/* Element size and family of a gdt tag. */
static int gdt_es(const char *gdt, int *is_float, int *is_signed) {
  *is_float = 0;
  *is_signed = 1;
  if (strcmp(gdt, "f64") == 0) {
    *is_float = 1;
    return 8;
  }
  if (strcmp(gdt, "f32") == 0) {
    *is_float = 1;
    return 4;
  }
  if (strcmp(gdt, "i32") == 0) return 4;
  if (strcmp(gdt, "i16") == 0) return 2;
  if (strcmp(gdt, "u16") == 0) {
    *is_signed = 0;
    return 2;
  }
  if (strcmp(gdt, "i8") == 0) return 1;
  if (strcmp(gdt, "u8") == 0) {
    *is_signed = 0;
    return 1;
  }
  error("unknown store payload dtype '%s'", gdt);
  return 0;
}

/* One plane of a payload as the R vector GDAL writes: doubles for
 * float payloads (NaN folded to `nodata` when one is given), integers
 * for the quantized integer payloads. `off` is the plane's byte
 * offset, `n` its element count. */
SEXP garry_sv_plane(SEXP x, SEXP off, SEXP n, SEXP gdt, SEXP nodata) {
  if (TYPEOF(x) != RAWSXP) error("payload must be raw");
  int is_float, is_signed;
  const int es = gdt_es(CHAR(STRING_ELT(gdt, 0)), &is_float, &is_signed);
  const R_xlen_t n_el = (R_xlen_t) asReal(n);
  const R_xlen_t b0 = (R_xlen_t) asReal(off);
  if (n_el < 0 || b0 < 0 || b0 + n_el * es > XLENGTH(x)) {
    error("plane [%lld, +%lld x %d) lies outside a %lld byte payload",
          (long long) b0, (long long) n_el, es, (long long) XLENGTH(x));
  }
  const unsigned char *src = RAW(x) + b0;
  const int has_nd = LENGTH(nodata) == 1;
  const double nd = has_nd ? REAL(nodata)[0] : 0.0;
  SEXP out;
  if (is_float) {
    out = PROTECT(allocVector(REALSXP, n_el));
    double *o = REAL(out);
    if (es == 8) {
      memcpy(o, src, (size_t) n_el * 8);
    } else {
      const float *s = (const float *) src;
      for (R_xlen_t i = 0; i < n_el; i++) o[i] = (double) s[i];
    }
    if (has_nd) {
      for (R_xlen_t i = 0; i < n_el; i++) {
        if (isnan(o[i])) o[i] = nd;
      }
    }
  } else {
    out = PROTECT(allocVector(INTSXP, n_el));
    int *o = INTEGER(out);
    switch (es) {
      case 4: memcpy(o, src, (size_t) n_el * 4); break;
      case 2:
        if (is_signed) {
          const int16_t *s = (const int16_t *) src;
          for (R_xlen_t i = 0; i < n_el; i++) o[i] = s[i];
        } else {
          const uint16_t *s = (const uint16_t *) src;
          for (R_xlen_t i = 0; i < n_el; i++) o[i] = s[i];
        }
        break;
      default:
        if (is_signed) {
          const int8_t *s = (const int8_t *) src;
          for (R_xlen_t i = 0; i < n_el; i++) o[i] = s[i];
        } else {
          for (R_xlen_t i = 0; i < n_el; i++) o[i] = src[i];
        }
    }
  }
  UNPROTECT(1);
  return out;
}

/* Read tail into an f32 buffer: sentinel and NA -> NaN, band affine,
 * cast. Mirrors .gdal_finish_vec()'s R arithmetic step for step. */
static void finish_f32(float *dst, SEXP v, SEXP nodata, SEXP scale,
                       SEXP offset) {
  const R_xlen_t n = XLENGTH(v);
  const int has_nd = LENGTH(nodata) == 1;
  const double nd = has_nd ? REAL(nodata)[0] : 0.0;
  const int has_sc = LENGTH(scale) == 1;
  const double sc = has_sc ? REAL(scale)[0] : 1.0;
  const double of = has_sc && LENGTH(offset) == 1 ? REAL(offset)[0] : 0.0;
  const int is_int = TYPEOF(v) == INTSXP || TYPEOF(v) == LGLSXP;
  if (!is_int && TYPEOF(v) != REALSXP) error("read buffer must be numeric");
  const int *vi = is_int ? INTEGER(v) : NULL;
  const double *vd = is_int ? NULL : REAL(v);
  for (R_xlen_t i = 0; i < n; i++) {
    double x;
    if (is_int) {
      x = vi[i] == NA_INTEGER ? R_NaN : (double) vi[i];
    } else {
      x = vd[i];
      if (ISNAN(x)) x = R_NaN;
    }
    if (has_nd && x == nd) x = R_NaN;
    if (has_sc) {
      x = x * sc;
      x = x + of;
    }
    dst[i] = (float) x;
  }
}

SEXP garry_finish_f32(SEXP v, SEXP nodata, SEXP scale, SEXP offset) {
  SEXP out = PROTECT(allocVector(RAWSXP, XLENGTH(v) * 4));
  finish_f32((float *) RAW(out), v, nodata, scale, offset);
  UNPROTECT(1);
  return out;
}

/* The same, written straight into a caller-owned raw buffer at byte
 * offset `off` (multi-band reads assemble their planes in place; the
 * buffer is private to the reader). */
SEXP garry_finish_f32_into(SEXP res, SEXP off, SEXP v, SEXP nodata,
                           SEXP scale, SEXP offset) {
  if (TYPEOF(res) != RAWSXP) error("destination must be raw");
  const R_xlen_t b0 = (R_xlen_t) asReal(off);
  if (b0 < 0 || b0 % 4 != 0 || b0 + XLENGTH(v) * 4 > XLENGTH(res)) {
    error("f32 plane does not fit the destination buffer");
  }
  finish_f32((float *) (RAW(res) + b0), v, nodata, scale, offset);
  return res;
}

/* Window of a rank-2 or rank-3 row-major payload: rows r0..r0+nr-1 and
 * columns c0..c0+nc-1 of every plane, gathered row by row (one memcpy
 * a row). Halo trims and producer-side part slicing both land here. */
SEXP garry_sv_window(SEXP v, SEXP dims, SEXP es_, SEXP r0_, SEXP c0_,
                     SEXP nr_, SEXP nc_) {
  if (TYPEOF(v) != RAWSXP) error("payload must be raw");
  const int nd = LENGTH(dims);
  const int *d = INTEGER(dims);
  const int es = asInteger(es_);
  const R_xlen_t r0 = asInteger(r0_), c0 = asInteger(c0_);
  const R_xlen_t nr = asInteger(nr_), nc = asInteger(nc_);
  const R_xlen_t nb = nd == 3 ? d[0] : 1;
  const R_xlen_t ny = d[nd - 2], nx = d[nd - 1];
  if (r0 < 0 || c0 < 0 || nr <= 0 || nc <= 0 || r0 + nr > ny || c0 + nc > nx) {
    error("window [%lld+%lld, %lld+%lld) exceeds the %lld x %lld payload",
          (long long) r0, (long long) nr, (long long) c0, (long long) nc,
          (long long) ny, (long long) nx);
  }
  if (nb * ny * nx * es != XLENGTH(v)) error("payload size does not match its dims");
  const size_t row_in = (size_t) nx * es;
  const size_t row_out = (size_t) nc * es;
  SEXP out = PROTECT(allocVector(RAWSXP, nb * nr * nc * es));
  const unsigned char *src = RAW(v);
  unsigned char *dst = RAW(out);
  for (R_xlen_t b = 0; b < nb; b++) {
    const unsigned char *plane = src + (size_t) b * ny * row_in;
    for (R_xlen_t r = 0; r < nr; r++) {
      memcpy(dst, plane + (size_t) (r0 + r) * row_in + (size_t) c0 * es, row_out);
      dst += row_out;
    }
  }
  UNPROTECT(1);
  return out;
}

static const R_CallMethodDef CallEntries[] = {
  {"garry_malloc_trim", (DL_FUNC) &garry_malloc_trim, 0},
  {"garry_sv_plane", (DL_FUNC) &garry_sv_plane, 5},
  {"garry_finish_f32", (DL_FUNC) &garry_finish_f32, 4},
  {"garry_finish_f32_into", (DL_FUNC) &garry_finish_f32_into, 6},
  {"garry_sv_window", (DL_FUNC) &garry_sv_window, 7},
  {NULL, NULL, 0}
};

void R_init_garry(DllInfo *dll) {
  R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
}
