# Installation and removal must agree on paths, managed-file boundaries, and
# service ownership. Keeping these rules together prevents one side from
# leaving behind (or removing) files that the other side handles differently.
# This file is sourced: it relies on the caller's private staging directory
# and deliberately shares settings such as manifest, platform, and state_dir.
die() { echo "Rex Recover: $*" >&2; exit 1; }

# EOF is not approval. A closed pipe or interrupted interactive session must
# cancel rather than silently accept a destructive action. IFS= and -r avoid
# changing user-entered paths that contain spaces or backslashes.
ask() {
  printf '%s' "$1"
  IFS= read -r answer || die "Input closed; cancelled."
}

# Every potentially unwanted change is opt-in. Invalid input gets another
# chance rather than accidentally being interpreted as consent.
confirm() {
  while :; do
    ask "$1 [y/N] "
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      ""|n|N|no|NO) return 1 ;;
      *) echo "Please answer yes or no." ;;
    esac
  done
}

# Generated shell files must treat paths as data, even when a home directory
# contains apostrophes or shell metacharacters. An embedded apostrophe needs
# to end the current quoted segment, escape the apostrophe, then reopen it.
quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# These paths can later become copy or deletion targets. Relative paths would
# depend on the launch directory, while root/home destinations are too broad.
# Control characters would also break the line/tab-based manifest format.
valid_path() {
  case "$1" in /*) ;; *) die "Paths must be absolute: $1" ;; esac
  [ "$1" != / ] && [ "$1" != "$HOME" ] || die "Refusing an unsafe destination: $1"
  clean=$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177')
  [ "$1" = "$clean" ] || die "Paths cannot contain control characters."
}

# No part of a personal terminal-recovery setup needs root privileges. Running
# as root would choose the wrong home and create files the real user cannot own.
# The platform defaults follow user-directory conventions; explicit XDG/custom
# locations must be honored consistently during both installation and removal.
paths() {
  platform=$(uname -s)
  uid=$(id -u)
  [ "$uid" != 0 ] || die "Run this as your normal user, not with sudo."
  config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
  state_dir=${REX_RECOVER_STATE_DIR:-${XDG_STATE_HOME:-"$HOME/.local/state"}/rex-recover}
  config=${REX_RECOVER_CONFIG:-"$config_home/rex-recover/apps.conf"}
  command_dir="$HOME/.local/bin"
  case "$platform" in
    Darwin)
      install_root=${XDG_DATA_HOME:-"$HOME/Library/Application Support"}/rex-recover
      service_file="$HOME/Library/LaunchAgents/local.rex-recover.plist"
      log_dir="$HOME/Library/Logs/rex-recover"
      ;;
    Linux)
      install_root=${XDG_DATA_HOME:-"$HOME/.local/share"}/rex-recover
      service_file="$config_home/systemd/user/rex-recover.service"
      # systemd already captures service output in the user journal, so Linux
      # does not need a second set of log files for this installation.
      log_dir=
      ;;
    *) die "Unsupported platform: $platform (supported: macOS and Linux)." ;;
  esac
  for path in "$install_root" "$config" "$state_dir" "$command_dir" "$service_file"; do
    valid_path "$path"
  done
}

# The manifest is local bookkeeping, not executable shell configuration.
# Reading it as data prevents a modified value from running code on uninstall.
meta() {
  if [ -f "$manifest" ]; then
    awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$manifest"
  fi
}

# Changed files may contain user edits. A nearby timestamped copy gives users
# a way back without requiring Git or discarding their dotfile-manager setup.
backup() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    saved="$1.rex-recover-backup-$(date +%Y%m%d%H%M%S)-$$"
    cp -p "$1" "$saved" || die "Could not back up $1"
    echo "Backed up: $saved"
  fi
}

# Identical reinstalls should not fill the home directory with backups.
# Changed content must be backed up before writing, and a directory must never
# be mistaken for a replaceable file. An empty mode preserves dotfile permissions.
copy_file() {
  source_file=$1 target_file=$2 mode=$3
  if ! cmp -s "$source_file" "$target_file"; then
    mkdir -p "$(dirname "$target_file")"
    [ ! -d "$target_file" ] || die "Refusing to replace a directory: $target_file"
    backup "$target_file"
    # Replacing the symlink itself would detach a dotfile manager's target.
    # Writing through it keeps that relationship intact.
    cat "$source_file" >"$target_file"
  fi
  [ -z "$mode" ] || chmod "$mode" "$target_file"
}

# A missing, duplicated, or nested boundary makes ownership ambiguous. Refuse
# malformed blocks rather than guessing which personal shell lines to delete.
# Staging the result means an awk failure cannot truncate the real startup file.
strip_shell_block() {
  if [ ! -e "$1" ]; then : >"$2"; return; fi
  awk '
    $0 == "# >>> Rex Recover >>>" {
      if (inside || ++blocks > 1) exit 2
      inside = 1; next
    }
    $0 == "# <<< Rex Recover <<<" {
      if (!inside) exit 2
      inside = 0; next
    }
    !inside { print }
    END { if (inside) exit 2 }
  ' "$1" >"$2" || die "Malformed managed block in $1; no shell changes made."
}

# Replacing our bounded block, rather than appending blindly, makes repeated
# installs idempotent and preserves settings the user added around the block.
update_shell() {
  strip_shell_block "$1" "$stage/startup"
  if [ -n "$2" ]; then cat "$2" >>"$stage/startup"; fi
  copy_file "$stage/startup" "$1" ""
}

# Service identity must be scoped to this user's watcher. A system-wide query
# or a Rex-server service name would cross the installation's ownership boundary.
service_loaded() {
  case "$platform" in
    Darwin) launchctl print "gui/$uid/local.rex-recover" >/dev/null 2>&1 ;;
    Linux) systemctl --user is-active --quiet rex-recover.service ;;
  esac
}

# A restart policy could recreate files while they are being removed. Unload
# (launchd) or disable and stop (systemd) our watcher before touching its runtime.
# This is deliberately not authority to start or stop the Rex server.
stop_service() {
  [ -n "$service_file" ] || return 0
  case "$platform" in
    Darwin)
      if service_loaded; then launchctl bootout "gui/$uid/local.rex-recover"; fi
      ;;
    Linux)
      systemctl --user disable --now rex-recover.service
      ;;
  esac
}

# A service is not the only possible watcher: the user may have started one
# manually. Replacing its runtime or deleting its lock file could allow a second
# watcher to race it. The kernel lock, not an old file's presence, decides.
check_lock() {
  [ -f "$state_dir/watcher.lock" ] || return 0
  if command -v lockf >/dev/null 2>&1; then
    lockf -s -k -t 0 "$state_dir/watcher.lock" /usr/bin/true ||
      die "A watcher is still running. Stop it with Ctrl-C, then run this script again."
  else
    flock -n "$state_dir/watcher.lock" /usr/bin/true ||
      die "A watcher is still running. Stop it with Ctrl-C, then run this script again."
  fi
}

# An installed path alone does not prove its contents still belong to us.
# Checksums let removal distinguish untouched copies from later user edits.
# cksum is change detection for local bookkeeping, not an authenticity check.
owned() {
  [ -f "$1" ] || return 0
  printf 'owned\t%s\t%s\n' "$(cksum <"$1")" "$1"
}

# Declining service changes on reinstall must not erase the ownership record
# needed to recognize that service during a later uninstall.
previous_owned() {
  if [ -f "$manifest" ]; then
    awk -F '\t' -v path="$1" '$1 == "owned" && $3 == path { print }' "$manifest"
  fi
}

# Names may enter a whitespace-separated file list, never arbitrary paths.
driver_filename_allowed() {
  case "$1" in *.lua) ;; *) return 1 ;; esac
  # Locale collation can make [a-z] accept uppercase; use literal ASCII characters.
  case "${1%.lua}" in ""|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1 ;; esac
}

opencode_interpreter() {
  javascript=$(command -v node 2>/dev/null || command -v bun 2>/dev/null || :)
  [ -n "$javascript" ] ||
    die "OpenCode setup needs Node.js or Bun. Install either, then rerun; or decline companion setup."
}

validate_opencode_ownership() {
  if [ -z "$opencode_plugin$opencode_cli$priorTitle$priorTerminal" ]; then return; fi
  valid_path "$opencode_plugin"
  valid_path "$opencode_cli"
  case "$opencode_plugin" in
    */../*|*/./*|*//*) die "Unsafe OpenCode path in manifest." ;;
    */opencode/plugins/rex-recover) ;;
    *) die "Invalid OpenCode companion directory in manifest." ;;
  esac
  [ "$opencode_cli" = "${opencode_plugin%/plugins/rex-recover}/cli.json" ] ||
    die "Invalid OpenCode CLI path in manifest."
  if [ -n "$priorTitle$priorTerminal" ]; then
    case "$priorTitle" in absent|true|false) ;; *) die "Invalid priorTitle in manifest." ;; esac
    case "$priorTerminal" in absent|present) ;; *) die "Invalid priorTerminal in manifest." ;; esac
  fi
  [ ! -L "$opencode_plugin" ] || die "The OpenCode companion directory is symlinked; resolve it manually."
}

# Backups must not sit under plugins: OpenCode watches that tree and could load
# a second copy of the companion. Rename only complete packages into discovery.
publish_opencode() {
  same_package=yes
  for companion in $opencode_files; do
    if [ -L "$opencode_plugin/$companion" ] ||
      ! cmp -s "$source_root/plugins/opencode-recover/$companion" "$opencode_plugin/$companion"; then
      same_package=no
    fi
  done
  [ "$same_package" = no ] || return 0
  opencode_directory=${opencode_cli%/cli.json}
  mkdir -p "$opencode_directory" "${opencode_plugin%/*}"
  plugin_stage_parent=$(mktemp -d "$opencode_directory/.rex-recover-stage.XXXXXX")
  if [ -d "$opencode_plugin" ]; then
    cp -Rp "$opencode_plugin" "$plugin_stage_parent/package"
  else
    mkdir "$plugin_stage_parent/package"
  fi
  for companion in $opencode_files; do
    rm -f "$plugin_stage_parent/package/$companion"
    cp "$source_root/plugins/opencode-recover/$companion" "$plugin_stage_parent/package/$companion"
    chmod 644 "$plugin_stage_parent/package/$companion"
  done
  opencode_backup="$opencode_directory/rex-recover-backups/package-$(date +%Y%m%d%H%M%S)-$$"
  "$javascript" "$source_root/scripts/opencode-config.mjs" publish \
    "$plugin_stage_parent/package" "$opencode_plugin" "$opencode_backup"
  rmdir "$plugin_stage_parent"
  plugin_stage_parent=
}

runtime_files='install.sh uninstall.sh scripts/setup.sh scripts/apps.sh recovery.lua watch.lua
scripts/driver-context.lua scripts/codex-config.mjs scripts/codex-session-start.mjs drivers/registry.lua
bin/rex-recover bin/rex-recover-config bin/rex-recover-run
shell/rex-recover.zsh shell/rex-recover.bash'
opencode_files='package.json tui.mjs server.mjs rpc.mjs'
runtime_files="$runtime_files
scripts/opencode-config.mjs
plugins/opencode-recover/package.json plugins/opencode-recover/tui.mjs
plugins/opencode-recover/server.mjs plugins/opencode-recover/rpc.mjs"
# Uninstall relies on its saved manifest, not drivers in whichever checkout ran it.
if [ -z "${self:-}" ]; then
  driver_root=${source_root:-${root:-}}
  [ -n "$driver_root" ] || die "Cannot locate the runtime driver directory."
  for driver_file in "$driver_root"/drivers/*.lua; do
    [ -f "$driver_file" ] || continue
    driver_name=${driver_file##*/}
    driver_filename_allowed "$driver_name" || die "Unsafe driver filename: $driver_name"
    [ "$driver_name" != registry.lua ] || continue
    runtime_files="$runtime_files
drivers/$driver_name"
  done
fi
