#!/bin/sh
set -eu
umask 077
self=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$self/scripts/setup.sh"
paths
if [ -f "$self/install.info" ]; then install_root=$self; fi
manifest="$install_root/install.info"
[ -f "$manifest" ] || die "No managed installation found at $install_root"
[ "$(meta format)" = 1 ] || die "Unsupported install manifest."
platform=$(meta platform)
case "$platform" in Darwin|Linux) ;; *) die "Invalid platform in install manifest." ;; esac
config=$(meta config)
state_dir=$(meta state)
shell_file=$(meta shell)
shell_created=$(meta shell_created)
service_file=$(meta service)
log_dir=$(meta logs)
valid_path "$config"
valid_path "$state_dir"
for path in "$shell_file" "$service_file" "$log_dir"; do
  if [ -n "$path" ]; then valid_path "$path"; fi
done

echo "Uninstall Rex Recover from: $install_root"
echo "This stops its watcher service, removes its managed shell block and installed files."
echo "Unrelated files, modified installed files (unless approved), and backups are preserved."
if ! confirm "Proceed with uninstall?"; then echo "Cancelled."; exit 0; fi
purge=no
if confirm "Also delete the app config, recovery state, and watcher logs?"; then purge=yes; fi
stage=$(mktemp -d "${TMPDIR:-/tmp}/rex-recover-uninstall.XXXXXX")
trap 'rm -f "$stage/"*; rmdir "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "$service_file" ]; then stop_service; fi
check_lock
if [ -n "$shell_file" ] && [ -e "$shell_file" ]; then
  awk '
    $0 == "# >>> Rex Recover >>>" { inside = 1 }
    inside { print }
    $0 == "# <<< Rex Recover <<<" { inside = 0 }
  ' "$shell_file" >"$stage/current-block"
  if [ -s "$stage/current-block" ]; then
    remove_block=yes
    if [ "$(cksum <"$stage/current-block")" != "$(meta block_checksum)" ] &&
      ! confirm "The managed shell block has been edited. Remove that entire block anyway?"; then
      remove_block=no
      echo "Kept the edited shell block; remove its capture setup manually if desired."
    fi
    if [ "$remove_block" = yes ]; then
      update_shell "$shell_file" ""
      if [ "$shell_created" = 1 ] && [ ! -s "$shell_file" ]; then rm -f "$shell_file"; fi
    fi
  fi
fi

leftovers=no
tab=$(printf '\t')
while IFS="$tab" read -r kind checksum path <&3; do
  [ "$kind" = owned ] || continue
  [ -e "$path" ] || [ -L "$path" ] || continue
  allowed=no
  for relative in $runtime_files; do
    if [ "$path" = "$install_root/$relative" ]; then allowed=yes; break; fi
  done
  case "$path" in
    "$command_dir/rex-recover"|"$command_dir/rex-recover-uninstall"|"$service_file") allowed=yes ;;
  esac
  [ "$allowed" = yes ] || die "Unexpected owned path in manifest: $path"
  if [ -f "$path" ] && [ "$(cksum <"$path")" = "$checksum" ]; then
    rm -f "$path"
  elif confirm "Installed file has changed: $path. Remove it anyway?"; then
    rm -f "$path"
  else
    echo "Kept modified file: $path"
    leftovers=yes
  fi
done 3<"$manifest"
if [ "$platform" = Linux ] && [ -n "$service_file" ]; then systemctl --user daemon-reload; fi

if [ "$purge" = yes ]; then
  rm -f "$config" "$state_dir/checkpoint.json" "$state_dir/checkpoint.json.tmp" "$state_dir/watcher.lock"
  for path in "$state_dir/launches"/block:* "$state_dir/launches"/.launch.*; do
    [ ! -f "$path" ] || rm -f "$path"
  done
  rmdir "$state_dir/launches" "$state_dir" 2>/dev/null || :
  if [ -n "$log_dir" ]; then
    rm -f "$log_dir/watcher.log" "$log_dir/watcher.error.log"
    rmdir "$log_dir" 2>/dev/null || :
  fi
else
  echo "Kept app config, recovery state, and logs."
fi
if [ "$leftovers" = no ]; then rm -f "$manifest"; fi
rmdir "$install_root/bin" "$install_root/shell" "$install_root/scripts" "$install_root" 2>/dev/null || :
echo "Uninstall complete. Backups and unrelated files were not removed."
echo "Open new terminals to discard any capture functions already loaded in existing shells."
