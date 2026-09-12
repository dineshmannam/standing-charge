#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "03  GET THE URL"
runsh 'export AGENT_URL=$(gcloud run services describe "$SERVICE_NAME" --project="$PROJECT_ID" --region "$REGION" --format "value(status.url)"); echo "[$AGENT_URL]"'
echo "$AGENT_URL" > "$SC_DIR/evidence/agent-url"
echo "  saved to evidence/agent-url"
