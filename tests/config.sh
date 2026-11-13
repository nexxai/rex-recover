#!/bin/sh
set -eu
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-config-tests.XXXXXX")
reader="$root/bin/rex-recover-config"
trap 'echo "Config test artifacts: $temporary"' EXIT

printf '# Apps\r\n\r\ncustom-worker # capture arguments\r\nview-tool\r\nother_tool\r\n' \
  >"$temporary/app rules.conf"
printf 'custom-worker\nview-tool\nother_tool\n' >"$temporary/expected"
"$reader" "$temporary/app rules.conf" >"$temporary/actual"
cmp "$temporary/expected" "$temporary/actual"
echo "ok - shared config supports arbitrary names, comments, and CRLF"

: >"$temporary/empty.conf"
"$reader" "$temporary/empty.conf" >"$temporary/actual"
[ ! -s "$temporary/actual" ]
echo "ok - an empty config has no implicit monitored apps"

for invalid in 'tool extra' 'tool two extras' '/path/to/tool' 'tool;touch' '$(whoami)'; do
  printf '%s\n' "$invalid" >"$temporary/invalid.conf"
  if "$reader" "$temporary/invalid.conf" >"$temporary/actual" 2>"$temporary/error"; then
    echo "FAIL: invalid config was accepted: $invalid" >&2
    exit 1
  fi
  grep -q "invalid.conf:1:" "$temporary/error"
done
printf 'tool\ntool\n' >"$temporary/invalid.conf"
if "$reader" "$temporary/invalid.conf" >"$temporary/actual" 2>"$temporary/error"; then
  echo "FAIL: duplicate app names were accepted" >&2
  exit 1
fi
grep -q "invalid.conf:2:" "$temporary/error"
echo "ok - invalid and duplicate entries report their file and line"

if "$reader" "$temporary/missing.conf" >"$temporary/actual" 2>"$temporary/error"; then
  echo "FAIL: missing config was accepted" >&2
  exit 1
fi
grep -q "config not readable" "$temporary/error"
echo "ok - missing configs fail with actionable errors"
