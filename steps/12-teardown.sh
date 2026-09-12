#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "12  TEARDOWN  (all three)"
mark teardown start
for L in A B C; do
  echo; echo "  --- lever $L ---"
  runsh "source ./env.sh $L >/dev/null && ./verify-teardown.sh"
done
mark teardown done
