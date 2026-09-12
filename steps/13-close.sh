#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "13  BACK TO ZERO"
runsh 'source ./env.sh A >/dev/null && ./preflight.sh A'
echo "  Preflight green again is the teardown proof. Same script I opened with."
runsh 'tail -20 "$SC_DIR/evidence/wallclock.csv"'
