#!/bin/sh
# A private Rex runtime supplies Lua/JSON only; the Lua fixtures fake API calls.
set -eu
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rex_bin=${REX_BIN:-rex}
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/w.XXXXXX")
temporary=$(CDPATH= cd -- "$temporary" && pwd -P)
endpoint="unix://$temporary/s"
unset REX_RECOVER_CONFIG REX_RECOVER_STATE_DIR REX_RECOVER_LAUNCH_DIR REX_RECOVER_SESSIONS

rex_test() {
  "$rex_bin" --autostart=false --server "$endpoint" "$@"
}

private_server_pid() {
  status=$(rex_test api call server.status) || return 1
  printf '%s' "$status" | grep -Fq "\"endpoint\":\"$endpoint\"" || return 1
  private_pid=$(printf '%s' "$status" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')
  normal_status=$("$rex_bin" --autostart=false api call server.status 2>/dev/null || :)
  normal_pid=$(printf '%s' "$normal_status" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')
  case "$private_pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
  [ "$private_pid" != "$normal_pid" ] || return 1
}

cleanup() {
  if private_server_pid >/dev/null 2>&1; then rex_test server stop >/dev/null 2>&1 || :; fi
  echo "Scheduling test artifacts: $temporary"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

rex_test server start --state-dir "$temporary/server" --config "$temporary/no-config.lua" >/dev/null
private_server_pid
case "${1:-all}" in
  all|unit) rex_test do "$root/tests/test.lua" --all root="$root" test_dir="$temporary" ;;
  watch) ;;
  *) echo "Usage: sh tests/watch-scheduling.sh [all|unit|watch]" >&2; exit 2 ;;
esac
case "${1:-all}" in
  all|watch)
    rex_test do "$root/tests/watch-scheduling.lua" --all root="$root" test_dir="$temporary"
    ticks=$(rex_test do -e 'local n = 0; rex.every(0.02, function()
      n = n + 1; if n == 2 then print("two timer ticks"); rex.stop() end
    end)' --all --for 2s --fail-fast)
    [ "$ticks" = "two timer ticks" ]
    echo "ok - Rex timers keep the watcher alive without event handlers"
    ;;
esac
