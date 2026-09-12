#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "05  HOLD ONE WARM  (min-instances = 1)"

AGENT_URL="$(< "$SC_DIR/evidence/agent-url")"
PROBE="${AGENT_URL}/list-apps"

mark warm start

run gcloud run services update "$SERVICE_NAME" \
  --project="$PROJECT_ID" --region "$REGION" \
  --min-instances=1 --labels="$LABELS"

echo "  From here it bills whether or not anyone calls it."
pause "wait ~2 min for the instance to come up"

# Token inside the curl, never echoed.
runsh "time curl -s -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' -H \"Authorization: Bearer \$(gcloud auth print-identity-token)\" '$PROBE'"

mark warm done

echo
echo "  Must be HTTP 200, and fast. No cold start, because one was already up."
