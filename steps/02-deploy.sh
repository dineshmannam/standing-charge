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
