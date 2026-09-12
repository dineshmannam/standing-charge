#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "12  TEARDOWN  (all three)"

# One start/done pair per lever, opened inside the loop.
#
# mark reads the global $LEVER, and runsh eval's in this same shell, so after
# `source ./env.sh $L` runs the shell is on lever $L. Marking the phase outside
# the loop therefore opened it as A and closed it as C: one phase claiming two
# different levers, in the wallclock data this repo publishes as an example of
# careful measurement. Teardown is per-project work anyway -- verify-teardown.sh
# runs once per lever -- so a pair per lever is what actually happened.
#
# Setting LEVER before `mark teardown start` is what makes the opening row
# correct; without it the pair opens on the previous iteration's lever.
for L in A B C; do
  echo; echo "  --- lever $L ---"
  LEVER="$L"
  mark teardown start
  runsh "source ./env.sh $L >/dev/null && ./verify-teardown.sh"
  mark teardown done
done
