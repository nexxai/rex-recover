#!/bin/sh
set -eu
umask 077
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${REX_BIN:?Pass the private Rex executable}"
: "${REX_SERVER:?Pass the private Rex endpoint}"
status=$("$REX_BIN" --autostart=false --server "$REX_SERVER" api call server.status)
printf '%s' "$status" | grep -Fq "\"endpoint\":\"$REX_SERVER\""
private_pid=$(printf '%s' "$status" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')
normal_status=$(env -u REX_SERVER "$REX_BIN" --autostart=false api call server.status 2>/dev/null || :)
normal_pid=$(printf '%s' "$normal_status" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')
case "$private_pid" in ''|*[!0-9]*|0|1) exit 1 ;; esac
[ "$private_pid" != "$normal_pid" ]
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-opt-in.XXXXXX")
temporary=$(CDPATH= cd -- "$temporary" && pwd -P)
trap 'echo "Selective session opt-in artifacts: $temporary"' EXIT
mkdir "$temporary/bin" "$temporary/home" "$temporary/launches"
cat >"$temporary/bin/opencode" <<'SH'
#!/bin/sh
printf '%s\000' "${REX_RECOVER_SESSIONS:-}" "$@" >"$OPT_IN_OUTPUT"
SH
chmod +x "$temporary/bin/opencode"
cp "$temporary/bin/opencode" "$temporary/bin/fixture-server"

record() {
  label=$1 mode=$2 app=$3
  HOME="$temporary/home" PATH="$temporary/bin:/usr/bin:/bin" \
    REX_RECOVER_SESSIONS="$mode" REX_RECOVER_LAUNCH_DIR="$temporary/launches" \
    REX_SESSION=session:selective REX_BLOCK="block:$label" OPT_IN_OUTPUT="$temporary/$label.argv" \
    "$root/bin/rex-recover-run" "$app" --literal "old prompt"
  tr '\000' '\n' <"$temporary/launches/block:$label" >"$temporary/$label.launch"
  printf '%s\000' "$mode" --literal "old prompt" >"$temporary/$label.expected-argv"
  cmp "$temporary/$label.expected-argv" "$temporary/$label.argv"
}

record matching opencode opencode
[ "$(sed -n '1p' "$temporary/matching.launch")" = rex-recover-launch-v2 ] || {
  echo "FAIL: the matching app was not opted into its session driver" >&2
  exit 1
}
[ "$(sed -n '8p' "$temporary/matching.launch")" = anomalyco-opencode ]
[ "$(sed -n '9p' "$temporary/matching.launch")" = "$temporary/home" ]
record unrelated opencode fixture-server
[ "$(sed -n '1p' "$temporary/unrelated.launch")" = rex-recover-launch-v1 ]
record disabled 0 opencode
[ "$(sed -n '1p' "$temporary/disabled.launch")" = rex-recover-launch-v1 ]
record all 1 opencode
[ "$(sed -n '1p' "$temporary/all.launch")" = rex-recover-launch-v2 ]
cp "$temporary/bin/opencode" "$temporary/bin/codex"
record both-opencode opencode,codex opencode
record both-codex opencode,codex codex
record near-match my-opencode,codex opencode
[ "$(sed -n '8p' "$temporary/both-opencode.launch")" = anomalyco-opencode ]
[ "$(sed -n '8p' "$temporary/both-codex.launch")" = openai-codex ]
[ "$(sed -n '1p' "$temporary/near-match.launch")" = rex-recover-launch-v1 ]
echo "ok - per-app session opt-in leaves unrelated apps, original argv and explicit opt-out unchanged"
