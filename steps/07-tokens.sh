#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "07  THE INVISIBLE BILL"

AGENT_URL="$(< "$SC_DIR/evidence/agent-url")"

echo "  One request. Look at what comes back."
echo

# Session first. Token inside the command, never echoed.
runsh "curl -s -X POST '$AGENT_URL/apps/${APP_NAME}/users/u_demo/sessions/s_demo' -H \"Authorization: Bearer \$(gcloud auth print-identity-token)\" -H 'Content-Type: application/json' -d '{}' >/dev/null && echo 'session created'"

echo
runsh "curl -s -X POST '$AGENT_URL/run' -H \"Authorization: Bearer \$(gcloud auth print-identity-token)\" -H 'Content-Type: application/json' -d '{\"appName\":\"${APP_NAME}\",\"userId\":\"u_demo\",\"sessionId\":\"s_demo\",\"newMessage\":{\"role\":\"user\",\"parts\":[{\"text\":\"hello\"}]}}' | jq '.[].usageMetadata | select(.)'"

echo
echo "  promptTokenCount       the question"
echo "  candidatesTokenCount   the answer you can read"
echo "  thoughtsTokenCount     billed the same, never shown"
echo "  totalTokenCount        what you actually pay for"
