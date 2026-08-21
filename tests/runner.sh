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
# metaproject checkout — tmp DB, ephemeral port, killed on exit — so the suite
# never touches a developer's live daemon on 3044.
#
# Model env: export PLURNK_MODEL=<selector> to admit the explicitly model-driven
# specs and forward that selection into the private daemon, plus any alias-scoped
# PLURNK_PROVIDERS_{CONTEXT_WINDOW,OUTPUT_BUDGET,REASONING_BUDGET,REASONING}
# controls needed to describe the serving box. The ordinary suite remains
# control-plane-only and does not read operator config or perform inference.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export PLURNK_NVIM_ROOT="$REPO_DIR"
export PLURNK_HOST="${PLURNK_HOST:-127.0.0.1}"

OPERATOR_HOME="${HOME:?HOME is required}"
OPERATOR_CONFIG_HOME="${XDG_CONFIG_HOME:-$OPERATOR_HOME/.config}"
case "$OPERATOR_CONFIG_HOME" in /*) ;; *) OPERATOR_CONFIG_HOME="$OPERATOR_HOME/.config";; esac
OPERATOR_ENV="$OPERATOR_CONFIG_HOME/plurnk/.env"
DAEMON_ENV_ARGS=()
if [ -n "${PLURNK_MODEL:-}" ]; then
  DAEMON_ENV_ARGS+=(--env-file-if-exists="$OPERATOR_ENV" --env-file-if-exists=.env)
fi

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
  # PLURNK_SERVICE_DIR overrides the canonical metaproject checkout.
  SERVICE_BIN=""
  for dir in "${PLURNK_SERVICE_DIR:-}" "$REPO_DIR/../plurnk-service"; do
    [ -z "$dir" ] && continue
    if [ -r "$dir/plurnk-core/src/service.ts" ]; then
      SERVICE_BIN="$dir/plurnk-core/src/service.ts"
      break
    fi
  done
  if [ -z "$SERVICE_BIN" ]; then
    echo "plurnk-service checkout not found; set PLURNK_SERVICE_DIR or PLURNK_PORT" >&2
    exit 1
  fi
  SERVICE_DIR="$(cd "$(dirname "$SERVICE_BIN")/.." && pwd -P)"
  DAEMON_DIR="$(mktemp -d)"
  PLURNK_PORT="$(node -e 'const s=require("net").createServer();s.listen(0,()=>{console.log(s.address().port);s.close()})')"
  export PLURNK_PORT
  (
    cd "$SERVICE_DIR"
    printf 'PLURNK_SERVICE_DB_PATH=%s\nPLURNK_PORT=%s\nPLURNK_WS_PORT=0\nPLURNK_MODEL=%s\nPLURNK_MODEL_nvimtest=lmstudio/nvim-family/selected\nPLURNK_PROVIDERS_CONTEXT_WINDOW_nvimtest=32768\nPLURNK_PROVIDERS_REASONING_nvimtest=off\nPLURNK_MCP_ENABLED=[]\nLMSTUDIO_API_KEY=nvim-test\n' "$DAEMON_DIR/plurnk.db" "$PLURNK_PORT" "${PLURNK_MODEL:-}" > "$DAEMON_DIR/test.env"
    # Control-plane specs stay modelless even when the operator config names a
    # default. Model-driven specs deliberately opt in by exporting PLURNK_MODEL;
    # alias declarations may still come from the operator environment.
    # the service loads env IN-SCRIPT (process.loadEnvFile overrides process env), so
    # exports don't survive — its own --env-file flags, loaded last, are the override.
    # A TS-source entrypoint (the monorepo) runs its WORKSPACE SIBLINGS from source
    # too — plurnk-dev is the monorepo's own convention. Without it, providers load
    # lazily from stale dist/ and the first loop dies on ERR_MODULE_NOT_FOUND while
    # the control plane answers fine.
    NODE_CONDITIONS=""
    case "$SERVICE_BIN" in *.ts) NODE_CONDITIONS="--conditions=plurnk-dev" ;; esac
    HOME="$DAEMON_DIR/home" \
    XDG_CONFIG_HOME="$DAEMON_DIR/config" \
    XDG_DATA_HOME="$DAEMON_DIR/data" \
    node $NODE_CONDITIONS "$SERVICE_BIN" \
      "${DAEMON_ENV_ARGS[@]}" \
      --env-file="$DAEMON_DIR/test.env" > "$DAEMON_DIR/daemon.log" 2>&1 &
    echo $! > "$DAEMON_DIR/pid"
  )
  DAEMON_PID="$(cat "$DAEMON_DIR/pid")"
  # AG-UI+ is the client surface. The banner prints the CONFIGURED port (0 stays 0 —
  # service bug, filed), so allocate a concrete free port up front and pass it in.
  # (Port was exported before boot; just await the module answering.)
  # A --conditions=plurnk-dev daemon compiles the TS graph on boot — well past the
  # old 10s window; specs 01-05 starved on cold boots. 60s, first answer wins.
  DAEMON_READY=0
  for _ in $(seq 1 300); do
    if curl -s -o /dev/null "http://127.0.0.1:$PLURNK_PORT/" -X POST -d '{}'; then DAEMON_READY=1; break; fi
    kill -0 "$DAEMON_PID" 2>/dev/null || break
    sleep 0.2
  done
  if [ "$DAEMON_READY" -ne 1 ]; then
    echo "private daemon failed to start" >&2
    cat "$DAEMON_DIR/daemon.log" >&2
    exit 1
  fi
  echo "── private daemon module on :$PLURNK_PORT ──"
fi

SPECS_DIR="$REPO_DIR/tests/specs"
FILTER="${1:-}"

pass=0
fail=0
failed_names=()

# Real-model specs are excluded from the ordinary deterministic gate. Exporting
# PLURNK_MODEL is both their model selection and their explicit admission.
MODEL_SPECS="10_ai_end_to_end 39_ask_steer"

# Stateful composed specimens get a fresh daemon so earlier client state cannot
# change their meaning. Isolation is the fix, not retries.
ISOLATED_SPECS="10_ai_end_to_end 17_exec_live 39_ask_steer"

reboot_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  kill -9 "$DAEMON_PID" 2>/dev/null || true
  DAEMON_DIR="$(mktemp -d)"
  PLURNK_PORT="$(node -e 'const s=require("net").createServer();s.listen(0,()=>{console.log(s.address().port);s.close()})')"
  export PLURNK_PORT
  (
    cd "$SERVICE_DIR"
    printf 'PLURNK_SERVICE_DB_PATH=%s\nPLURNK_PORT=%s\nPLURNK_WS_PORT=0\nPLURNK_MODEL=%s\nPLURNK_MODEL_nvimtest=lmstudio/nvim-family/selected\nPLURNK_PROVIDERS_CONTEXT_WINDOW_nvimtest=32768\nPLURNK_PROVIDERS_REASONING_nvimtest=off\nPLURNK_MCP_ENABLED=[]\nLMSTUDIO_API_KEY=nvim-test\n' "$DAEMON_DIR/plurnk.db" "$PLURNK_PORT" "${PLURNK_MODEL:-}" > "$DAEMON_DIR/test.env"
    # Control-plane specs stay modelless even when the operator config names a
    # default. Model-driven specs deliberately opt in by exporting PLURNK_MODEL;
    # alias declarations may still come from the operator environment.
    # the service loads env IN-SCRIPT (process.loadEnvFile overrides process env), so
    # exports don't survive — its own --env-file flags, loaded last, are the override.
    # A TS-source entrypoint (the monorepo) runs its WORKSPACE SIBLINGS from source
    # too — plurnk-dev is the monorepo's own convention. Without it, providers load
    # lazily from stale dist/ and the first loop dies on ERR_MODULE_NOT_FOUND while
    # the control plane answers fine.
    NODE_CONDITIONS=""
    case "$SERVICE_BIN" in *.ts) NODE_CONDITIONS="--conditions=plurnk-dev" ;; esac
    HOME="$DAEMON_DIR/home" \
    XDG_CONFIG_HOME="$DAEMON_DIR/config" \
    XDG_DATA_HOME="$DAEMON_DIR/data" \
    node $NODE_CONDITIONS "$SERVICE_BIN" \
      "${DAEMON_ENV_ARGS[@]}" \
      --env-file="$DAEMON_DIR/test.env" > "$DAEMON_DIR/daemon.log" 2>&1 &
    echo $! > "$DAEMON_DIR/pid"
  )
  DAEMON_PID="$(cat "$DAEMON_DIR/pid")"
  # A --conditions=plurnk-dev daemon compiles the TS graph on boot — well past the
  # old 10s window; specs 01-05 starved on cold boots. 60s, first answer wins.
  DAEMON_READY=0
  for _ in $(seq 1 300); do
    if curl -s -o /dev/null "http://127.0.0.1:$PLURNK_PORT/" -X POST -d '{}'; then DAEMON_READY=1; break; fi
    kill -0 "$DAEMON_PID" 2>/dev/null || break
    sleep 0.2
  done
  if [ "$DAEMON_READY" -ne 1 ]; then
    echo "private daemon failed to restart" >&2
    cat "$DAEMON_DIR/daemon.log" >&2
    return 1
  fi
  echo "  (fresh daemon on :$PLURNK_PORT)"
}

for spec in "$SPECS_DIR"/*.lua; do
  name="$(basename "$spec" .lua)"
  if [ -n "$FILTER" ] && [[ "$name" != "$FILTER"* ]]; then continue; fi
  echo "== $name =="
  case " $MODEL_SPECS " in
    *" $name "*)
      if [ -z "${PLURNK_MODEL:-}" ]; then
        if [ -n "$FILTER" ]; then
          echo "  ERROR: $name requires an explicit PLURNK_MODEL selector" >&2
          exit 2
        fi
        echo "  SKIP: real-model spec requires an explicit PLURNK_MODEL selector"
        continue
      fi
      ;;
  esac
  case " $ISOLATED_SPECS " in *" $name "*) reboot_daemon;; esac
  # SIGKILL, not the default SIGTERM: headless nvim survives SIGTERM, so a
  # hung spec under plain `timeout` detaches and spins forever (99% CPU
  # orphans). A timed-out spec is a loud FAIL, never a silent leak.
  if timeout -s KILL "${SPEC_TIMEOUT:-600}" nvim --headless -u NONE -l "$spec" 2>&1; then
    pass=$((pass + 1))
  else
    rc=$?
    fail=$((fail + 1))
    if [ "$rc" -eq 137 ]; then
      echo "  TIMED OUT — SIGKILL after ${SPEC_TIMEOUT:-600}s"
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
  if [ -n "$DAEMON_DIR" ] && [ -s "$DAEMON_DIR/daemon.log" ]; then
    echo "── private daemon log (tail) ──"
    tail -n 80 "$DAEMON_DIR/daemon.log"
  fi
  exit 1
fi
exit 0
