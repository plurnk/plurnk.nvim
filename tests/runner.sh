#!/usr/bin/env bash
# Headless e2e test runner. One nvim process per spec to enforce
# isolation. Exits non-zero on any FAIL.
#
# Usage:
#   ./tests/runner.sh                 — run every spec
#   ./tests/runner.sh 05              — run a single spec by id prefix
#
# Daemon address: PLURNK_HOST / PLURNK_PORT (defaults 127.0.0.1:3044).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export PLURNK_NVIM_ROOT="$REPO_DIR"
export PLURNK_HOST="${PLURNK_HOST:-127.0.0.1}"
export PLURNK_PORT="${PLURNK_PORT:-3044}"

SPECS_DIR="$REPO_DIR/tests/specs"
FILTER="${1:-}"

pass=0
fail=0
failed_names=()

for spec in "$SPECS_DIR"/*.lua; do
  name="$(basename "$spec" .lua)"
  if [ -n "$FILTER" ] && [[ "$name" != "$FILTER"* ]]; then continue; fi
  echo "== $name =="
  if nvim --headless -u NONE -l "$spec" 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_names+=("$name")
  fi
done

echo
echo "── results ──"
echo "PASS: $pass"
echo "FAIL: $fail"
if [ $fail -gt 0 ]; then
  printf 'failed: %s\n' "${failed_names[@]}"
  exit 1
fi
