#!/bin/sh
set -eu
umask 077
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-bash-tests.XXXXXX")
mkdir "$temporary/bin"
trap 'echo "Bash test artifacts: $temporary"' EXIT
printf 'sample-worker\nsample-viewer\n' >"$temporary/apps.conf"
cat >"$temporary/bin/sample-worker" <<'SH'
#!/bin/sh
printf '%s\000' "$@" >"$TEST_DIRECTORY/args"
printf '%s\n' "$#" >"$TEST_DIRECTORY/count"
umask >"$TEST_DIRECTORY/umask"
exit 23
SH
chmod +x "$temporary/bin/sample-worker"
cp "$temporary/bin/sample-worker" "$temporary/bin/sample-viewer"
env -u BASH_ENV TEST_DIRECTORY="$temporary" REX_SESSION=session:fixture REX_BLOCK=block:fixture \
  REX_RECOVER_CONFIG="$temporary/apps.conf" REX_RECOVER_STATE_DIR="$temporary/state" \
  PATH="$temporary/bin:$PATH" bash --noprofile --norc -s -- "$root" <<'BASH'
source "$1/shell/rex-recover.bash" || exit 1
source "$1/shell/rex-recover.bash" || exit 1
umask 022
sample-worker "a b" "a'b" '$(touch never)' ""
[[ $? == 23 ]] || exit 1
cp "$TEST_DIRECTORY/args" "$TEST_DIRECTORY/worker-args"
saved_runner=$_REX_RECOVER_RUNNER
_REX_RECOVER_RUNNER="$TEST_DIRECTORY/no-longer-installed"
sample-worker "still works"
[[ $? == 23 ]] || exit 1
_REX_RECOVER_RUNNER=$saved_runner
function sample-worker { printf '%s\n' user-function; }
printf 'sample-viewer\n' >"$REX_RECOVER_CONFIG"
source "$1/shell/rex-recover.bash" || exit 1
[[ "$(sample-worker)" == user-function ]] || exit 1
sample-viewer
[[ $? == 23 ]] || exit 1
printf 'invalid entry\n' >"$REX_RECOVER_CONFIG"
if source "$1/shell/rex-recover.bash" 2>/dev/null; then exit 1; fi
declare -F sample-viewer >/dev/null || exit 1
: >"$REX_RECOVER_CONFIG"
source "$1/shell/rex-recover.bash" || exit 1
if declare -F sample-viewer >/dev/null; then exit 1; fi
[[ "$(sample-worker)" == user-function ]]
BASH
printf '%s\000' "a b" "a'b" '$(touch never)' "" >"$temporary/expected-args"
cmp "$temporary/expected-args" "$temporary/worker-args"
[ "$(cat "$temporary/count")" = 0 ]
[ "$(cat "$temporary/umask")" = 0022 ]
[ -f "$temporary/state/launches/block:fixture" ]
echo "ok - bash integration preserves calls, reloads config, and keeps user functions"
