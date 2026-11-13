#!/bin/sh
set -eu
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-setup-tests.XXXXXX")
temporary=$(CDPATH= cd -- "$temporary" && pwd -P)
trap 'echo "Setup test artifacts: $temporary"' EXIT

make_environment() {
  environment="$temporary/$1"
  home="$environment/User's Home & 50% dollars\$"
  mkdir -p "$environment/bin" "$home"
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
      bootstrap:*) : >"$TEST_ENV/active" ;;
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
  printf 'sample-worker\nsample-editor\n' >"$environment/expected-apps"
  cmp "$environment/expected-apps" "$home/.config/rex-recover/apps.conf"
  [ "$(grep -c '^# >>> Rex Recover >>>$' "$startup")" = 1 ]
  if [ "$platform" = Darwin ]; then
    if command -v plutil >/dev/null; then plutil -lint "$service"; fi
    grep -q '&amp;' "$service"
    grep -q 'boot.*gui/501' "$environment/services"
  else
    grep -q '^Type=exec$' "$service"
    grep -Fq '%%' "$service"
    grep -Fq '$$' "$service"
    grep -q 'systemctl --user enable --now rex-recover.service' "$environment/services"
  fi
  env HOME="$home" PATH="$environment/bin:$PATH" \
    REX_SESSION=session:fixture REX_BLOCK=block:fixture \
    "$shell" -c '. "$1"; type sample-worker >/dev/null; test "$KEEP_USER_SETTING" = 1' \
    -- "$startup"
  echo "ok - $platform installer creates a configured runtime, shell hook, and user service"

  run_installer '
y
y
y
'
  [ "$(grep -c '^# >>> Rex Recover >>>$' "$startup")" = 1 ]
  printf 'export USER_ADDED_LATER=1\n' >>"$startup"
  printf 'n\n' | env TEST_PLATFORM="$platform" TEST_ENV="$environment" HOME="$home" \
    PATH="$environment/bin:$PATH" /bin/sh "$runtime/uninstall.sh" \
    >"$environment/cancel-uninstall.log" 2>&1
  [ -f "$environment/active" ]
  [ -f "$runtime/recovery.lua" ]
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
! grep -q 'Rex Recover' "$startup"
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

make_environment unsupported
if env TEST_PLATFORM=UnsupportedOS TEST_ENV="$environment" HOME="$home" \
  PATH="$environment/bin:$PATH" /bin/sh "$root/install.sh" >"$environment/install.log" 2>&1; then
  echo "FAIL: unsupported platform was accepted" >&2
  exit 1
fi
grep -q 'Unsupported platform' "$environment/install.log"
[ ! -e "$home/.local" ]
echo "ok - unsupported platforms are rejected before installation changes"
