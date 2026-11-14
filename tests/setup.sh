#!/bin/sh
# Installation touches startup files and services; tests must prove its behavior
# without obtaining authority over the developer's actual home or service manager.
# Keep the sandbox private but retained so a failure's generated files are inspectable.
set -eu
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-setup-tests.XXXXXX")
temporary=$(CDPATH= cd -- "$temporary" && pwd -P)
trap 'echo "Setup test artifacts: $temporary"' EXIT

# Special characters in the fake home expose shell/XML/systemd escaping mistakes
# that a simple path would hide. Every service operation goes through a fake
# executable; unexpected Rex use is evidence of violating installer boundaries.
make_environment() {
  environment="$temporary/$1"
  home="$environment/User's Home & 50% dollars\$"
  mkdir -p "$environment/bin" "$home"
  # One fake dispatcher keeps the platform cases comparable. Unknown operations
  # fail rather than silently pretending an unmodeled service action succeeded.
  for tool in uname id launchctl systemctl rex; do
    cat >"$environment/bin/$tool" <<'SH'
#!/bin/sh
case "${0##*/}" in
  uname) printf '%s\n' "$TEST_PLATFORM" ;;
  id) if [ "$1" = -u ]; then echo 501; else /usr/bin/id "$@"; fi ;;
  rex) echo "Unexpected Rex execution" >>"$TEST_ENV/rex-calls"; exit 1 ;;
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
run_installer() {
  answers=$1
  if ! printf '%s' "$answers" | env -u XDG_DATA_HOME -u ZDOTDIR -u REX_RECOVER_CONFIG \
    -u REX_RECOVER_STATE_DIR TEST_PLATFORM="$platform" TEST_ENV="$environment" \
    HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" \
    SHELL="$shell" REX_BIN="$environment/bin/rex" PATH="$environment/bin:$PATH" \
    /bin/sh "$root/install.sh" >"$environment/install.log" 2>&1; then
    cat "$environment/install.log" >&2
    exit 1
  fi
}

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
  env HOME="$home" PATH="$environment/bin:$PATH" \
    REX_SESSION=session:fixture REX_BLOCK=block:fixture \
    "$shell" -c '. "$1"; type sample-worker >/dev/null; test "$KEEP_USER_SETTING" = 1' \
    -- "$startup"
  echo "ok - $platform installer creates a configured runtime, shell hook, and user service"

  # Run the installed launcher, not just the checkout, to catch omitted runtime
  # helpers. Assert the complete service log so no Rex/system-wide restart slips in.
  : >"$environment/services"
  env -u REX_RECOVER_CONFIG -u REX_RECOVER_STATE_DIR \
    TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    PATH="$environment/bin:$PATH" "$home/.local/bin/rex-recover" service restart \
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
    PATH="$environment/bin:$PATH" "$home/.local/bin/rex-recover" service restart \
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
    PATH="$environment/bin:$PATH" "$home/.local/bin/rex-recover" service restart \
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
      XDG_CONFIG_HOME="$home/.config" PATH="$environment/bin:$PATH" \
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
    PATH="$environment/bin:$PATH" /bin/sh "$runtime/uninstall.sh" \
    >"$environment/cancel-uninstall.log" 2>&1
  [ -f "$environment/active" ]
  [ -f "$runtime/recovery.lua" ]
  # Default removal leaves choices and evidence available for a later reinstall.
  # Comparing the entire startup file catches collateral edits outside markers.
  printf 'y\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
    PATH="$environment/bin:$PATH" /bin/sh "$runtime/uninstall.sh" \
    >"$environment/uninstall.log" 2>&1
  [ ! -f "$environment/active" ]
  [ ! -f "$service" ]
  [ ! -e "$home/.local/bin/rex-recover" ]
  [ ! -e "$home/.local/bin/rex-recover-uninstall" ]
  [ -f "$home/.config/rex-recover/apps.conf" ]
  ! grep -q 'Rex Recover' "$startup"
  printf 'export KEEP_USER_SETTING=1\nexport USER_ADDED_LATER=1\n' >"$environment/expected-startup"
  cmp "$environment/expected-startup" "$startup"
  [ ! -f "$environment/rex-calls" ]
  echo "ok - $platform uninstall stops the service and preserves user settings and app configuration"
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
  PATH="$environment/bin:$PATH" "$home/.local/bin/rex-recover" service restart \
  >"$environment/no-service.log" 2>&1; then
  echo "FAIL: restart accepted a missing service installation" >&2
  exit 1
fi
grep -q 'service not installed' "$environment/no-service.log"
[ ! -s "$environment/services" ]
echo "ok - restarting without an installed service fails before any service-manager calls"
printf 'user modification\n' >>"$runtime/recovery.lua"
printf 'unrelated file\n' >"$runtime/user-notes"
mkdir -p "$home/.local/state/rex-recover/launches"
printf 'state\n' >"$home/.local/state/rex-recover/checkpoint.json"
printf 'launch\n' >"$home/.local/state/rex-recover/launches/block:fixture"
printf 'unrelated state file\n' >"$home/.local/state/rex-recover/user-notes"
printf 'y\ny\nn\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
  PATH="$environment/bin:$PATH" /bin/sh "$runtime/uninstall.sh" >"$environment/uninstall.log" 2>&1
[ ! -e "$home/.config/rex-recover/apps.conf" ]
[ ! -e "$home/.local/state/rex-recover/checkpoint.json" ]
[ ! -e "$home/.local/state/rex-recover/launches/block:fixture" ]
[ -f "$home/.local/state/rex-recover/user-notes" ]
grep -q 'user modification' "$runtime/recovery.lua"
[ -f "$runtime/user-notes" ]
echo "ok - optional integration can be declined and purge preserves modified or unrelated files"

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
  PATH="$environment/bin:$PATH" /bin/sh "$runtime/uninstall.sh" >"$environment/uninstall.log" 2>&1
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
  PATH="$environment/bin:$PATH" /bin/sh "$runtime/uninstall.sh" >"$environment/uninstall.log" 2>&1
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

# Unknown platforms must not receive guessed paths or partially installed files.
make_environment unsupported
if env TEST_PLATFORM=UnsupportedOS TEST_ENV="$environment" HOME="$home" \
  PATH="$environment/bin:$PATH" /bin/sh "$root/install.sh" >"$environment/install.log" 2>&1; then
  echo "FAIL: unsupported platform was accepted" >&2
  exit 1
fi
grep -q 'Unsupported platform' "$environment/install.log"
[ ! -e "$home/.local" ]
echo "ok - unsupported platforms are rejected before installation changes"
