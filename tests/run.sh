#!/bin/sh
# Fast shell-level checks run before the private-server scenarios so basic
# config or installation failures do not require a Rex restart cycle to diagnose.
# Artifacts can include invocation data, so they must not be world-readable.
set -eu
umask 077
# Never inherit a user's opt-in mode or recording path into generic fixtures.
unset REX_RECOVER_CONFIG REX_RECOVER_STATE_DIR REX_RECOVER_LAUNCH_DIR REX_RECOVER_SESSIONS
unset CODEX_HOME ENV BASH_ENV

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rex_bin=${REX_BIN:-rex}
sh "$root/tests/config.sh"
sh "$root/tests/management.sh"
sh "$root/tests/launcher.sh"
sh "$root/tests/commands.sh"
sh "$root/tests/bash.sh"
sh "$root/tests/setup.sh"
sh "$root/tests/codex-setup.sh"
sh "$root/tests/codex-real-contract.sh"
node --test "$root/tests/codex-hook.mjs"
node --experimental-vm-modules --test "$root"/tests/opencode-*.mjs
env REX_BIN="$(command -v "$rex_bin")" sh "$root/tests/watch-scheduling.sh" watch
# A distinct state tree and socket are essential: these tests deliberately
# stop and kill their server and must never control the user's working server.
# Resolve the physical path so macOS's /var symlink cannot confuse identity checks.
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-recovery-tests.XXXXXX")
temporary=$(CDPATH= cd -- "$temporary" && pwd -P)
endpoint="unix://$temporary/rex.sock"
watcher_pid=
test_shell=$(command -v zsh)
mkdir "$temporary/zsh"
printf '%s\n' sample-viewer sample-worker sample-editor custom-worker >"$temporary/apps.conf"

# Stop/kill permission must come from the responding server's identity, not
# merely from assuming the endpoint option selected the intended server.
status_pid() {
  sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p'
}

# Autostart would mask failures to wait for Rex and could create a server during
# a status check. Every private-server operation must keep it disabled.
rex_test() {
  "$rex_bin" --autostart=false --server "$endpoint" "$@"
}

# Wrong endpoints or matching live-server PIDs are hard safety failures. Normal
# server lookup is read-only and cannot autostart it; uncertainty never grants
# permission to stop a process whose private endpoint was not verified.
private_server_pid() {
  status=$(rex_test api call server.status) || return 1
  if ! printf '%s' "$status" | grep -Fq "\"endpoint\":\"$endpoint\""; then
    echo "REFUSING server control: response does not identify the private test socket." >&2
    return 1
  fi
  private_pid=$(printf '%s' "$status" | status_pid)
  normal_status=$("$rex_bin" --autostart=false api call server.status 2>/dev/null || :)
  normal_pid=$(printf '%s' "$normal_status" | status_pid)
  case "$private_pid" in ""|*[!0-9]*|0|1) return 1 ;; esac
  if [ "$private_pid" = "$normal_pid" ]; then
    echo "REFUSING server control: the test PID matches the normal server." >&2
    return 1
  fi
  printf '%s\n' "$private_pid"
}

# Centralizing this guard prevents a new graceful-shutdown scenario from
# accidentally adding an unverified server-stop call.
stop_server() {
  private_server_pid >/dev/null || exit 1
  rex_test server stop
}

# Failed tests must not leave their own watcher or server running. Cleanup gets
# no broader stop permission than the test itself; artifacts stay for diagnosis.
cleanup() {
  test_status=$?
  if [ "$test_status" -ne 0 ]; then
    # Hosted runners disappear after failure. Retain the private fixture's
    # watcher decisions and checkpoint in the log before that evidence is lost.
    echo "Failure diagnostics: private watcher"
    if [ -f "$temporary/watcher.log" ]; then cat "$temporary/watcher.log"; fi
    if [ -f "$temporary/watcher/checkpoint.json" ]; then cat "$temporary/watcher/checkpoint.json"; fi
  fi
  if [ -n "$watcher_pid" ]; then
    kill "$watcher_pid" 2>/dev/null || :
    wait "$watcher_pid" 2>/dev/null || :
  fi
  if private_server_pid >/dev/null 2>&1; then rex_test server stop >/dev/null 2>&1 || :; fi
  echo "Test artifacts: $temporary"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A separate state directory prevents restoring or modifying the user's saved
# sessions. A blank config prevents their normal automation from running here.
# Restored panes start login shells, not the fixture's original command.
start_server() {
  rex_test server start --state-dir "$temporary/server" \
    --env "ZDOTDIR=$temporary/zsh" --env "SHELL=$test_shell" \
    --config "$temporary/no-config.lua" >/dev/null
  private_server_pid >/dev/null || exit 1
}

# Lua assertions exercise real terminal state, not just successful CLI exits.
integration() {
  rex_test do "$root/tests/integration.lua" --all \
    root="$root" test_dir="$temporary" phase="$1"
}

# The supervisor must outlive its server, so it is launched by this outer test
# shell rather than from one of the private Rex terminals it is watching.
start_watcher() {
  sh "$root/bin/rex-recover" --rex "$rex_bin" --server "$endpoint" \
    --state-dir "$temporary/watcher" --config "$temporary/apps.conf" \
    --interval 0.2 >>"$temporary/watcher.log" 2>&1 &
  watcher_pid=$!
}

start_server
env REX_BIN="$(command -v "$rex_bin")" REX_SERVER="$endpoint" sh "$root/tests/sessions.sh"
env REX_BIN="$(command -v "$rex_bin")" REX_SERVER="$endpoint" sh "$root/tests/claude-sessions.sh"
env REX_BIN="$(command -v "$rex_bin")" REX_SERVER="$endpoint" sh "$root/tests/session-opt-in.sh"
env REX_BIN="$(command -v "$rex_bin")" sh "$root/tests/driver-loading.sh"
rex_test do "$root/tests/test.lua" --all root="$root" test_dir="$temporary"
rex_test do "$root/tests/sessions.lua" --all root="$root" test_dir="$temporary" phase=unit
rex_test do "$root/tests/claude-sessions.lua" --all root="$root" test_dir="$temporary" phase=unit
rex_test do "$root/tests/opencode-sessions.lua" --all root="$root" test_dir="$temporary" phase=unit
env REX_BIN="$(command -v "$rex_bin")" REX_SERVER="$endpoint" sh "$root/tests/selection-adversarial.sh"

# Looking at a live app's cwd would restore it in the wrong place after it has
# changed directory. This fixture makes that shortcut observably incorrect,
# while also proving a no-argument command needs no special recovery path.
cat >"$temporary/sample-viewer" <<'SH'
#!/bin/sh
printf '%s\000' "$PWD" "$#" "$@" >"${0%/*}/viewer-launch.$$"
cd /
exec /bin/cat
SH
chmod +x "$temporary/sample-viewer"
mkdir "$temporary/project one" "$temporary/project'two"
integration setup
start_watcher
integration checkpoint

# Concurrent watchers could replay twice and corrupt shared state; a second
# supervisor must fail before it can compete for the same checkpoint.
if sh "$root/bin/rex-recover" --rex "$rex_bin" --server "$endpoint" \
  --state-dir "$temporary/watcher" --config "$temporary/apps.conf" \
  >"$temporary/second-watcher.log" 2>&1; then
  echo "FAIL: a second watcher acquired the same checkpoint" >&2
  exit 1
fi

# A successful reconnect alone would not reveal an unwanted automatic restart.
# Assert that Rex stays down until this test explicitly brings it back.
stop_server
sleep 1
if rex_test server status >/dev/null 2>&1; then
  echo "FAIL: watcher restarted the server" >&2
  exit 1
fi
start_server
integration restored
integration checkpoint

# A dropped watcher connection is not evidence that apps died. Replaying here
# would duplicate commands that never stopped.
kill "$watcher_pid"
wait "$watcher_pid" 2>/dev/null || :
watcher_pid=
start_watcher
integration restored
integration checkpoint

# Graceful shutdown hooks can hide incomplete ongoing checkpointing. SIGKILL
# proves recovery can rely on the last durable observation without a final save.
server_pid=$(private_server_pid)
kill -KILL "$server_pid"
sleep 1
if rex_test server status >/dev/null 2>&1; then
  echo "FAIL: watcher restarted the killed server" >&2
  exit 1
fi
start_server
integration restored
integration checkpoint

# PID-file locking can strand recovery after a crash. Killing the supervisor
# forces its surviving worker to release the kernel lock when Rex goes away,
# so a replacement watcher can resume without manual lock-file deletion.
kill -KILL "$watcher_pid"
wait "$watcher_pid" 2>/dev/null || :
watcher_pid=
stop_server
sleep 1
start_watcher
start_server
integration restored
integration checkpoint

# Completion is intentional, unlike a server failure. Terminal history or a
# lingering launch record must not bring an exited app back on the next restart.
integration exit-apps
stop_server
start_server
integration not-restored

# Each app writes independently observable launch evidence before changing cwd.
# That catches recovery into the wrong folder or pane without trusting the
# checkpoint's own description of what it intended to run.
mkdir -p "$temporary/apps/logs"
for app in sample-worker sample-editor custom-worker; do
  cat >"$temporary/apps/$app" <<'SH'
#!/bin/sh
printf '%s\000' "$PWD" "$@" >"${0%/*}/logs/${0##*/}.$$"
cd /
exec /bin/cat
SH
  chmod +x "$temporary/apps/$app"
done

# Repeated restarts prove restored commands re-enter capture; otherwise only
# the first recovery would retain trustworthy process identity and arguments.
arguments() {
  rex_test do "$root/tests/arguments.lua" --all \
    root="$root" test_dir="$temporary" phase="$1"
}

arguments setup
arguments checkpoint
stop_server
start_server
arguments restored
arguments checkpoint
server_pid=$(private_server_pid)
kill -KILL "$server_pid"
sleep 1
start_server
arguments restored
arguments checkpoint
stop_server
start_server
arguments restored
arguments checkpoint
arguments exit
stop_server
start_server
arguments not-restored

# Without a qualifying hook, opt-in Codex must fail closed while a separate
# generic invocation still recovers exactly. Both use stand-ins.
sh "$root/tests/sessions.sh" prepare "$temporary"
printf 'codex\n' >>"$temporary/apps.conf"
# Configuration is read once per worker. Reconnect it before adding the panes.
kill "$watcher_pid"
wait "$watcher_pid" 2>/dev/null || :
watcher_pid=
start_watcher
sessions() {
  rex_test do "$root/tests/sessions.lua" --all \
    root="$root" test_dir="$temporary" phase="$1"
}
sessions setup
sessions checkpoint
sessions new
sessions checkpoint
server_pid=$(private_server_pid)
kill -KILL "$server_pid"
sleep 1
start_server
sessions restored
sessions checkpoint
server_pid=$(private_server_pid)
kill -KILL "$server_pid"
sleep 1
start_server
sessions restored
sessions checkpoint
sessions exit
stop_server
start_server
sessions not-restored

# This stand-in implements only documented `agents --json` and CLI boundaries.
# The absolute recorded executable is intentionally absent from the watcher PATH.
sh "$root/tests/claude-sessions.sh" prepare "$temporary"
printf 'claude\n' >>"$temporary/apps.conf"
kill "$watcher_pid"
wait "$watcher_pid" 2>/dev/null || :
watcher_pid=
start_watcher
claude_sessions() {
  rex_test do "$root/tests/claude-sessions.lua" --all \
    root="$root" test_dir="$temporary" rex_bin="$(command -v "$rex_bin")" endpoint="$endpoint" phase="$1"
}
claude_sessions setup
claude_sessions checkpoint
claude_sessions invalidate
claude_sessions checkpoint
server_pid=$(private_server_pid)
kill -KILL "$server_pid"
sleep 1
start_server
claude_sessions restored
claude_sessions checkpoint
server_pid=$(private_server_pid)
kill -KILL "$server_pid"
sleep 1
start_server
claude_sessions restored
claude_sessions checkpoint
claude_sessions exit
stop_server
start_server
claude_sessions not-restored

# OpenCode is a shell stand-in for the documented CLI and companion sidecar
# protocol. Neither the real application nor its plugin SDK is a prerequisite.
sh "$root/tests/opencode-sessions.sh" prepare "$temporary"
printf 'opencode\n' >>"$temporary/apps.conf"
kill "$watcher_pid"
wait "$watcher_pid" 2>/dev/null || :
watcher_pid=
start_watcher
opencode_sessions() {
  rex_test do "$root/tests/opencode-sessions.lua" --all \
    root="$root" test_dir="$temporary" phase="$1"
}
opencode_sessions setup
opencode_sessions checkpoint
opencode_sessions invalidate
opencode_sessions checkpoint
server_pid=$(private_server_pid)
kill -KILL "$server_pid"
sleep 1
start_server
opencode_sessions restored
opencode_sessions checkpoint
server_pid=$(private_server_pid)
kill -KILL "$server_pid"
sleep 1
start_server
opencode_sessions restored
opencode_sessions checkpoint
opencode_sessions exit
stop_server
start_server
opencode_sessions not-restored
echo "All tests passed (generic recovery and mock Codex, Claude, and OpenCode sessions)."
