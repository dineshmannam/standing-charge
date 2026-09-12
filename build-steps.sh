#!/usr/bin/env bash
#
# build-steps.sh
#
# Generates steps/ for film day. Every command run on camera lives in a numbered
# script so you never type, never autocomplete, and never mistype.
#
# Each script echoes the command, waits for Enter, then runs it: a visible
# command, a beat to talk over it, and no thinking.
#
# Rewritten 4 Sep after data collection. Corrections carried in:
#   - source env.sh B, not LEVER=B source env.sh          (F13)
#   - no gcloud surface for reasoning engines, REST only  (F15)
#   - Agent Engine has no URL, different contract         (F16)
#   - lever B session death is reproducible on camera     (F14)
#
# Run from the standing-charge root:  ./build-steps.sh

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$ROOT/steps"
mkdir -p "$S"

created=0; skipped=0
w() {
  local p="$1"
  if [[ -e "$p" ]]; then echo "  skip   ${p#$ROOT/}"; skipped=$((skipped+1)); cat >/dev/null
  else cat > "$p"; chmod +x "$p"; echo "  create ${p#$ROOT/}"; created=$((created+1)); fi
}

# ---------------------------------------------------------------------------
w "$S/_lib.sh" <<'EOF'
#!/usr/bin/env bash
# Shared helpers. Sourced by every step script.
set -uo pipefail

[[ -n "${SC_DIR:-}" ]] || { echo "source env.sh first"; exit 1; }

# Step scripts run in a subshell that inherits exported variables but not
# exported functions, so `mark` and friends are missing. Re-source to get them.
source "$SC_DIR/env.sh" "${LEVER:-A}" >/dev/null 2>&1 || true

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'; RESET=$'\033[0m'

banner() {
  printf "\n%s%s%s\n" "$BOLD" "$(printf '=%.0s' {1..64})" "$RESET"
  printf "%s  %s%s\n" "$BOLD" "$1" "$RESET"
  printf "%s%s%s\n\n" "$BOLD" "$(printf '=%.0s' {1..64})" "$RESET"
}

# Show the command, wait, then run it. This is the teleprompter.
run() {
  printf "\n%s\$ %s%s\n\n" "$DIM" "$*" "$RESET"
  read -rp "  [Enter to run] " _
  "$@"
  local rc=$?
  if [[ $rc -eq 0 ]]; then printf "\n  %sok%s\n" "$GREEN" "$RESET"
  else printf "\n  %sexit %d%s\n" "$YELLOW" "$rc" "$RESET"; fi
  return $rc
}

# Same, for a shell string with pipes or substitutions.
runsh() {
  printf "\n%s\$ %s%s\n\n" "$DIM" "$1" "$RESET"
  read -rp "  [Enter to run] " _
  eval "$1"
}

pause() { printf "\n  %s%s%s\n" "$YELLOW" "${1:-pause}" "$RESET"; read -rp "  [Enter to continue] " _; }
EOF

# ---------------------------------------------------------------------------
w "$S/00-preflight.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "00  PREFLIGHT  (cold open)"
run ./preflight.sh A
EOF

w "$S/01-context.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "01  WHERE WE ARE"
run scenv
runsh 'gcloud run services list --project="$PROJECT_ID" --region="$REGION"'
EOF

w "$S/02-deploy.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "02  DEPLOY TO CLOUD RUN"
mark deploy start
run gcloud run deploy "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --source "$AGENT_DIR" \
  --region "$REGION" \
  --allow-unauthenticated \
  --service-account="agent-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --set-env-vars="GOOGLE_GENAI_USE_VERTEXAI=TRUE,GOOGLE_CLOUD_PROJECT=${PROJECT_ID},GOOGLE_CLOUD_LOCATION=${VERTEX_LOCATION},AGENT_MODEL=${VERTEX_MODEL}" \
  --labels="$LABELS" \
  --min-instances=0
mark deploy done
echo
echo "  The allow-unauthenticated warning is expected. Org policy blocks"
echo "  allUsers, so the service needs a token. loadgen already sends one."
EOF

w "$S/03-url.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "03  GET THE URL"
runsh 'export AGENT_URL=$(gcloud run services describe "$SERVICE_NAME" --project="$PROJECT_ID" --region "$REGION" --format "value(status.url)"); echo "[$AGENT_URL]"'
echo "$AGENT_URL" > "$SC_DIR/evidence/agent-url"
echo "  saved to evidence/agent-url"
EOF

w "$S/04-cold.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "04  COLD START  (min-instances = 0)"
AGENT_URL="$(< "$SC_DIR/evidence/agent-url")"
TOKEN=$(gcloud auth print-identity-token)
echo "  Nothing is running. This first request has to start a container."
mark cold start
runsh "time curl -s -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' -H 'Authorization: Bearer $TOKEN' '$AGENT_URL'"
echo
echo "  Now immediately again. Same request, the instance is warm."
runsh "time curl -s -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' -H 'Authorization: Bearer $TOKEN' '$AGENT_URL'"
mark cold done
echo
echo "  Measured 3 Sep: 9,752ms then ~3,400ms. Roughly 2.9x."
EOF

w "$S/05-warm.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "05  HOLD ONE WARM  (min-instances = 1)"
mark warm start
run gcloud run services update "$SERVICE_NAME" \
  --project="$PROJECT_ID" --region "$REGION" --min-instances=1 --labels="$LABELS"
echo "  From here it bills whether or not anyone calls it."
pause "wait ~2 min for the instance to come up"
AGENT_URL="$(< "$SC_DIR/evidence/agent-url")"
TOKEN=$(gcloud auth print-identity-token)
runsh "time curl -s -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' -H 'Authorization: Bearer $TOKEN' '$AGENT_URL'"
mark warm done
EOF

w "$S/06-demo-load.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "06  LIVE LOAD  (filmdemo, ~5 min)"
AGENT_URL="$(< "$SC_DIR/evidence/agent-url")"
mark demoload start
run caffeinate -dimsu python3 loadgen.py --url "$AGENT_URL" --profile filmdemo --fresh-session
mark demoload done
echo
echo "  Watch the think= column. That is the number this whole video is about."
EOF

w "$S/07-tokens.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "07  THE INVISIBLE BILL"
echo "  One request. Look at what comes back."
AGENT_URL="$(< "$SC_DIR/evidence/agent-url")"
TOKEN=$(gcloud auth print-identity-token)
runsh "curl -s -X POST '$AGENT_URL/apps/${APP_NAME}/users/u_demo/sessions/s_demo' -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' -d '{}' >/dev/null; curl -s -X POST '$AGENT_URL/run' -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' -d '{\"appName\":\"${APP_NAME}\",\"userId\":\"u_demo\",\"sessionId\":\"s_demo\",\"newMessage\":{\"role\":\"user\",\"parts\":[{\"text\":\"hello\"}]}}' | jq '.[].usageMetadata | select(.)'"
echo
echo "  promptTokenCount   the question"
echo "  candidatesTokenCount   the answer you can read"
echo "  thoughtsTokenCount   billed at the same rate, never shown"
echo "  totalTokenCount    what you actually pay for"
EOF

w "$S/08-reset-a.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "08  LEVER A DOWN"
run gcloud run services update "$SERVICE_NAME" \
  --project="$PROJECT_ID" --region "$REGION" --min-instances=0
run ./verify-teardown.sh
EOF

w "$S/09-lever-b.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "09  LEVER B  CONTEXT SIZE"
echo "  Different question, different project, different billing boundary."
runsh 'source ./env.sh B && scenv'
echo
echo "  Note: source env.sh B, not LEVER=B source env.sh."
echo "  The assignment prefix does not reach a sourced file in zsh, and it"
echo "  fails silently: you stay on lever A pointing at the wrong project."
run ./preflight.sh B
EOF

w "$S/10-session-death.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "10  WHERE THE SESSION WENT"
echo "  ADK's default session service is in-memory. Watch the startup log."
runsh 'gcloud run services logs read "$SERVICE_NAME" --project="$PROJECT_ID" --region="$REGION" --limit=30 | grep -i "in-memory\|storage" || echo "(scroll the logs, the line is there)"'
echo
echo "  Sessions live in one container's RAM. A second instance, or a"
echo "  replacement, has never heard of them."
echo
echo "  On the first attempt this cost 116 of 120 requests. The conversation"
echo "  died at request 4 and every one after returned 404."
EOF

w "$S/11-lever-c.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "11  LEVER C  TWO HOSTS, TWO CONTRACTS"
runsh 'source ./env.sh C && scenv'
echo
echo "  Cloud Run gives you a URL:"
runsh 'gcloud run services list --project="$PROJECT_ID" --region="$REGION" --format="value(status.url)" 2>/dev/null || echo "(none deployed right now)"'
echo
echo "  Agent Engine does not. It gives you a resource name."
runsh 'curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" "https://${VERTEX_LOCATION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${VERTEX_LOCATION}/reasoningEngines" | jq -r ".reasoningEngines[]?.name // \"none deployed\""'
echo
echo "  There is no gcloud command for these. Not beta aiplatform, not beta ai."
echo "  REST only."
echo
echo "  Different address, different auth, different endpoint, different"
echo "  response shape. And no unary query method at all: stream only."
EOF

w "$S/12-teardown.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "12  TEARDOWN  (all three)"
mark teardown start
for L in A B C; do
  echo; echo "  --- lever $L ---"
  runsh "source ./env.sh $L >/dev/null && ./verify-teardown.sh"
done
mark teardown done
EOF

w "$S/13-close.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "13  BACK TO ZERO"
runsh 'source ./env.sh A >/dev/null && ./preflight.sh A'
echo "  Preflight green again is the teardown proof. Same script I opened with."
runsh 'tail -20 "$SC_DIR/evidence/wallclock.csv"'
EOF

# ---------------------------------------------------------------------------
if [[ -f "$ROOT/traffic-profiles.json" ]]; then
  if ! grep -q '"filmdemo"' "$ROOT/traffic-profiles.json"; then
    python3 - "$ROOT/traffic-profiles.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["profiles"].append({
  "id":"filmdemo",
  "description":"On camera only. Short, visible, not for analysis. Excluded from the cost dataset.",
  "shape":"constant","requests_per_hour":120,"duration_minutes":5})
json.dump(d,open(p,"w"),indent=2)
print("  added filmdemo profile")
PY
  else
    echo "  skip   filmdemo profile already present"
  fi
fi

echo
echo "  $created created, $skipped skipped"
echo "  run them in order: steps/00 through steps/13"
