#!/usr/bin/env bash
#
# Back-to-back HLS NDVI benchmark: garry vs ODC + dask, same workload as
# compare.sh but B04/B08 -> temporal median each -> NDVI. garry runs the wired
# general path (collect -> .gd_decompose -> .execute_gd_reduce); ODC computes
# two medians + the arithmetic. Reports every run, best-of, and an output check.
#
# Usage:  benchmarks/compare-ndvi.sh [REPS]     (default REPS=2)

set -euo pipefail
cd "$(dirname "$0")"

REPS="${1:-${REPS:-2}}"
PYTHON=".venv/bin/python"
GARRY_TIF="ndvi_garry.tif"
ODC_TIF="ndvi_python.tif"

command -v Rscript >/dev/null || { echo "Rscript not found" >&2; exit 1; }
[ -x "$PYTHON" ] || { echo "ODC venv missing at $PYTHON" >&2; exit 1; }

parse_secs() { grep -oE '[0-9]+\.[0-9]+' <<<"$1" | tail -1; }

echo "== HLS NDVI: garry vs ODC =="
echo "   reps: $REPS   device: ${GARRY_DEVICE:-cpu}"
echo

garry_times=(); odc_times=()
for i in $(seq 1 "$REPS"); do
  echo "-- rep $i/$REPS --"
  g_out=$(Rscript ndvi-garry.R auto 2>/dev/null | grep "processing time")
  g_sec=$(parse_secs "$g_out"); garry_times+=("$g_sec")
  echo "   garry : ${g_sec}s"
  o_out=$("$PYTHON" ndvi-odc.py 2>/dev/null | grep "Elapsed time")
  o_sec=$(parse_secs "$o_out"); odc_times+=("$o_sec")
  echo "   odc   : ${o_sec}s"
done

best() { printf '%s\n' "$@" | sort -n | head -1; }
g_best=$(best "${garry_times[@]}"); o_best=$(best "${odc_times[@]}")
echo
echo "== best-of-$REPS =="
printf "   garry : %ss\n" "$g_best"
printf "   odc   : %ss\n" "$o_best"
awk -v g="$g_best" -v o="$o_best" 'BEGIN{ printf "   garry is %.2fx ODC (%.2fs faster)\n", o/g, o-g }'

echo
echo "== output check ($GARRY_TIF vs $ODC_TIF) =="
if [ -f "$GARRY_TIF" ] && [ -f "$ODC_TIF" ]; then
  Rscript - "$GARRY_TIF" "$ODC_TIF" <<'RS'
suppressWarnings(suppressMessages(library(gdalraster)))
a <- commandArgs(TRUE)
rd <- function(p) { ds <- new(GDALRaster, p); on.exit(ds$close())
  nx <- ds$getRasterXSize(); ny <- ds$getRasterYSize()
  v <- ds$read(1, 0, 0, nx, ny, nx, ny); v[v == -9999] <- NA; v }
g <- rd(a[1]); o <- rd(a[2]); d <- abs(g - o)
cat(sprintf("   %12s %12s %12s\n", "garry.med", "odc.med", "mean|Δ|"))
cat(sprintf("   %12.4f %12.4f %12.6f\n",
            median(g, na.rm = TRUE), median(o, na.rm = TRUE), mean(d, na.rm = TRUE)))
cat(sprintf("   correlation: %.5f\n", cor(as.vector(g), as.vector(o), use = "complete.obs")))
RS
else
  echo "   (one or both outputs missing; skipped)"
fi
