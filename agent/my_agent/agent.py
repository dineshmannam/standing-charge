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
