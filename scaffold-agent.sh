#!/usr/bin/env bash
#
# scaffold-agent.sh
#
# Creates the ADK agent directory in the layout the Python buildpack expects.
#
# From the codelab (§8): requirements.txt sits at the ROOT, the agent package is
# a SUBDIRECTORY, and you deploy from the root, not from the package.
#
#   agent/
#     requirements.txt
#     my_agent/
#       __init__.py
#       agent.py
#
# Note: the codelab writes `__init.py__`, which is a typo. Python needs
# `__init__.py` or the package will not import.
#
# Usage:  ./scaffold-agent.sh [dir]     default: ./agent

set -euo pipefail

ROOT="${1:-./agent}"
PKG="${APP_NAME:-my_agent}"
ADK_PIN="${ADK_PIN:-}"

created=0; skipped=0
w() {
  local p="$1"; mkdir -p "$(dirname "$p")"
  if [[ -e "$p" ]]; then echo "  skip   $p"; skipped=$((skipped+1)); cat >/dev/null
  else cat > "$p"; echo "  create $p"; created=$((created+1)); fi
}

echo
echo "Scaffolding ADK agent in $ROOT (package: $PKG)"
echo

mkdir -p "$ROOT/$PKG"

if [[ -z "$ADK_PIN" ]]; then
  ADK_PIN=$(python3 -c 'import importlib.metadata as m; print(m.version("google-adk"))' 2>/dev/null || true)
fi

if [[ -n "$ADK_PIN" ]]; then
  w "$ROOT/requirements.txt" <<EOF
google-adk==${ADK_PIN}
EOF
  echo "         pinned google-adk==${ADK_PIN}"
else
  w "$ROOT/requirements.txt" <<'EOF'
google-adk
EOF
  echo "         WARNING: google-adk not installed locally, left unpinned."
  echo "         Pin it before running any lever. An upgrade mid-experiment"
  echo "         confounds the comparison and nothing in the data would show it."
fi

w "$ROOT/$PKG/__init__.py" <<'EOF'
# Copyright 2026 Dinesh Mannam
#
# Derived from the Google "Ultimate Cloud Run guide" codelab, whose code samples
# are licensed under the Apache License, Version 2.0. Codelab content (c) Google LLC.
# See ATTRIBUTION.md. Licensed under the Apache License, Version 2.0.

from . import agent
EOF

w "$ROOT/$PKG/agent.py" <<'EOF'
# Copyright 2026 Dinesh Mannam
#
# Derived from the Google "Ultimate Cloud Run guide" codelab, whose code samples
# are licensed under the Apache License, Version 2.0. Codelab content (c) Google LLC.
# Modified: the model id is read from AGENT_MODEL instead of being hardcoded.
# See ATTRIBUTION.md.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import os

from google.adk import Agent

# Model is read from the environment so the same image can be pointed at a
# different model without a code change. Keep it identical across all levers.
MODEL = os.environ.get("AGENT_MODEL", "gemini-2.5-flash")

root_agent = Agent(
    name="demo_agent",
    model=MODEL,
    instruction="You are a helpful assistant for a Cloud Run demo.",
)
EOF

w "$ROOT/.gcloudignore" <<'EOF'
# Only the agent should reach Cloud Build. Nothing else.
../
evidence/
queries/
docs/
steps/
*.csv
*.md
env.local.sh
.hf_token
*.token
.venv/
__pycache__/
*.pyc
EOF

echo
echo "  $created created, $skipped skipped"
cat <<EOF

  Deploy from ${ROOT}, not from ${ROOT}/${PKG}:

    gcloud run deploy "\$SERVICE_NAME" \\
      --project="\$PROJECT_ID" \\
      --source "\$AGENT_DIR" \\
      --region "\$REGION" \\
      --allow-unauthenticated \\
      --service-account="agent-sa@\${PROJECT_ID}.iam.gserviceaccount.com" \\
      --set-env-vars="GOOGLE_GENAI_USE_VERTEXAI=TRUE,GOOGLE_CLOUD_PROJECT=\${PROJECT_ID},GOOGLE_CLOUD_LOCATION=\${VERTEX_LOCATION},AGENT_MODEL=\${VERTEX_MODEL}" \\
      --labels="\$LABELS" \\
      --min-instances=0

EOF
