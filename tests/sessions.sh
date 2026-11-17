#!/bin/sh
# These stand-ins never discover/run installed Codex or emit terminal titles.
set -eu
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
unset REX_RECOVER_CONFIG REX_RECOVER_STATE_DIR REX_RECOVER_LAUNCH_DIR REX_RECOVER_SESSIONS CODEX_HOME

if [ "${1:-}" = prepare ]; then
  directory=$2
  mkdir -p "$directory/sessions-app/logs" "$directory/sessions-app/inputs" "$directory/session's home/sessions" \
    "$directory/session project"
  node=$(command -v node)
  # A script named codex still appears as `bash`/`dash` to Rex. Use a
  # tiny native stand-in so the real foreground ownership guard runs unchanged.
  cc "$root/tests/codex-tui.c" -o "$directory/sessions-app/codex"
  printf '%s\n' "$node" "$root/scripts/codex-session-start.mjs" >"$directory/sessions-app/hook"
  exit 0
fi

# Driver metadata now runs in Rex's Lua runtime. Standalone recorder checks
# require an explicitly supplied private server rather than selecting a default.
: "${REX_BIN:?Pass REX_BIN for the private test server}"
: "${REX_SERVER:?Pass REX_SERVER for the private test server}"
status=$("$REX_BIN" --autostart=false --server "$REX_SERVER" api call server.status)
printf '%s' "$status" | grep -Fq "\"endpoint\":\"$REX_SERVER\""
private_pid=$(printf '%s' "$status" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')
normal_status=$(env -u REX_SERVER "$REX_BIN" --autostart=false api call server.status 2>/dev/null || :)
normal_pid=$(printf '%s' "$normal_status" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')
case "$private_pid" in ''|*[!0-9]*|0|1) exit 1 ;; esac
[ "$private_pid" != "$normal_pid" ] || {
  echo "REFUSING recorder test: supplied server is the normal server." >&2
  exit 1
}

temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-sessions-shell.XXXXXX")
temporary=$(CDPATH= cd -- "$temporary" && pwd -P)
trap 'echo "Session recorder test artifacts: $temporary"' EXIT
mkdir -p "$temporary/bin" "$temporary/project" "$temporary/home"
cat >"$temporary/bin/codex" <<'SH'
#!/bin/sh
printf '%s\000' "$PWD" "${CODEX_HOME:-}" "${REX_RECOVER_SESSIONS:-}" "$@" >"$SESSION_TEST_OUTPUT"
if [ -n "${CODEX_HOME:-}" ]; then
  (CDPATH= cd -- "$CODEX_HOME" && pwd -P) >"$SESSION_TEST_OUTPUT.actual-store"
fi
: >"$SESSION_TEST_OUTPUT.app-file"
SH
chmod +x "$temporary/bin/codex"
printf 'retain private user configuration\n' >"$temporary/home/config.toml"
cp "$temporary/home/config.toml" "$temporary/expected-config"
sh "$0" prepare "$temporary/stand-in"
(
  cd "$temporary/project"
  printf 'new\nexit\n' | REX_BLOCK=block:silent CODEX_HOME="$temporary/home" \
    "$temporary/stand-in/sessions-app/codex"
) >"$temporary/stand-in.output"
test ! -s "$temporary/stand-in.output"
printf 'new\n' >"$temporary/expected-input"
cmp "$temporary/expected-input" "$temporary/stand-in/sessions-app/inputs/block:silent"
echo "ok - fake Codex records activity without title OSC or other stdout"

(
  cd "$temporary/project"
  umask 022
  HOME="$temporary/home" CODEX_HOME="../home" REX_RECOVER_SESSIONS=opencode,codex \
    REX_SESSION=session:recorder REX_BLOCK=block:codex \
    REX_RECOVER_LAUNCH_DIR="$temporary/launches" \
    SESSION_TEST_OUTPUT="$temporary/received" PATH="$temporary/bin:/usr/bin:/bin" \
    "$root/bin/rex-recover-run" codex --model 'model name' --config \
    'model_reasoning_effort="low"' "a'b" '$(touch never)' ''
)
# Exact original arguments arrive unchanged, including empty strings. The
# recorder resolves relative storage for recovery without mutating app env.
printf '%s\000' "$temporary/project" ../home opencode,codex --model 'model name' --config \
  'model_reasoning_effort="low"' "a'b" '$(touch never)' '' >"$temporary/expected-received"
cmp "$temporary/expected-received" "$temporary/received"
tr '\000' '\n' <"$temporary/launches/block:codex" >"$temporary/launch.txt"
[ "$(sed -n '1p' "$temporary/launch.txt")" = rex-recover-launch-v2 ]
[ "$(sed -n '8p' "$temporary/launch.txt")" = openai-codex ]
[ "$(sed -n '9p' "$temporary/launch.txt")" = "$temporary/home" ]
# Compare the NUL-framed argv, not shell-rendered or newline-flattened text.
printf '%s\000' "$temporary/bin/codex" --model 'model name' --config \
  'model_reasoning_effort="low"' "a'b" '$(touch never)' '' >"$temporary/expected-argv"
dd if="$temporary/launches/block:codex" bs=1 \
  skip="$(printf '%s\000' "$(sed -n '1p' "$temporary/launch.txt")" \
    session:recorder block:codex "$(sed -n '4p' "$temporary/launch.txt")" \
    "$(sed -n '5p' "$temporary/launch.txt")" codex "$temporary/project" openai-codex \
    "$temporary/home" | wc -c | tr -d ' ')" \
  of="$temporary/recorded-argv" 2>/dev/null
cmp "$temporary/expected-argv" "$temporary/recorded-argv"
case "$(ls -ld "$temporary/launches" | cut -c1-10)" in drwx------) ;; *) exit 1 ;; esac
case "$(ls -l "$temporary/launches/block:codex" | cut -c1-10)" in -rw-------) ;; *) exit 1 ;; esac
case "$(ls -l "$temporary/received.app-file" | cut -c1-10)" in -rw-r--r--) ;; *) exit 1 ;; esac
cmp "$temporary/expected-config" "$temporary/home/config.toml"
[ ! -e "$temporary/project/never" ]
echo "ok - Codex v2 recorder preserves argv, relative home, app umask and private user config"

(
  cd "$temporary/project"
  HOME="$temporary/home" REX_SESSION=session:recorder REX_BLOCK=block:generic \
    REX_RECOVER_LAUNCH_DIR="$temporary/launches" \
    SESSION_TEST_OUTPUT="$temporary/generic" PATH="$temporary/bin:/usr/bin:/bin" \
    "$root/bin/rex-recover-run" codex resume original-selector 'initial prompt'
)
tr '\000' '\n' <"$temporary/launches/block:generic" >"$temporary/generic-launch.txt"
[ "$(sed -n '1p' "$temporary/generic-launch.txt")" = rex-recover-launch-v1 ]
printf '%s\000' "$temporary/project" '' '' resume original-selector 'initial prompt' \
  >"$temporary/expected-generic"
cmp "$temporary/expected-generic" "$temporary/generic"
echo "ok - no opt-in keeps generic v1 launch recording unchanged"

# Codex canonicalizes its store at startup. A later symlink retarget must not
# make recovery silently select an entirely different store.
mkdir "$temporary/store-a" "$temporary/store-b"
ln -s "$temporary/store-a" "$temporary/store-alias"
HOME="$temporary/home" CODEX_HOME="$temporary/store-alias" REX_RECOVER_SESSIONS=1 \
  REX_SESSION=session:recorder REX_BLOCK=block:symlink \
  REX_RECOVER_LAUNCH_DIR="$temporary/launches" \
  SESSION_TEST_OUTPUT="$temporary/symlink" PATH="$temporary/bin:/usr/bin:/bin" \
  "$root/bin/rex-recover-run" codex resume saved-session
rm "$temporary/store-alias"
ln -s "$temporary/store-b" "$temporary/store-alias"
tr '\000' '\n' <"$temporary/launches/block:symlink" >"$temporary/symlink-launch.txt"
captured_home=$(sed -n '9p' "$temporary/symlink-launch.txt")
[ "$(cat "$temporary/symlink.actual-store")" = "$temporary/store-a" ]
if [ "$captured_home" != "$temporary/store-a" ]; then
  echo "FAIL: symlink home must capture startup store $temporary/store-a, got $captured_home" >&2
  exit 1
fi
echo "ok - symlink retarget cannot change the launch-time canonical Codex store"
