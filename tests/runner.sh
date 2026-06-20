#!/usr/bin/env bash
# Headless e2e test runner. One nvim process per spec to enforce
# isolation. Exits non-zero on any FAIL.
#
# Usage:
#   ./tests/runner.sh                 — run every spec
#   ./tests/runner.sh 05              — run a single spec by id prefix
#
# Daemon: with PLURNK_PORT set, the suite targets that daemon (yours to
# manage). Without it, the runner boots a PRIVATE plurnk-service from the
# sibling repo — tmp DB, ephemeral port, killed on exit — so the suite
# never touches a developer's live daemon on 3044.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export PLURNK_NVIM_ROOT="$REPO_DIR"
export PLURNK_HOST="${PLURNK_HOST:-127.0.0.1}"

DAEMON_PID=""
DAEMON_DIR=""
cleanup() {
  if [ -n "$DAEMON_PID" ]; then
    pkill -P "$DAEMON_PID" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
  fi
  [ -n "$DAEMON_DIR" ] && rm -rf "$DAEMON_DIR"
  return 0  # never let the trap's last falsy test leak into the exit code
}
trap cleanup EXIT

if [ -z "${PLURNK_PORT:-}" ]; then
  # PLURNK_SERVICE_DIR overrides where the daemon is launched from —
  # CI, or a clean worktree while the sibling checkout is mid-edit.
  SERVICE_BIN=""
  for dir in "${PLURNK_SERVICE_DIR:-}" "$REPO_DIR/../plurnk-service"; do
    [ -z "$dir" ] && continue
    # Entrypoint has moved over time: bin/plurnk-service.{js,ts} → src/service.ts
    # (bin: dist/service.js, 2026-06-20). Probe newest-first, old paths kept.
    for rel in src/service.ts dist/service.js bin/plurnk-service.ts bin/plurnk-service.js; do
      if [ -r "$dir/$rel" ]; then SERVICE_BIN="$dir/$rel"; break 2; fi
    done
  done
  if [ -z "$SERVICE_BIN" ]; then
    echo "plurnk-service sibling not found; set PLURNK_PORT to use an existing daemon" >&2
    exit 1
  fi
  SERVICE_DIR="$(cd "$(dirname "$SERVICE_BIN")/.." && pwd -P)"
  DAEMON_DIR="$(mktemp -d)"
  (
    cd "$SERVICE_DIR"
    PLURNK_DB_PATH="$DAEMON_DIR/plurnk.db" PLURNK_PORT=0 \
      node --env-file-if-exists=.env "$SERVICE_BIN" > "$DAEMON_DIR/daemon.log" 2>&1 &
    echo $! > "$DAEMON_DIR/pid"
  )
  DAEMON_PID="$(cat "$DAEMON_DIR/pid")"
  PORT_LINE=""
  for _ in $(seq 1 50); do
    PORT_LINE="$(grep -o 'ws://127\.0\.0\.1:[0-9]*' "$DAEMON_DIR/daemon.log" 2>/dev/null | head -1 || true)"
    [ -n "$PORT_LINE" ] && break
    sleep 0.2
  done
  if [ -z "$PORT_LINE" ]; then
    echo "private daemon failed to boot:" >&2
    cat "$DAEMON_DIR/daemon.log" >&2 || true
    exit 1
  fi
  export PLURNK_PORT="${PORT_LINE##*:}"
  echo "── private daemon on :$PLURNK_PORT ──"
fi

SPECS_DIR="$REPO_DIR/tests/specs"
FILTER="${1:-}"

pass=0
fail=0
failed_names=()

for spec in "$SPECS_DIR"/*.lua; do
  name="$(basename "$spec" .lua)"
  if [ -n "$FILTER" ] && [[ "$name" != "$FILTER"* ]]; then continue; fi
  echo "== $name =="
  # SIGKILL, not the default SIGTERM: headless nvim survives SIGTERM, so a
  # hung spec under plain `timeout` detaches and spins forever (99% CPU
  # orphans). A timed-out spec is a loud FAIL, never a silent leak.
  if timeout -s KILL "${SPEC_TIMEOUT:-60}" nvim --headless -u NONE -l "$spec" 2>&1; then
    pass=$((pass + 1))
  else
    rc=$?
    fail=$((fail + 1))
    if [ "$rc" -eq 137 ]; then
      echo "  TIMED OUT — SIGKILL after ${SPEC_TIMEOUT:-60}s"
      failed_names+=("$name (timeout)")
    else
      failed_names+=("$name")
    fi
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
exit 0
