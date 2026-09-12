# Attribution

This project builds on Google codelabs. The debt is uneven, and stating it
precisely matters more than stating it broadly: attributing everything to "the
codelabs" would overclaim a relationship with material that was never used,
while saying nothing would understate the one real debt.

So, separating code taken from ideas taken:

## Code taken

**Ultimate Cloud Run guide** —
<https://codelabs.developers.google.com/next26/ultimate-cloud-run-guide>

This is the only codelab that supplied code: roughly forty lines of ADK agent
scaffold. Google's codelab **code samples are licensed Apache License 2.0**, and
the surrounding codelab **prose is licensed CC BY 4.0**.

The derived files in this repository are:

| File | What was taken |
|---|---|
| `agent/my_agent/agent.py` | The `root_agent` definition and the buildpack-compatible layout |
| `agent/my_agent/__init__.py` | The package re-export |
| `scaffold-agent.sh` | The heredocs that generate both of the above |

**What was modified:**

- The model id is read from the `AGENT_MODEL` environment variable rather than
  hardcoded, so the same image can be pointed at a different model without a
  code change and stays identical across all three levers.
- The codelab writes `touch my_agent/__init.py__`. Python needs `__init__.py`.
  Followed literally the package never imports, the container still builds and
  deploys, and it fails on the first request with a `NameError` about thirty
  lines down a FastAPI/ADK traceback. This repository uses the correct filename.
  Reported to Google on 4 September 2026.
- `scaffold-agent.sh` pins `google-adk` to the locally installed version, so an
  ADK upgrade between levers cannot silently confound the comparison.

## Ideas taken

**Debugging Agents at Scale** —
<https://codelabs.developers.google.com/next26/dev-keynote/debugging-agents>

Supplied the question behind lever B — what `EventCompaction` actually costs —
and nothing else. No implementation was used. The codelab is a debugging
exercise built around a session that *exceeds* the model's context limit; this
repository turns that question into a measurement at ordinary agent scale, which
is where the answer turns out to be different. Licensed CC BY 4.0, code samples
Apache 2.0.

Lever C's question — whether managed hosting carries a premium — came from
reading both codelabs against each other. Again no implementation was taken.

## What this repository adds

Everything else, and it is the substance:

- The measurement layer: `preflight.sh`, `postflight.sh`, `loadgen.py`,
  `verify-teardown.sh`, `env.sh`, `build-steps.sh`, `steps/`.
- The frozen traffic profiles in `traffic-profiles.json`.
- Every BigQuery query in `queries/`.
- The three-project-per-lever attribution design, the labelling scheme, and the
  billing-export reconciliation.
- All run evidence in `evidence/`, and every number in `findings.md`.

None of the measurement work, and none of the results, come from any codelab.

## Licences

| Material | Licence |
|---|---|
| This repository's own code and documents | Apache License 2.0 — see [`LICENSE`](LICENSE) |
| Google codelab **code samples** the agent scaffold derives from | Apache License 2.0 |
| Google codelab **prose** the lever questions derive from | CC BY 4.0 — <https://creativecommons.org/licenses/by/4.0/> |

Google codelab content is © Google LLC. This project is not affiliated with or
endorsed by Google.
