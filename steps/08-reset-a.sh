#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "08  LEVER A DOWN"
run gcloud run services update "$SERVICE_NAME" \
  --project="$PROJECT_ID" --region "$REGION" --min-instances=0
run ./verify-teardown.sh
