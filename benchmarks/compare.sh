#!/usr/bin/env bash
#
# Back-to-back HLS median-composite benchmark: garry vs ODC + dask, same
# workload (HLS S30, 2023, Kuamut bbox, EPSG:20255 30 m grid, Fmask bits 0-3
# with opening(2)/dilation(3) cleanup, per-band temporal median of B04/B03/B02).
# Runs each engine REPS times, reports every run and the best-of, then compares
# the two output GeoTIFFs band by band so a speed win can't hide a wrong answer.
#
# Usage:  benchmarks/compare.sh [REPS]      (default REPS=1)
#   REPS=3 benchmarks/compare.sh            (env form also works)
#   GARRY_DEVICE=cuda benchmarks/compare.sh (garry on GPU)
#
# Both engines run from a warm state is NOT assumed: the first rep of each pays
# cold caches (daemon spawn / dask graph build), so REPS>=2 and read the best-of.

set -euo pipefail
cd "$(dirname "$0")"

REPS="${1:-${REPS:-1}}"
BANDS="${BANDS:-B04 B03 B02}"
PYTHON=".venv/bin/python"
GARRY_TIF="composite_garry.tif"
ODC_TIF="composite_python.tif"

command -v Rscript >/dev/null || { echo "Rscript not found" >&2; exit 1; }
[ -x "$PYTHON" ] || { echo "ODC venv missing at $PYTHON (see requirements-odc.txt)" >&2; exit 1; }

# Extract the trailing "NN.NN" seconds from an engine's stdout line.
parse_secs() { grep -oE '[0-9]+\.[0-9]+' <<<"$1" | tail -1; }

echo "== HLS median composite: garry vs ODC =="
echo "   bands: $BANDS   reps: $REPS   device: ${GARRY_DEVICE:-cpu}"
echo

garry_times=(); odc_times=()
for i in $(seq 1 "$REPS"); do
  echo "-- rep $i/$REPS --"

  g_out=$(Rscript hls-median-composite.R auto $BANDS 2>/dev/null | grep "processing time")
  g_sec=$(parse_secs "$g_out")
  garry_times+=("$g_sec")
  echo "   garry : ${g_sec}s"

  o_out=$("$PYTHON" hls-median-composite-odc.py 2>/dev/null | grep "Elapsed time")
  o_sec=$(parse_secs "$o_out")
  odc_times+=("$o_sec")
  echo "   odc   : ${o_sec}s"
done

best() { printf '%s\n' "$@" | sort -n | head -1; }
g_best=$(best "${garry_times[@]}")
o_best=$(best "${odc_times[@]}")

echo
echo "== best-of-$REPS =="
printf "   garry : %ss\n" "$g_best"
printf "   odc   : %ss\n" "$o_best"
awk -v g="$g_best" -v o="$o_best" 'BEGIN{ printf "   garry is %.2fx ODC (%.2fs faster)\n", o/g, o-g }'

# --- correctness: compare the two composites band by band --------------------
echo
echo "== output check ($GARRY_TIF vs $ODC_TIF) =="
if [ -f "$GARRY_TIF" ] && [ -f "$ODC_TIF" ]; then
  Rscript - "$GARRY_TIF" "$ODC_TIF" <<'RS'
suppressWarnings(suppressMessages(library(gdalraster)))
a <- commandArgs(TRUE)
rd <- function(p) { ds <- new(GDALRaster, p); on.exit(ds$close())
  nb <- ds$getRasterCount(); nx <- ds$getRasterXSize(); ny <- ds$getRasterYSize()
  lapply(seq_len(nb), function(b) {
    v <- ds$read(b, 0, 0, nx, ny, nx, ny); v[v == -9999] <- NA; v }) }
G <- rd(a[1]); O <- rd(a[2])
nb <- min(length(G), length(O))
cat(sprintf("   %-5s %12s %12s %12s\n", "band", "garry.med", "odc.med", "mean|Δ|"))
for (b in seq_len(nb)) {
  g <- G[[b]]; o <- O[[b]]; d <- abs(g - o)
  cat(sprintf("   %-5d %12.2f %12.2f %12.4f\n", b,
              median(g, na.rm = TRUE), median(o, na.rm = TRUE),
              mean(d, na.rm = TRUE)))
}
RS
else
  echo "   (one or both outputs missing; skipped)"
fi
