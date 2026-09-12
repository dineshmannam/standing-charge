#!/usr/bin/env bash
# Asserts nothing is still billing. Do not trust a delete command's exit code.
set -uo pipefail
: "${PROJECT_ID:?source env.sh first}"
: "${REGION:?source env.sh first}"

fail=0
check() {
  local label="$1"; shift
  local out; out=$("$@" 2>/dev/null)
  if [[ -n "$out" ]]; then echo "STILL PRESENT: $label"; echo "$out"; fail=1
  else echo "clear: $label"; fi
}

check "cloud run services" gcloud run services list \
  --project="$PROJECT_ID" --region="$REGION" --format="value(metadata.name)"

# Reasoning engines have NO gcloud surface. Not `gcloud beta aiplatform`, not
# `gcloud beta ai` (F15). The old check called one of those non-existent
# commands through check(), which swallows stderr, so an invalid command
# produced empty output and printed "clear" for a resource class it could never
# see. A forgotten reasoning engine bills while it exists, so a false all-clear
# here is the most expensive failure this script can have.
#
# REST is the only path, and an empty body, an empty list and an error object
# must be told apart rather than collapsed into "nothing found".
VERTEX_LOCATION="${VERTEX_LOCATION:-$REGION}"
RE_JSON=$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" \
  "https://${VERTEX_LOCATION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${VERTEX_LOCATION}/reasoningEngines" 2>/dev/null)

if [[ -z "${RE_JSON//[[:space:]]/}" ]]; then
  echo "UNVERIFIED: reasoning engines (no response from the API)"
  echo "  An empty body is not an empty list. Check the aiplatform API and network."
  fail=1
elif grep -q '"error"' <<<"$RE_JSON"; then
  echo "UNVERIFIED: reasoning engines (API returned an error)"
  jq -r '"  " + (.error.message // "unknown")' <<<"$RE_JSON" 2>/dev/null \
    || echo "  could not parse the error body"
  fail=1
else
  RE_NAMES=$(jq -r '.reasoningEngines[]?.name // empty' <<<"$RE_JSON" 2>/dev/null)
  if [[ -n "$RE_NAMES" ]]; then
    echo "STILL PRESENT: reasoning engines"
    while read -r n; do
      [[ -z "$n" ]] && continue
      echo "  $n"
      printf '  delete: curl -X DELETE -H "Authorization: Bearer $(gcloud auth print-access-token)" \\\n            "https://%s-aiplatform.googleapis.com/v1beta1/%s?force=true"\n' \
        "$VERTEX_LOCATION" "$n"
    done <<<"$RE_NAMES"
    fail=1
  else
    echo "clear: reasoning engines"
  fi
fi

check "artifact registry repos" gcloud artifacts repositories list \
  --project="$PROJECT_ID" --location="$REGION" --format="value(name)"

echo
[[ $fail -eq 0 ]] && echo "Teardown verified." || echo "Teardown INCOMPLETE."
exit $fail
