#!/bin/sh
# Installation touches startup files and services; tests must prove its behavior
# without obtaining authority over the developer's actual home or service manager.
# Keep the sandbox private but retained so a failure's generated files are inspectable.
set -eu
umask 077
unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME ZDOTDIR REX_RECOVER_CONFIG REX_RECOVER_STATE_DIR
unset REX_RECOVER_LAUNCH_DIR REX_RECOVER_SESSIONS OPENCODE_CONFIG_DIR OPENCODE_CLI_CONFIG_CONTENT CODEX_HOME

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-setup-tests.XXXXXX")
temporary=$(CDPATH= cd -- "$temporary" && pwd -P)
trap 'echo "Setup test artifacts: $temporary"' EXIT
node_bin=$(command -v node)
# Deliberately omit the host PATH: merely having OpenCode installed on the
# developer's machine must never opt a fixture into integration setup.
mkdir "$temporary/tools"
for tool in sh awk dirname tr paste sed cp cat cmp mkdir chmod date cksum mktemp rm rmdir mv \
  flock lockf true env grep wc cut readlink; do
  tool_path=$(command -v "$tool" 2>/dev/null || :)
  [ -z "$tool_path" ] || ln -s "$tool_path" "$temporary/tools/$tool"
done

# Special characters in the fake home expose shell/XML/systemd escaping mistakes
# that a simple path would hide. Every service operation goes through a fake
# executable; unexpected Rex use is evidence of violating installer boundaries.
make_environment() {
  environment="$temporary/$1"
  home="$environment/User's Home & 50% dollars\$"
  mkdir -p "$environment/bin" "$home"
  fixture_path="$environment/bin:$temporary/tools"
  ln -s "$node_bin" "$environment/bin/node"
  # One fake dispatcher keeps the platform cases comparable. Unknown operations
  # fail rather than silently pretending an unmodeled service action succeeded.
  for tool in uname id launchctl systemctl rex; do
    cat >"$environment/bin/$tool" <<'SH'
#!/bin/sh
case "${0##*/}" in
  uname) printf '%s\n' "$TEST_PLATFORM" ;;
  id) if [ "$1" = -u ]; then echo 501; else /usr/bin/id "$@"; fi ;;
  rex|codex) printf 'Unexpected %s execution\n' "${0##*/}" >>"$TEST_ENV/rex-calls"; exit 1 ;;
  launchctl)
    printf 'launchctl %s\n' "$*" >>"$TEST_ENV/services"
    case "$1:$2" in
      print:gui/501) exit 0 ;;
      print:gui/501/local.rex-recover) test -f "$TEST_ENV/active" ;;
      bootstrap:*)
        if [ -f "$TEST_ENV/fail-restart" ]; then echo "fixture restart failed" >&2; exit 1; fi
        : >"$TEST_ENV/active"
        ;;
      bootout:*) rm -f "$TEST_ENV/active" ;;
      *) exit 1 ;;
    esac
    ;;
  systemctl)
    printf 'systemctl %s\n' "$*" >>"$TEST_ENV/services"
    case "$*" in
      "--user show-environment") exit 0 ;;
      "--user is-active --quiet rex-recover.service") test -f "$TEST_ENV/active" ;;
      "--user enable --now rex-recover.service") : >"$TEST_ENV/active" ;;
      "--user restart rex-recover.service")
        if [ -f "$TEST_ENV/fail-restart" ]; then echo "fixture restart failed" >&2; exit 1; fi
        : >"$TEST_ENV/active"
        ;;
      "--user disable --now rex-recover.service") rm -f "$TEST_ENV/active" ;;
      "--user daemon-reload") exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
esac
SH
    chmod +x "$environment/bin/$tool"
  done
}

# Ambient XDG and capture settings must not redirect a test into real user data.
# Scripted answers make consent choices explicit; captured logs explain a failed
# prompt sequence without requiring another interactive installation.
install_command() {
  answers=$1
  install_source=$2
  shift 2
  printf '%s' "$answers" | env -u XDG_DATA_HOME -u ZDOTDIR -u REX_RECOVER_CONFIG \
    -u REX_RECOVER_STATE_DIR -u OPENCODE_CLI_CONFIG_CONTENT -u OPENCODE_CONFIG_DIR \
    TEST_PLATFORM="$platform" TEST_ENV="$environment" \
    HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" \
    SHELL="$shell" REX_BIN="$environment/bin/rex" PATH="$fixture_path" \
    "$@" /bin/sh "$install_source/install.sh" >"$environment/install.log" 2>&1
}

run_installer() {
  if ! install_command "$1" "${2:-$root}"; then
    cat "$environment/install.log" >&2
    exit 1
  fi
}

# Source fixtures may add drivers without changing the installer or registry.
copy_source() {
  mkdir "$environment/source"
  cp "$root/recovery.lua" "$root/watch.lua" "$root/install.sh" "$root/uninstall.sh" \
    "$environment/source/"
  cp -R "$root/bin" "$root/scripts" "$root/shell" "$root/drivers" "$root/plugins" "$environment/source/"
  rm -f "$environment/source/drivers/catalog.tsv" "$environment/source/scripts/drivers.sh"
}

# A descriptor file alone must be enough: no catalog, parser, or shell branch.
# Non-Lua notes in the source directory are not executable install targets.
make_environment discovered-addon
platform=Linux
shell=/bin/bash
runtime="$home/.local/share/rex-recover"
copy_source
mkdir -p "$environment/source/plugins/opencode-recover"
printf '{"name":"opencode-recover-fixture","exports":{"./tui":"./tui.mjs"}}\n' \
  >"$environment/source/plugins/opencode-recover/package.json"
printf 'throw new Error("installation must not execute the TUI companion");\n' \
  >"$environment/source/plugins/opencode-recover/tui.mjs"
cat >"$environment/driver-descriptor.lua" <<'LUA'
assert(not os.getenv("TEST_ENV"), "installation must not execute driver modules")
return {
  executable = "sample-addon",
  home_env = "SAMPLE_ADDON_HOME",
  default_home = ".sample-addon",
  capture = function(context) return nil end,
}
LUA
ln -s "$environment/driver-descriptor.lua" "$environment/source/drivers/sample-addon.lua"
printf 'unrelated notes\n' >"$environment/source/drivers/unlisted-notes.txt"
run_installer 'sample-addon
n
n
y
' "$environment/source"
if [ ! -f "$runtime/drivers/sample-addon.lua" ]; then
  echo "FAIL: a single driver descriptor did not install drivers/sample-addon.lua" >&2
  exit 1
fi
cmp "$environment/source/drivers/sample-addon.lua" "$runtime/drivers/sample-addon.lua"
[ "$(ls -l "$runtime/drivers/sample-addon.lua" | cut -c1-10)" = "-rw-r--r--" ]
printf 'owned\t%s\t%s\n' "$(cksum <"$environment/source/drivers/sample-addon.lua")" \
  "$runtime/drivers/sample-addon.lua" >"$environment/expected-addon-ownership"
awk -F '\t' -v path="$runtime/drivers/sample-addon.lua" '$1 == "owned" && $3 == path' \
  "$runtime/install.info" >"$environment/addon-ownership"
cmp "$environment/expected-addon-ownership" "$environment/addon-ownership"
for companion in package.json tui.mjs server.mjs rpc.mjs; do
  cmp "$environment/source/plugins/opencode-recover/$companion" \
    "$runtime/plugins/opencode-recover/$companion"
  printf 'owned\t%s\t%s\n' "$(cksum <"$environment/source/plugins/opencode-recover/$companion")" \
    "$runtime/plugins/opencode-recover/$companion" >"$environment/expected-companion-ownership"
  awk -F '\t' -v path="$runtime/plugins/opencode-recover/$companion" '$1 == "owned" && $3 == path' \
    "$runtime/install.info" >"$environment/companion-ownership"
  cmp "$environment/expected-companion-ownership" "$environment/companion-ownership"
done
[ ! -e "$runtime/drivers/unlisted-notes.txt" ]
[ ! -e "$runtime/drivers.lua" ]
[ ! -e "$runtime/drivers/catalog.tsv" ]
[ ! -e "$runtime/scripts/drivers.sh" ]
# A different checkout may lack an installed optional driver or contain new
# invalid source files. Neither changes which installed files the manifest owns.
cp -R "$environment/source" "$environment/other-source"
rm -f "$environment/other-source/drivers/sample-addon.lua"
printf 'return {}\n' >"$environment/other-source/drivers/Acme-editor.lua"
printf 'unowned Lua module\n' >"$environment/expected-unowned.lua"
cp "$environment/expected-unowned.lua" "$runtime/drivers/user-addon.lua"
printf 'unowned notes\n' >"$environment/expected-notes"
cp "$environment/expected-notes" "$runtime/drivers/user-notes"
if ! printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
   PATH="$fixture_path" /bin/sh "$environment/other-source/uninstall.sh" \
  >"$environment/uninstall.log" 2>&1; then
  cat "$environment/uninstall.log" >&2
  exit 1
fi
[ ! -e "$runtime/drivers/sample-addon.lua" ]
[ ! -e "$runtime/drivers/registry.lua" ]
[ ! -e "$runtime/drivers/openai-codex.lua" ]
[ ! -e "$runtime/plugins/opencode-recover/tui.mjs" ]
[ ! -e "$runtime/plugins/opencode-recover/package.json" ]
[ ! -d "$runtime/plugins" ]
[ ! -e "$runtime/install.info" ]
[ ! -e "$home/.local/bin/rex-recover" ]
cmp "$environment/expected-unowned.lua" "$runtime/drivers/user-addon.lua"
cmp "$environment/expected-notes" "$runtime/drivers/user-notes"
[ ! -f "$environment/rex-calls" ]
echo "ok - one driver descriptor alone drives installation, ownership, and removal without a catalog"
echo "ok - symlinked regular driver files are packaged without executing them"
echo "ok - another checkout removes owned drivers while preserving unowned Lua files and notes"

# Scope errors at the end of a manifest must be caught before earlier owned
# files, the service, or unrelated data are touched.
for corruption in outside nested unterminated; do
  make_environment "corrupt-$corruption"
  platform=Linux
  shell=/bin/bash
  runtime="$home/.local/share/rex-recover"
  run_installer 'sample-worker
n
y
y
'
  if [ "$corruption" = nested ]; then
    mkdir "$runtime/drivers/nested"
    target="$runtime/drivers/nested/unrelated.lua"
  else
    target="$home/unrelated.lua"
  fi
  printf 'unrelated contents\n' >"$environment/expected-unrelated"
  cp "$environment/expected-unrelated" "$target"
  if [ "$corruption" = unterminated ]; then
    printf 'owned\t%s\t%s' "$(cksum <"$target")" "$target" >>"$runtime/install.info"
  else
    printf 'owned\t%s\t%s\n' "$(cksum <"$target")" "$target" >>"$runtime/install.info"
  fi
  cp "$runtime/install.info" "$environment/expected-manifest"
  cp "$environment/services" "$environment/expected-services"
  if printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
    PATH="$fixture_path" /bin/sh "$root/uninstall.sh" >"$environment/uninstall.log" 2>&1; then
    echo "FAIL: uninstall accepted an out-of-scope owned path: $target" >&2
    exit 1
  fi
  grep -Fq "Unexpected owned path in manifest: $target" "$environment/uninstall.log"
  cmp "$environment/expected-manifest" "$runtime/install.info"
  cmp "$environment/expected-services" "$environment/services"
  cmp "$environment/expected-unrelated" "$target"
  [ -f "$environment/active" ]
  [ -f "$runtime/recovery.lua" ]
  [ -f "$runtime/scripts/setup.sh" ]
  [ -f "$runtime/drivers/registry.lua" ]
  [ -x "$home/.local/bin/rex-recover" ]
  [ ! -f "$environment/rex-calls" ]
done
echo "ok - corrupt manifest scopes are rejected before any service or owned-file removal"

# Both generated service formats need coverage on this host. These are fixture
# tests, not evidence that a real Linux systemd manager has accepted the unit.
for platform in Darwin Linux; do
  make_environment "$platform"
  if [ "$platform" = Darwin ]; then
    runtime="$home/Library/Application Support/rex-recover"
    startup="$home/.zshrc"
    shell=$(command -v zsh)
    service="$home/Library/LaunchAgents/local.rex-recover.plist"
  else
    runtime="$home/.local/share/rex-recover"
    startup="$home/.bashrc"
    shell=/bin/bash
    service="$home/.config/systemd/user/rex-recover.service"
  fi
  printf 'export KEEP_USER_SETTING=1\n' >"$startup"
  # Choose invented apps explicitly: examples in a prompt are never defaults.
  run_installer 'sample-worker, sample-editor
y
y
y
'
  [ -x "$home/.local/bin/rex-recover" ]
  [ -x "$home/.local/bin/rex-recover-uninstall" ]
  [ -f "$runtime/install.info" ]
  [ -f "$runtime/recovery.lua" ]
  for module in scripts/driver-context.lua drivers/registry.lua drivers/openai-codex.lua; do
    if [ ! -f "$runtime/$module" ]; then
      echo "FAIL: $platform installation omitted $module" >&2
      exit 1
    fi
    cmp "$root/$module" "$runtime/$module"
    [ "$(ls -l "$runtime/$module" | cut -c1-10)" = "-rw-r--r--" ]
    printf 'owned\t%s\t%s\n' "$(cksum <"$root/$module")" "$runtime/$module" \
      >"$environment/expected-driver-ownership"
    awk -F '\t' -v path="$runtime/$module" '$1 == "owned" && $3 == path' \
      "$runtime/install.info" >"$environment/driver-ownership"
    cmp "$environment/expected-driver-ownership" "$environment/driver-ownership"
    echo "ok - $platform installer copies $module and records its ownership"
  done
  [ ! -e "$runtime/drivers.lua" ]
  [ ! -e "$runtime/drivers/catalog.tsv" ]
  [ ! -e "$runtime/scripts/drivers.sh" ]
  [ -f "$service" ]
  [ -f "$environment/active" ]
  [ ! -f "$environment/rex-calls" ]
  grep -Fq "Manage apps:    $home/.local/bin/rex-recover apps" "$environment/install.log"
  grep -Fq "Restart watcher: $home/.local/bin/rex-recover service restart" "$environment/install.log"
  printf 'sample-worker\nsample-editor\n' >"$environment/expected-apps"
  cmp "$environment/expected-apps" "$home/.config/rex-recover/apps.conf"
  [ "$(grep -c '^# >>> Rex Recover >>>$' "$startup")" = 1 ]
  if [ "$platform" = Darwin ]; then
    # A syntactically valid plist can still contain incorrectly escaped paths;
    # both syntax and the deliberately troublesome path deserve an assertion.
    if command -v plutil >/dev/null; then plutil -lint "$service"; fi
    grep -q '&amp;' "$service"
    grep -q 'boot.*gui/501' "$environment/services"
  else
    # Quotes alone do not suppress systemd's percent and dollar expansions.
    grep -q '^Type=exec$' "$service"
    grep -Fq '%%' "$service"
    grep -Fq '$$' "$service"
    grep -q 'systemctl --user enable --now rex-recover.service' "$environment/services"
  fi
  # A correct-looking startup file is insufficient if the target shell cannot
  # actually load its hook while preserving a pre-existing personal setting.
  env HOME="$home" PATH="$fixture_path" \
    REX_SESSION=session:fixture REX_BLOCK=block:fixture \
    "$shell" -c '. "$1"; type sample-worker >/dev/null; test "$KEEP_USER_SETTING" = 1' \
    -- "$startup"
  echo "ok - $platform installer creates a configured runtime, shell hook, and user service"

  # The installed copy has no Git metadata. Its version must still be available
  # without valid settings, a Rex connection, or service-manager operations.
  cp "$environment/services" "$environment/services-before-version"
  env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
    REX_RECOVER_CONFIG="$environment/missing.conf" REX_RECOVER_STATE_DIR="$environment/version-state" \
    PATH="$fixture_path" "$home/.local/bin/rex-recover" --version \
    >"$environment/version.out" 2>"$environment/version.err"
  printf 'rex-recover 0.1.0\n' >"$environment/expected-version"
  cmp "$environment/expected-version" "$environment/version.out"
  [ ! -s "$environment/version.err" ]
  [ ! -f "$environment/rex-calls" ]
  [ ! -e "$environment/version-state" ]
  cmp "$environment/services-before-version" "$environment/services"
  echo "ok - $platform installed --version works without calling Rex or changing recovery state or services"

  # Run the installed launcher, not just the checkout, to catch omitted runtime
  # helpers. Assert the complete service log so no Rex/system-wide restart slips in.
  : >"$environment/services"
  env -u REX_RECOVER_CONFIG -u REX_RECOVER_STATE_DIR \
    TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    PATH="$fixture_path" "$home/.local/bin/rex-recover" service restart \
    >"$environment/restart.log" 2>&1
  if [ "$platform" = Darwin ]; then
    printf 'launchctl print gui/501/local.rex-recover\nlaunchctl bootout gui/501/local.rex-recover\nlaunchctl bootstrap gui/501 %s\n' \
      "$service" >"$environment/expected-services"
  else
    printf 'systemctl --user restart rex-recover.service\n' >"$environment/expected-services"
  fi
  cmp "$environment/expected-services" "$environment/services"
  [ -f "$environment/active" ]
  [ ! -f "$environment/rex-calls" ]
  echo "ok - $platform service restart targets only the installed user watcher"

  rm "$environment/active"
  : >"$environment/services"
  env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    PATH="$fixture_path" "$home/.local/bin/rex-recover" service restart \
    >"$environment/restart-stopped.log" 2>&1
  if [ "$platform" = Darwin ]; then
    printf 'launchctl print gui/501/local.rex-recover\nlaunchctl bootstrap gui/501 %s\n' \
      "$service" >"$environment/expected-services"
  fi
  cmp "$environment/expected-services" "$environment/services"
  [ -f "$environment/active" ]
  echo "ok - $platform restart also starts a stopped watcher service"

  : >"$environment/fail-restart"
  if env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    PATH="$fixture_path" "$home/.local/bin/rex-recover" service restart \
    >"$environment/restart-failed.log" 2>&1; then
    echo "FAIL: service-manager failure was reported as success" >&2
    exit 1
  fi
  grep -q 'fixture restart failed' "$environment/restart-failed.log"
  ! grep -q 'restart requested' "$environment/restart-failed.log"
  rm "$environment/fail-restart"
  echo "ok - $platform restart reports service-manager failures"

  printf 'a\nsample-viewer\ns\n' |
    env -u REX_RECOVER_CONFIG TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
      XDG_CONFIG_HOME="$home/.config" PATH="$fixture_path" \
      "$home/.local/bin/rex-recover" apps >"$environment/apps.log" 2>&1
  printf 'sample-worker\nsample-editor\nsample-viewer\n' >"$environment/expected-apps"
  cmp "$environment/expected-apps" "$home/.config/rex-recover/apps.conf"
  [ ! -f "$environment/rex-calls" ]
  echo "ok - $platform installed app menu updates the installer's config"

  # Reinstallation is a normal update path, not permission to append another
  # copy of the managed block or erase settings added since the first install.
  run_installer '
y
y
y
'
  [ "$(grep -c '^# >>> Rex Recover >>>$' "$startup")" = 1 ]
  printf 'export USER_ADDED_LATER=1\n' >>"$startup"
  # Declining uninstall must leave even a running service untouched.
  printf 'n\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
    PATH="$fixture_path" /bin/sh "$runtime/uninstall.sh" \
    >"$environment/cancel-uninstall.log" 2>&1
  [ -f "$environment/active" ]
  [ -f "$runtime/recovery.lua" ]
  [ -f "$runtime/scripts/driver-context.lua" ]
  [ -f "$runtime/drivers/registry.lua" ]
  [ -f "$runtime/drivers/openai-codex.lua" ]
  # Default removal leaves choices and evidence available for a later reinstall.
  # Comparing the entire startup file catches collateral edits outside markers.
  printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
    PATH="$fixture_path" /bin/sh "$runtime/uninstall.sh" \
    >"$environment/uninstall.log" 2>&1
  [ ! -f "$environment/active" ]
  [ ! -f "$service" ]
  [ ! -e "$home/.local/bin/rex-recover" ]
  [ ! -e "$home/.local/bin/rex-recover-uninstall" ]
  [ ! -e "$runtime/scripts/driver-context.lua" ]
  [ ! -e "$runtime/drivers/registry.lua" ]
  [ ! -e "$runtime/drivers/openai-codex.lua" ]
  [ ! -d "$runtime/drivers" ]
  [ -f "$home/.config/rex-recover/apps.conf" ]
  ! grep -q 'Rex Recover' "$startup"
  printf 'export KEEP_USER_SETTING=1\nexport USER_ADDED_LATER=1\n' >"$environment/expected-startup"
  cmp "$environment/expected-startup" "$startup"
  [ ! -f "$environment/rex-calls" ]
  echo "ok - $platform uninstall stops the service and preserves user settings and app configuration"
  echo "ok - $platform uninstall removes unchanged driver modules and their empty directory"
done

# Optional integrations must truly be optional. Even explicit data-purge consent
# does not extend to modified runtime code or unrelated files in the same tree.
make_environment minimal
platform=Linux
shell=/bin/bash
runtime="$home/.local/share/rex-recover"
startup="$home/.bashrc"
printf 'export KEEP_USER_SETTING=1\n' >"$startup"
run_installer '
n
n
y
'
[ ! -s "$home/.config/rex-recover/apps.conf" ]
[ ! -f "$home/.config/systemd/user/rex-recover.service" ]
! grep -q '^Restart watcher:' "$environment/install.log"
! grep -q 'Rex Recover' "$startup"
: >"$environment/services"
if env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
  PATH="$fixture_path" "$home/.local/bin/rex-recover" service restart \
  >"$environment/no-service.log" 2>&1; then
  echo "FAIL: restart accepted a missing service installation" >&2
  exit 1
fi
grep -q 'service not installed' "$environment/no-service.log"
[ ! -s "$environment/services" ]
echo "ok - restarting without an installed service fails before any service-manager calls"
printf 'user modification\n' >>"$runtime/recovery.lua"
for module in registry.lua openai-codex.lua; do
  printf '\n-- user driver modification\n' >>"$runtime/drivers/$module"
  cp "$runtime/drivers/$module" "$environment/expected-$module"
done
printf '\n// user companion modification\n' >>"$runtime/plugins/opencode-recover/tui.mjs"
cp "$runtime/plugins/opencode-recover/tui.mjs" "$environment/expected-companion.mjs"
printf 'unrelated companion note\n' >"$runtime/plugins/opencode-recover/user-notes"
printf 'unrelated file\n' >"$runtime/user-notes"
printf 'unrelated driver file\n' >"$environment/expected-driver-notes"
cp "$environment/expected-driver-notes" "$runtime/drivers/user-notes"
printf 'return {}\n' >"$environment/expected-user-addon.lua"
cp "$environment/expected-user-addon.lua" "$runtime/drivers/user-addon.lua"
mkdir -p "$home/.local/state/rex-recover/launches"
printf 'state\n' >"$home/.local/state/rex-recover/checkpoint.json"
printf 'launch\n' >"$home/.local/state/rex-recover/launches/block:fixture"
printf 'unrelated state file\n' >"$home/.local/state/rex-recover/user-notes"
printf 'y\ny\nn\nn\nn\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
  PATH="$fixture_path" /bin/sh "$runtime/uninstall.sh" >"$environment/uninstall.log" 2>&1
[ ! -e "$home/.config/rex-recover/apps.conf" ]
[ ! -e "$home/.local/state/rex-recover/checkpoint.json" ]
[ ! -e "$home/.local/state/rex-recover/launches/block:fixture" ]
[ -f "$home/.local/state/rex-recover/user-notes" ]
grep -q 'user modification' "$runtime/recovery.lua"
for module in registry.lua openai-codex.lua; do
  cmp "$environment/expected-$module" "$runtime/drivers/$module"
  grep -Fq "Kept modified file: $runtime/drivers/$module" "$environment/uninstall.log"
  echo "ok - uninstall preserves modified drivers/$module when removal is declined"
done
cmp "$environment/expected-companion.mjs" "$runtime/plugins/opencode-recover/tui.mjs"
[ -f "$runtime/plugins/opencode-recover/user-notes" ]
echo "ok - uninstall preserves edited and unowned companion files when removal is declined"
cmp "$environment/expected-driver-notes" "$runtime/drivers/user-notes"
cmp "$environment/expected-user-addon.lua" "$runtime/drivers/user-addon.lua"
[ -f "$runtime/install.info" ]
[ -f "$runtime/user-notes" ]
echo "ok - optional integration can be declined and purge preserves modified or unrelated files"
echo "ok - uninstall preserves unrelated notes and unowned Lua modules in the drivers directory"

# Planning an install is not consent to apply it. The final "no" must leave
# config, runtime, command directories, and personal shell settings untouched.
make_environment cancelled
platform=Darwin
shell=/bin/zsh
startup="$home/.zshrc"
printf 'export KEEP_USER_SETTING=1\n' >"$startup"
run_installer 'sample-worker
n
n
n
'
[ ! -d "$home/Library/Application Support/rex-recover" ]
[ ! -e "$home/.config/rex-recover/apps.conf" ]
[ ! -e "$home/.local/bin/rex-recover" ]
! grep -q 'Rex Recover' "$startup"
echo "ok - cancelling the final installation confirmation leaves user files untouched"

# Replacing a startup symlink would silently detach a dotfile-manager checkout.
# Both installation and removal must preserve that relationship.
make_environment symlink
platform=Darwin
shell=/bin/zsh
runtime="$home/Library/Application Support/rex-recover"
mkdir "$environment/dotfiles"
printf 'export KEEP_USER_SETTING=1\n' >"$environment/dotfiles/zshrc"
ln -s "$environment/dotfiles/zshrc" "$home/.zshrc"
run_installer 'sample-worker
y
n
y
'
[ -L "$home/.zshrc" ]
printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
  PATH="$fixture_path" /bin/sh "$runtime/uninstall.sh" >"$environment/uninstall.log" 2>&1
[ -L "$home/.zshrc" ]
printf 'export KEEP_USER_SETTING=1\n' >"$environment/expected-startup"
cmp "$environment/expected-startup" "$environment/dotfiles/zshrc"
echo "ok - shell startup symlinks are preserved during installation and removal"

# Markers are not blanket ownership of future user edits inside them. Declining
# removal of an edited block must preserve those edits even during uninstall.
make_environment edited-block
platform=Darwin
shell=/bin/zsh
runtime="$home/Library/Application Support/rex-recover"
startup="$home/.zshrc"
printf 'export KEEP_USER_SETTING=1\n' >"$startup"
run_installer 'sample-worker
y
n
y
'
awk '{ print; if ($0 == "# >>> Rex Recover >>>") print "export USER_EDIT_INSIDE_BLOCK=1" }' \
  "$startup" >"$environment/edited"
cat "$environment/edited" >"$startup"
printf 'y\nn\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
  PATH="$fixture_path" /bin/sh "$runtime/uninstall.sh" >"$environment/uninstall.log" 2>&1
grep -q 'USER_EDIT_INSIDE_BLOCK' "$startup"
grep -q 'Kept the edited shell block' "$environment/uninstall.log"
echo "ok - uninstall asks before removing user edits inside its managed block"

# A systemctl binary does not imply a usable user manager. That limitation must
# not prevent an otherwise valid manual installation or trigger sudo fallback.
make_environment no-manager
platform=Linux
shell=/bin/bash
printf '#!/bin/sh\nexit 1\n' >"$environment/bin/systemctl"
run_installer 'sample-worker
y
y
'
grep -q 'service setup will be skipped' "$environment/install.log"
[ ! -f "$home/.config/systemd/user/rex-recover.service" ]
echo "ok - hosts without a usable user service manager can install without a service"

# A damaged release must not report success when a required runtime helper is missing.
for module in drivers/registry.lua scripts/driver-context.lua; do
  make_environment "missing-${module##*/}"
  platform=Linux
  shell=/bin/bash
  copy_source
  rm -f "$environment/source/$module"
  if printf 'sample-worker\nn\nn\ny\n' |
    env -u XDG_DATA_HOME -u ZDOTDIR -u REX_RECOVER_CONFIG -u REX_RECOVER_STATE_DIR \
      TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
      XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" \
      SHELL="$shell" REX_BIN="$environment/bin/rex" PATH="$fixture_path" \
      /bin/sh "$environment/source/install.sh" >"$environment/install.log" 2>&1; then
    echo "FAIL: installation succeeded without its $module source module" >&2
    exit 1
  fi
  grep -Fq "$module" "$environment/install.log"
  ! grep -q '^Installed\.' "$environment/install.log"
  [ ! -e "$home/.config/rex-recover/apps.conf" ]
  [ ! -e "$home/.local/bin/rex-recover" ]
  [ ! -f "$environment/active" ]
  [ ! -f "$environment/rex-calls" ]
  echo "ok - a missing $module source module fails installation without reporting success"
done

# Names enter a whitespace-separated ownership allowlist, so unsafe Lua filenames
# must fail before any runtime is copied rather than being split into new targets.
for filename in 'unsafe name.lua' 'traversal..lua' Acme-editor.lua; do
  make_environment "unsafe-$filename"
  platform=Linux
  shell=/bin/bash
  copy_source
  printf 'return {}\n' >"$environment/source/drivers/$filename"
  if printf 'sample-worker\nn\nn\ny\n' |
    env -u XDG_DATA_HOME -u ZDOTDIR -u REX_RECOVER_CONFIG -u REX_RECOVER_STATE_DIR \
      TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
      XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" \
      SHELL="$shell" REX_BIN="$environment/bin/rex" PATH="$fixture_path" \
      /bin/sh "$environment/source/install.sh" >"$environment/install.log" 2>&1; then
    echo "FAIL: installation accepted unsafe driver filename: $filename" >&2
    exit 1
  fi
  grep -Fq "Unsafe driver filename: $filename" "$environment/install.log"
  [ ! -d "$home/.local/share/rex-recover" ]
  [ ! -f "$environment/active" ]
  [ ! -f "$environment/rex-calls" ]
done
echo "ok - unsafe driver filenames cannot enter the installation/removal allowlist"

# Unknown platforms must not receive guessed paths or partially installed files.
make_environment unsupported
if env TEST_PLATFORM=UnsupportedOS TEST_ENV="$environment" HOME="$home" \
  PATH="$fixture_path" /bin/sh "$root/install.sh" >"$environment/install.log" 2>&1; then
  echo "FAIL: unsupported platform was accepted" >&2
  exit 1
fi
grep -q 'Unsupported platform' "$environment/install.log"
[ ! -e "$home/.local" ]
echo "ok - unsupported platforms are rejected before installation changes"

make_opencode() {
  cat >"$environment/bin/opencode" <<'SH'
#!/bin/sh
echo "Unexpected OpenCode execution" >>"$TEST_ENV/opencode-calls"
exit 1
SH
  chmod +x "$environment/bin/opencode"
}

for preference in missing true false absent; do
  make_environment "opencode-native-title-$preference"
  platform=Linux
  shell=/bin/bash
  runtime="$home/.local/share/rex-recover"
  cli="$home/.config/opencode/cli.json"
  plugin="$home/.config/opencode/plugins/rex-recover"
  make_opencode
  copy_source
  for companion in tui.mjs server.mjs rpc.mjs; do
    printf 'throw new Error("installation must not execute companion modules");\n' \
      >"$environment/source/plugins/opencode-recover/$companion"
  done
  if [ "$preference" != missing ]; then
    mkdir -p "$(dirname "$cli")"
    if [ "$preference" = absent ]; then
      printf '{ "terminal": { "keep": 7 }, "plugins": ["*", "other"] }\n' >"$cli"
    else
      printf '{ "terminal": { "title": %s, "keep": 7 }, "plugins": ["*", "other"] }\n' \
        "$preference" >"$cli"
    fi
    cp "$cli" "$environment/expected-cli"
    if [ "$preference" = true ]; then
      mkdir "$environment/dotfiles"
      mv "$cli" "$environment/dotfiles/cli.json"
      chmod 640 "$environment/dotfiles/cli.json"
      ln -s "$environment/dotfiles/cli.json" "$cli"
    fi
  fi
  run_installer '
n
n
y
y
' "$environment/source"
  for companion in package.json tui.mjs server.mjs rpc.mjs; do
    cmp "$environment/source/plugins/opencode-recover/$companion" "$plugin/$companion"
  done
  [ -z "$(awk -F '\t' '$1 == "priorTitle" || $1 == "priorTerminal" { printf "%s", $2 }' "$runtime/install.info")" ]
  if [ "$preference" = missing ]; then
    [ ! -e "$cli" ]
  else
    cmp "$environment/expected-cli" "$cli"
  fi
  if [ "$preference" = true ]; then
    [ -L "$cli" ]
    [ "$(ls -l "$environment/dotfiles/cli.json" | cut -c1-10)" = "-rw-r-----" ]
  fi
  [ "$(find "$home/.config/opencode" -name 'cli.json.rex-recover-backup-*' | wc -l | tr -d ' ')" = 0 ]
  grep -Fq 'After a Rex crash, this helper lets Rex reopen the saved conversation you were using,' "$environment/install.log"
  grep -Fq 'rather than just relaunching OpenCode.' "$environment/install.log"
  grep -Fq 'Install/update the optional OpenCode recovery helper? [y/N]' "$environment/install.log"
  ! grep -q 'terminal.title=false' "$environment/install.log"
  # Native discovery does not need to rewrite CLI settings to remove the package.
  # Node/Bun may have been removed since the helper was installed.
  if [ "$preference" = true ]; then rm "$environment/bin/node"; fi
  if ! printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" PATH="$fixture_path" "$home/.local/bin/rex-recover-uninstall" \
    >"$environment/uninstall.log" 2>&1; then
    cat "$environment/uninstall.log" >&2
    exit 1
  fi
  if [ "$preference" = missing ]; then
    [ ! -e "$cli" ]
  else
    cmp "$environment/expected-cli" "$cli"
  fi
  if [ "$preference" = true ]; then
    [ -L "$cli" ]
    [ "$(ls -l "$environment/dotfiles/cli.json" | cut -c1-10)" = "-rw-r-----" ]
  fi
  [ ! -e "$plugin" ]
  [ ! -e "$environment/opencode-calls" ]
  [ ! -e "$environment/rex-calls" ]
  [ ! -e "$environment/active" ]
done
echo "ok - fresh discovery leaves native title preferences byte-exact and absent CLI settings absent without executing copied modules"
echo "ok - the installed uninstaller removes a discovered package even if Node/Bun is gone"

# Detection must not execute the CLI (even --version can start its service).
make_environment opencode-opt-in
platform=Linux
shell=/bin/bash
runtime="$home/.local/share/rex-recover"
plugin="$home/.config/opencode/plugins/rex-recover"
cli="$home/.config/opencode/cli.json"
make_opencode
mkdir -p "$(dirname "$cli")"
printf '{"$schema":"https://opencode.ai/v2/cli.json","theme":{"name":"personal"},"terminal":{"title":true,"keep":7},"plugins":[{"package":"other","options":{"keep":true}}]}\n' \
  >"$cli"
run_installer '
n
n
y
y
'
if [ ! -f "$plugin/server.mjs" ]; then
  echo "FAIL: consenting to OpenCode setup did not install the complete global companion" >&2
  exit 1
fi
"$node_bin" --input-type=module - "$cli" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
assert.deepEqual(JSON.parse(readFileSync(process.argv[2], 'utf8')), {
    $schema: 'https://opencode.ai/v2/cli.json',
    theme: { name: 'personal' },
    terminal: { title: true, keep: 7 },
    plugins: [{ package: 'other', options: { keep: true } }],
});
JS
for companion in package.json tui.mjs server.mjs rpc.mjs; do
  cmp "$root/plugins/opencode-recover/$companion" "$plugin/$companion"
  printf 'owned\t%s\t%s\n' "$(cksum <"$plugin/$companion")" "$plugin/$companion" \
    >"$environment/expected-global-ownership"
  awk -F '\t' -v path="$plugin/$companion" '$1 == "owned" && $3 == path' \
    "$runtime/install.info" >"$environment/global-ownership"
  cmp "$environment/expected-global-ownership" "$environment/global-ownership"
done
[ ! -e "$environment/opencode-calls" ]
[ ! -e "$environment/active" ]
[ ! -s "$home/.config/rex-recover/apps.conf" ]
grep -Fq "$plugin" "$environment/install.log"
grep -Fq 'REX_RECOVER_SESSIONS=opencode' "$environment/install.log"
echo "ok - OpenCode detection asks separately, copies all four files, and preserves unrelated CLI settings"

printf 'user notes\n' >"$plugin/user-notes"
printf '{"unrelated":true}\n' >"$home/.config/opencode/opencode.json"
cp "$home/.config/opencode/opencode.json" "$environment/expected-server-config"
# Simulate an older install that owned terminal.title=false. Declining an
# upgrade must preserve that legacy ownership so uninstall can still restore it.
"$node_bin" --input-type=module - "$cli" "$runtime/install.info" <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
const file = process.argv[2];
const config = JSON.parse(readFileSync(file));
config.terminal.title = false;
writeFileSync(file, `${JSON.stringify(config)}\n`);
const manifest = process.argv[3];
writeFileSync(manifest, readFileSync(manifest, 'utf8')
    .replace(/^priorTitle\t.*$/m, 'priorTitle\ttrue')
    .replace(/^priorTerminal\t.*$/m, 'priorTerminal\tpresent'));
JS
run_installer '
n
n
n
y
'
"$node_bin" --input-type=module - "$cli" "$runtime" "$plugin" <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const file = process.argv[2];
const config = JSON.parse(readFileSync(file, 'utf8'));
config.terminal.later = 'preserve';
config.tabs = { mode: 'off' };
config.plugins.push(`${process.argv[3]}/plugins/opencode-recover`, pathToFileURL(process.argv[4]).href);
writeFileSync(file, `${JSON.stringify(config)}\n`);
JS
cp "$cli" "$environment/expected-cli-backup"
printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
  XDG_CONFIG_HOME="$home/.config" PATH="$fixture_path" "$home/.local/bin/rex-recover-uninstall" \
  >"$environment/uninstall.log" 2>&1 || {
    cat "$environment/uninstall.log" >&2
    echo "FAIL: uninstall could not remove its optional global companion" >&2
    exit 1
  }
"$node_bin" --input-type=module - "$cli" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
assert.deepEqual(JSON.parse(readFileSync(process.argv[2], 'utf8')), {
    $schema: 'https://opencode.ai/v2/cli.json',
    theme: { name: 'personal' },
    terminal: { title: true, keep: 7, later: 'preserve' },
    plugins: [{ package: 'other', options: { keep: true } }],
    tabs: { mode: 'off' },
});
JS
for companion in package.json tui.mjs server.mjs rpc.mjs; do [ ! -e "$plugin/$companion" ]; done
[ ! -e "$runtime/plugins/opencode-recover" ]
set -- "$cli".rex-recover-backup-*
[ "$#" = 1 ]
cmp "$environment/expected-cli-backup" "$1"
[ -f "$plugin/user-notes" ]
cmp "$environment/expected-server-config" "$home/.config/opencode/opencode.json"
[ ! -e "$environment/opencode-calls" ]
echo "ok - after a declined upgrade, installed uninstall removes legacy paths and restores only its old title override; unrelated preferences, notes and backups survive"

make_environment opencode-legacy-upgrade
platform=Linux
shell=/bin/bash
runtime="$home/.local/share/rex-recover"
plugin="$home/.config/opencode/plugins/rex-recover"
cli="$home/.config/opencode/cli.json"
make_opencode
run_installer '
n
n
y
y
'
"$node_bin" --input-type=module - "$cli" "$runtime/install.info" <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
writeFileSync(process.argv[2], '{"terminal":{"title":false,"keep":4},"plugins":["*","-rex-recover.opencode","-other"]}\n');
const manifest = process.argv[3];
writeFileSync(manifest, readFileSync(manifest, 'utf8')
    .replace(/^priorTitle\t.*$/m, 'priorTitle\ttrue')
    .replace(/^priorTerminal\t.*$/m, 'priorTerminal\tpresent'));
JS
run_installer '
n
n
y
y
'
"$node_bin" --input-type=module - "$cli" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
const config = JSON.parse(readFileSync(process.argv[2]));
assert.deepEqual(config, { terminal: { title: true, keep: 4 }, plugins: ['*', '-other'] });
config.terminal.title = false;
writeFileSync(process.argv[2], `${JSON.stringify(config)}\n`);
JS
[ -z "$(awk -F '\t' '$1 == "priorTitle" || $1 == "priorTerminal" { printf "%s", $2 }' "$runtime/install.info")" ]
cp "$cli" "$environment/expected-cli"
printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
  XDG_CONFIG_HOME="$home/.config" PATH="$fixture_path" /bin/sh "$runtime/uninstall.sh" \
  >"$environment/uninstall.log" 2>&1
cmp "$environment/expected-cli" "$cli"
[ ! -e "$plugin" ]
[ ! -e "$environment/opencode-calls" ]
echo "ok - upgrading restores legacy-owned false once, clears old ownership, and later uninstall preserves the user's false title preference"

make_environment opencode-symlink-idempotent
platform=Linux
shell=/bin/bash
runtime="$home/.local/share/rex-recover"
plugin="$home/.config/opencode/plugins/rex-recover"
cli="$home/.config/opencode/cli.json"
make_opencode
mkdir -p "$(dirname "$cli")" "$environment/dotfiles"
"$node_bin" --input-type=module - "$environment/dotfiles/cli.json" "$runtime" "$plugin" <<'JS'
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
writeFileSync(process.argv[2], JSON.stringify({
    terminal: { keep: 1 },
    mouse: false,
    plugins: [
        `${process.argv[3]}/plugins/opencode-recover`,
        pathToFileURL(process.argv[4]).href,
        '*',
        '-rex-recover.opencode',
        '-other.opencode',
        { package: 'other', options: { enabled: true } },
    ],
}));
JS
chmod 640 "$environment/dotfiles/cli.json"
ln -s "$environment/dotfiles/cli.json" "$cli"
cp "$cli" "$environment/expected-before-consent"
run_installer '
n
n
n
y
'
cmp "$environment/expected-before-consent" "$cli"
[ ! -e "$plugin" ]
run_installer '
n
n
y
y
'
cp "$cli" "$environment/expected-installed-cli"
set -- "$cli".rex-recover-backup-*
[ "$#" = 1 ]
cmp "$environment/expected-before-consent" "$1"
"$node_bin" --input-type=module - "$cli" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
assert.deepEqual(JSON.parse(readFileSync(process.argv[2])), {
    terminal: { keep: 1 },
    mouse: false,
    plugins: ['*', '-other.opencode', { package: 'other', options: { enabled: true } }],
});
JS
printf 'keep notes\n' >"$plugin/notes"
run_installer '
n
n
y
y
'
cmp "$environment/expected-installed-cli" "$cli"
set -- "$cli".rex-recover-backup-*
[ "$#" = 1 ]
cmp "$environment/expected-before-consent" "$1"
[ -L "$cli" ]
[ "$(ls -l "$environment/dotfiles/cli.json" | cut -c1-10)" = "-rw-r-----" ]
[ -f "$plugin/notes" ]
if [ -d "$home/.config/opencode/rex-recover-backups" ]; then
  echo "FAIL: an identical companion reinstall created unnecessary package backups" >&2
  exit 1
fi
echo "ok - idempotent companion reinstalls preserve CLI symlinks, permissions, and global notes without duplicate backups"

copy_source
printf '\n// fixture package update\n' >>"$environment/source/plugins/opencode-recover/server.mjs"
run_installer '
n
n
y
y
' "$environment/source"
[ -f "$plugin/notes" ]
cmp "$environment/source/plugins/opencode-recover/server.mjs" "$plugin/server.mjs"
[ "$(find "$home/.config/opencode/plugins" -name package.json | wc -l | tr -d ' ')" = 1 ]
[ "$(find "$home/.config/opencode/rex-recover-backups" -name package.json | wc -l | tr -d ' ')" = 1 ]
# Later title edits and modifications to one owned global file remain user work.
printf '\n// user change\n' >>"$plugin/rpc.mjs"
# Replacing a managed file with a symlink is also an edit, even if bytes match.
mv "$plugin/server.mjs" "$environment/user-server.mjs"
ln -s "$environment/user-server.mjs" "$plugin/server.mjs"
"$node_bin" --input-type=module - "$cli" <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
const file = process.argv[2];
const config = JSON.parse(readFileSync(file));
config.terminal.title = true;
writeFileSync(file, `${JSON.stringify(config)}\n`);
JS
printf 'y\nn\nn\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
  XDG_CONFIG_HOME="$home/.config" PATH="$fixture_path" "$home/.local/bin/rex-recover-uninstall" \
  >"$environment/uninstall.log" 2>&1
[ -L "$cli" ]
[ "$(ls -l "$environment/dotfiles/cli.json" | cut -c1-10)" = "-rw-r-----" ]
"$node_bin" --input-type=module - "$cli" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
assert.deepEqual(JSON.parse(readFileSync(process.argv[2])), {
    terminal: { keep: 1, title: true },
    mouse: false,
    plugins: ['*', '-other.opencode', { package: 'other', options: { enabled: true } }],
});
JS
grep -Fq "Kept modified file: $plugin/rpc.mjs" "$environment/uninstall.log"
[ -f "$plugin/rpc.mjs" ]
[ -L "$plugin/server.mjs" ]
[ -f "$environment/user-server.mjs" ]
[ ! -e "$plugin/package.json" ]
[ -f "$plugin/notes" ]
[ "$(find "$home/.config/opencode/rex-recover-backups" -name package.json | wc -l | tr -d ' ')" = 1 ]
echo "ok - package updates retain notes and keep backups outside discovery; uninstall preserves later title changes and edited companion files"

for presence in absent nonexecutable declined; do
  make_environment "opencode-$presence-no-interpreter"
  platform=Linux
  shell=/bin/bash
  cli="$home/.config/opencode/cli.json"
  plugin="$home/.config/opencode/plugins/rex-recover"
  mkdir -p "$(dirname "$cli")"
  printf '// existing JSONC must not be read or touched when declined\n' >"$cli"
  cp "$cli" "$environment/expected-cli"
  rm "$environment/bin/node"
  case "$presence" in
    nonexecutable) make_opencode; chmod -x "$environment/bin/opencode" ;;
    declined) make_opencode ;;
  esac
  if [ "$presence" = declined ]; then
    # A manually copied package at our usual path is not installer-owned.
    mkdir -p "${plugin%/*}"
    cp -R "$root/plugins/opencode-recover" "$plugin"
    run_installer '
n
n

y
'
    grep -Fq 'Install/update the optional OpenCode recovery helper? [y/N]' "$environment/install.log"
    printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
      XDG_CONFIG_HOME="$home/.config" PATH="$fixture_path" "$home/.local/bin/rex-recover-uninstall" \
      >"$environment/uninstall.log" 2>&1
    diff -r "$root/plugins/opencode-recover" "$plugin"
  else
    run_installer '
n
n
y
'
    ! grep -Fq 'Install/update the optional OpenCode recovery helper?' "$environment/install.log"
    [ ! -e "$home/.config/opencode/plugins" ]
  fi
  cmp "$environment/expected-cli" "$cli"
  [ ! -e "$environment/opencode-calls" ]
done
echo "ok - absent, non-executable, and declined OpenCode require no interpreter; uninstall preserves manual packages"

# Errors during opt-in planning must precede runtime, service, shell, and CLI writes.
for problem in no-interpreter invalid-json invalid-shape own-options inline override symlink-folder concurrent; do
  make_environment "opencode-reject-$problem"
  platform=Linux
  shell=/bin/bash
  runtime="$home/.local/share/rex-recover"
  cli="$home/.config/opencode/cli.json"
  plugin="$home/.config/opencode/plugins/rex-recover"
  make_opencode
  mkdir -p "$(dirname "$cli")"
  printf '{"theme":{"name":"private-sentinel"}}\n' >"$cli"
  case "$problem" in
    no-interpreter) rm "$environment/bin/node"; expected='Node.js or Bun' ;;
    invalid-json) printf '{// private-sentinel\n"plugins":["-rex-recover.opencode"]}\n' >"$cli"; expected='strict JSON' ;;
    invalid-shape) printf '{"terminal":[],"plugins":["-rex-recover.opencode"]}\n' >"$cli"; expected='settings shape' ;;
    own-options)
      "$node_bin" --input-type=module - "$cli" "$runtime" <<'JS'
import { writeFileSync } from 'node:fs';
writeFileSync(process.argv[2], JSON.stringify({
    plugins: [{ package: `${process.argv[3]}/plugins/opencode-recover`, options: { private: true } }],
}));
JS
      expected='custom options' ;;
    inline) expected=OPENCODE_CLI_CONFIG_CONTENT ;;
    override) expected=OPENCODE_CONFIG_DIR ;;
    symlink-folder)
      mkdir -p "${plugin%/*}" "$environment/user-plugin"
      ln -s "$environment/user-plugin" "$plugin"
      expected=symlinked ;;
    concurrent)
      printf '{"plugins":["-rex-recover.opencode"]}\n' >"$cli"
      rm "$environment/bin/node"
      cat >"$environment/bin/node" <<'SH'
#!/bin/sh
if [ "$2" = check ]; then
  printf '{"mouse":false}\n' >"$3"
fi
exec "$TEST_NODE" "$@"
SH
      chmod +x "$environment/bin/node"
      expected='changed during planning' ;;
  esac
  cp "$cli" "$environment/expected-cli"
  set -- TEST_NODE="$node_bin"
  case "$problem" in
    inline) set -- "$@" OPENCODE_CLI_CONFIG_CONTENT='{}' ;;
    override) set -- "$@" OPENCODE_CONFIG_DIR=/fixture/custom ;;
  esac
  if install_command '
n
n
y
y
' "$root" "$@"; then
    echo "FAIL: installer accepted unsafe OpenCode setup: $problem" >&2
    exit 1
  fi
  grep -Fq "$expected" "$environment/install.log"
  ! grep -q 'private-sentinel' "$environment/install.log"
  [ ! -e "$runtime" ]
  [ ! -e "$home/.local/bin/rex-recover" ]
  [ ! -e "$home/.config/rex-recover/apps.conf" ]
  [ ! -e "$home/.bashrc" ]
  [ ! -e "$environment/active" ]
  [ ! -e "$environment/opencode-calls" ]
  if [ "$problem" != concurrent ]; then cmp "$environment/expected-cli" "$cli"; fi
done
echo "ok - unsafe OpenCode settings, missing interpreters, overrides, symlinked packages, and concurrent edits fail before installation writes"

make_environment opencode-final-cancel
platform=Linux
shell=/bin/bash
cli="$home/.config/opencode/cli.json"
make_opencode
mkdir -p "$(dirname "$cli")"
printf '{"terminal":{"title":true},"mouse":false,"plugins":["*","-rex-recover.opencode","-other"]}\n' >"$cli"
cp "$cli" "$environment/expected-cli"
run_installer '
n
n
y
n
'
cmp "$environment/expected-cli" "$cli"
[ ! -e "$home/.config/opencode/plugins" ]
[ ! -e "$home/.local" ]
[ ! -e "$environment/opencode-calls" ]
echo "ok - final cancellation after companion consent makes no persistent changes"

make_environment opencode-selective-shell
platform=Linux
shell=/bin/bash
runtime="$home/.local/share/rex-recover"
make_opencode
run_installer 'opencode sample-worker
y
n
y
y
'
if ! grep -Fq 'export REX_RECOVER_SESSIONS=opencode' "$home/.bashrc"; then
  echo "FAIL: accepted OpenCode recovery did not enable selective recovery in its managed shell block" >&2
  exit 1
fi
for prior in empty 0 claude; do
  case "$prior" in empty) value= ;; *) value=$prior ;; esac
  expected=${value:-opencode}
  env HOME="$home" PATH="$fixture_path" REX_SESSION=session:fixture REX_BLOCK=block:fixture \
    REX_RECOVER_SESSIONS="$value" /bin/bash -c \
    '. "$1"; test "$REX_RECOVER_SESSIONS" = "$2"' -- "$home/.bashrc" "$expected"
done
env -u REX_SESSION -u REX_BLOCK -u REX_RECOVER_SESSIONS HOME="$home" PATH="$fixture_path" \
  /bin/bash -c '. "$1"; test -z "${REX_RECOVER_SESSIONS:-}"' -- "$home/.bashrc"
run_installer '
y
n
n
y
'
grep -Fq 'export REX_RECOVER_SESSIONS=opencode' "$home/.bashrc"
echo "ok - accepted shell integration scopes activation to OpenCode inside Rex and respects explicit user values and prior ownership"

make_environment opencode-bun-only
platform=Linux
shell=/bin/bash
make_opencode
rm "$environment/bin/node"
# The stand-in implements the same stdlib command interface without requiring
# an additional interpreter installation on the test host.
ln -s "$node_bin" "$environment/bin/bun"
run_installer '
n
n
y
y
'
[ -f "$home/.config/opencode/plugins/rex-recover/server.mjs" ]
[ ! -e "$environment/opencode-calls" ]
echo "ok - companion setup can select Bun when Node is unavailable"

for corruption in global-owned prior-title; do
  make_environment "opencode-corrupt-$corruption"
  platform=Linux
  shell=/bin/bash
  runtime="$home/.local/share/rex-recover"
  plugin="$home/.config/opencode/plugins/rex-recover"
  cli="$home/.config/opencode/cli.json"
  make_opencode
  mkdir -p "$(dirname "$cli")"
  printf '{"mouse":false}\n' >"$cli"
  run_installer '
n
n
y
y
'
  if [ "$corruption" = global-owned ]; then
    printf 'user notes\n' >"$plugin/notes"
    printf 'owned\t%s\t%s\n' "$(cksum <"$plugin/notes")" "$plugin/notes" >>"$runtime/install.info"
    expected='Unexpected owned path in manifest'
  else
    sed 's/^priorTitle.*/priorTitle	bad/' "$runtime/install.info" >"$environment/edited-manifest"
    cat "$environment/edited-manifest" >"$runtime/install.info"
    expected='Invalid priorTitle'
  fi
  cp "$cli" "$environment/expected-cli"
  if printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" PATH="$fixture_path" /bin/sh "$root/uninstall.sh" \
    >"$environment/uninstall.log" 2>&1; then
    echo "FAIL: uninstaller accepted corrupt OpenCode ownership" >&2
    exit 1
  fi
  grep -Fq "$expected" "$environment/uninstall.log"
  cmp "$environment/expected-cli" "$cli"
  [ -f "$runtime/recovery.lua" ]
  [ -f "$plugin/package.json" ]
done
echo "ok - global companion ownership and title metadata are validated before uninstall changes"

for ownership in changed manual; do
  make_environment "codex-uninstall-$ownership"
  platform=Linux
  shell=/bin/bash
  runtime="$home/.local/share/rex-recover"
  codex_dir="$home/Recorded Codex Home"
  mkdir -p "$codex_dir" "$home/.codex"
  printf '[features]\ndaemon_auto_start = false\nother_feature = true\n' >"$codex_dir/config.toml"
  cp "$codex_dir/config.toml" "$home/.codex/config.toml"
  cp "$codex_dir/config.toml" "$environment/expected-config"
  run_installer '
n
n
y
'
  if [ "$ownership" = changed ]; then
    printf 'codex_daemon_config\t%s\n' "$codex_dir/config.toml" >>"$runtime/install.info"
  fi
  # Uninstall reads the recorded config even if the current CODEX_HOME differs.
  # The stub catches any attempted Codex CLI action, including daemon stop.
  cp "$environment/bin/rex" "$environment/bin/codex"
  if ! printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
    CODEX_HOME="$home/.codex" PATH="$fixture_path" "$home/.local/bin/rex-recover-uninstall" \
    >"$environment/uninstall.log" 2>&1; then
    cat "$environment/uninstall.log" >&2
    exit 1
  fi
  cmp "$environment/expected-config" "$codex_dir/config.toml"
  cmp "$environment/expected-config" "$home/.codex/config.toml"
  [ ! -e "$environment/rex-calls" ]
  [ ! -e "$runtime/install.info" ]
  if [ "$ownership" = changed ]; then
    grep -Fq "$codex_dir/config.toml" "$environment/uninstall.log" || {
      echo "FAIL: uninstall did not remind the user how to undo its Codex daemon change" >&2
      exit 1
    }
    grep -Fq 'remove only daemon_auto_start under [features]' "$environment/uninstall.log"
  elif grep -Fq daemon_auto_start "$environment/uninstall.log"; then
    echo "FAIL: uninstall claimed ownership of the user's manual Codex preference" >&2
    exit 1
  fi
done
echo "ok - uninstall reminds only for installer-owned Codex daemon changes and never edits its config or calls Codex"

make_environment codex-uninstall-hook
platform=Linux
shell=/bin/bash
runtime="$home/.local/share/rex-recover"
codex_dir="$home/Recorded Codex Home"
mkdir -p "$codex_dir" "$home/.codex"
hooks="$codex_dir/hooks.json"
cat >"$hooks" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"startup|resume","hooks":[{"type":"command","command":"echo keep-start"}]}],"Stop":[{"hooks":[{"type":"command","command":"echo keep-stop"}]}]}}
JSON
cp "$hooks" "$environment/expected-hooks"
cp "$hooks" "$home/.codex/hooks.json"
cp "$hooks" "$environment/original-hooks"
printf '[hooks.state."personal"]\ntrusted_hash = "sha256:personal"\n' >"$codex_dir/config.toml"
cp "$codex_dir/config.toml" "$environment/expected-trust"
cp "$environment/bin/rex" "$environment/bin/codex"
if ! install_command 'codex
n
n
n
y
y
' "$root" CODEX_HOME="$codex_dir"; then
  cat "$environment/install.log" >&2
  exit 1
fi
[ -f "$runtime/scripts/codex-session-start.mjs" ]
grep -Fq 'codex-session-start.mjs' "$hooks"
# Losing the parser cannot be allowed to leave a runnable registration without
# its script. Fail before any files are removed; retry with the parser available.
cp "$hooks" "$environment/hooks-after-install"
rm "$environment/bin/node"
if printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
  CODEX_HOME="$home/.codex" PATH="$fixture_path" "$home/.local/bin/rex-recover-uninstall" \
  >"$environment/no-parser.log" 2>&1; then
  echo "FAIL: uninstall claimed success without removing its Codex hook registration" >&2
  exit 1
fi
grep -Fq 'Node.js or Bun' "$environment/no-parser.log"
cmp "$environment/hooks-after-install" "$hooks"
[ -f "$runtime/scripts/codex-session-start.mjs" ]
ln -s "$node_bin" "$environment/bin/node"
# A command edited after installation may still point to the runtime.
sed 's/codex-session-start\.mjs/codex-session-start.mjs --extra/' \
  "$environment/hooks-after-install" >"$environment/edited-hooks"
cp "$environment/edited-hooks" "$hooks"
if printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
  CODEX_HOME="$home/.codex" PATH="$fixture_path" "$home/.local/bin/rex-recover-uninstall" \
  >"$environment/edited-hook.log" 2>&1; then
  echo "FAIL: uninstall left an edited Codex hook dangling" >&2
  exit 1
fi
grep -Fq "Review the Codex hooks in $hooks manually" "$environment/edited-hook.log"
cmp "$environment/edited-hooks" "$hooks"
[ -f "$runtime/scripts/codex-session-start.mjs" ]
[ -f "$runtime/install.info" ]
cp "$environment/hooks-after-install" "$hooks"
# Even a known managed command must not leave a copy in another event dangling.
"$node_bin" --input-type=module - "$hooks" <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
const [hooksFile] = process.argv.slice(2);
const config = JSON.parse(readFileSync(hooksFile, 'utf8'));
config.hooks.Stop.push(config.hooks.SessionStart.at(-1));
writeFileSync(hooksFile, `${JSON.stringify(config)}\n`);
JS
cp "$hooks" "$environment/duplicated-hook"
if printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
  CODEX_HOME="$home/.codex" PATH="$fixture_path" "$home/.local/bin/rex-recover-uninstall" \
  >"$environment/duplicated-hook.log" 2>&1; then
  echo "FAIL: uninstall left a duplicate Codex hook in the Stop event dangling" >&2
  exit 1
fi
grep -Fq "Remove or repoint only the \"Stop\" hook command that uses $runtime/scripts/codex-session-start.mjs in $hooks" \
  "$environment/duplicated-hook.log"
cmp "$environment/duplicated-hook" "$hooks"
[ -f "$runtime/scripts/codex-session-start.mjs" ]
[ -f "$runtime/install.info" ]
cp "$environment/hooks-after-install" "$hooks"
# Add a later user group after installation. Its Codex trust key depends on
# the group index, so removing Rex's group must leave an empty slot.
"$node_bin" --input-type=module - "$hooks" "$environment/expected-hooks" <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
const [hooksFile, expectedFile] = process.argv.slice(2);
const later = { hooks: [{ type: 'command', command: 'echo keep-later' }] };
const updated = JSON.parse(readFileSync(hooksFile, 'utf8'));
updated.hooks.SessionStart.push(later);
writeFileSync(hooksFile, `${JSON.stringify(updated)}\n`);
const expected = JSON.parse(readFileSync(expectedFile, 'utf8'));
expected.hooks.SessionStart.push({ hooks: [] }, later);
writeFileSync(expectedFile, `${JSON.stringify(expected)}\n`);
JS
if ! printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
  CODEX_HOME="$home/.codex" PATH="$fixture_path" "$home/.local/bin/rex-recover-uninstall" \
  >"$environment/uninstall.log" 2>&1; then
  cat "$environment/uninstall.log" >&2
  exit 1
fi
"$node_bin" --input-type=module - "$environment/expected-hooks" "$hooks" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
assert.deepEqual(JSON.parse(readFileSync(process.argv[3])), JSON.parse(readFileSync(process.argv[2])));
JS
cmp "$environment/original-hooks" "$home/.codex/hooks.json"
cmp "$environment/expected-trust" "$codex_dir/config.toml"
[ ! -e "$runtime/scripts/codex-session-start.mjs" ]
[ ! -e "$runtime/install.info" ]
[ ! -e "$environment/rex-calls" ]
echo "ok - installed uninstall removes only its Codex hook and preserves other hooks, trust, and edited commands"

make_environment codex-uninstall-manual-hook
platform=Linux
shell=/bin/bash
runtime="$home/.local/share/rex-recover"
codex_dir="$home/Recorded Codex Home"
mkdir -p "$codex_dir"
hooks="$codex_dir/hooks.json"
printf 'keep unrelated settings\n' >"$codex_dir/personal.txt"
cp "$environment/bin/rex" "$environment/bin/codex"
"$node_bin" --input-type=module - "$hooks" "$environment/expected-hooks" \
  "$runtime/scripts/codex-session-start.mjs" <<'JS'
import { realpathSync, writeFileSync } from 'node:fs';
const [hooks, expected, runtime] = process.argv.slice(2);
const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
const personal = { hooks: [{ type: 'command', command: 'echo keep' }] };
const manual = { hooks: [{ type: 'command', command: `exec ${quote(realpathSync(process.execPath))} ${quote(runtime)}` }] };
writeFileSync(hooks, JSON.stringify({ hooks: { SessionStart: [personal, manual] } }));
writeFileSync(expected, JSON.stringify({ hooks: { SessionStart: [personal] } }));
JS
cp "$hooks" "$environment/manual-hooks"
if ! install_command 'codex
n
y
n
y
y
' "$root" CODEX_HOME="$codex_dir"; then
  cat "$environment/install.log" >&2
  exit 1
fi
cmp "$environment/manual-hooks" "$hooks"
cp "$environment/services" "$environment/services-before-uninstall"
if printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
  PATH="$fixture_path" "$home/.local/bin/rex-recover-uninstall" >"$environment/blocked-uninstall.log" 2>&1; then
  echo "FAIL: uninstall left an existing user-owned Codex hook dangling" >&2
  exit 1
fi
grep -Fq "Remove or repoint only the \"SessionStart\" hook command that uses $runtime/scripts/codex-session-start.mjs in $hooks" \
  "$environment/blocked-uninstall.log"
cmp "$environment/manual-hooks" "$hooks"
cmp "$environment/services-before-uninstall" "$environment/services"
[ -f "$runtime/scripts/codex-session-start.mjs" ]
[ -f "$runtime/install.info" ]
cp "$environment/expected-hooks" "$hooks"
printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
  PATH="$fixture_path" "$home/.local/bin/rex-recover-uninstall" >"$environment/uninstall.log" 2>&1
cmp "$environment/expected-hooks" "$hooks"
grep -Fxq 'keep unrelated settings' "$codex_dir/personal.txt"
[ ! -e "$runtime/install.info" ]
[ ! -e "$runtime/scripts/codex-session-start.mjs" ]
[ ! -e "$environment/rex-calls" ]
echo "ok - installed uninstall keeps a manually configured Codex hook and its helper until the user removes the reference"

# The default suite reaches the helper's public command seam too.
"$node_bin" --test "$root/tests/opencode-config.mjs"
