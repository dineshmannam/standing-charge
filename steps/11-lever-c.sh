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
