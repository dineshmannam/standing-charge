#!/usr/bin/env bash
#
# postflight.sh  (Standing Charge)
#
# Preflight asks "can I run?". Teardown asks "did I stop paying?".
# This asks the question in between: "did the run actually produce what I need?"
#
# Run it at the end of every data collection day, while there is still time to
# redo a broken sweep. Finding a silently failed run on Sunday with the camera
# rolling is the failure this prevents.
#
# Usage:
#   ./postflight.sh                    # check the current RUN_ID
#   ./postflight.sh --run run-2026-09-03-a
#   ./postflight.sh --sweep            # check all six lever A runs are present
#   ./postflight.sh --sweep --billing  # also query BigQuery (slow, needs lag)
#
# Exit codes: 0 clear, 1 something is missing or wrong

set -uo pipefail
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

SC_DIR="${SC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
EVIDENCE_DIR="$SC_DIR/evidence"
PROFILES="$SC_DIR/traffic-profiles.json"

CHECK_RUN="${RUN_ID:-}"
SWEEP=0
BILLING=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) CHECK_RUN="$2"; shift 2 ;;
    --sweep) SWEEP=1; shift ;;
    --billing) BILLING=1; shift ;;
    -h|--help)
      cat <<'USAGE'
usage: postflight.sh [--run RUN_ID] [--sweep] [--billing]

  --run ID    check one run id (default: $RUN_ID)
  --sweep     check all six lever A runs exist and look sane
  --billing   also query BigQuery for cost rows. Needs several hours of lag.
USAGE
      exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

FAILURES=0; WARNINGS=0
declare -a NOTES=()

pass() { printf "  %s[ PASS ]%s %s\n" "$GREEN" "$RESET" "$1"; }
fail() {
  printf "  %s[ FAIL ]%s %s\n" "$RED" "$RESET" "$1"
  [[ $# -gt 1 ]] && printf "           %s%s%s\n" "$YELLOW" "$2" "$RESET"
  FAILURES=$((FAILURES+1)); NOTES+=("$1")
}
warn() {
  printf "  %s[ WARN ]%s %s\n" "$YELLOW" "$RESET" "$1"
  [[ $# -gt 1 ]] && printf "           %s\n" "$2"
  WARNINGS=$((WARNINGS+1))
}
info()    { printf "  %s[ INFO ]%s %s\n" "$BLUE" "$RESET" "$1"; }
section() { printf "\n%s%s%s\n" "$BOLD" "$1" "$RESET"; }

printf "\n%sStanding Charge postflight%s\n" "$BOLD" "$RESET"
[[ -n "$CHECK_RUN" ]] && printf "  run: %s\n" "$CHECK_RUN"

# ---------------------------------------------------------------------------
section "Evidence files"
# ---------------------------------------------------------------------------

[[ -d "$EVIDENCE_DIR" ]] && pass "evidence/ exists" \
  || { fail "evidence/ not found at $EVIDENCE_DIR"; printf "\nCannot continue.\n"; exit 1; }

CSV_COUNT=$(find "$EVIDENCE_DIR" -maxdepth 1 -name 'load-*.csv' 2>/dev/null | wc -l | tr -d ' ')
if [[ "${CSV_COUNT:-0}" -gt 0 ]]; then
  pass "$CSV_COUNT load CSV(s) present"
else
  fail "no load-*.csv in evidence/" "The load generator wrote nothing."
fi

[[ -s "$EVIDENCE_DIR/adk-version" ]] \
  && pass "adk version captured: $(< "$EVIDENCE_DIR/adk-version")" \
  || warn "evidence/adk-version missing" "Run preflight to capture it. Needed for the caveats."

[[ -s "$EVIDENCE_DIR/wallclock.csv" ]] && pass "wallclock.csv has content" \
  || fail "wallclock.csv empty or missing" "No phase timings. Cost cannot be sliced by phase."

# ---------------------------------------------------------------------------
section "Load results"
# ---------------------------------------------------------------------------

LOAD_PY_RC=0
python3 - "$EVIDENCE_DIR" "$PROFILES" "${CHECK_RUN:-}" "$SWEEP" <<'PY' || LOAD_PY_RC=$?
import csv, glob, json, os, sys
from collections import defaultdict

ev, profiles_path, check_run, sweep = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"

expected = {}
if os.path.exists(profiles_path):
    d = json.load(open(profiles_path))
    for p in d.get("profiles", []):
        if p.get("shape") == "constant":
            n = int(p["duration_minutes"] * 60 / (3600.0 / p["requests_per_hour"]))
        else:
            b = p["burst"]; gap = 3600.0 / b["active_rate_per_hour"]
            dur = p["duration_minutes"] * 60; n = 0; el = 0.0
            while el < dur:
                el += b["idle_minutes"] * 60.0
                n += int((b["active_minutes"] * 60.0) / gap)
                el += b["active_minutes"] * 60.0
        expected[p["id"]] = n

runs = defaultdict(lambda: defaultdict(list))
for f in sorted(glob.glob(os.path.join(ev, "load-*.csv"))):
    try:
        with open(f) as fh:
            for row in csv.DictReader(fh):
                runs[row.get("run_id", "?")][row.get("profile", "?")].append(row)
    except Exception as e:
        print(f"  [ WARN ] could not parse {os.path.basename(f)}: {e}")

bad_runs = 0

if not runs:
    print("  [ FAIL ] no parseable rows in any load CSV")
    sys.exit(1)

targets = [check_run] if (check_run and check_run in runs) else sorted(runs)

for rid in targets:
    print(f"\n  run {rid}")
    for prof, rows in sorted(runs[rid].items()):
        n = len(rows)
        exp = expected.get(prof)
        bad = [r for r in rows if r.get("status") != "200"]
        zero = [r for r in rows if r.get("latency_ms") in ("0", "", None)]
        cold = [r for r in rows if r.get("cold_hint")]

        tag = "PASS"
        msg = f"{prof}: {n} requests"
        if exp is not None:
            if abs(n - exp) > max(2, exp * 0.1):
                tag = "FAIL"; msg += f" (expected ~{exp})"
            else:
                msg += f" (expected ~{exp})"
        if bad:
            tag = "FAIL"; msg += f", {len(bad)} non-200"
        if zero:
            tag = "FAIL"; msg += f", {len(zero)} zero-latency"
        if cold:
            msg += f", {len(cold)} cold hints"

        if tag == "FAIL":
            bad_runs += 1
        colour = {"PASS": "\033[0;32m", "FAIL": "\033[0;31m"}[tag]
        print(f"    {colour}[ {tag} ]\033[0m {msg}")

        if prof == "filmdemo":
            print("             \033[0;33mcamera only. Exclude this run id from the cost dataset.\033[0m")

sys.exit(1 if bad_runs else 0)
PY

if [[ $LOAD_PY_RC -ne 0 ]]; then
  FAILURES=$((FAILURES+1))
  NOTES+=("one or more load runs are incomplete or contain errors")
fi

# ---------------------------------------------------------------------------
if [[ $SWEEP -eq 1 ]]; then
section "Lever A sweep completeness"

  MISSING=()
  for MIN in 0 1; do
    for P in steady bursty sparse; do
      if ! grep -lq "min${MIN}-${P}" "$EVIDENCE_DIR"/load-*.csv 2>/dev/null \
         && ! ls "$EVIDENCE_DIR"/load-*min${MIN}-${P}*.csv >/dev/null 2>&1; then
        MISSING+=("min${MIN}/${P}")
      fi
    done
  done

  if [[ ${#MISSING[@]} -eq 0 ]]; then
    pass "all six lever A runs present"
  else
    fail "missing ${#MISSING[@]} of 6 lever A runs: ${MISSING[*]}" \
         "Rerun before moving on. The curve needs all six points."
  fi
fi

# ---------------------------------------------------------------------------
section "Phase timings"
# ---------------------------------------------------------------------------

if [[ -s "$EVIDENCE_DIR/wallclock.csv" ]]; then
  python3 - "$EVIDENCE_DIR/wallclock.csv" <<'PY'
import csv, sys
from collections import defaultdict
rows = list(csv.DictReader(open(sys.argv[1])))
if not rows:
    print("  [ WARN ] wallclock.csv has a header but no rows")
    sys.exit(0)
ph = defaultdict(set)
for r in rows:
    ph[(r.get("run_id"), r.get("phase"))].add(r.get("event"))
unpaired = [k for k, v in ph.items() if not {"start", "done"} <= v]
print(f"  [ INFO ] {len(rows)} timing rows across {len(ph)} phases")
if unpaired:
    for run, phase in unpaired[:8]:
        print(f"  \033[0;33m[ WARN ]\033[0m {run} / {phase}: missing start or done")
    print("           Cost cannot be sliced for these phases.")
else:
    print("  \033[0;32m[ PASS ]\033[0m every phase has start and done")
PY
fi

# ---------------------------------------------------------------------------
if [[ $BILLING -eq 1 ]]; then
section "Billing rows"

  if [[ -z "${BILLING_PROJECT:-}" || -z "${DETAILED_DATASET:-}" || -z "${BILLING_ACCOUNT_UNDERSCORE:-}" ]]; then
    warn "BILLING_PROJECT, DETAILED_DATASET or BILLING_ACCOUNT_UNDERSCORE not set" "source env.sh first"
  else
    TABLE="${BILLING_PROJECT}.${DETAILED_DATASET}.gcp_billing_export_resource_v1_${BILLING_ACCOUNT_UNDERSCORE}"
    info "querying $TABLE"

    # 'rows' is reserved in BigQuery (window frame clauses), so the column is
    # row_count. A query that fails still writes to stdout, so check the exit
    # code rather than whether output appeared.
    Q="SELECT label.value AS run_id, COUNT(*) AS row_count, ROUND(SUM(cost),6) AS cost
       FROM \`${TABLE}\`, UNNEST(labels) AS label
       WHERE label.key = 'run-id'
         AND DATE(usage_start_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL 3 DAY)
       GROUP BY 1 ORDER BY 1"

    OUT=$(bq query --use_legacy_sql=false --format=sparse --quiet "$Q" 2>&1)
    RC=$?

    if [[ $RC -ne 0 ]]; then
      fail "billing query failed (exit $RC)" "$(head -3 <<<"$OUT")"
    elif [[ -z "${OUT//[[:space:]]/}" ]]; then
      warn "no billing rows for any run-id in the last 3 days" \
           "Either export lag, or labels are not propagating. This is the gate."
    else
      pass "billing query returned rows"
      echo "$OUT" | sed 's/^/           /'
      if [[ -n "$CHECK_RUN" ]]; then
        grep -q "$CHECK_RUN" <<<"$OUT" \
          && pass "run $CHECK_RUN present in billing export" \
          || warn "run $CHECK_RUN not in billing export yet" "Export lags several hours. Recheck later."
      fi
      grep -qi 'filmdemo' <<<"$OUT" \
        && warn "a filmdemo run id has billing rows" "Exclude it from the analysis."
    fi
  fi
fi

# ---------------------------------------------------------------------------
section "Still billing?"
# ---------------------------------------------------------------------------

if [[ -n "${PROJECT_ID:-}" && -n "${REGION:-}" ]]; then
  MIN=$(gcloud run services describe "${SERVICE_NAME:-standing-charge-agent}" \
        --region="$REGION" --project="$PROJECT_ID" \
        --format="value(spec.template.metadata.annotations['autoscaling.knative.dev/minScale'])" 2>/dev/null)
  if [[ -z "$MIN" || "$MIN" == "0" ]]; then
    pass "min-instances is 0 or service is gone"
  else
    fail "min-instances is $MIN, still billing" \
         "gcloud run services update ${SERVICE_NAME:-standing-charge-agent} --region=$REGION --min-instances=0"
  fi
else
  warn "PROJECT_ID or REGION unset" "source env.sh to check whether anything is still running"
fi

# ---------------------------------------------------------------------------

printf "\n%s%s%s\n" "$BOLD" "$(printf '=%.0s' {1..70})" "$RESET"
if [[ $FAILURES -eq 0 && $WARNINGS -eq 0 ]]; then
  printf "%sRun looks complete. Safe to move on.%s\n" "$GREEN" "$RESET"
elif [[ $FAILURES -eq 0 ]]; then
  printf "%s%d warning(s), nothing broken.%s\n" "$YELLOW" "$WARNINGS" "$RESET"
else
  printf "%s%d problem(s). Fix before moving on.%s\n" "$RED" "$FAILURES" "$RESET"
  for n in "${NOTES[@]}"; do printf "  x %s\n" "$n"; done
fi
printf "%s%s%s\n\n" "$BOLD" "$(printf '=%.0s' {1..70})" "$RESET"

[[ $FAILURES -eq 0 ]] && exit 0 || exit 1
