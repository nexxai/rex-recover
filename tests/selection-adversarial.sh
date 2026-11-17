#!/bin/sh
# Run assertions only in an explicitly supplied private Rex runtime. This test
# neither starts/stops servers nor opens terminals or invokes AI applications.
set -eu
umask 077
unset REX_SESSION REX_BLOCK REX_CLIENT

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${REX_BIN:?Pass REX_BIN for the private test server}"
: "${REX_SERVER:?Pass REX_SERVER for the private test server}"
rex_bin=$(command -v "$REX_BIN")
status=$("$rex_bin" --autostart=false --timeout 3s --server "$REX_SERVER" api call server.status)
printf '%s' "$status" | grep -Fq "\"endpoint\":\"$REX_SERVER\""
private_pid=$(printf '%s' "$status" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')
normal_status=$(env -u REX_SERVER "$rex_bin" --autostart=false --timeout 3s api call server.status 2>/dev/null || :)
normal_pid=$(printf '%s' "$normal_status" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')
case "$private_pid" in ''|*[!0-9]*|0|1) exit 1 ;; esac
if [ "$private_pid" = "$normal_pid" ]; then
  echo "REFUSING selection test: supplied server is the normal server." >&2
  exit 1
fi

temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-selection-adversarial.XXXXXX")
temporary=$(CDPATH= cd -- "$temporary" && pwd -P)
trap 'echo "Selection adversary artifacts: $temporary"' EXIT
PATH=/usr/bin:/bin "$rex_bin" --autostart=false --server "$REX_SERVER" \
  do "$root/tests/selection-adversarial.lua" --all root="$root" test_dir="$temporary"
