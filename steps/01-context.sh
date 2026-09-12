#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "01  WHERE WE ARE"
run scenv
runsh 'gcloud run services list --project="$PROJECT_ID" --region="$REGION"'
