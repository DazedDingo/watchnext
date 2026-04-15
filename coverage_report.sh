#!/usr/bin/env bash
# Summarises lcov.info into a per-file coverage table + total.
# Usage: ./coverage_report.sh
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -f coverage/lcov.info ]; then
  echo "coverage/lcov.info missing. Run: flutter test --coverage"
  exit 1
fi
awk '
  /^SF:/   { file=$0; sub(/^SF:/,"",file); next }
  /^LF:/   { lf=$0; sub(/^LF:/,"",lf); total[file]=lf; grand_total += lf; next }
  /^LH:/   { lh=$0; sub(/^LH:/,"",lh); covered[file]=lh; grand_covered += lh; next }
  END {
    for (f in total) {
      pct = (total[f] > 0) ? (100 * covered[f] / total[f]) : 0
      printf "%5.1f%%  %4d/%-4d  %s\n", pct, covered[f], total[f], f
    }
    pct = (grand_total > 0) ? (100 * grand_covered / grand_total) : 0
    printf "\n%5.1f%%  %4d/%-4d  TOTAL (lib/)\n", pct, grand_covered, grand_total
  }
' coverage/lcov.info | sort
