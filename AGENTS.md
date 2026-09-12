# Project agent memory

Standing Charge is a measurement study published as a public companion to a
video. Its bar is that a stranger who watched the video can clone it and run it.
Four constraints follow from that and are not obvious from the code.

## Every shell script must run under bash 3.2

Stock macOS ships bash 3.2.57 at `/bin/bash`; Homebrew bash 5 on `PATH` hides
this. `#!/usr/bin/env bash` picks up whichever is first, so a reader on a clean
Mac gets 3.2. No `declare -A` (subscripts evaluate as arithmetic and silently
collapse to index 0 — see the comment at the lever-isolation section of
`preflight.sh`), and never expand an empty array under `set -u` without guarding
the count first. Check with `/bin/bash -n <script>`, not `bash -n`.

## `tests/no-leaked-identifiers.sh` is the gate before any push

It scans tracked files only, and its exact checks read real values from the
untracked local files that hold them, so it is strongest on the machine that did
the study. It also checks history, not just the tip. If a change makes it fail,
that is a finding, not a test to adjust.

## Some files stay on disk, untracked, on purpose

`evidence/billing-account`, `evidence/current-run-id`, `evidence/agent-url`,
`evidence/agent-url-B`, `evidence/agent-engine-C`, `env.local.sh`, `filmday.md`,
`script.md`. Committing the evidence caches makes a fresh clone silently inherit
the last operator's billing account and run id — `.gitignore` explains the
mechanism. Never `git add -f` them and never delete them.

## `build-steps.sh` must regenerate `steps/` byte-for-byte

`steps/` is the authority; the generator is the record of how it is built. The
header of `build-steps.sh` carries the diff command that proves they agree, and
the two invariants (no identity token in a string `runsh` will echo; probe
`/list-apps`, not `/`) that a past drift broke.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
