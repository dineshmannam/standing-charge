#!/usr/bin/env bash
#
# Load evidence/load-*.csv into BigQuery.
#
# Do NOT use --autodetect. Two reasons:
#   1. Token columns contain "NA" on failed requests, so autodetect infers
#      STRING and every downstream SUM() breaks silently.
#   2. Column counts changed as loadgen evolved; autodetect would give files
#      different schemas.
#
# --null_marker=NA turns those into real NULLs so the columns stay INTEGER.
#
# A column-count mismatch is a hard failure, not a skip. An earlier version
# skipped every file and exited 0, which looked like success.

set -uo pipefail
: "${BILLING_PROJECT:?source env.sh first}"
: "${DETAILED_DATASET:?source env.sh first}"

TABLE="${BILLING_PROJECT}:${DETAILED_DATASET}.load_results"

SCHEMA="run_id:STRING,lever:STRING,profile:STRING,seq:INTEGER,\
utc_time:TIMESTAMP,status:INTEGER,latency_ms:INTEGER,prompt_tokens:INTEGER,\
completion_tokens:INTEGER,thoughts_tokens:INTEGER,total_tokens:INTEGER,\
model_version:STRING,traffic_type:STRING,session_mode:STRING,\
scheduled_offset_s:FLOAT,drift_ms:INTEGER,cold_hint:STRING"

EXPECTED_COLS=17

# Runs that must never enter the cost dataset.
# load-A-steady-run-2026-09-04-b-nocompaction.csv is the failed lever B attempt:
# 116 of 120 requests returned 404 after the in-memory session vanished. It also
# carries a lever A prefix because the shell was still on lever A when it ran,
# which is the zsh `LEVER=B source env.sh` bug (F13).
EXCLUDE=(
  "load-A-steady-run-2026-09-04-b-nocompaction.csv"
)

loaded=0; skipped=0; failed=0

echo "target: $TABLE"
echo

for f in evidence/load-*.csv; do
  [[ -e "$f" ]] || continue
  base=$(basename "$f")

  excluded=0
  for x in "${EXCLUDE[@]}"; do
    [[ "$base" == "$x" ]] && excluded=1
  done
  if [[ $excluded -eq 1 ]]; then
    echo "  EXCLUDE  $base  (known bad run, see EXCLUDE list)"
    skipped=$((skipped+1)); continue
  fi

  cols=$(head -1 "$f" | awk -F',' '{print NF}')
  rows=$(( $(wc -l < "$f") - 1 ))

  if [[ "$cols" -ne "$EXPECTED_COLS" ]]; then
    echo "  FAIL     $base  ($cols columns, expected $EXPECTED_COLS)"
    echo "           Schema mismatch. Do not load this without checking why."
    failed=$((failed+1)); continue
  fi

  if bq load --source_format=CSV --skip_leading_rows=1 --null_marker=NA \
       --noreplace "$TABLE" "$f" "$SCHEMA" 2>/dev/null; then
    echo "  LOADED   $base  ($rows rows)"
    loaded=$((loaded+1))
  else
    echo "  FAIL     $base  (bq load returned non-zero)"
    failed=$((failed+1))
  fi
done

echo
echo "  loaded $loaded, excluded $skipped, failed $failed"

if [[ $loaded -eq 0 ]]; then
  echo
  echo "  NOTHING WAS LOADED. That is a failure, not a no-op."
  exit 1
fi

if [[ $failed -gt 0 ]]; then
  echo "  $failed file(s) failed. Fix before running the analysis."
  exit 1
fi

echo
echo "  verify:"
cat <<SQL
    bq query --use_legacy_sql=false --format=pretty "
    SELECT lever, profile, run_id, COUNT(*) AS rows,
           COUNTIF(status != 200) AS errors,
           SUM(total_tokens) AS billed_tokens
    FROM \\\`${BILLING_PROJECT}.${DETAILED_DATASET}.load_results\\\`
    GROUP BY 1,2,3 ORDER BY lever, profile, run_id"
SQL
