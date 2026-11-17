#!/bin/sh
# A missing setting or failed removal step must not turn into a guessed target.
# Staged copies may contain private paths, so new files default to user-only.
set -eu
umask 077
# The installed copy must be able to remove itself after the checkout is gone.
self=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$self/scripts/setup.sh"
paths
# Environment defaults may have changed since installation. The installed
# manifest is the record of which paths this particular install actually used.
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
opencode_plugin=$(meta opencode_plugin)
opencode_cli=$(meta opencode_cli)
priorTitle=$(meta priorTitle)
priorTerminal=$(meta priorTerminal)
codex_daemon_config=$(meta codex_daemon_config)
codex_hooks=$(meta codex_hooks)
codex_hook_command=$(meta codex_hook_command)
validate_opencode_ownership
# Bookkeeping is data, not unquestionable authority. Reject obviously unsafe
# targets before any service or file changes can happen.
valid_path "$config"
valid_path "$state_dir"
for path in "$shell_file" "$service_file" "$log_dir" "$codex_daemon_config" "$codex_hooks"; do
  if [ -n "$path" ]; then valid_path "$path"; fi
done
if [ -n "$codex_hooks$codex_hook_command" ]; then
  case "$codex_hooks" in
    */../*|*/./*|*//*) die "Unsafe Codex hooks path in manifest." ;;
    */hooks.json) ;;
    *) die "Invalid Codex hooks path in manifest." ;;
  esac
fi
# Optional drivers may no longer exist in the checkout running uninstall.
# Only direct, safely named driver paths qualify; ownership still comes from
# the manifest, so discovering an unrelated module never grants removal rights.
owned_path_allowed() {
  for relative in $runtime_files; do
    if [ "$1" = "$install_root/$relative" ]; then return 0; fi
  done
  case "$1" in
    "$command_dir/rex-recover"|"$command_dir/rex-recover-uninstall") return 0 ;;
    "$install_root"/drivers/*)
      if driver_filename_allowed "${1#"$install_root/drivers/"}"; then return 0; fi
      ;;
  esac
  if [ -n "$service_file" ] && [ "$1" = "$service_file" ]; then return 0; fi
  if [ -n "$opencode_plugin" ]; then
    for companion in $opencode_files; do
      if [ "$1" = "$opencode_plugin/$companion" ]; then return 0; fi
    done
  fi
  return 1
}

# Reject every bad scope before stopping a service or removing earlier entries.
tab=$(printf '\t')
while IFS="$tab" read -r kind checksum path ||
  [ -n "${kind:-}${checksum:-}${path:-}" ]; do
  [ "$kind" = owned ] || continue
  owned_path_allowed "$path" || die "Unexpected owned path in manifest: $path"
done <"$manifest"

# Uninstalling software is not permission to erase the user's app choices or
# recovery evidence. Data removal needs its own, default-no decision.
echo "Uninstall Rex Recover from: $install_root"
echo "This stops its watcher service, removes its managed shell block and installed files."
echo "Unrelated files, modified installed files (unless approved), and backups are preserved."
if ! confirm "Proceed with uninstall?"; then echo "Cancelled."; exit 0; fi
purge=no
if confirm "Also delete the app config, recovery state, and watcher logs?"; then purge=yes; fi
# The trap only removes the private directory just created by mktemp.
stage=$(mktemp -d "${TMPDIR:-/tmp}/rex-recover-uninstall.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -n "$opencode_cli" ] && { [ -e "$opencode_cli" ] || [ -L "$opencode_cli" ]; }; then
  if javascript=$(command -v node 2>/dev/null || command -v bun 2>/dev/null); then
    "$javascript" "$self/scripts/opencode-config.mjs" remove "$opencode_cli" \
      "$install_root/plugins/opencode-recover" "$opencode_plugin" "$stage/opencode.json" \
      "$stage/opencode.snapshot" "${priorTitle:--}" "${priorTerminal:--}"
  else
    # Modern auto-discovery only needs the managed package files removed.
    # Don't guess how to edit older JSON settings without a parser.
    printf 'Node.js or Bun not found; leaving OpenCode settings unchanged: %s\n' "$opencode_cli"
    printf 'If its plugins list still references either Rex Recover package below, remove only those entries:\n  %s\n  %s\n' \
      "$install_root/plugins/opencode-recover" "$opencode_plugin"
    case "$priorTitle" in
      absent) echo "If terminal.title is still false, remove the old Rex Recover terminal.title key." ;;
      true) echo "If terminal.title is still false, restore its pre-install value of true." ;;
    esac
  fi
fi
if [ -n "$codex_hooks" ] && { [ -e "$codex_hooks" ] || [ -L "$codex_hooks" ]; }; then
  # Even a user-owned hook may still call the script we are about to remove.
  codex_js=$(command -v node 2>/dev/null || command -v bun 2>/dev/null) ||
    die "Checking the Codex hooks in $codex_hooks needs Node.js or Bun. Restore either and rerun uninstall."
  codex_editor="$self/scripts/codex-config.mjs"
  "$codex_js" "$codex_editor" remove-hooks "$codex_hooks" "$stage/codex-hooks" \
    "$codex_hook_command" "$install_root/scripts/codex-session-start.mjs" ||
    die "Nothing was removed. Review the Codex hooks in $codex_hooks manually, then rerun uninstall."
fi

# Keep a restart policy from recreating the watcher during removal. A manually
# running watcher still has to release its lock before runtime files can go.
if [ -n "$service_file" ]; then stop_service; fi
check_lock
if [ -f "$stage/opencode.json" ]; then
  "$javascript" "$self/scripts/opencode-config.mjs" check "$opencode_cli" "$stage/opencode.snapshot"
  copy_file "$stage/opencode.json" "$opencode_cli" ""
fi
if [ -d "$stage/codex-hooks" ]; then
  "$codex_js" "$codex_editor" publish "$codex_hooks" "$stage/codex-hooks"
fi
# Markers identify our intended region, but user edits inside them still belong
# to the user. A checksum mismatch requires another decision, not silent deletion.
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
      # An empty file is removable only if installation created it. Otherwise
      # even an originally empty startup file is the user's to keep.
      if [ "$shell_created" = 1 ] && [ ! -s "$shell_file" ]; then rm -f "$shell_file"; fi
    fi
  fi
fi

leftovers=no
# Prompts must keep reading the user's stdin. Using that same stream for the
# manifest loop would consume manifest lines as answers to removal questions.
# Descriptor 3 keeps bookkeeping and consent on separate input channels.
while IFS="$tab" read -r kind checksum path <&3 ||
  [ -n "${kind:-}${checksum:-}${path:-}" ]; do
  [ "$kind" = owned ] || continue
  owned_path_allowed "$path" || die "Unexpected owned path in manifest: $path"
  [ -e "$path" ] || [ -L "$path" ] || continue
  # Unchanged copies are ours to remove. Changed copies may contain user work,
  # even though they still have an installer-owned filename.
  # The global companion was published as regular files, not dotfile links.
  if [ -f "$path" ] &&
    { [ ! -L "$path" ] || [ "${path%/*}" != "$opencode_plugin" ]; } &&
    [ "$(cksum <"$path")" = "$checksum" ]; then
    rm -f "$path"
  elif confirm "Installed file has changed: $path. Remove it anyway?"; then
    rm -f "$path"
  else
    echo "Kept modified file: $path"
    leftovers=yes
  fi
done 3<"$manifest"
# systemd caches unit definitions; after removing ours, its view must catch up.
if [ "$platform" = Linux ] && [ -n "$service_file" ]; then systemctl --user daemon-reload; fi

# Consent covers known recovery data, not everything sharing its directory.
# Narrow file patterns and rmdir leave unrelated files and backups untouched.
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
# Keep ownership evidence for modified runtime files the user chose to retain.
# Nonempty directories are deliberately left rather than recursively deleted.
if [ "$leftovers" = no ]; then rm -f "$manifest"; fi
if [ -n "$opencode_plugin" ]; then rmdir "$opencode_plugin" 2>/dev/null || :; fi
rmdir "$install_root/bin" "$install_root/shell" "$install_root/scripts" "$install_root/drivers" \
  "$install_root/plugins/opencode-recover" "$install_root/plugins" "$install_root" 2>/dev/null || :
echo "Uninstall complete. Backups and unrelated files were not removed."
if [ -n "$codex_daemon_config" ]; then
  printf 'Rex Recover disabled Codex daemon auto-start in %s; the setting was not changed during uninstall.\n' \
    "$codex_daemon_config"
  echo "To undo it, restore the previous value of daemon_auto_start under [features], or remove only daemon_auto_start under [features] if it was not previously set. Keep the rest of [features]."
fi
# Removing a source file cannot unload functions already in an interactive shell.
echo "Open new terminals to discard any capture functions already loaded in existing shells."
