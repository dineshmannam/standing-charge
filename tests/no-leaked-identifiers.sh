#!/usr/bin/env bash
#
# Guard against republishing account or infrastructure identifiers.
#
# This repository is public. Several run-local files hold real identifiers and
# stay on disk deliberately - evidence/billing-account, evidence/agent-url,
# evidence/agent-engine-C and friends - so "is the working tree clean" is the
# wrong question. The only question that matters is what git would publish.
#
# So every scan here runs over TRACKED FILES ONLY, via git ls-files. A real value
# sitting in an untracked working file is correct and expected; the same value in
# a tracked file is a leak.
#
# This script deliberately contains NO secret values of its own. A denylist of
# literal identifiers would have to spell out the very strings it exists to keep
# out of the published tree, which is self-defeating. Instead it works two ways:
#
#   * SHAPE checks, which need no secrets and also catch identifiers nobody has
#     thought to add to a list yet - billing-account-shaped strings, bare project
#     numbers, deployed *.run.app hostnames, reasoningEngine ids.
#
#   * EXACT checks, where the forbidden values are read at runtime from the
#     untracked local files that hold them. On the author's machine that is an
#     exact denylist with no hardcoded secrets; on a fresh public clone those
#     files are absent and the script says so rather than pretending it checked.
#
# It also asserts three things a grep for identifiers would not catch, all of
# which were live defects before the pre-publication pass:
#
#   * verify-teardown.sh must not call `gcloud ... reasoning-engines`. No such
#     gcloud surface exists, and the old call sat inside a stderr-swallowing
#     helper, so an invalid command produced empty output and printed a clean
#     bill of health for a resource class that bills while it exists.
#
#   * runbook.md must not TEACH `LEVER=B source env.sh`. The assignment prefix
#     does not reliably reach a sourced file in zsh and fails silently, leaving
#     you on the previous lever pointing at the wrong project.
#
#   * runbook.md must not recommend `bq load --autodetect`, which infers STRING
#     for the NA-bearing token columns and silently breaks every downstream SUM.
#
#   In all three cases prose warning against the form is fine. Only a command
#   line actually using it is a regression, so these match shell-command shapes,
#   not any mention of the words.
#
# Usage:  ./tests/no-leaked-identifiers.sh
# Exit:   0 clean, 1 something would be published that should not be, 2 cannot run

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 2

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "not inside a git repository"; exit 2; }

fail=0
skipped=0
note() { printf '  %s\n' "$1"; }
section() { printf '\n%s\n' "$1"; }

# Tracked files, NUL-separated, reused by every scan.
tracked_grep() { git ls-files -z | xargs -0 grep -nHE -- "$1" 2>/dev/null; }

report() {                       # report <label> <hits>
  if [[ -n "$2" ]]; then
    note "LEAK  $1"
    printf '%s\n' "$2" | sed 's/^/        /'
    fail=1
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
section "Shape checks (no secrets needed)"
# ---------------------------------------------------------------------------
shape_bad=0

# A GCP billing account id: three hyphen-joined uppercase-hex blocks. The
# published placeholder 012345-6789AB-CDEF01 is the one allowed value.
hits=$(tracked_grep '\b[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}\b' \
       | grep -v '012345-6789AB-CDEF01')
report "billing-account-shaped string" "$hits" || shape_bad=1

# A deployed Cloud Run hostname. Any real one carries a service hash.
hits=$(tracked_grep '[A-Za-z0-9-]+\.[a-z0-9-]+\.run\.app' | grep -v 'example')
report "deployed *.run.app hostname" "$hits" || shape_bad=1

# A bare project number or reasoningEngine id: a long digit run that is not part
# of a date, a token count, a cost, or a CSV row. Evidence CSVs are numeric by
# nature, so they are excluded and covered by the exact checks below instead.
hits=$(git ls-files -z | grep -zv '\.csv$' | xargs -0 grep -nHE -- '\b[0-9]{9,}\b' 2>/dev/null)
report "bare 9+ digit identifier" "$hits" || shape_bad=1

# A fully-qualified Vertex resource path with a numeric project, rather than the
# PROJECT_NUMBER / ENGINE_ID placeholders.
hits=$(tracked_grep 'projects/[0-9]+/locations/')
report "resource path with a numeric project" "$hits" || shape_bad=1

[[ $shape_bad -eq 0 ]] && note "clean: no identifier-shaped string in any tracked file"

# ---------------------------------------------------------------------------
section "Exact checks (values read from untracked local files)"
# ---------------------------------------------------------------------------
exact_bad=0
checked_any=0

# Collect the real values from wherever they actually live, without ever writing
# one into this file. Each source is optional.
declare -a secrets=()
add_secret() { [[ -n "${1:-}" ]] && secrets+=("$1"); }

# Note: evidence/current-run-id is NOT a secret source. It is untracked for a
# reproducibility reason - a fresh clone must not inherit the last operator's run
# id - but the run id itself is published data and appears throughout the
# evidence CSVs by design. Those are different concerns.
for f in evidence/billing-account \
         evidence/agent-url evidence/agent-url-B evidence/agent-engine-C; do
  [[ -s "$f" ]] || continue
  # Never trust a tracked file as a secret source: if it is tracked, its content
  # is already published and the shape checks above own that failure.
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue
  add_secret "$(tr -d '[:space:]' < "$f")"
done

if [[ -f env.local.sh ]] && ! git ls-files --error-unmatch env.local.sh >/dev/null 2>&1; then
  while IFS= read -r v; do add_secret "$v"; done < <(
    sed -n 's/^[[:space:]]*export[[:space:]]\{1,\}\(PROJECT_LEVER_[ABC]\|BILLING_PROJECT\|PROJECT_ID\)=//p' \
      env.local.sh | tr -d '"'"'" | tr -d '[:space:]'
  )
fi

if [[ ${#secrets[@]} -eq 0 ]]; then
  note "SKIPPED: no untracked source of real identifiers found on this machine."
  note "  Nothing to compare against, so this section proved nothing. The shape"
  note "  checks above still ran. Run this on the machine that did the study."
  skipped=1
else
  for v in "${secrets[@]}"; do
    # Two characters of context is enough to be a real identifier, and skipping
    # short values keeps a run id like "a" from matching the entire tree.
    [[ ${#v} -ge 6 ]] || continue
    checked_any=1
    hits=$(git ls-files -z | xargs -0 grep -nHEF -- "$v" 2>/dev/null)
    if [[ -n "$hits" ]]; then
      # Report the finding without echoing the secret into the log.
      note "LEAK  a real local identifier (${#v} chars) appears in tracked files:"
      printf '%s\n' "$hits" | cut -d: -f1-2 | sort -u | sed 's/^/        /'
      fail=1; exact_bad=1
    fi
  done
  if [[ $checked_any -eq 0 ]]; then
    note "SKIPPED: local sources held nothing long enough to check."
    skipped=1
  elif [[ $exact_bad -eq 0 ]]; then
    note "clean: ${#secrets[@]} local identifier(s) checked, none appear in tracked files"
  fi
fi

# ---------------------------------------------------------------------------
section "Run-local files stay untracked but preserved"
# ---------------------------------------------------------------------------
files_bad=0
for f in evidence/billing-account evidence/current-run-id evidence/agent-url \
         evidence/agent-url-B evidence/agent-engine-C filmday.md script.md; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    note "TRACKED   $f  (must be untracked and gitignored)"
    fail=1; files_bad=1
  elif [[ -e "$f" ]] && ! git check-ignore -q "$f"; then
    note "UNIGNORED $f  (on disk but not ignored: a git add -A would publish it)"
    fail=1; files_bad=1
  fi
done
[[ $files_bad -eq 0 ]] && note "clean: all run-local files untracked"

# ---------------------------------------------------------------------------
section "Known-bad command forms have not come back"
# ---------------------------------------------------------------------------
forms_bad=0

if grep -qE '^[[:space:]]*[^#]*gcloud[[:alnum:][:space:]-]*reasoning-engines' verify-teardown.sh 2>/dev/null; then
  note "verify-teardown.sh calls a gcloud reasoning-engines surface that does not exist,"
  note "  so it reports a false all-clear for engines that are still billing."
  fail=1; forms_bad=1
fi

if grep -qE '^[[:space:]]*LEVER=[ABC][[:space:]]+source[[:space:]]+env\.sh' runbook.md 2>/dev/null; then
  note "runbook.md teaches 'LEVER=X source env.sh', which fails silently in zsh."
  fail=1; forms_bad=1
fi

if grep -qE '^[[:space:]]*bq load[[:space:]].*--autodetect' runbook.md 2>/dev/null; then
  note "runbook.md recommends 'bq load --autodetect', which infers STRING for the"
  note "  NA-bearing token columns and silently breaks every downstream SUM()."
  fail=1; forms_bad=1
fi

[[ $forms_bad -eq 0 ]] && note "clean: no known-bad command form in a runnable position"

# ---------------------------------------------------------------------------
section "History (warning only)"
# ---------------------------------------------------------------------------
#
# Everything above asks what the CURRENT tree publishes. A public repository
# publishes its history too: `git show <commit>:<path>` retrieves any blob any
# commit ever contained, and clones and forks keep those objects even after the
# original is scrubbed. Removing a value at the tip does nothing about that.
#
# This section reports rather than fails, because rewriting history is a
# deliberate act with its own ordering constraints, not something a test should
# force. It goes quiet once the history no longer carries the values, so it also
# serves as the check that the rewrite worked.

# Identifier shapes only. A bad *instruction* surviving in history is not a
# disclosure risk, so the command-form checks above deliberately stay out of it.
# No \b: git grep's regex engine does not honour it, and a pattern that silently
# matches nothing would make this warning worse than useless.
HIST_SHAPES='[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}|[A-Za-z0-9-]+\.[a-z0-9-]+\.run\.app|projects/[0-9]+/locations/[a-z]'

hist_hits=""
for rev in $(git rev-list --all 2>/dev/null); do
  # Match on content so the published placeholder can be filtered out, then
  # reduce to rev:path. Filtering on filenames alone could not tell them apart.
  # Placeholder exclusions, each naming one exact permitted value. A value the
  # tip checks deliberately permit must not be reported here as a historical
  # leak, or the warning fires forever on a clean repo and stops being read.
  #
  # Name the literal, never a loose word. Filtering on 'example' would drop any
  # line that merely uses the word, so a genuine identifier sitting in a
  # sentence about an example would vanish silently - the one failure mode this
  # whole section exists to prevent. -F keeps the dots literal.
  h=$(git grep -nE "$HIST_SHAPES" "$rev" -- 2>/dev/null \
      | grep -v '012345-6789AB-CDEF01' \
      | grep -vE 'projects/PROJECT_NUMBER/' \
      | grep -vF 'example-uc.a.run.app' \
      | cut -d: -f1-2)
  [[ -n "$h" ]] && hist_hits+="$h"$'\n'
done

if [[ -n "${hist_hits//[[:space:]]/}" ]]; then
  note "WARNING: earlier commits still carry identifiers the tip has removed."
  note "  Shape-detected, so treat this as a floor and not an inventory: an"
  note "  arbitrary project id has no distinguishing shape and will not appear."
  printf '%s' "$hist_hits" | sed '/^$/d' | sort -u | sed 's/^/        /'
  note ""
  note "  Scrubbing the tip does NOT remove these. Anyone who clones can run"
  note "  'git show <commit>:<path>' and read them, and forks keep the objects"
  note "  even after a later rewrite. History must be rewritten or squashed"
  note "  BEFORE the first public push, not after."
else
  note "clean: no earlier commit carries an identifier either"
fi

# ---------------------------------------------------------------------------
echo
if [[ $fail -ne 0 ]]; then
  echo "FAIL  the tracked tree would publish something it should not. Do not push."
elif [[ $skipped -ne 0 ]]; then
  echo "PASS (with skips)  nothing sensitive found, but the exact check had no local source."
else
  echo "PASS  nothing sensitive would be published."
fi
exit $fail
