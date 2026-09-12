#!/usr/bin/env bash
#
# preflight.sh  (Standing Charge)
#
# Validates prerequisites before spending anything. Runs in about 30 seconds.
#
# Three levers, each in its own project:
#   A  idle capacity   Cloud Run min-instances versus scale to zero
#   B  context size    ADK EventCompaction on versus off
#   C  hosting model   Agent Runtime versus Cloud Run
#
# Usage:
#   ./preflight.sh          # shared checks plus every lever
#   ./preflight.sh A        # shared checks plus lever A
#   LEVER=B ./preflight.sh
#
# Exit codes: 0 clear, 1 blocking failure, 2 cannot run

set -uo pipefail

# gcloud must never block waiting on stdin. Without this, a call against a
# project with a disabled API sits on an "enable it? (y/N)" prompt forever.
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

LOCAL_ONLY=0
LEVER_ARG=""
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL_ONLY=1 ;;
    -h|--help)
      cat <<'USAGE'
usage: preflight.sh [LEVER] [--local]

  LEVER     A, B, C, or all (default: all, or $LEVER)
  --local   local tooling, venv, ADK and file checks only. No cloud calls.

exit: 0 clear, 1 blocking failure, 2 cannot run
USAGE
      exit 0 ;;
    *) LEVER_ARG="$arg" ;;
  esac
done

LEVER="${LEVER_ARG:-${LEVER:-all}}"
LEVER="$(tr '[:lower:]' '[:upper:]' <<<"$LEVER")"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-us-central1}"
VERTEX_LOCATION="${VERTEX_LOCATION:-$REGION}"
VERTEX_MODEL="${VERTEX_MODEL:-gemini-2.5-flash}"
SERVICE_NAME="${SERVICE_NAME:-standing-charge-agent}"
AGENT_DIR="${AGENT_DIR:-./agent}"
APP_NAME="${APP_NAME:-my_agent}"
EVIDENCE_DIR="${SC_DIR:-.}/evidence"

PROJECT_LEVER_A="${PROJECT_LEVER_A:-}"
PROJECT_LEVER_B="${PROJECT_LEVER_B:-}"
PROJECT_LEVER_C="${PROJECT_LEVER_C:-}"

BILLING_PROJECT="${BILLING_PROJECT:-}"
DETAILED_DATASET="${DETAILED_DATASET:-}"

# Rough rate, USD. Drifts. Measuring the real number is the point.
RATE_MIN_INSTANCE_HR="${RATE_MIN_INSTANCE_HR:-0.020}"

REQUIRED_APIS_SHARED=(
  run.googleapis.com
  aiplatform.googleapis.com
  cloudbuild.googleapis.com
  artifactregistry.googleapis.com
  logging.googleapis.com
  monitoring.googleapis.com
)
REQUIRED_APIS_B=( cloudtrace.googleapis.com )

REQUIRED_PERMISSIONS=(
  run.services.create
  run.services.update
  iam.serviceAccounts.create
  cloudbuild.builds.create
  artifactregistry.repositories.create
  aiplatform.endpoints.predict
)

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

FAILURES=0; WARNINGS=0
declare -a FAILURE_NOTES=()

pass() { printf "  %s[ PASS ]%s %s\n" "$GREEN" "$RESET" "$1"; }
fail() {
  printf "  %s[ FAIL ]%s %s\n" "$RED" "$RESET" "$1"
  [[ $# -gt 1 ]] && printf "           %s%s%s\n" "$YELLOW" "$2" "$RESET"
  FAILURES=$((FAILURES+1)); FAILURE_NOTES+=("$1")
}
warn() {
  printf "  %s[ WARN ]%s %s\n" "$YELLOW" "$RESET" "$1"
  [[ $# -gt 1 ]] && printf "           %s\n" "$2"
  WARNINGS=$((WARNINGS+1))
}
info()    { printf "  %s[ INFO ]%s %s\n" "$BLUE" "$RESET" "$1"; }
section() { printf "\n%s%s%s\n" "$BOLD" "$1" "$RESET"; }
want()    { [[ "$LEVER" == "ALL" || "$LEVER" == "$1" ]]; }

case "$LEVER" in A|B|C|ALL) ;; *) echo "unknown lever '$LEVER'. use A, B, C, or all."; exit 2 ;; esac

if [[ $LOCAL_ONLY -eq 1 ]]; then
  printf "\n%sStanding Charge preflight%s  (local only)\n" "$BOLD" "$RESET"
else
  printf "\n%sStanding Charge preflight%s  (lever: %s)\n" "$BOLD" "$RESET" "$LEVER"
fi

section "Local tooling"
MISSING=0
for t in gcloud jq curl python3; do
  command -v "$t" >/dev/null 2>&1 && pass "$t" || { fail "$t is not installed"; MISSING=$((MISSING+1)); }
done
command -v uvx >/dev/null 2>&1 && pass "uvx (used by adk deploy cloud_run)" \
  || warn "uvx not found" "The codelab deploys via uvx. Install uv, or use gcloud run deploy."
[[ $MISSING -gt 0 ]] && { printf "\n%sCannot continue.%s\n" "$RED" "$RESET"; exit 2; }

section "Python and ADK"

# .venv is gitignored, so on a fresh clone it does not exist yet and pointing at
# its activate script is advice that cannot be followed. Say which it is.
if [[ -n "${VIRTUAL_ENV:-}" ]]; then
  pass "venv active: $(basename "$VIRTUAL_ENV")"
elif [[ -f "${SC_DIR:-.}/.venv/bin/activate" ]]; then
  warn "no virtualenv active" "Run: source .venv/bin/activate"
else
  warn "no virtualenv active, and no .venv in the repo" \
       "python3 -m venv .venv && source .venv/bin/activate && pip install -r agent/requirements.txt"
fi

ADK_VER=$(python3 -c 'import importlib.metadata as m; print(m.version("google-adk"))' 2>/dev/null)
if [[ -n "$ADK_VER" ]]; then
  pass "google-adk $ADK_VER importable"
  mkdir -p "$EVIDENCE_DIR" 2>/dev/null
  echo "$ADK_VER" > "$EVIDENCE_DIR/adk-version" 2>/dev/null
else
  fail "google-adk not importable" \
       "pip install -r agent/requirements.txt (it pins the version), or activate the venv. See README Setup."
fi

# Lever C deploys with `adk deploy agent_engine`, which does `import vertexai`.
# google-adk does not pull that in, so a venv built from agent/requirements.txt
# alone satisfies every check above and then fails at the deploy. Lever-gated:
# levers A and B never touch it.
if want C; then
  if python3 -c 'import vertexai' 2>/dev/null; then
    pass "vertexai importable (needed by adk deploy agent_engine)"
  else
    fail "vertexai not importable, and lever C deploys through it" \
         "pip install 'google-cloud-aiplatform[adk,agent_engines]==2.1.0'. See README Setup."
  fi
fi

if command -v adk >/dev/null 2>&1; then
  pass "adk CLI on PATH"
elif command -v uvx >/dev/null 2>&1; then
  info "adk not on PATH, will run via uvx"
else
  fail "no adk CLI and no uvx"
fi

# Layout the Python buildpack expects (codelab section 8):
#   $AGENT_DIR/requirements.txt        at the ROOT
#   $AGENT_DIR/$APP_NAME/__init__.py   package subdirectory
#   $AGENT_DIR/$APP_NAME/agent.py
# You deploy from $AGENT_DIR, never from the package directory.

if [[ ! -d "$AGENT_DIR" ]]; then
  fail "AGENT_DIR '$AGENT_DIR' does not exist" "Run ./scaffold-agent.sh, then set AGENT_DIR in env.local.sh."
else
  pass "agent dir: $AGENT_DIR"

  if [[ -f "$AGENT_DIR/requirements.txt" ]]; then
    pass "requirements.txt at agent root"
    if grep -qE '^google-adk==' "$AGENT_DIR/requirements.txt"; then
      pass "google-adk is version pinned: $(grep -E '^google-adk==' "$AGENT_DIR/requirements.txt")"
    else
      warn "google-adk not pinned in requirements.txt" \
           "An ADK upgrade mid-experiment confounds the comparison and nothing in the data would show it."
    fi
  else
    fail "$AGENT_DIR/requirements.txt missing" "The buildpack needs it at the agent root, not inside the package."
  fi

  if [[ -d "$AGENT_DIR/$APP_NAME" ]]; then
    pass "package dir: $AGENT_DIR/$APP_NAME"
  else
    fail "package dir '$AGENT_DIR/$APP_NAME' missing" "APP_NAME must match the directory name. It is also the appName in every /run call."
  fi

  if [[ -f "$AGENT_DIR/$APP_NAME/__init__.py" ]]; then
    pass "__init__.py present"
  else
    fail "$AGENT_DIR/$APP_NAME/__init__.py missing" \
         "The codelab writes __init.py__, which is a typo. Python needs __init__.py or the package will not import."
  fi

  if [[ -f "$AGENT_DIR/$APP_NAME/agent.py" ]]; then
    grep -q 'root_agent' "$AGENT_DIR/$APP_NAME/agent.py" \
      && pass "agent.py defines root_agent" \
      || fail "agent.py has no root_agent" "ADK looks for a module level root_agent."
  else
    fail "$AGENT_DIR/$APP_NAME/agent.py missing"
  fi

  [[ -f "$AGENT_DIR/.gcloudignore" ]] && pass ".gcloudignore present" \
    || warn "no .gcloudignore in $AGENT_DIR" "Evidence CSVs and credentials could be uploaded to Cloud Build."
fi

if [[ $LOCAL_ONLY -eq 1 ]]; then
  printf "\n%s%s%s\n" "$BOLD" "$(printf '=%.0s' {1..70})" "$RESET"
  if [[ $FAILURES -eq 0 ]]; then
    printf "%sLocal checks passed. Cloud checks skipped.%s\n" "$GREEN" "$RESET"
  else
    printf "%s%d local failure(s).%s\n" "$RED" "$FAILURES" "$RESET"
    for n in "${FAILURE_NOTES[@]}"; do printf "  x %s\n" "$n"; done
  fi
  printf "%s%s%s\n\n" "$BOLD" "$(printf '=%.0s' {1..70})" "$RESET"
  [[ $FAILURES -eq 0 ]] && exit 0 || exit 1
fi

section "Identity and project"
ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n1)
[[ -n "$ACCOUNT" ]] && pass "authenticated as $ACCOUNT" || fail "no active account" "gcloud auth login"
if [[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]]; then
  pass "project is $PROJECT_ID"
else
  fail "no project configured" "Set PROJECT_LEVER_$LEVER in env.local.sh"
  printf "\n%sCannot continue.%s\n" "$RED" "$RESET"; exit 2
fi
info "region $REGION, vertex $VERTEX_LOCATION, model $VERTEX_MODEL"

section "Lever isolation"
# Vertex bills at project level with no resource to label, so the project is the
# only attribution boundary. Check the configured mapping, not the project name.
#
# A case, not `declare -A`. Associative arrays need bash 4; stock macOS ships
# 3.2.57 at /bin/bash, where the subscripts [A] [B] [C] are evaluated as
# arithmetic and all collapse to index 0. Every lever then resolves to lever C's
# project, so this gate reports "two or more levers share a project" on a correct
# setup and "project mismatch, expected <lever C>" when you run lever A. That is
# a confident wrong answer from the one check the whole experimental design rests
# on -- the thing standing between you and lever B's spend landing in lever A's
# billing rows.
lever_project() {
  case "$1" in
    A) printf '%s' "${PROJECT_LEVER_A:-}" ;;
    B) printf '%s' "${PROJECT_LEVER_B:-}" ;;
    C) printf '%s' "${PROJECT_LEVER_C:-}" ;;
    *) printf '%s' "" ;;
  esac
}

UNSET_COUNT=0
for L in A B C; do
  if [[ -z "$(lever_project "$L")" ]]; then
    warn "PROJECT_LEVER_$L is not set" "Set it in env.local.sh before running lever $L."
    UNSET_COUNT=$((UNSET_COUNT+1))
  fi
done

if [[ $UNSET_COUNT -eq 0 ]]; then
  DUPES=$(printf '%s\n' "$(lever_project A)" "$(lever_project B)" "$(lever_project C)" | sort | uniq -d)
  if [[ -n "$DUPES" ]]; then
    fail "two or more levers share a project: $DUPES" \
         "Vertex spend cannot be separated. Give each lever its own project."
  else
    pass "three distinct projects configured"
  fi
fi

if [[ "$LEVER" != "ALL" ]]; then
  EXPECTED="$(lever_project "$LEVER")"
  if [[ -z "$EXPECTED" ]]; then
    warn "cannot verify project for lever $LEVER" "PROJECT_LEVER_$LEVER is unset."
  elif [[ "$PROJECT_ID" == "$EXPECTED" ]]; then
    pass "project matches lever $LEVER"
  else
    fail "project mismatch: running lever $LEVER against '$PROJECT_ID'" \
         "Expected '$EXPECTED'. Stale shell export, or env.local.sh not sourced. Run: source env.sh"
  fi
fi

section "Billing"
BJ=$(gcloud billing projects describe "$PROJECT_ID" --format=json 2>/dev/null)
if [[ -n "$BJ" ]]; then
  EN=$(jq -r '.billingEnabled // false' <<<"$BJ")
  ACCT=$(jq -r '.billingAccountName // ""' <<<"$BJ" | sed 's|billingAccounts/||')
  [[ "$EN" == "true" ]] && pass "billing enabled (account $ACCT)" || fail "billing not enabled on $PROJECT_ID"
  if [[ -n "$ACCT" ]]; then
    N=$(gcloud billing budgets list --billing-account="$ACCT" --format="value(name)" 2>/dev/null | wc -l | tr -d ' ')
    [[ "${N:-0}" -gt 0 ]] && pass "$N budget(s) on the billing account" || warn "no budget alerts found"
  fi
else
  warn "could not read billing config" "Verify manually."
fi

if [[ -n "$BILLING_PROJECT" ]]; then
  DS=$(bq ls --project_id="$BILLING_PROJECT" --format=json 2>/dev/null | jq -r '.[].datasetReference.datasetId' 2>/dev/null)
  if [[ -n "$DS" ]]; then
    F=$(grep '^gcp_billing_immutable_' <<<"$DS" | head -n1)
    [[ -n "$F" ]] && pass "FOCUS dataset: $F" || warn "no FOCUS dataset in $BILLING_PROJECT"
    if [[ -n "$DETAILED_DATASET" ]]; then
      grep -qx "$DETAILED_DATASET" <<<"$DS" && pass "detailed dataset: $DETAILED_DATASET" \
        || fail "detailed dataset '$DETAILED_DATASET' not found in $BILLING_PROJECT"
    else
      warn "DETAILED_DATASET not set" "Redundancy matters while FOCUS is Preview."
    fi
  else
    warn "could not list datasets in $BILLING_PROJECT"
  fi
else
  warn "BILLING_PROJECT not set" "Cost data is unrecoverable. Confirm exports before running."
fi

section "APIs"
EA=$(gcloud services list --enabled --project="$PROJECT_ID" --format="value(config.name)" 2>/dev/null)
NEEDED=("${REQUIRED_APIS_SHARED[@]}")
want B && NEEDED+=("${REQUIRED_APIS_B[@]}")
DISABLED=()
for api in $(printf '%s\n' "${NEEDED[@]}" | sort -u); do
  grep -qx "$api" <<<"$EA" && pass "$api" || { fail "$api not enabled"; DISABLED+=("$api"); }
done

# Everything below depends on these. Continuing produces a cascade of confusing
# 403s rather than one clear instruction.
if [[ ${#DISABLED[@]} -gt 0 ]]; then
  printf "\n%sRequired APIs are disabled. Enable them and rerun.%s\n\n" "$RED" "$RESET"
  printf "  gcloud services enable %s \\\\\n    --project=%s\n\n" "${DISABLED[*]}" "$PROJECT_ID"
  exit 1
fi

section "IAM: your permissions"
TOKEN=$(gcloud auth print-access-token 2>/dev/null)
if [[ -n "$TOKEN" ]]; then
  PAYLOAD=$(printf '%s\n' "${REQUIRED_PERMISSIONS[@]}" | jq -R . | jq -sc '{permissions: .}')
  G=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT_ID}:testIamPermissions" \
      | jq -r '.permissions[]?' 2>/dev/null)
  for p in "${REQUIRED_PERMISSIONS[@]}"; do
    grep -qx "$p" <<<"$G" && pass "$p" || fail "missing permission: $p"
  done
else
  warn "no access token" "Skipping IAM checks."
fi

section "IAM: service account permissions"

# The permissions you hold are not the permissions your build has. Google stopped
# granting Editor to the default compute service account on new projects, so
# source deploys fail with an opaque storage 403 until these are granted.
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null)

if [[ -z "$PROJECT_NUMBER" ]]; then
  warn "could not resolve project number" "Skipping service account checks."
else
  COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
  info "checking $COMPUTE_SA"

  SA_ROLES=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:${COMPUTE_SA}" \
    --format="value(bindings.role)" 2>/dev/null)

  if grep -qx "roles/editor" <<<"$SA_ROLES" || grep -qx "roles/owner" <<<"$SA_ROLES"; then
    pass "compute SA has broad project role, source deploy will work"
  else
    SA_MISSING=()
    for r in roles/storage.objectViewer roles/artifactregistry.writer roles/logging.logWriter; do
      if grep -qx "$r" <<<"$SA_ROLES"; then
        pass "compute SA has ${r##*/}"
      else
        fail "compute SA missing $r"
        SA_MISSING+=("$r")
      fi
    done

    if [[ ${#SA_MISSING[@]} -gt 0 ]]; then
      printf "\n%sCloud Build runs as the compute service account, not as you.%s\n" "$YELLOW" "$RESET"
      printf "  Source deploys will fail with a storage 403 until you run:\n\n"
      for r in "${SA_MISSING[@]}"; do
        printf "  gcloud projects add-iam-policy-binding %s \\\n" "$PROJECT_ID"
        printf "    --member=serviceAccount:%s \\\n" "$COMPUTE_SA"
        printf "    --role=%s --condition=None\n" "$r"
      done
      printf "\n  IAM takes a minute or two to propagate.\n\n"
    fi
  fi

  RUN_AGENT="service-${PROJECT_NUMBER}@serverless-robot-prod.iam.gserviceaccount.com"
  if gcloud projects get-iam-policy "$PROJECT_ID" \
       --flatten="bindings[].members" \
       --filter="bindings.members:serviceAccount:${RUN_AGENT}" \
       --format="value(bindings.role)" 2>/dev/null | grep -q .; then
    pass "Cloud Run service agent has a binding"
  else
    warn "Cloud Run service agent has no visible binding" \
         "Usually fine, it is granted on first deploy. Watch for a run.serviceAgent error."
  fi
fi

AGENT_SA="agent-sa@${PROJECT_ID}.iam.gserviceaccount.com"
if gcloud iam service-accounts describe "$AGENT_SA" --project="$PROJECT_ID" >/dev/null 2>&1; then
  pass "agent-sa exists"
  AGENT_ROLES=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:${AGENT_SA}" \
    --format="value(bindings.role)" 2>/dev/null)
  grep -qx "roles/aiplatform.user" <<<"$AGENT_ROLES" \
    && pass "agent-sa has aiplatform.user" \
    || fail "agent-sa missing roles/aiplatform.user" \
            "gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$AGENT_SA --role=roles/aiplatform.user --condition=None"
else
  warn "agent-sa does not exist" \
       "gcloud iam service-accounts create agent-sa --project=$PROJECT_ID --display-name='Agent Service Account'"
fi

section "Artifact Registry"

AR_REPO="${AR_REPO:-cloud-run-source-deploy}"
if gcloud artifacts repositories describe "$AR_REPO" \
     --project="$PROJECT_ID" --location="$REGION" >/dev/null 2>&1; then
  AR_LABELS=$(gcloud artifacts repositories describe "$AR_REPO" \
    --project="$PROJECT_ID" --location="$REGION" --format="value(labels)" 2>/dev/null)
  if [[ -n "$AR_LABELS" ]]; then
    pass "$AR_REPO exists and is labelled"
  else
    warn "$AR_REPO exists but has no labels" \
         "Its cost will not be attributable. Auto-created repos are unlabelled."
  fi
else
  warn "$AR_REPO does not exist yet" \
       "Source deploy will auto-create it WITHOUT labels. Create it first: gcloud artifacts repositories create $AR_REPO --project=$PROJECT_ID --repository-format=docker --location=$REGION --labels=\"\$LABELS\""
fi

section "Vertex AI reachability"
# The global endpoint has no region prefix. The codelab uses
# GOOGLE_CLOUD_LOCATION=global for the agent.
if [[ "$VERTEX_LOCATION" == "global" ]]; then
  VERTEX_HOST="aiplatform.googleapis.com"
else
  VERTEX_HOST="${VERTEX_LOCATION}-aiplatform.googleapis.com"
fi
URL="https://${VERTEX_HOST}/v1/projects/${PROJECT_ID}/locations/${VERTEX_LOCATION}/publishers/google/models/${VERTEX_MODEL}:generateContent"
# mktemp, not a fixed /tmp name: two preflights running at once would overwrite
# each other's response, and a predictable path in a world-writable directory is
# a symlink target on a shared machine.
VERTEX_OUT=$(mktemp "${TMPDIR:-/tmp}/sc_vertex.XXXXXX")
trap 'rm -f "$VERTEX_OUT"' EXIT
CODE=$(curl -s -o "$VERTEX_OUT" -w "%{http_code}" -X POST \
  -H "Authorization: Bearer ${TOKEN:-}" -H "Content-Type: application/json" "$URL" \
  -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}],"generationConfig":{"maxOutputTokens":1}}' 2>/dev/null)
case "$CODE" in
  200) pass "$VERTEX_MODEL responds in $VERTEX_LOCATION"
       case "$VERTEX_MODEL" in
         *preview*|*exp*)
           warn "$VERTEX_MODEL is a preview model" \
                "Preview models often have no published list price. The whole comparison rests on one. Consider a GA model." ;;
       esac
       T=$(jq -r '.usageMetadata.promptTokenCount // "?"' "$VERTEX_OUT" 2>/dev/null)
       info "usageMetadata present (promptTokenCount=$T), token capture will work" ;;
  403) fail "Vertex returned 403" "Check IAM on $PROJECT_ID." ;;
  404) fail "model $VERTEX_MODEL not found in $VERTEX_LOCATION" "Try another location or model id." ;;
  429) warn "Vertex returned 429" "Rate limited. Watch this during load tests." ;;
  *)   fail "Vertex call returned HTTP $CODE" "$(jq -r '.error.message // "no message"' "$VERTEX_OUT" 2>/dev/null)" ;;
esac
rm -f "$VERTEX_OUT"; trap - EXIT

section "Cloud Run"
if gcloud run services describe "$SERVICE_NAME" --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  MIN=$(gcloud run services describe "$SERVICE_NAME" --region="$REGION" --project="$PROJECT_ID" \
    --format="value(spec.template.metadata.annotations['autoscaling.knative.dev/minScale'])" 2>/dev/null)
  warn "service '$SERVICE_NAME' already exists (minScale=${MIN:-0})" \
       "If minScale is above zero it is billing right now."
else
  pass "service name '$SERVICE_NAME' is free in $REGION"
fi
R=$(gcloud run services list --project="$PROJECT_ID" --region="$REGION" --format="value(metadata.name)" 2>/dev/null | wc -l | tr -d ' ')
info "${R:-0} Cloud Run service(s) currently in $REGION"

if want A; then
  section "Lever A: idle capacity"
  if [[ -f traffic-profiles.json ]]; then
    if jq -e '.profiles | length >= 3' traffic-profiles.json >/dev/null 2>&1; then
      pass "traffic-profiles.json with $(jq -r '.profiles|length' traffic-profiles.json) profiles"
      jq -r '.profiles[] | "           \(.id): \(.requests_per_hour) rph for \(.duration_minutes) min"' traffic-profiles.json
      jq -e '.profiles[] | select(.id=="filmdemo")' traffic-profiles.json >/dev/null 2>&1 \
        && info "filmdemo is camera only. Keep its run ids out of the cost dataset."
    else
      fail "traffic-profiles.json malformed or fewer than three profiles"
    fi
  else
    fail "traffic-profiles.json not found" "Freeze traffic shapes before the first run."
  fi
  [[ -f ./loadgen.py ]] && pass "loadgen.py present" || fail "loadgen.py not found"
fi

if want B; then
  section "Lever B: context size"
  grep -qx "cloudtrace.googleapis.com" <<<"$EA" && pass "Cloud Trace enabled" \
    || fail "Cloud Trace not enabled" "Lever B reads token counts from spans."
  info "compaction on/off must be the only difference between the two runs"
fi

if want C; then
  section "Lever C: hosting model"
  # There is no gcloud surface for reasoning engines. Not `gcloud beta
  # aiplatform`, not `gcloud beta ai`. REST is the only way.
  RE_JSON=$(curl -s -H "Authorization: Bearer ${TOKEN:-}" \
    "https://${VERTEX_LOCATION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${VERTEX_LOCATION}/reasoningEngines" 2>/dev/null)

  if [[ -z "$RE_JSON" ]]; then
    fail "no response from the reasoningEngines endpoint" \
         "Check aiplatform API and network. An empty body is not an empty list."
  elif grep -q '"error"' <<<"$RE_JSON"; then
    fail "Agent Engine unreachable in $VERTEX_LOCATION" \
         "$(jq -r '.error.message // "unknown"' <<<"$RE_JSON" 2>/dev/null)"
  else
    pass "Agent Engine endpoint reachable"
    RE_NAMES=$(jq -r '.reasoningEngines[]?.name // empty' <<<"$RE_JSON" 2>/dev/null)
    if [[ -n "$RE_NAMES" ]]; then
      N=$(grep -c . <<<"$RE_NAMES")
      warn "$N reasoning engine(s) deployed" "These bill while they exist. Delete with:"
      while read -r n; do
        [[ -n "$n" ]] && printf "           curl -X DELETE -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" \\\n             \"https://%s-aiplatform.googleapis.com/v1beta1/%s?force=true\"\n" "$VERTEX_LOCATION" "$n"
      done <<<"$RE_NAMES"
    else
      info "no reasoning engines deployed"
    fi
  fi

  info "the same agent must be deployed both ways or the comparison is meaningless"
fi

section "Cost estimate"
printf "  %sHolding one warm instance:%s ~\$%s per hour, ~\$%s per day\n" \
  "$BOLD" "$RESET" "$RATE_MIN_INSTANCE_HR" \
  "$(awk -v r="$RATE_MIN_INSTANCE_HR" 'BEGIN{printf "%.2f", r*24}')"
printf "\n"
printf "    %-40s %s\n" "Lever A sweep (3 profiles, 1h each)" "cents"
printf "    %-40s %s\n" "Lever B (2 configs, 1h each)"        "cents"
printf "    %-40s %s\n" "Lever C (2 hosts, 1h each)"          "cents"
printf "    %-40s %s\n" "Min-instance left on for a week"     "\$$(awk -v r="$RATE_MIN_INSTANCE_HR" 'BEGIN{printf "%.0f", r*168}')"
printf "\n"
info "model tokens will likely dominate hosting. That is a finding, not a problem."
info "rates are hardcoded approximations, verify against the pricing calculator"

section "What this cannot check"
cat <<'EOF'
  Cold start behaviour. Only load testing reveals it, and it is the point of
  lever A. Expect the first request after idle to be several times slower.

  Vertex rate limits under sustained load. A 200 here does not mean a burst of
  300 requests per hour all succeed.

  Whether your levers are isolated in time. Separate projects give attribution,
  but overlapping runs still muddy the story. Run them one at a time.

  Agent Runtime pricing shape. Different billing model to Cloud Run, so compare
  cost per thousand invocations, never cost per hour.

  Whether IAM has finished propagating. A binding added a minute ago may still
  fail the next call. If a deploy 403s right after you granted a role, wait.
EOF

printf "\n%s%s%s\n" "$BOLD" "$(printf '=%.0s' {1..70})" "$RESET"
if [[ $FAILURES -eq 0 && $WARNINGS -eq 0 ]]; then
  printf "%sAll checks passed. Clear to run lever %s.%s\n" "$GREEN" "$LEVER" "$RESET"
elif [[ $FAILURES -eq 0 ]]; then
  printf "%s%d warning(s), no blockers. Proceed with care.%s\n" "$YELLOW" "$WARNINGS" "$RESET"
else
  printf "%s%d blocking failure(s), %d warning(s). Do not run.%s\n" "$RED" "$FAILURES" "$WARNINGS" "$RESET"
  for n in "${FAILURE_NOTES[@]}"; do printf "  x %s\n" "$n"; done
fi
printf "%s%s%s\n\n" "$BOLD" "$(printf '=%.0s' {1..70})" "$RESET"

[[ $FAILURES -eq 0 ]] && exit 0 || exit 1
