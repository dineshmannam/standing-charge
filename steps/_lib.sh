#!/usr/bin/env bash
# Shared helpers. Sourced by every step script.
set -uo pipefail

[[ -n "${SC_DIR:-}" ]] || { echo "source env.sh first"; exit 1; }

# Step scripts run in a subshell that inherits exported variables but not
# exported functions, so `mark` and friends are missing. Re-source to get them.
source "$SC_DIR/env.sh" "${LEVER:-A}" >/dev/null 2>&1 || true

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'; RESET=$'\033[0m'

banner() {
  printf "\n%s%s%s\n" "$BOLD" "$(printf '=%.0s' {1..64})" "$RESET"
  printf "%s  %s%s\n" "$BOLD" "$1" "$RESET"
  printf "%s%s%s\n\n" "$BOLD" "$(printf '=%.0s' {1..64})" "$RESET"
}

# Show the command, wait, then run it. This is the teleprompter.
run() {
  printf "\n%s\$ %s%s\n\n" "$DIM" "$*" "$RESET"
  read -rp "  [Enter to run] " _
  "$@"
  local rc=$?
  if [[ $rc -eq 0 ]]; then printf "\n  %sok%s\n" "$GREEN" "$RESET"
  else printf "\n  %sexit %d%s\n" "$YELLOW" "$rc" "$RESET"; fi
  return $rc
}

# Same, for a shell string with pipes or substitutions.
runsh() {
  printf "\n%s\$ %s%s\n\n" "$DIM" "$1" "$RESET"
  read -rp "  [Enter to run] " _
  eval "$1"
}

pause() { printf "\n  %s%s%s\n" "$YELLOW" "${1:-pause}" "$RESET"; read -rp "  [Enter to continue] " _; }

# Keep the machine awake for the duration of a command, on whatever OS this is.
#
# F12: the Mac slept for 368s mid-run, drifting the schedule past the identity
# token's one hour expiry. That produces a silent hole -- no error, no retry,
# just an absence you only see as drift. An unattended hour needs a sleep
# inhibitor. `caffeinate` is macOS-only; the Linux equivalent is
# `systemd-inhibit`. On anything else, say so rather than failing with
# "command not found" on the documented run path.
nosleep() {
  if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -dimsu "$@"
  elif command -v systemd-inhibit >/dev/null 2>&1; then
    systemd-inhibit --what=idle:sleep --why="standing-charge load run" "$@"
  else
    printf "  %sno sleep inhibitor (caffeinate/systemd-inhibit) found.%s\n" "$YELLOW" "$RESET"
    printf "  %sIf this machine sleeps mid-run the schedule drifts past the token expiry (F12).%s\n" "$YELLOW" "$RESET"
    "$@"
  fi
}
