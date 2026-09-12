#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "10  WHERE THE SESSION WENT"
echo "  ADK's default session service is in-memory. Watch the startup log."
runsh 'gcloud run services logs read "$SERVICE_NAME" --project="$PROJECT_ID" --region="$REGION" --limit=30 | grep -i "in-memory\|storage" || echo "(scroll the logs, the line is there)"'
echo
echo "  Sessions live in one container's RAM. A second instance, or a"
echo "  replacement, has never heard of them."
