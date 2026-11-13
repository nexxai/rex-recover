# Shared by the interactive installer and uninstaller.
die() { echo "Rex Recover: $*" >&2; exit 1; }

ask() {
  printf '%s' "$1"
  IFS= read -r answer || die "Input closed; cancelled."
}

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

quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

valid_path() {
  case "$1" in /*) ;; *) die "Paths must be absolute: $1" ;; esac
  [ "$1" != / ] && [ "$1" != "$HOME" ] || die "Refusing an unsafe destination: $1"
  clean=$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177')
  [ "$1" = "$clean" ] || die "Paths cannot contain control characters."
}

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
      log_dir=
      ;;
    *) die "Unsupported platform: $platform (supported: macOS and Linux)." ;;
  esac
  for path in "$install_root" "$config" "$state_dir" "$command_dir" "$service_file"; do
    valid_path "$path"
  done
}

meta() {
  if [ -f "$manifest" ]; then
    awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$manifest"
  fi
}

backup() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    saved="$1.rex-recover-backup-$(date +%Y%m%d%H%M%S)-$$"
    cp -p "$1" "$saved" || die "Could not back up $1"
    echo "Backed up: $saved"
  fi
}

copy_file() {
  source_file=$1 target_file=$2 mode=$3
  if ! cmp -s "$source_file" "$target_file"; then
    mkdir -p "$(dirname "$target_file")"
    [ ! -d "$target_file" ] || die "Refusing to replace a directory: $target_file"
    backup "$target_file"
    # Write through existing symlinks, preserving dotfile-manager links.
    cat "$source_file" >"$target_file"
  fi
  [ -z "$mode" ] || chmod "$mode" "$target_file"
}

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

update_shell() {
  strip_shell_block "$1" "$stage/startup"
  if [ -n "$2" ]; then cat "$2" >>"$stage/startup"; fi
  copy_file "$stage/startup" "$1" ""
}

service_loaded() {
  case "$platform" in
    Darwin) launchctl print "gui/$uid/local.rex-recover" >/dev/null 2>&1 ;;
    Linux) systemctl --user is-active --quiet rex-recover.service ;;
  esac
}

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

owned() {
  [ -f "$1" ] || return 0
  printf 'owned\t%s\t%s\n' "$(cksum <"$1")" "$1"
}

previous_owned() {
  if [ -f "$manifest" ]; then
    awk -F '\t' -v path="$1" '$1 == "owned" && $3 == path { print }' "$manifest"
  fi
}

runtime_files='install.sh uninstall.sh scripts/setup.sh recovery.lua watch.lua
bin/rex-recover bin/rex-recover-config bin/rex-recover-run
shell/rex-recover.zsh shell/rex-recover.bash'
