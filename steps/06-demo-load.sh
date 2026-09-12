#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "06  LIVE LOAD  (filmdemo, ~5 min)"
AGENT_URL="$(< "$SC_DIR/evidence/agent-url")"
mark demoload start
run caffeinate -dimsu python3 loadgen.py --url "$AGENT_URL" --profile filmdemo --fresh-session
mark demoload done
echo
echo "  Watch the think= column. That is the number this whole video is about."
