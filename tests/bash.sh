#!/bin/sh
# Bash's function introspection differs from zsh's, so the reload/ownership
# contract needs coverage in bash itself rather than only in a shared helper.
# Temporary artifacts stay private and remain available when a test fails.
set -eu
umask 077
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-bash-tests.XXXXXX")
mkdir "$temporary/bin"
trap 'echo "Bash test artifacts: $temporary"' EXIT
printf 'sample-worker\nsample-viewer\n' >"$temporary/apps.conf"
# A harmless executable records what it actually received. Its nonzero status
# exposes wrappers that accidentally substitute the recorder's success status.
cat >"$temporary/bin/sample-worker" <<'SH'
#!/bin/sh
printf '%s\000' "$@" >"$TEST_DIRECTORY/args"
printf '%s\n' "$#" >"$TEST_DIRECTORY/count"
umask >"$TEST_DIRECTORY/umask"
exit 23
SH
chmod +x "$temporary/bin/sample-worker"
cp "$temporary/bin/sample-worker" "$temporary/bin/sample-viewer"
# Personal startup code could define competing functions or aliases and make
# this test depend on the contributor's machine instead of the integration.
env -u BASH_ENV TEST_DIRECTORY="$temporary" REX_SESSION=session:fixture REX_BLOCK=block:fixture \
  REX_RECOVER_CONFIG="$temporary/apps.conf" REX_RECOVER_STATE_DIR="$temporary/state" \
  PATH="$temporary/bin:$PATH" bash --noprofile --norc -s -- "$root" <<'BASH'
# Re-sourcing is normal after config changes; it must not build wrapper layers.
source "$1/shell/rex-recover.bash" || exit 1
source "$1/shell/rex-recover.bash" || exit 1
umask 022
sample-worker "a b" "a'b" '$(touch never)' ""
[[ $? == 23 ]] || exit 1
cp "$TEST_DIRECTORY/args" "$TEST_DIRECTORY/worker-args"
# Uninstall cannot erase functions in existing shells. Those functions must
# remain usable even though their recorder no longer exists.
saved_runner=$_REX_RECOVER_RUNNER
_REX_RECOVER_RUNNER="$TEST_DIRECTORY/no-longer-installed"
sample-worker "still works"
[[ $? == 23 ]] || exit 1
_REX_RECOVER_RUNNER=$saved_runner
# A user replacement is no longer ours, even if its name used to be configured.
# Reload must remove obsolete owned wrappers without deleting that replacement.
function sample-worker { printf '%s\n' user-function; }
printf 'sample-viewer\n' >"$REX_RECOVER_CONFIG"
source "$1/shell/rex-recover.bash" || exit 1
[[ "$(sample-worker)" == user-function ]] || exit 1
sample-viewer
[[ $? == 23 ]] || exit 1
# A bad later config must not destroy the last working wrappers.
printf 'invalid entry\n' >"$REX_RECOVER_CONFIG"
if source "$1/shell/rex-recover.bash" 2>/dev/null; then exit 1; fi
declare -F sample-viewer >/dev/null || exit 1
# Empty means no interception, but still does not make user functions ours.
: >"$REX_RECOVER_CONFIG"
source "$1/shell/rex-recover.bash" || exit 1
if declare -F sample-viewer >/dev/null; then exit 1; fi
[[ "$(sample-worker)" == user-function ]]
BASH
# Independently specified NUL-separated bytes catch lost empty arguments and
# accidental shell evaluation; a word-count check alone would miss both.
printf '%s\000' "a b" "a'b" '$(touch never)' "" >"$temporary/expected-args"
cmp "$temporary/expected-args" "$temporary/worker-args"
[ "$(cat "$temporary/count")" = 0 ]
[ "$(cat "$temporary/umask")" = 0022 ]
[ -f "$temporary/state/launches/block:fixture" ]
echo "ok - bash integration preserves calls, reloads config, and keeps user functions"
