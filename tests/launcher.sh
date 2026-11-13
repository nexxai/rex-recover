#!/bin/sh
set -eu
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-launcher-tests.XXXXXX")
child=
cleanup() {
  if [ -n "$child" ]; then
    kill "$child" 2>/dev/null || :
    wait "$child" 2>/dev/null || :
  fi
  echo "Launcher test artifacts: $temporary"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$temporary/home/.config/rex-recover"
printf 'custom-worker\n' >"$temporary/home/.config/rex-recover/apps.conf"

make_rex() {
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<'SH'
#!/bin/sh
printf '%s\n' "$0" "$@" >"$REX_TEST_CALL_LOG"
SH
  chmod +x "$1"
}

expect_launch() {
  expected=$1
  shift
  rm -f "$temporary/call.log"
  env -u REX_BIN -u REX_RECOVER_CONFIG -u XDG_CONFIG_HOME HOME="$temporary/home" PATH="/usr/bin:/bin" \
    REX_TEST_CALL_LOG="$temporary/call.log" "$@" \
    /bin/sh "$root/bin/rex-recover" --state-dir "$temporary/state" \
    >"$temporary/output.log" 2>&1 &
  child=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ ! -f "$temporary/call.log" ] || break
    sleep 0.1
  done
  kill "$child" 2>/dev/null || :
  wait "$child" 2>/dev/null || :
  child=
  if [ ! -f "$temporary/call.log" ]; then
    echo "FAIL: launcher did not find $expected" >&2
    cat "$temporary/output.log" >&2
    exit 1
  fi
  [ "$(sed -n '1p' "$temporary/call.log")" = "$expected" ]
  [ "$(sed -n '2p' "$temporary/call.log")" = "--autostart=false" ]
  if ! grep -Fxq "config=$temporary/home/.config/rex-recover/apps.conf" "$temporary/call.log"; then
    echo "FAIL: launcher did not pass the default external config to the watcher" >&2
    exit 1
  fi
}

bundled="$temporary/home/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
if [ "$(uname -s)" = Darwin ]; then
  make_rex "$bundled"
  expect_launch "$bundled" /usr/bin/env
  echo "ok - bundled macOS CLI is discovered without rex on PATH"
fi

make_rex "$temporary/explicit rex"
expect_launch "$temporary/explicit rex" /usr/bin/env "REX_BIN=$temporary/explicit rex"
echo "ok - REX_BIN overrides automatic discovery"

# A bad explicit executable must fail once, not enter the reconnect loop.
env -u REX_BIN -u REX_RECOVER_CONFIG -u XDG_CONFIG_HOME HOME="$temporary/home" PATH="/usr/bin:/bin" \
  /bin/sh "$root/bin/rex-recover" --rex "$temporary/missing" \
  --state-dir "$temporary/state" >"$temporary/missing.log" 2>&1 &
child=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$child" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$child" 2>/dev/null; then
  echo "FAIL: missing Rex executable entered the retry loop" >&2
  exit 1
fi
status=0
wait "$child" || status=$?
child=
[ "$status" = 127 ]
grep -q "Rex CLI not found" "$temporary/missing.log"
[ "$(wc -l <"$temporary/missing.log" | tr -d ' ')" = 1 ]
echo "ok - invalid explicit CLI fails once with actionable guidance"
