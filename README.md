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

## Quick start

```bash
cp env.local.sh.example env.local.sh   # fill in, one project per lever
source env.sh
./preflight.sh A
```

## Project layout

One GCP project per lever. Vertex AI calls bill at project level with no
resource to label, so the project is the only attribution boundary that works.
All three link to one billing account, and all rows land in one export dataset.
Separation happens in the query, not the export.

## Layout

| Path | What |
|---|---|
| `env.sh` | Shared variables, sources `env.local.sh` |
| `preflight.sh` | Prerequisite checks, lever aware |
| `traffic-profiles.json` | Frozen traffic shapes. Do not edit between runs. |
| `loadgen.py` | Holds a target requests per hour, writes per request CSV |
| `verify-teardown.sh` | Asserts nothing is still billing |
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
