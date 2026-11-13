#!/bin/sh
set -eu
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-command-tests.XXXXXX")
temporary=$(CDPATH= cd -- "$temporary" && pwd -P)
mkdir "$temporary/bin"
trap 'echo "Command test artifacts: $temporary"' EXIT

printf '%s\n' sample-worker sample-editor sample-viewer custom-worker >"$temporary/apps.conf"
export REX_RECOVER_CONFIG="$temporary/apps.conf"

for app in sample-worker sample-editor sample-viewer custom-worker; do
  cat >"$temporary/bin/$app" <<'SH'
#!/bin/sh
printf '%s\000' "$@" >"$TEST_DIRECTORY/actual-args"
printf '%s\n' "$#" >"$TEST_DIRECTORY/actual-count"
umask >"$TEST_DIRECTORY/actual-umask"
exit 23
SH
  chmod +x "$temporary/bin/$app"
  TEST_DIRECTORY="$temporary" REX_SESSION=session:work REX_BLOCK="block:$app" \
    REX_RECOVER_STATE_DIR="$temporary/state" PATH="$temporary/bin:$PATH" \
    zsh -f -s -- "$root" "$app" <<'ZSH'
source "$1/shell/rex-recover.zsh"
source "$1/shell/rex-recover.zsh"
umask 022
"$2" run dev -- "a b" "a'b" '$(touch nope)' ""
[[ $? == 23 ]]
ZSH
  printf '%s\000' run dev -- "a b" "a'b" '$(touch nope)' "" >"$temporary/expected-args"
  cmp "$temporary/expected-args" "$temporary/actual-args"
  [ "$(cat "$temporary/actual-umask")" = 0022 ]
  tr '\000' '\n' <"$temporary/state/launches/block:$app" >"$temporary/record-lines"
  [ "$(sed -n '1p' "$temporary/record-lines")" = rex-recover-launch-v1 ]
  [ "$(sed -n '2p' "$temporary/record-lines")" = session:work ]
  [ "$(sed -n '3p' "$temporary/record-lines")" = "block:$app" ]
  [ "$(sed -n '6p' "$temporary/record-lines")" = "$app" ]
  [ "$(sed -n '8p' "$temporary/record-lines")" = "$temporary/bin/$app" ]
  [ "$(ls -ld "$temporary/state/launches/block:$app" | cut -c1-10)" = "-rw-------" ]
  tail -n +9 "$temporary/record-lines" >"$temporary/recorded-args"
  printf '%s\n' run dev -- "a b" "a'b" '$(touch nope)' "" >"$temporary/expected-lines"
  cmp "$temporary/recorded-args" "$temporary/expected-lines"
  echo "ok - $app captures exact arguments and preserves exit status and umask"
done

TEST_DIRECTORY="$temporary" PATH="$temporary/bin:$PATH" \
  env -u REX_SESSION -u REX_BLOCK REX_RECOVER_STATE_DIR="$temporary/outside" \
  zsh -f -s -- "$root" <<'ZSH'
source "$1/shell/rex-recover.zsh"
sample-worker --version
[[ $? == 23 ]]
ZSH
[ ! -d "$temporary/outside" ]
echo "ok - shell integration outside Rex does not record commands"

zsh -f -s -- "$root" <<'ZSH'
function sample-worker { print -r -- existing-user-function }
alias sample-editor=sample-viewer
source "$1/shell/rex-recover.zsh"
[[ "$(sample-worker)" == existing-user-function ]] || exit 1
[[ "${aliases[sample-editor]}" == sample-viewer ]]
ZSH
echo "ok - existing shell functions and aliases are preserved"

TEST_DIRECTORY="$temporary" REX_SESSION=session:work REX_BLOCK=block:unsupported \
  REX_RECOVER_STATE_DIR="$temporary/state" PATH="$temporary/bin:$PATH" \
  zsh -f -s -- "$root" 2>"$temporary/unsupported.log" <<'ZSH'
source "$1/shell/rex-recover.zsh"
sample-worker $'line one\nline two'
[[ $? == 23 ]]
ZSH
[ ! -f "$temporary/state/launches/block:unsupported" ]
grep -q "running it without argument recovery" "$temporary/unsupported.log"
printf '%s\000' 'line one
line two' >"$temporary/expected-args"
cmp "$temporary/expected-args" "$temporary/actual-args"
echo "ok - unsupported terminal control characters do not break the original command"

TEST_DIRECTORY="$temporary" REX_SESSION=session:work REX_BLOCK=block:noargs \
  REX_RECOVER_STATE_DIR="$temporary/state" PATH="$temporary/bin:$PATH" \
  zsh -f -s -- "$root" <<'ZSH'
source "$1/shell/rex-recover.zsh"
sample-viewer
[[ $? == 23 ]]
ZSH
[ "$(cat "$temporary/actual-count")" = 0 ]
tr '\000' '\n' <"$temporary/state/launches/block:noargs" >"$temporary/record-lines"
[ "$(wc -l <"$temporary/record-lines" | tr -d ' ')" = 8 ]
echo "ok - a configured command without arguments uses the same launch capture"

zsh -f -s -- "$root" "$temporary" <<'ZSH'
source "$1/shell/rex-recover.zsh"
function sample-worker { print -r -- user-modified-function }
print -r -- sample-viewer >"$REX_RECOVER_CONFIG"
source "$1/shell/rex-recover.zsh"
(( $+functions[sample-viewer] && ! $+functions[sample-editor] )) || exit 1
[[ "$(sample-worker)" == user-modified-function ]] || exit 1
print -r -- 'invalid entry' >"$REX_RECOVER_CONFIG"
if source "$1/shell/rex-recover.zsh" 2>"$2/invalid-config.log"; then exit 1; fi
(( $+functions[sample-viewer] )) || exit 1
: >"$REX_RECOVER_CONFIG"
source "$1/shell/rex-recover.zsh"
(( ! $+functions[sample-viewer] )) || exit 1
[[ "$(sample-worker)" == user-modified-function ]]
ZSH
echo "ok - config reload removes only owned wrappers and rejects partial invalid updates"

printf 'sample-worker\n' >"$temporary/apps.conf"
TEST_DIRECTORY="$temporary" REX_SESSION=session:work REX_BLOCK=block:removed \
  REX_RECOVER_STATE_DIR="$temporary/state" PATH="$temporary/bin:$PATH" \
  zsh -f -s -- "$root" "$temporary" <<'ZSH'
source "$1/shell/rex-recover.zsh"
_REX_RECOVER_RUNNER="$2/no-longer-installed"
sample-worker "still works"
[[ $? == 23 ]]
ZSH
[ ! -f "$temporary/state/launches/block:removed" ]
echo "ok - zsh commands keep working after the recorder is uninstalled"
