#!/bin/sh
# Claude coverage is documentation-backed and mock-only. Never discover an
# installed Claude executable or change the user's configuration.
set -eu
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
unset REX_RECOVER_CONFIG REX_RECOVER_STATE_DIR REX_RECOVER_LAUNCH_DIR REX_RECOVER_SESSIONS CLAUDE_CONFIG_DIR

if [ "${1:-}" = prepare ]; then
  directory=$2
  mkdir -p "$directory/claude-app/logs" "$directory/claude-app/native" "$directory/claude-app/queries" \
    "$directory/claude's home/projects/not-derived-from-cwd" "$directory/claude project"
  cat >"$directory/claude-app/claude" <<'SH'
#!/bin/sh
set -eu
app_dir=${0%/*}
if [ "${1:-}" = agents ]; then
  [ "$#" -eq 2 ] && [ "$2" = --json ] || exit 2
  printf '%s\000' "$PWD" "${CLAUDE_CONFIG_DIR:-}" "$@" >"$app_dir/queries/$$"
  printf '['
  comma=
  for file in "$app_dir"/native/*; do
    [ -f "$file" ] || continue
    pid=${file##*/}
    kill -0 "$pid" 2>/dev/null || continue
    printf '%s' "$comma"
    cat "$file"
    comma=,
  done
  printf ']\n'
  exit 0
fi
printf '%s\000' "$PWD" "${CLAUDE_CONFIG_DIR:-}" "${REX_RECOVER_SESSIONS:-}" "$@" \
  >"$app_dir/logs/$REX_BLOCK.$$"
launch_cwd=$PWD
id=550e8400-e29b-41d4-a716-446655440000
kind=interactive
for argument do
  case "$argument" in
    550e8400-e29b-41d4-a716-446655440000|9d73450d-598c-4d30-b866-824a08df2201)
      id=$argument ;;
  esac
done
publish() {
  {
    printf '{"cwd":"%s","kind":"%s","startedAt":1794830000002,"pid":%s' "$launch_cwd" "$kind" "$$"
    if [ -n "$id" ]; then printf ',"sessionId":"%s"' "$id"; fi
    printf '}'
  } >"$app_dir/native/$$.tmp"
  mv "$app_dir/native/$$.tmp" "$app_dir/native/$$"
}
trap 'rm -f "$app_dir/native/$$" "$app_dir/native/$$.tmp"' EXIT
publish
# Recovery must query and restore the recorded launch cwd, not this live cwd.
cd /
while IFS= read -r input; do
  case "$input" in
    beta) id=9d73450d-598c-4d30-b866-824a08df2201; kind=interactive ;;
    alpha) id=550e8400-e29b-41d4-a716-446655440000; kind=interactive ;;
    new) id=f074f2c9-4cf0-458a-86de-08d167818003; kind=interactive ;;
    noid) id=; kind=interactive ;;
    background) kind=background ;;
    exit) exit 0 ;;
    *) continue ;;
  esac
  publish
done
SH
  chmod +x "$directory/claude-app/claude"
  exit 0
fi

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

temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-claude-shell.XXXXXX")
temporary=$(CDPATH= cd -- "$temporary" && pwd -P)
trap 'echo "Claude recorder test artifacts: $temporary"' EXIT
mkdir -p "$temporary/bin" "$temporary/project" "$temporary/home"
cat >"$temporary/bin/claude" <<'SH'
#!/bin/sh
printf '%s\000' "$PWD" "${CLAUDE_CONFIG_DIR:-}" "${REX_RECOVER_SESSIONS:-}" "$@" >"$CLAUDE_TEST_OUTPUT"
: >"$CLAUDE_TEST_OUTPUT.app-file"
SH
chmod +x "$temporary/bin/claude"
printf 'retain private user configuration\n' >"$temporary/home/settings.json"
cp "$temporary/home/settings.json" "$temporary/expected-config"

(
  cd "$temporary/project"
  umask 022
  HOME="$temporary/home" CLAUDE_CONFIG_DIR="../home" REX_RECOVER_SESSIONS=1 \
    REX_SESSION=session:recorder REX_BLOCK=block:claude \
    REX_RECOVER_LAUNCH_DIR="$temporary/launches" \
    CLAUDE_TEST_OUTPUT="$temporary/received" PATH="$temporary/bin:/usr/bin:/bin" \
    "$root/bin/rex-recover-run" claude --model 'model name' "a'b" '$(touch never)' ''
)
printf '%s\000' "$temporary/project" ../home 1 --model 'model name' "a'b" '$(touch never)' '' \
  >"$temporary/expected-received"
cmp "$temporary/expected-received" "$temporary/received"
tr '\000' '\n' <"$temporary/launches/block:claude" >"$temporary/launch.txt"
marker=$(sed -n '1p' "$temporary/launch.txt")
if [ "$marker" != rex-recover-launch-v2 ]; then
  echo "FAIL: opted-in Claude must record rex-recover-launch-v2; got $marker" >&2
  exit 1
fi
[ "$(sed -n '8p' "$temporary/launch.txt")" = anthropic-claude-code ]
[ "$(sed -n '9p' "$temporary/launch.txt")" = "$temporary/home" ]
printf '%s\000' "$temporary/bin/claude" --model 'model name' "a'b" '$(touch never)' '' \
  >"$temporary/expected-argv"
dd if="$temporary/launches/block:claude" bs=1 \
  skip="$(printf '%s\000' rex-recover-launch-v2 session:recorder block:claude \
    "$(sed -n '4p' "$temporary/launch.txt")" "$(sed -n '5p' "$temporary/launch.txt")" \
    claude "$temporary/project" anthropic-claude-code "$temporary/home" | wc -c | tr -d ' ')" \
  of="$temporary/recorded-argv" 2>/dev/null
cmp "$temporary/expected-argv" "$temporary/recorded-argv"
case "$(ls -ld "$temporary/launches" | cut -c1-10)" in drwx------) ;; *) exit 1 ;; esac
case "$(ls -l "$temporary/launches/block:claude" | cut -c1-10)" in -rw-------) ;; *) exit 1 ;; esac
case "$(ls -l "$temporary/received.app-file" | cut -c1-10)" in -rw-r--r--) ;; *) exit 1 ;; esac
cmp "$temporary/expected-config" "$temporary/home/settings.json"
[ ! -e "$temporary/project/never" ]
echo "ok - Claude v2 recorder preserves original argv, custom home, app umask and private config"

(
  cd "$temporary/project"
  HOME="$temporary/home" REX_RECOVER_SESSIONS=1 \
    REX_SESSION=session:recorder REX_BLOCK=block:default \
    REX_RECOVER_LAUNCH_DIR="$temporary/launches" \
    CLAUDE_TEST_OUTPUT="$temporary/default" PATH="$temporary/bin:/usr/bin:/bin" \
    "$root/bin/rex-recover-run" claude
)
tr '\000' '\n' <"$temporary/launches/block:default" >"$temporary/default-launch.txt"
[ "$(sed -n '8p' "$temporary/default-launch.txt")" = anthropic-claude-code ]
[ "$(sed -n '9p' "$temporary/default-launch.txt")" = "$temporary/home/.claude" ]
printf '%s\000' "$temporary/project" '' 1 >"$temporary/expected-default"
cmp "$temporary/expected-default" "$temporary/default"
echo "ok - default Claude home is captured without changing the original application environment"

(
  cd "$temporary/project"
  HOME="$temporary/home" CLAUDE_CONFIG_DIR="../home" \
    REX_SESSION=session:recorder REX_BLOCK=block:generic \
    REX_RECOVER_LAUNCH_DIR="$temporary/launches" \
    CLAUDE_TEST_OUTPUT="$temporary/generic" PATH="$temporary/bin:/usr/bin:/bin" \
    "$root/bin/rex-recover-run" claude --continue 'original prompt'
)
tr '\000' '\n' <"$temporary/launches/block:generic" >"$temporary/generic-launch.txt"
[ "$(sed -n '1p' "$temporary/generic-launch.txt")" = rex-recover-launch-v1 ]
printf '%s\000' "$temporary/project" ../home '' --continue 'original prompt' >"$temporary/expected-generic"
cmp "$temporary/expected-generic" "$temporary/generic"
echo "ok - no Claude opt-in retains generic launch recording"

mkdir "$temporary/store-a" "$temporary/store-b"
ln -s "$temporary/store-a" "$temporary/store-alias"
HOME="$temporary/home" CLAUDE_CONFIG_DIR="$temporary/store-alias" REX_RECOVER_SESSIONS=1 \
  REX_SESSION=session:recorder REX_BLOCK=block:symlink \
  REX_RECOVER_LAUNCH_DIR="$temporary/launches" \
  CLAUDE_TEST_OUTPUT="$temporary/symlink" PATH="$temporary/bin:/usr/bin:/bin" \
  "$root/bin/rex-recover-run" claude
rm "$temporary/store-alias"
ln -s "$temporary/store-b" "$temporary/store-alias"
tr '\000' '\n' <"$temporary/launches/block:symlink" >"$temporary/symlink-launch.txt"
[ "$(sed -n '9p' "$temporary/symlink-launch.txt")" = "$temporary/store-a" ]
echo "ok - a retargeted config-home symlink cannot move Claude recovery to another store"
