#!/usr/bin/env bash
# source env.sh        uses the current lever (default A)
# source env.sh B      switches to lever B and its project
#
# Do not use `LEVER=B source env.sh`. A variable assignment prefixed to a
# sourced file does not reliably reach it in zsh, and it silently leaves you on
# the previous lever pointing at the wrong project.

_SC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export SC_DIR="$_SC_DIR"
[[ -f "${SC_DIR}/env.local.sh" ]] && source "${SC_DIR}/env.local.sh"

# gcloud must never block waiting on stdin.
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

# Lever can be given three ways, in priority order:
#   source env.sh B      argument, most reliable
#   export LEVER=B       then source env.sh
#   LEVER=B source env.sh   works in bash, unreliable in zsh, avoid
if [[ -n "${1:-}" ]]; then
  LEVER="$1"
fi
export LEVER="$(tr '[:lower:]' '[:upper:]' <<<"${LEVER:-A}")"

# ---------------------------------------------------------------------------
# Project, one per lever. No silent fallback: with three projects in play, a
# wrong default puts one lever's spend in another lever's billing rows.
# ---------------------------------------------------------------------------

case "$LEVER" in
  A) export PROJECT_ID="${PROJECT_LEVER_A:-}" ;;
  B) export PROJECT_ID="${PROJECT_LEVER_B:-}" ;;
  C) export PROJECT_ID="${PROJECT_LEVER_C:-}" ;;
  *) echo "LEVER must be A, B or C (got '$LEVER')" ;;
esac

if [[ -z "${PROJECT_ID:-}" ]]; then
  echo "ERROR: no project for lever ${LEVER}."
  echo "       Set PROJECT_LEVER_${LEVER} in env.local.sh."
  echo "       Refusing to fall back to gcloud config."
  return 1 2>/dev/null || exit 1
fi

# Makes the gcloud default follow the active lever, so a command that forgets
# --project still lands in the right place.
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

export REGION="${REGION:-us-central1}"
export VERTEX_LOCATION="${VERTEX_LOCATION:-$REGION}"
export VERTEX_MODEL="${VERTEX_MODEL:-gemini-2.5-flash}"
export SERVICE_NAME="${SERVICE_NAME:-standing-charge-agent}"
export AGENT_DIR="${AGENT_DIR:-./agent}"
export APP_NAME="${APP_NAME:-my_agent}"

# Identity values are hardcoded, not defaulted. A stale export from another
# project once won and got written into resource labels.
export OWNER="${OWNER:-unset}"
export PROJECT_NAME="standing-charge"

# ---------------------------------------------------------------------------
# Billing. Cached in a file because gcloud calls are slow and this is sourced
# in every pane. Delete evidence/billing-account to force a refresh.
# ---------------------------------------------------------------------------

_SC_BILLING_CACHE="${SC_DIR}/evidence/billing-account"
mkdir -p "${SC_DIR}/evidence"

if [[ -s "$_SC_BILLING_CACHE" ]]; then
  BILLING_ACCOUNT="$(< "$_SC_BILLING_CACHE")"
else
  BILLING_ACCOUNT="$(gcloud billing projects describe "$PROJECT_ID" \
    --format='value(billingAccountName)' 2>/dev/null | sed 's|billingAccounts/||')"
  [[ -n "$BILLING_ACCOUNT" ]] && echo "$BILLING_ACCOUNT" > "$_SC_BILLING_CACHE"
fi
export BILLING_ACCOUNT

# BigQuery table names cannot contain hyphens, so the billing account id is
# rewritten with underscores in the export table name:
#   012345-6789AB-CDEF01  ->  gcp_billing_export_resource_v1_012345_6789AB_CDEF01
export BILLING_ACCOUNT_UNDERSCORE="${BILLING_ACCOUNT//-/_}"

export BILLING_PROJECT="${BILLING_PROJECT:-$PROJECT_ID}"
export DETAILED_DATASET="${DETAILED_DATASET:-}"

# FOCUS dataset name is created by Google and its location suffix is permanent.
# Discover it rather than guessing. Ours came back lowercase (_us), not _US.
if [[ -z "${FOCUS_DATASET:-}" && -n "$BILLING_PROJECT" ]]; then
  # Plain bq ls rather than JSON plus jq: a missing jq would silently yield an
  # empty dataset name, and an empty FOCUS_TABLE is easy to not notice.
  FOCUS_DATASET="$(bq ls --project_id="$BILLING_PROJECT" 2>/dev/null \
    | awk '{print $1}' | grep '^gcp_billing_immutable_' | head -n1)"
fi
export FOCUS_DATASET

# Fully qualified table names, so queries and scripts stop rebuilding them.
if [[ -n "$BILLING_PROJECT" && -n "$DETAILED_DATASET" && -n "$BILLING_ACCOUNT_UNDERSCORE" ]]; then
  export DETAILED_TABLE="${BILLING_PROJECT}.${DETAILED_DATASET}.gcp_billing_export_resource_v1_${BILLING_ACCOUNT_UNDERSCORE}"
else
  export DETAILED_TABLE=""
fi
if [[ -n "$BILLING_PROJECT" && -n "$FOCUS_DATASET" && -n "$BILLING_ACCOUNT_UNDERSCORE" ]]; then
  export FOCUS_TABLE="${BILLING_PROJECT}.${FOCUS_DATASET}.gcp_billing_export_focus_${BILLING_ACCOUNT_UNDERSCORE}"
else
  export FOCUS_TABLE=""
fi

# ---------------------------------------------------------------------------
# Run id lives in a file so every pane agrees.
# ---------------------------------------------------------------------------

export RUN_ID_FILE="${SC_DIR}/evidence/current-run-id"
[[ -s "$RUN_ID_FILE" ]] || echo "run-$(date +%Y-%m-%d)-a" > "$RUN_ID_FILE"
RUN_ID="$(< "$RUN_ID_FILE")"; export RUN_ID

_sc_labels() {
  export LABELS="run-id=${RUN_ID},lever=$(tr '[:upper:]' '[:lower:]' <<<"$LEVER"),owner=${OWNER},project-name=${PROJECT_NAME}"
}
_sc_labels

newrun() {
  echo "run-$(date +%Y-%m-%d)-${1:-a}" > "$RUN_ID_FILE"
  RUN_ID="$(< "$RUN_ID_FILE")"; export RUN_ID; _sc_labels
  echo "run id is now ${RUN_ID}"
  echo "other panes need: source env.sh"
}

mark() {
  local f="${SC_DIR}/evidence/wallclock.csv"
  [[ -s "$f" ]] || echo "run_id,lever,phase,event,utc_time" > "$f"
  echo "${RUN_ID},${LEVER},${1},${2},$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$f"
}

scenv() {
  cat <<EOF
  lever          ${LEVER}
  project        ${PROJECT_ID}
  region         ${REGION}
  vertex         ${VERTEX_LOCATION} / ${VERTEX_MODEL}
  service        ${SERVICE_NAME}
  agent dir      ${AGENT_DIR} (app: ${APP_NAME})
  run id         ${RUN_ID}
  labels         ${LABELS}
  billing acct   ${BILLING_ACCOUNT:-<unresolved>}
  detailed table ${DETAILED_TABLE:-<unset: need BILLING_PROJECT and DETAILED_DATASET>}
  focus table    ${FOCUS_TABLE:-<unset>}
EOF
}

export -f newrun mark scenv _sc_labels
unset _SC_DIR _SC_BILLING_CACHE

echo "lever ${LEVER}, project ${PROJECT_ID}, run ${RUN_ID}. type scenv for detail."
