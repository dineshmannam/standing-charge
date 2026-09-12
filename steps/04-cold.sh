#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "04  COLD START  (min-instances = 0)"

AGENT_URL="$(< "$SC_DIR/evidence/agent-url")"
PROBE="${AGENT_URL}/list-apps"

# Token is fetched INSIDE the curl so it never appears in the echoed command.
# A printed identity token is a live credential on tape.
# /list-apps is a real ADK route. Hitting / returns 404 in ~150ms, which
# measures the frontend rejecting you rather than a cold start.

RUNNING=$(gcloud run services describe "$SERVICE_NAME" \
  --project="$PROJECT_ID" --region="$REGION" \
  --format="value(spec.template.metadata.annotations['autoscaling.knative.dev/minScale'])" 2>/dev/null)

if [[ -n "$RUNNING" && "$RUNNING" != "0" ]]; then
  printf "  %sminScale is %s. Held warm, so there is no cold start to measure.%s\n" \
    "$YELLOW" "$RUNNING" "$RESET"
  echo "  Set --min-instances=0, wait ~15 min, then run this."
  exit 1
fi

echo "  Service is at minScale 0."
echo "  If the first request comes back under a second, it was still warm."
echo
pause "ready to roll"

mark cold start

echo
echo "  Request one. Nothing is running, so this has to start a container."
runsh "time curl -s -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' -H \"Authorization: Bearer \$(gcloud auth print-identity-token)\" '$PROBE'"

echo
echo "  Request two. Immediately. Same request, the instance is warm now."
runsh "time curl -s -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' -H \"Authorization: Bearer \$(gcloud auth print-identity-token)\" '$PROBE'"

mark cold done

echo
echo "  Both must be HTTP 200. A 404 means the route is wrong and this"
echo "  measured the frontend, not a cold start."
