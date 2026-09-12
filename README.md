# Standing Charge

What are you actually paying for when you run an agent?

A standing charge is the line on a utility bill you pay just for being
connected, before you have used anything. This project measures the standing
charges hiding in a Cloud Run plus Vertex AI agent deployment.

## The three levers

| Lever | Question | Codelab |
|---|---|---|
| A. Idle capacity | At what requests per hour does a warm min-instance beat scale to zero? | Ultimate Cloud Run guide |
| B. Context size | What does ADK EventCompaction actually save per invocation? | Debugging Agents at Scale |
| C. Hosting model | Does Agent Runtime carry a premium over Cloud Run? | Both |

Unit of measurement: **cost per thousand invocations**, with cost per million
tokens secondary.

Thesis: idle capacity costs the same as busy capacity. Every lever is a
different way of paying for something you did not use.

## What you need

| | Why |
|---|---|
| `gcloud`, `jq`, `curl`, `python3` | Every script. `preflight.sh` checks for all four. |
| A GCP project per lever, on one billing account | See below |
| `google-adk` | To deploy and check the agent. Pinned in `agent/requirements.txt`. |
| `google-cloud-aiplatform` | Lever C only, and only to run `adk deploy agent_engine`. |
| `uv` / `uvx` | Optional. The codelab deploys with `uvx`; `gcloud run deploy` also works. |

**`loadgen.py` needs no install at all.** It is pure standard library — `argparse`,
`csv`, `datetime`, `json`, `os`, `statistics`, `subprocess`, `sys`, `time`,
`urllib`, `uuid` — so it runs on a bare clone with no venv:

```bash
python3 loadgen.py --url https://example-uc.a.run.app --profile steady --dry-run
```

That is deliberate. The tool that produces the measurements should not itself be
a dependency problem. The same is true of `queries/`, of `steps/`, and of reading
`evidence/`: none of them need Python packages.

## Setup

Skip this entirely if you only want to run `loadgen.py`, read the evidence, or
run the queries. You need it to deploy or check the agent.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r agent/requirements.txt          # google-adk==2.8.0
```

That is enough for levers A and B, and for `./preflight.sh`. Verified: on a fresh
clone `./preflight.sh --local` fails on `google-adk not importable` and exits 1;
after these three lines it passes.

**Lever C needs one more package**, because `adk deploy agent_engine` does
`import vertexai` and the ADK pin does not pull it in:

```bash
pip install 'google-cloud-aiplatform[adk,agent_engines]==2.1.0'
```

This one is deliberately not in `agent/requirements.txt`. That file is the
manifest Cloud Build installs into the deployed image, so adding a package there
would change what levers A and B are measuring. `adk deploy agent_engine` adds
the requirement to the Agent Engine image itself.

### Why there is no top-level requirements.txt

Those two are the repo's only direct dependencies; everything else in a working
environment is their transitive closure. Pinning that closure would freeze a
resolution specific to one OS, one architecture, one interpreter and one
afternoon's index state, without making any measurement more reproducible — and
it would put a second, drifting copy of the ADK version next to the one
`agent/requirements.txt` already owns.

The numbers in `findings.md` were produced under **Python 3.14.6** with
**google-adk 2.8.0** and **google-cloud-aiplatform 2.1.0**. That environment held
73 packages; installing the two pins today resolves a slightly different set,
which is the point. `evidence/adk-version` records the ADK version each run
actually used.

## Quick start

```bash
cp env.local.sh.example env.local.sh   # fill in, one project per lever
source env.sh
./preflight.sh A
```

`./preflight.sh --local` runs only the checks that need no cloud access, which is
the fastest way to see whether your machine is ready.

## One project per lever

Vertex AI calls bill at project level with no resource to label, so the project
is the only attribution boundary that works. All three link to one billing
account, and all rows land in one export dataset. Separation happens in the
query, not the export.

## Layout

| Path | What |
|---|---|
| `env.sh` | Shared variables, sources `env.local.sh` |
| `preflight.sh` | Prerequisite checks, lever aware |
| `postflight.sh` | Did the run produce what the analysis needs? |
| `traffic-profiles.json` | Frozen traffic shapes. Do not edit between runs. |
| `loadgen.py` | Holds a target requests per hour, writes per request CSV |
| `verify-teardown.sh` | Asserts nothing is still billing |
| `steps/` | The commands, one numbered script each, in run order |
| `queries/` | BigQuery SQL |
| `evidence/` | Run artifacts |
| `runbook.md` | Every command, marked as new or as replacing a codelab step |
| `findings.md` | What the measurements turned out to say |
| `decisions.md` | Why each choice was made, and what was rejected |

## Licence and attribution

This repository is licensed under the Apache License 2.0. See [`LICENSE`](LICENSE).

It builds on Google codelabs, whose prose is CC BY 4.0 and whose code samples are
Apache 2.0. Only one codelab supplied code, about forty lines of agent scaffold;
the other two supplied questions and no implementation. Everything measured, and
every number, is this repository's own. [`ATTRIBUTION.md`](ATTRIBUTION.md) says
exactly which is which.
