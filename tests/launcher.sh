#!/bin/sh
# CLI discovery should be testable without opening a real Rex connection.
# Everything writable lives under a private fixture home, not the user's home.
set -eu
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-launcher-tests.XXXXXX")
child=
# A supervisor intentionally runs forever; a failed assertion must not leave
# its retry loop alive after the test process exits. Keep logs for diagnosis.
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

# A fake CLI reports the actual executable and argv selected by the supervisor.
# This lets the test inspect discovery and autostart policy without launching Rex.
make_rex() {
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<'SH'
#!/bin/sh
printf '%s\n' "$0" "$@" >"$REX_TEST_CALL_LOG"
SH
  chmod +x "$1"
}

# A restricted PATH proves discovery does not accidentally pass because the
# developer already installed rex. Bounded waiting tolerates process startup
# without allowing a broken supervisor to hang the suite indefinitely.
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
  # Finding a binary is insufficient: retrying it must not start Rex, and its
  # worker must receive the same external app list as the shell integration.
  [ "$(sed -n '1p' "$temporary/call.log")" = "$expected" ]
  [ "$(sed -n '2p' "$temporary/call.log")" = "--autostart=false" ]
  if ! grep -Fxq "config=$temporary/home/.config/rex-recover/apps.conf" "$temporary/call.log"; then
    echo "FAIL: launcher did not pass the default external config to the watcher" >&2
    exit 1
  fi
}

# A bundled path deliberately contains spaces, as real macOS app bundles do.
# Linux should not acquire a dependency on this macOS-specific discovery path.
bundled="$temporary/home/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
if [ "$(uname -s)" = Darwin ]; then
  make_rex "$bundled"
  expect_launch "$bundled" /usr/bin/env
  echo "ok - bundled macOS CLI is discovered without rex on PATH"
fi

# An explicit choice must win even when automatic discovery could find a CLI.
make_rex "$temporary/explicit rex"
expect_launch "$temporary/explicit rex" /usr/bin/env "REX_BIN=$temporary/explicit rex"
echo "ok - REX_BIN overrides automatic discovery"

# A typo is not a temporary connection failure. Repeated retries would bury
# the actionable error and leave a useless background process running.
env -u REX_BIN -u REX_RECOVER_CONFIG -u XDG_CONFIG_HOME HOME="$temporary/home" PATH="/usr/bin:/bin" \
  /bin/sh "$root/bin/rex-recover" --rex "$temporary/missing" \
  --state-dir "$temporary/state" >"$temporary/missing.log" 2>&1 &
child=$!
# Bound the negative case too: a mistaken retry loop must fail the test, not
# make the test wait for that loop to finish.
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
