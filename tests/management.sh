#!/bin/sh
# Exercise the menu through the same CLI users run, without a Rex connection or
# writes outside a temporary home. Keep artifacts for failed-session diagnosis.
set -eu
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-management-tests.XXXXXX")
trap 'echo "Management test artifacts: $temporary"' EXIT
export HOME="$temporary/home"
export XDG_CONFIG_HOME="$HOME/.config"
export REX_RECOVER_CONFIG="$XDG_CONFIG_HOME/rex-recover/apps.conf"
export REX_BIN="$temporary/missing-rex"
mkdir -p "$(dirname "$REX_RECOVER_CONFIG")"

printf '# My tools\nsample-worker # keep this note\nsample-editor\n' >"$REX_RECOVER_CONFIG"
printf 'a\nsample-viewer, sample-worker\ns\n' |
  sh "$root/bin/rex-recover" apps >"$temporary/menu.log" 2>&1
printf '# My tools\nsample-worker # keep this note\nsample-editor\nsample-viewer\n' >"$temporary/expected"
cmp "$temporary/expected" "$REX_RECOVER_CONFIG"
grep -q '1) sample-worker' "$temporary/menu.log"
grep -q '3) sample-viewer' "$temporary/menu.log"
grep -q 'rex-recover service restart' "$temporary/menu.log"
echo "ok - app menu adds commands without retyping the existing list or needing Rex"

printf 'r\n1, 3\ns\n' |
  sh "$root/bin/rex-recover" apps >"$temporary/remove.log" 2>&1
printf '# My tools\nsample-editor\n' >"$temporary/expected"
cmp "$temporary/expected" "$REX_RECOVER_CONFIG"
echo "ok - app menu removes numbered selections and keeps unselected commands and comments"

cp "$REX_RECOVER_CONFIG" "$temporary/before"
printf 'a\nsample-editor#already-listed\ns\n' |
  sh "$root/bin/rex-recover" apps >"$temporary/duplicate.log" 2>&1
cmp "$temporary/before" "$REX_RECOVER_CONFIG"
echo "ok - adding an already monitored app does not change the config"

# A failed batch must not partially opt commands into automatic replay.
for invalid in '/path/to/app' 'bad;command' '$(whoami)' 'duplicate duplicate'; do
  printf 'a\nsample-new %s\ns\n' "$invalid" |
    sh "$root/bin/rex-recover" apps >"$temporary/invalid-add.log" 2>&1
  cmp "$temporary/before" "$REX_RECOVER_CONFIG"
  grep -q 'no changes made' "$temporary/invalid-add.log"
done
for invalid in 0 2 -1 '1;touch' '1 999'; do
  printf 'r\n%s\ns\n' "$invalid" |
    sh "$root/bin/rex-recover" apps >"$temporary/invalid-remove.log" 2>&1
  cmp "$temporary/before" "$REX_RECOVER_CONFIG"
  grep -q 'Choose numbers from the displayed list' "$temporary/invalid-remove.log"
done
echo "ok - invalid additions and out-of-range removals leave the whole list unchanged"

printf 'a\nsample-viewer\nq\n' |
  sh "$root/bin/rex-recover" apps >"$temporary/cancel.log" 2>&1
cmp "$temporary/before" "$REX_RECOVER_CONFIG"
if printf 'a\nsample-viewer\n' |
  sh "$root/bin/rex-recover" apps >"$temporary/eof.log" 2>&1; then
  echo "FAIL: closed input was treated as approval to save" >&2
  exit 1
fi
cmp "$temporary/before" "$REX_RECOVER_CONFIG"
echo "ok - cancel and closed input discard staged edits"

# The explicit path must win over environment defaults, and a symlink must keep
# pointing into the user's dotfile checkout after an edit.
printf '# Custom list\r\nsample-worker#note\r\nsample-editor\r\n' >"$temporary/dotfile"
ln -s "$temporary/dotfile" "$temporary/custom config"
printf 'r\n1\ns\n' |
  sh "$root/bin/rex-recover" apps --config "$temporary/custom config" >"$temporary/custom.log" 2>&1
[ -L "$temporary/custom config" ]
printf '# Custom list\r\nsample-editor\r\n' >"$temporary/expected-custom"
cmp "$temporary/expected-custom" "$temporary/dotfile"
cmp "$temporary/before" "$REX_RECOVER_CONFIG"
backup=$(sed -n 's/.*Backed up: //p' "$temporary/custom.log")
printf '# Custom list\r\nsample-worker#note\r\nsample-editor\r\n' >"$temporary/original-custom"
cmp "$temporary/original-custom" "$backup"
[ "$(LC_ALL=C ls -l "$temporary/dotfile" | cut -c 1-10)" = '-rw-------' ]
echo "ok - custom configs preserve symlinks, comments, CRLF, private permissions, and a backup"

printf 'sample-worker' >"$temporary/unterminated"
printf 'r\n\ns\n' |
  sh "$root/bin/rex-recover" --config "$temporary/unterminated" apps >"$temporary/blank.log" 2>&1
printf 'sample-worker' >"$temporary/expected-unterminated"
cmp "$temporary/expected-unterminated" "$temporary/unterminated"
echo "ok - a blank removal leaves even an unterminated file unchanged"

printf 'r\n1\ns\n' |
  sh "$root/bin/rex-recover" apps >"$temporary/empty.log" 2>&1
printf '# My tools\n' >"$temporary/expected"
cmp "$temporary/expected" "$REX_RECOVER_CONFIG"
echo "ok - removing the final app explicitly monitors nothing"

# Another editor can save while the menu is open. Wait for its first prompt
# before making that external change, then prove Save refuses to overwrite it.
if {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'Choose an action:' "$temporary/concurrent.log" 2>/dev/null; then break; fi
    sleep 0.1
  done
  grep -q 'Choose an action:' "$temporary/concurrent.log" || exit 1
  printf 'external-worker\n' >"$REX_RECOVER_CONFIG"
  printf 's\n'
} | sh "$root/bin/rex-recover" apps >"$temporary/concurrent.log" 2>&1; then
  echo "FAIL: saving overwrote a concurrent configuration edit" >&2
  exit 1
fi
printf 'external-worker\n' >"$temporary/external"
cmp "$temporary/external" "$REX_RECOVER_CONFIG"
grep -q 'changed while' "$temporary/concurrent.log"
echo "ok - saving refuses to overwrite edits made while the menu was open"

printf 'duplicate\nduplicate\n' >"$REX_RECOVER_CONFIG"
cp "$REX_RECOVER_CONFIG" "$temporary/invalid-original"
if printf 's\n' |
  sh "$root/bin/rex-recover" apps >"$temporary/invalid-config.log" 2>&1; then
  echo "FAIL: invalid existing config was silently accepted" >&2
  exit 1
fi
cmp "$temporary/invalid-original" "$REX_RECOVER_CONFIG"
echo "ok - an invalid existing config is reported without overwriting it"
