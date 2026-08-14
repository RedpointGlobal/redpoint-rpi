#!/usr/bin/env bash
# Chart regression suite runner. Run from the repository root.
#
#   ./test-chart-suite.sh
#
# Suites:
#   test-datamaps-cache.sh     provider resolution + DataMaps semantics (S1-S5)
#   test-chart-structure.sh    mechanism lints: resolver bypass, range scope, helm lint (T7)
#   test-empty-env.sh          zero unexpected empty env values across the matrix (T5)
#   test-required-failures.sh  required settings fail render with actionable errors (T4)

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
FAIL=0
for t in test-datamaps-cache.sh test-chart-structure.sh test-empty-env.sh test-required-failures.sh; do
  echo "=============================== $t"
  if "$DIR/$t" > /tmp/chart-suite-$$.log 2>&1; then
    tail -1 /tmp/chart-suite-$$.log
  else
    cat /tmp/chart-suite-$$.log
    FAIL=1
  fi
done
rm -f /tmp/chart-suite-$$.log
if [ "$FAIL" -eq 0 ]; then echo "SUITE PASS"; else echo "SUITE FAILURES"; fi
exit "$FAIL"
