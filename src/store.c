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
 * FP contraction is off: `v * scale + offset` must round twice,
 * exactly as the R expression it replaces, or the f32 store stops being
 * byte-identical to the doubles oracle on FMA hosts. It is set here
 * rather than as a Makevars flag, which R CMD check rejects as
 * non-portable: GCC ignores the standard pragma and takes its own.
 */
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC optimize("fp-contract=off")
#else
#pragma STDC FP_CONTRACT OFF
#endif

#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

SEXP garry_malloc_trim(void);
SEXP garry_statvfs_mb(SEXP path);

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

/* A float plane as integers, NaN folded to `nd`. Returns 0, leaving
 * `o` partly written, at the first value that is not a whole number in
 * int range, or at a NaN with no sentinel (the caller's doubles carry
 * it to the integer-output check). */
static int float_plane_int(int *o, const unsigned char *src, R_xlen_t n_el,
                           int es, int has_nd, int nd) {
  for (R_xlen_t i = 0; i < n_el; i++) {
    const double v = es == 8 ? ((const double *) src)[i]
                             : (double) ((const float *) src)[i];
    if (isnan(v)) {
      if (!has_nd) return 0;
      o[i] = nd;
    } else if (v >= -2147483647.0 && v <= 2147483647.0 && v == (int) v) {
      o[i] = (int) v;
    } else {
      return 0;
    }
  }
  return 1;
}

/* One plane of a payload as the R vector GDAL writes: doubles for
 * float payloads (NaN folded to `nodata` when one is given), integers
 * for the quantized integer payloads. `off` is the plane's byte
 * offset, `n` its element count. With `as_int` (an integer output), a
 * float plane of whole numbers comes back as integers: GDAL converts
 * those to the band type 4x faster than doubles, and clamps a whole
 * number the same way from either. */
SEXP garry_sv_plane(SEXP x, SEXP off, SEXP n, SEXP gdt, SEXP nodata,
                    SEXP as_int) {
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
  if (is_float && asLogical(as_int) == TRUE &&
      (!has_nd || (fabs(nd) <= 2147483647.0 && nd == (int) nd))) {
    out = PROTECT(allocVector(INTSXP, n_el));
    if (float_plane_int(INTEGER(out), src, n_el, es, has_nd, (int) nd)) {
      UNPROTECT(1);
      return out;
    }
    UNPROTECT(1);
  }
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

/* The same tail into a [ny, nx] double matrix: GDAL's row-major buffer
 * transposed to R's column-major order in the same pass, blocked so
 * both sides stay in cache. Mirrors .gdal_finish_vec()'s doubles path
 * (no f32 cast), which the single-threaded executor's values rest on. */
SEXP garry_finish_matrix(SEXP v, SEXP ny_, SEXP nx_, SEXP nodata,
                         SEXP scale, SEXP offset) {
  const R_xlen_t ny = (R_xlen_t) asReal(ny_), nx = (R_xlen_t) asReal(nx_);
  if (XLENGTH(v) != ny * nx) error("read buffer does not match its window");
  const int has_nd = LENGTH(nodata) == 1;
  const double nd = has_nd ? REAL(nodata)[0] : 0.0;
  const int has_sc = LENGTH(scale) == 1;
  const double sc = has_sc ? REAL(scale)[0] : 1.0;
  const double of = has_sc && LENGTH(offset) == 1 ? REAL(offset)[0] : 0.0;
  const int is_int = TYPEOF(v) == INTSXP || TYPEOF(v) == LGLSXP;
  if (!is_int && TYPEOF(v) != REALSXP) error("read buffer must be numeric");
  const int *vi = is_int ? INTEGER(v) : NULL;
  const double *vd = is_int ? NULL : REAL(v);
  SEXP out = PROTECT(allocMatrix(REALSXP, (int) ny, (int) nx));
  double *o = REAL(out);
  const R_xlen_t B = 64;
  for (R_xlen_t r0 = 0; r0 < ny; r0 += B) {
    const R_xlen_t r1 = r0 + B < ny ? r0 + B : ny;
    for (R_xlen_t c0 = 0; c0 < nx; c0 += B) {
      const R_xlen_t c1 = c0 + B < nx ? c0 + B : nx;
      for (R_xlen_t r = r0; r < r1; r++) {
        for (R_xlen_t c = c0; c < c1; c++) {
          const R_xlen_t i = r * nx + c;
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
          o[r + c * ny] = x;
        }
      }
    }
  }
  UNPROTECT(1);
  return out;
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

/* Grow a rank-2 or rank-3 row-major payload to ny2 x nx2 planes, its
 * cells at the top left and the new rows and columns filled with the
 * element `fill` (es bytes: NaN for floats, zeros for integers). Edge
 * chunks run a stage's modal kernel this way. */
SEXP garry_sv_pad(SEXP v, SEXP dims, SEXP es_, SEXP fill, SEXP ny2_, SEXP nx2_) {
  if (TYPEOF(v) != RAWSXP || TYPEOF(fill) != RAWSXP) error("payload and fill must be raw");
  const int nd = LENGTH(dims);
  const int *d = INTEGER(dims);
  const int es = asInteger(es_);
  const R_xlen_t nb = nd == 3 ? d[0] : 1;
  const R_xlen_t ny = d[nd - 2], nx = d[nd - 1];
  const R_xlen_t ny2 = asInteger(ny2_), nx2 = asInteger(nx2_);
  if (XLENGTH(fill) != es) error("fill must be one element");
  if (ny2 < ny || nx2 < nx) error("padded planes must not be smaller");
  if (nb * ny * nx * es != XLENGTH(v)) error("payload size does not match its dims");
  const R_xlen_t n = nb * ny2 * nx2;
  SEXP out = PROTECT(allocVector(RAWSXP, n * es));
  unsigned char *dst = RAW(out);
  const unsigned char *f = RAW(fill);
  for (R_xlen_t i = 0; i < n; i++) memcpy(dst + (size_t) i * es, f, es);
  const unsigned char *src = RAW(v);
  const size_t row_in = (size_t) nx * es, row_out = (size_t) nx2 * es;
  for (R_xlen_t b = 0; b < nb; b++) {
    for (R_xlen_t r = 0; r < ny; r++) {
      memcpy(dst + ((size_t) b * ny2 + r) * row_out, src + ((size_t) b * ny + r) * row_in, row_in);
    }
  }
  UNPROTECT(1);
  return out;
}

/* Copy a row-major f32 store payload -- one [h, w] plane or a [nb, h, w]
 * stack -- into a column-major double array of dims (NY, NX, NK) at
 * (y0, x0, k0): out[(y0 + y) + (x0 + x) * NY + (k0 + b) * NY * NX] =
 * plane_b[y * w + x]. The read-only collect path assembles its result
 * this way in one pass: no per-chunk matrix transpose, no assemble copy,
 * no final aperm. Blocked so both sides stay cache-resident. */
SEXP garry_f32_into_colmajor(SEXP out, SEXP raw, SEXP origin, SEXP dims) {
  const double *o = REAL(origin); /* y0, x0, k0 */
  const double *d = REAL(dims);   /* NY, NX, NK, nb, h, w */
  R_xlen_t y0 = (R_xlen_t)o[0], x0 = (R_xlen_t)o[1], k0 = (R_xlen_t)o[2];
  R_xlen_t NY = (R_xlen_t)d[0], NX = (R_xlen_t)d[1], NK = (R_xlen_t)d[2];
  R_xlen_t nb = (R_xlen_t)d[3], h = (R_xlen_t)d[4], w = (R_xlen_t)d[5];
  if (TYPEOF(out) != REALSXP || TYPEOF(raw) != RAWSXP) {
    Rf_error("garry_f32_into_colmajor: out must be double, raw must be raw");
  }
  if (y0 < 0 || x0 < 0 || k0 < 0 || y0 + h > NY || x0 + w > NX || k0 + nb > NK) {
    Rf_error("garry_f32_into_colmajor: window outside the target array");
  }
  if (XLENGTH(raw) < nb * h * w * 4 || XLENGTH(out) < NY * NX * NK) {
    Rf_error("garry_f32_into_colmajor: payload or target too short");
  }
  const float *src = (const float *)RAW(raw);
  double *dst = REAL(out);
  const R_xlen_t B = 64;
  for (R_xlen_t b = 0; b < nb; b++) {
    const float *plane = src + b * h * w;
    double *slab = dst + (k0 + b) * NY * NX;
    for (R_xlen_t yy = 0; yy < h; yy += B) {
      R_xlen_t ye = yy + B < h ? yy + B : h;
      for (R_xlen_t xx = 0; xx < w; xx += B) {
        R_xlen_t xe = xx + B < w ? xx + B : w;
        for (R_xlen_t x = xx; x < xe; x++) {
          double *col = slab + (x0 + x) * NY + y0;
          for (R_xlen_t y = yy; y < ye; y++) {
            col[y] = (double)plane[y * w + x];
          }
        }
      }
    }
  }
  return R_NilValue;
}

/* An uninitialised double vector of length n, for a result the caller
 * fills completely (the read-only collect writes every cell). */
SEXP garry_alloc_double(SEXP n) {
  return Rf_allocVector(REALSXP, (R_xlen_t)REAL(n)[0]);
}

/* Copy an integer band read into `dst` from element `off` on, folding
 * NA (GDAL's nodata mask) and `nodata` (the source node's sentinel) to
 * `out_nd`, or NA without one. `dst` is a private plane the caller
 * allocated; it is filled in place. Returns whether a nodata cell met
 * no sentinel. */
SEXP garry_fold_int_into(SEXP dst, SEXP off, SEXP src, SEXP nodata,
                         SEXP out_nd) {
  if (TYPEOF(dst) != INTSXP || TYPEOF(src) != INTSXP) {
    error("integer planes expected");
  }
  const R_xlen_t o0 = (R_xlen_t) asReal(off);
  const R_xlen_t n = XLENGTH(src);
  if (o0 < 0 || o0 + n > XLENGTH(dst)) {
    error("read of %lld cells at %lld overruns a %lld cell plane",
          (long long) n, (long long) o0, (long long) XLENGTH(dst));
  }
  const int has_nd = LENGTH(nodata) == 1;
  const double nd = has_nd ? REAL(nodata)[0] : 0.0;
  const int has_out = LENGTH(out_nd) == 1;
  const int ond = has_out ? (int) REAL(out_nd)[0] : NA_INTEGER;
  const int *s = INTEGER(src);
  int *d = INTEGER(dst) + o0;
  int bare = 0;
  for (R_xlen_t i = 0; i < n; i++) {
    const int v = s[i];
    if (v == NA_INTEGER || (has_nd && (double) v == nd)) {
      d[i] = ond;
      bare |= !has_out;
    } else {
      d[i] = v;
    }
  }
  return ScalarLogical(bare);
}

/* A row-major vector of `nr` rows of `nc` elements with its rows in
 * reverse order: a south-up file read in its own row order, put north
 * first (one memcpy a row, no index vector). */
SEXP garry_flip_rows(SEXP v, SEXP nr_, SEXP nc_) {
  const R_xlen_t nr = (R_xlen_t) asReal(nr_), nc = (R_xlen_t) asReal(nc_);
  if (nr * nc != XLENGTH(v)) error("%lld x %lld rows do not hold %lld elements",
                                   (long long) nr, (long long) nc,
                                   (long long) XLENGTH(v));
  SEXP out = PROTECT(allocVector(TYPEOF(v), XLENGTH(v)));
  const char *s;
  char *d;
  size_t es;
  switch (TYPEOF(v)) {
  case INTSXP:
    s = (const char *) INTEGER_RO(v);
    d = (char *) INTEGER(out);
    es = sizeof(int);
    break;
  case LGLSXP:
    s = (const char *) LOGICAL_RO(v);
    d = (char *) LOGICAL(out);
    es = sizeof(int);
    break;
  case REALSXP:
    s = (const char *) REAL_RO(v);
    d = (char *) REAL(out);
    es = sizeof(double);
    break;
  case RAWSXP:
    s = (const char *) RAW_RO(v);
    d = (char *) RAW(out);
    es = 1;
    break;
  default:
    UNPROTECT(1);
    error("cannot flip a vector of this type");
  }
  const size_t row = (size_t) nc * es;
  for (R_xlen_t r = 0; r < nr; r++) {
    memcpy(d + (size_t) r * row, s + (size_t) (nr - 1 - r) * row, row);
  }
  UNPROTECT(1);
  return out;
}

/* Lay the valid (non-NaN) cells of a (nb, h, w) row-major f32 payload
 * over the (nb, y, x) f32 buffer `dst` at column c0 and row r0, in
 * place: one source's share of a mosaic window, a later source's valid
 * cells winning. `geo` = (nb, x, y, c0, r0, w, h). A NULL `dst` starts
 * a new window, every cell NaN. */
SEXP garry_paste_f32(SEXP dst, SEXP src, SEXP geo) {
  if (LENGTH(geo) != 7) error("paste geometry is (nb, x, y, c0, r0, w, h)");
  const double *g = REAL(geo);
  const R_xlen_t nb = (R_xlen_t) g[0], x = (R_xlen_t) g[1], y = (R_xlen_t) g[2];
  const R_xlen_t c0 = (R_xlen_t) g[3], r0 = (R_xlen_t) g[4];
  const R_xlen_t w = (R_xlen_t) g[5], h = (R_xlen_t) g[6];
  int prot = 0;
  if (isNull(dst)) {
    dst = PROTECT(allocVector(RAWSXP, nb * x * y * 4));
    prot = 1;
    float *d = (float *) RAW(dst);
    for (R_xlen_t i = 0; i < nb * x * y; i++) d[i] = NAN;
  }
  if (TYPEOF(dst) != RAWSXP || TYPEOF(src) != RAWSXP) {
    error("raw f32 payloads expected");
  }
  if (c0 < 0 || r0 < 0 || c0 + w > x || r0 + h > y ||
      XLENGTH(dst) != nb * x * y * 4 || XLENGTH(src) != nb * w * h * 4) {
    error("a %lld x %lld part at (%lld, %lld) does not fit a %lld x %lld window",
          (long long) w, (long long) h, (long long) c0, (long long) r0,
          (long long) x, (long long) y);
  }
  const float *s = (const float *) RAW(src);
  float *d = (float *) RAW(dst);
  for (R_xlen_t b = 0; b < nb; b++) {
    for (R_xlen_t r = 0; r < h; r++) {
      const float *sr = s + (b * h + r) * w;
      float *dr = d + (b * y + r0 + r) * x + c0;
      for (R_xlen_t c = 0; c < w; c++) {
        if (!isnan(sr[c])) dr[c] = sr[c];
      }
    }
  }
  UNPROTECT(prot);
  return dst;
}

/* Decode a slab of codes into rows of `dst` from cell `off`, in place:
 * `codes` holds (ny * by) rows of (nx * bx) codes, north first, and
 * each of the ny x nx target cells takes the mean of the decoded values
 * of its by x bx block (the value itself when the block is one code),
 * NaN where none is valid. A code decodes to table[code - lo]; NA (a
 * masked code), a code outside the table and a NaN entry (the nodata
 * code) drop out. The sum runs in double over the block row by row, as
 * GDAL averages a Float32 band. `geo` = (lo, bx, by, nx, ny). */
SEXP garry_decode_into(SEXP dst, SEXP off, SEXP codes, SEXP geo, SEXP table) {
  if (TYPEOF(dst) != REALSXP || TYPEOF(codes) != INTSXP || TYPEOF(table) != REALSXP) {
    error("double output, integer codes and a double table expected");
  }
  if (LENGTH(geo) != 5) error("decode geometry is (lo, bx, by, nx, ny)");
  const double *g = REAL(geo);
  const int lo = (int) g[0];
  const R_xlen_t bx = (R_xlen_t) g[1], by = (R_xlen_t) g[2];
  const R_xlen_t nx = (R_xlen_t) g[3], ny = (R_xlen_t) g[4];
  const R_xlen_t o0 = (R_xlen_t) asReal(off);
  const R_xlen_t sw = nx * bx;
  if (XLENGTH(codes) != sw * ny * by || o0 < 0 || o0 + nx * ny > XLENGTH(dst)) {
    error("%lld codes do not decode to %lld x %lld cells at %lld of %lld",
          (long long) XLENGTH(codes), (long long) nx, (long long) ny,
          (long long) o0, (long long) XLENGTH(dst));
  }
  const int nt = LENGTH(table);
  const double *t = REAL(table);
  const int *c = INTEGER(codes);
  double *d = REAL(dst) + o0;
  for (R_xlen_t r = 0; r < ny; r++) {
    for (R_xlen_t q = 0; q < nx; q++) {
      double sum = 0.0;
      R_xlen_t n = 0;
      for (R_xlen_t j = 0; j < by; j++) {
        const int *row = c + (r * by + j) * sw + q * bx;
        for (R_xlen_t i = 0; i < bx; i++) {
          const int code = row[i];
          if (code == NA_INTEGER) continue;
          const int k = code - lo;
          if (k < 0 || k >= nt || isnan(t[k])) continue;
          sum += t[k];
          n++;
        }
      }
      d[r * nx + q] = n ? sum / (double) n : NAN;
    }
  }
  return dst;
}

/* Block means of a slab of f32 band planes into rows of `dst`, in
 * place: `src` holds nb planes of (ny * k) rows of (nx * k) values, and
 * each of the ny x nx cells from row offset `off` of every plane of
 * `dst` (nb planes of `n_px` doubles) takes the mean of its k x k
 * block's valid values, NaN where none is. With a table (codes stored
 * exactly as f32), a value is the code's decoded value table[code - lo]
 * instead, and NaN entries drop out. The sum runs in double over the
 * block row by row, as garry_decode_into() sums.
 * `geo` = (nb, k, nx, ny, n_px, lo). */
SEXP garry_coarsen_into(SEXP dst, SEXP off, SEXP src, SEXP geo, SEXP table) {
  if (TYPEOF(dst) != REALSXP || TYPEOF(src) != RAWSXP || TYPEOF(table) != REALSXP) {
    error("double output, raw f32 planes and a double table expected");
  }
  if (LENGTH(geo) != 6) error("coarsen geometry is (nb, k, nx, ny, n_px, lo)");
  const double *g = REAL(geo);
  const R_xlen_t nb = (R_xlen_t) g[0], k = (R_xlen_t) g[1];
  const R_xlen_t nx = (R_xlen_t) g[2], ny = (R_xlen_t) g[3];
  const R_xlen_t n_px = (R_xlen_t) g[4];
  const int lo = (int) g[5];
  const R_xlen_t o0 = (R_xlen_t) asReal(off);
  const R_xlen_t fw = nx * k, fh = ny * k;
  if (XLENGTH(src) != nb * fw * fh * 4 || o0 < 0 || o0 + nx * ny > n_px ||
      XLENGTH(dst) != nb * n_px) {
    error("a %lld x %lld slab of %lld planes does not coarsen into %lld cells at %lld",
          (long long) fw, (long long) fh, (long long) nb, (long long) n_px,
          (long long) o0);
  }
  const int nt = LENGTH(table);
  const double *t = REAL(table);
  const float *s = (const float *) RAW(src);
  for (R_xlen_t b = 0; b < nb; b++) {
    const float *sp = s + b * fw * fh;
    double *d = REAL(dst) + b * n_px + o0;
    for (R_xlen_t r = 0; r < ny; r++) {
      for (R_xlen_t q = 0; q < nx; q++) {
        double sum = 0.0;
        R_xlen_t n = 0;
        for (R_xlen_t j = 0; j < k; j++) {
          const float *row = sp + (r * k + j) * fw + q * k;
          for (R_xlen_t i = 0; i < k; i++) {
            const float x = row[i];
            if (isnan(x)) continue;
            double val = x;
            if (nt) {
              const int c = (int) x - lo;
              if (c < 0 || c >= nt || isnan(t[c])) continue;
              val = t[c];
            }
            sum += val;
            n++;
          }
        }
        d[r * nx + q] = n ? sum / (double) n : NAN;
      }
    }
  }
  return dst;
}

static const R_CallMethodDef CallEntries[] = {
  {"garry_coarsen_into", (DL_FUNC) &garry_coarsen_into, 5},
  {"garry_decode_into", (DL_FUNC) &garry_decode_into, 5},
  {"garry_flip_rows", (DL_FUNC) &garry_flip_rows, 3},
  {"garry_paste_f32", (DL_FUNC) &garry_paste_f32, 3},
  {"garry_malloc_trim", (DL_FUNC) &garry_malloc_trim, 0},
  {"garry_sv_plane", (DL_FUNC) &garry_sv_plane, 6},
  {"garry_fold_int_into", (DL_FUNC) &garry_fold_int_into, 5},
  {"garry_finish_f32", (DL_FUNC) &garry_finish_f32, 4},
  {"garry_finish_f32_into", (DL_FUNC) &garry_finish_f32_into, 6},
  {"garry_sv_window", (DL_FUNC) &garry_sv_window, 7},
  {"garry_sv_pad", (DL_FUNC) &garry_sv_pad, 6},
  {"garry_f32_into_colmajor", (DL_FUNC) &garry_f32_into_colmajor, 4},
  {"garry_alloc_double", (DL_FUNC) &garry_alloc_double, 1},
  {"garry_finish_matrix", (DL_FUNC) &garry_finish_matrix, 6},
  {"garry_statvfs_mb", (DL_FUNC) &garry_statvfs_mb, 1},
  {NULL, NULL, 0}
};

void R_init_garry(DllInfo *dll) {
  R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
}
