#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
banner "09  LEVER B  CONTEXT SIZE"
echo "  Different question, different project, different billing boundary."
runsh 'source ./env.sh B && scenv'
echo
echo "  Note: source env.sh B, not LEVER=B source env.sh."
echo "  The assignment prefix does not reach a sourced file in zsh, and it"
echo "  fails silently: you stay on lever A pointing at the wrong project."
run ./preflight.sh B
