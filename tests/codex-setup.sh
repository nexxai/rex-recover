#!/bin/sh
set -eu
umask 077
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-codex-setup.XXXXXX")
temporary=$(CDPATH= cd -- "$temporary" && pwd -P)
trap 'rm -rf "$temporary"' EXIT
node=$(command -v node)
mkdir "$temporary/tools"
for tool in awk cat chmod cmp cp cksum date dirname env flock grep lockf mkdir mktemp mv paste rm rmdir sed sh tr; do
  binary=$(command -v "$tool" 2>/dev/null || :)
  [ -z "$binary" ] || ln -s "$binary" "$temporary/tools/$tool"
done
printf '#!/bin/sh\necho Linux\n' >"$temporary/tools/uname"
printf '#!/bin/sh\necho 501\n' >"$temporary/tools/id"
chmod +x "$temporary/tools/uname" "$temporary/tools/id"

fixture() {
  directory="$temporary/$1"
  home="$directory/User's Home & \$"
  bin="$directory/tools with ' quotes"
  codex_home="$home/.codex"
  runtime="$home/.local/share/rex-recover"
  settings="$codex_home/config.toml"
  hooks="$codex_home/hooks.json"
  mkdir -p "$codex_home" "$bin"
  for app in rex codex; do
    cat >"$bin/$app" <<'SH'
#!/bin/sh
printf 'Unexpected execution: %s %s\n' "$0" "$*" >>"${0%/*}/unexpected"
exit 99
SH
    chmod +x "$bin/$app"
  done
  ln -s "$node" "$bin/node"
}

install() {
  printf '%b' "$1" | env -i PATH="$bin:$temporary/tools" HOME="$home" CODEX_HOME="$codex_home" \
    TMPDIR="$directory" SHELL=/bin/bash REX_BIN="$bin/rex" /bin/sh "$root/install.sh" \
    >"$directory/install.log" 2>&1
}

run_install() {
  if ! install "$1"; then
    cat "$directory/install.log" >&2
    exit 1
  fi
  [ ! -e "$bin/unexpected" ]
}

fixture default-no
printf '%s\n' 'test existing, potentially unsupported config' >"$settings"
printf '%s\n' 'test existing, potentially unsupported hooks' >"$hooks"
cp "$settings" "$directory/settings.before"
cp "$hooks" "$directory/hooks.before"
run_install 'worker\ny\n\n\ny\n'
grep -Fq 'Codex detected.' "$directory/install.log"
grep -Fq 'codex --no-daemon' "$directory/install.log"
cmp "$settings" "$directory/settings.before"
cmp "$hooks" "$directory/hooks.before"
if grep -q 'REX_RECOVER_SESSIONS' "$home/.bashrc"; then
  echo 'FAIL: declining Codex setup enabled a session driver' >&2
  exit 1
fi
echo 'ok - detecting Codex offers default-no setup without invoking Codex or editing its files'

fixture nonexecutable
chmod -x "$bin/codex"
rm "$bin/node"
run_install 'worker\nn\ny\n'
if grep -Fq 'Codex detected.' "$directory/install.log"; then
  echo 'FAIL: a non-executable Codex file triggered setup' >&2
  exit 1
fi

fixture hook
cat >"$hooks" <<'JSON'
{
    "description": "keep this",
    "hooks": {
        "SessionStart": [{"matcher":"startup","hooks":[{"type":"command","command":"echo already here"}]}],
        "Stop": [{"hooks":[{"type":"command","command":"echo stop"}]}]
    }
}
JSON
cp "$hooks" "$directory/hooks.before"
printf '[hooks.state."existing"]\ntrusted_hash = "do not change"\n' >"$settings"
cp "$settings" "$directory/settings.before"
run_install 'worker\ny\nn\ny\nn\n'
cmp "$hooks" "$directory/hooks.before"
[ ! -e "$home/.local" ]
run_install 'worker\ny\nn\ny\ny\n'
cmp "$settings" "$directory/settings.before"
cmp "$root/scripts/codex-session-start.mjs" "$runtime/scripts/codex-session-start.mjs"
grep -Fq 'export REX_RECOVER_SESSIONS=codex;' "$home/.bashrc"
grep -Fq 'open /hooks, choose SessionStart' "$directory/install.log"
printf 'worker\n' >"$directory/apps.expected"
cmp "$directory/apps.expected" "$home/.config/rex-recover/apps.conf"
"$node" --input-type=module - "$hooks" "$directory/hooks.before" "$runtime" "$runtime/install.info" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, realpathSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const [, , hookPath, originalPath, runtime, manifest] = process.argv;
const config = JSON.parse(readFileSync(hookPath));
const group = config.hooks.SessionStart.pop();
assert.deepEqual(config, JSON.parse(readFileSync(originalPath)));
assert.equal(group.hooks.length, 1);
assert.equal(group.hooks[0].type, 'command');
const command = group.hooks[0].command;
// Parse the generated shell quoting without running its interpreter or hook.
assert(command.startsWith('exec '));
const argv = spawnSync('/bin/sh', ['-c', `set -- ${command.slice(5)}; printf '%s\\n' "$@"`], { env: {} });
assert.equal(argv.status, 0, argv.stderr.toString());
assert.equal(argv.stdout.toString(), `${realpathSync(process.execPath)}\n${runtime}/scripts/codex-session-start.mjs\n`);
const ownership = readFileSync(manifest, 'utf8');
assert(ownership.includes(`codex_hooks\t${hookPath}\n`));
assert(ownership.includes(`codex_hook_command\t${command}\n`));
assert(!/^owned\t.*\/hooks\.json$/m.test(ownership));
JS
cp "$hooks" "$directory/hooks.installed"
run_install 'worker\ny\nn\ny\ny\n'
cmp "$hooks" "$directory/hooks.installed"
set -- "$hooks".rex-recover-backup-*
[ "$#" = 1 ]
cmp "$1" "$directory/hooks.before"
env -i PATH="$bin:$temporary/tools" HOME="$home" REX_SESSION=session:test REX_BLOCK=block:test REX_RECOVER_SESSIONS=0 \
  /bin/bash -c '. "$1"; test "$REX_RECOVER_SESSIONS" = 0' -- "$home/.bashrc"
echo 'ok - consent appends one correctly quoted hook without touching existing trust, apps, order, or an explicit opt-in'

fixture both
cp -p "$bin/rex" "$bin/opencode"
run_install 'opencode,codex\ny\ny\nn\ny\ny\n'
grep -Fq 'export REX_RECOVER_SESSIONS=opencode,codex;' "$home/.bashrc"
[ -f "$home/.config/opencode/plugins/rex-recover/server.mjs" ]
[ -f "$hooks" ]
run_install '\ny\nn\nn\nn\ny\n'
grep -Fq 'export REX_RECOVER_SESSIONS=opencode,codex;' "$home/.bashrc"
echo 'ok - selecting both companions keeps a scoped list when the installer is rerun'

for preference in missing add true false dotted quoted multiline hostile stale; do
  fixture "daemon-$preference"
  case "$preference" in
    missing)
      printf '[features]\ndaemon_auto_start = false\n' >"$directory/settings.expected"
      ;;
    add)
      printf 'model = "my-model"\n\n[features] # comment\nother = true\n\n[other]\nkey = "value"\n' >"$settings"
      printf 'model = "my-model"\n\n[features] # comment\nother = true\ndaemon_auto_start = false\n\n[other]\nkey = "value"\n' \
        >"$directory/settings.expected"
      ;;
    dotted)
      printf 'features.daemon_auto_start = true # keep this\n' >"$settings"
      ;;
    quoted)
      printf '["features"]\n"daemon_auto_start" = true # keep this\n' >"$settings"
      ;;
    multiline)
      printf '%s\n' '[features]' 'daemon_auto_start = true # keep this' \
        '' '["a"."b"]' "description = '''" '[features]' "'''" >"$settings"
      ;;
    *)
      printf '%s\n' '[features]' '# keep this comment' 'daemon_auto_start = true # and this' \
        '' '["a"."b"]' 'description = "keep this too"' >"$settings"
      sed 's/= true/= false/' "$settings" >"$directory/settings.expected"
      if [ "$preference" = false ]; then cp "$directory/settings.expected" "$settings"; fi
      ;;
  esac
  printf '%s\n' "$preference" >"$bin/preference"
  printf '%s\n' "$codex_home" >"$bin/real-codex-home"
  cat >"$bin/codex" <<'SH'
#!/bin/sh
set -eu
bin=${0%/*}
real_home=$(cat "$bin/real-codex-home")
[ "$*" = "features disable daemon_auto_start" ] &&
  [ "$CODEX_HOME" != "$real_home" ] && [ "$HOME" = "$CODEX_HOME" ] &&
  [ "$(pwd -P)" = "$CODEX_HOME" ] && [ -z "${API_KEY:-}" ] || {
  : >"$bin/unexpected"
  exit 1
}
echo "$*" >>"$bin/editor-called"
case "$(cat "$bin/preference")" in
  missing) printf '[features]\ndaemon_auto_start = false\n' >config.toml ;;
  add)
    awk '{ print; if ($0 == "other = true") print "daemon_auto_start = false" }' config.toml >new.toml
    mv new.toml config.toml
    ;;
  hostile) printf '[features]\ndaemon_auto_start = false\nunrelated = true\n' >config.toml ;;
  *)
    sed 's/= true/= false/' config.toml >new.toml
    mv new.toml config.toml
    if [ "$(cat "$bin/preference")" = stale ]; then
      printf '\n# editing while installer plans\n' >>"$real_home/config.toml"
    fi
    ;;
esac
SH
  if [ -f "$settings" ]; then cp "$settings" "$directory/settings.before"; fi
  run_install 'worker\nn\ny\nn\nn\n'
  [ ! -e "$bin/editor-called" ]
  [ ! -e "$runtime" ]
  case "$preference" in
    dotted|quoted|multiline|hostile|stale)
      if install 'worker\ny\ny\ny\ny\n'; then
        echo "FAIL: accepted unsafe or unsupported Codex edit ($preference)" >&2
        exit 1
      fi
      case "$preference" in
        dotted|quoted|multiline)
          grep -Fq 'Rex Recover only recognizes an unquoted [features] stanza' "$directory/install.log"
          grep -Fq 'Rerun setup, decline the daemon setting change, and use codex --no-daemon' "$directory/install.log"
          ;;
        hostile) grep -Fq 'Codex editor changed unexpected TOML bytes' "$directory/install.log" ;;
        stale)
          printf '\n# editing while installer plans\n' >>"$directory/settings.before"
          grep -Fq 'Codex settings changed during planning' "$directory/install.log"
          ;;
      esac
      cmp "$settings" "$directory/settings.before"
      [ ! -e "$home/.local" ]
      [ ! -e "$home/.config" ]
      [ ! -e "$home/.bashrc" ]
      [ ! -e "$hooks" ]
      set -- "$settings".rex-recover-backup-*
      [ ! -e "$1" ]
      ;;
    *)
      run_install 'worker\nn\ny\nn\ny\n'
      cmp "$settings" "$directory/settings.expected"
      [ ! -f "$hooks" ]
      if [ "$preference" = false ]; then
        if grep -q '^codex_daemon_config' "$runtime/install.info"; then
          echo 'FAIL: an existing false preference was claimed by Rex' >&2
          exit 1
        fi
      else
        printf 'codex_daemon_config\t%s\n' "$settings" >"$directory/manifest.expected"
        grep '^codex_daemon_config' "$runtime/install.info" >"$directory/manifest.actual"
        cmp "$directory/manifest.actual" "$directory/manifest.expected"
      fi
      if [ -f "$directory/settings.before" ] && [ "$preference" != false ]; then
        set -- "$settings".rex-recover-backup-*
        [ "$#" = 1 ]
        cmp "$1" "$directory/settings.before"
      fi
      ;;
  esac
  [ ! -e "$bin/unexpected" ]
  [ "$(grep -c '^features disable daemon_auto_start$' "$bin/editor-called")" = 1 ]
done
echo 'ok - persistent choice invokes only the scratch native editor after approval, checks byte differences and journals real edits only'

for link in settings hooks home; do
  fixture "linked-$link"
  printf 'do not change this target\n' >"$directory/target"
  cp "$directory/target" "$directory/target.expected"
  case "$link" in
    settings) ln -s "$directory/target" "$settings"; answers='worker\nn\ny\nn\ny\n' ;;
    hooks) ln -s "$directory/target" "$hooks"; answers='worker\nn\nn\ny\ny\n' ;;
    home)
      rmdir "$codex_home"
      ln -s "$directory" "$codex_home"
      answers='worker\nn\nn\ny\ny\n'
      ;;
  esac
  if install "$answers"; then
    echo "FAIL: followed linked Codex $link" >&2
    exit 1
  fi
  cmp "$directory/target" "$directory/target.expected"
  [ ! -e "$bin/unexpected" ]
  [ ! -e "$runtime" ]
done
echo 'ok - linked Codex settings or parent directories are untouched'
