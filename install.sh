#!/bin/sh
# Installation writes executable launchers and private recovery settings, so an
# unexpected error must stop the plan rather than leave later steps guessing.
# Private defaults also protect staged paths and config from other local users.
set -eu
umask 077
# The checkout's location is arbitrary; the caller's working folder must not
# decide which runtime or shared safety rules get installed.
source_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$source_root/scripts/setup.sh"
paths
# Installing a watcher that cannot exclude another watcher would create a
# duplicate-recovery risk. Discover that missing prerequisite before any changes.
if ! command -v lockf >/dev/null 2>&1 && ! command -v flock >/dev/null 2>&1; then
  die "A native file-lock utility (lockf or flock) is required before installing."
fi

# Gather choices and generated content away from real user files. Cancellation
# should leave the installation untouched; signals should not strand staging
# files. This cleanup is restricted to files in our own mktemp directory.
stage=$(mktemp -d "${TMPDIR:-/tmp}/rex-recover-install.XXXXXX")
trap 'rm -f "$stage/"*; rmdir "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Preserve previous ownership separately: this install will replace its manifest
# but still needs to remember earlier shell/service choices while planning.
manifest="$stage/previous.info"
if [ -f "$install_root/install.info" ]; then
  cp "$install_root/install.info" "$manifest"
  [ "$(meta format)" = 1 ] || die "Unsupported install manifest: $install_root/install.info"
fi

# A service usually has a smaller PATH than an interactive shell. Pinning the
# CLI selected now avoids depending on service-time discovery. macOS's stable
# bundle path avoids requiring a separate CLI installation.
rex_bin=${REX_BIN:-}
if [ -z "$rex_bin" ]; then
  rex_bin=$(command -v rex 2>/dev/null || :)
  if [ -z "$rex_bin" ] && [ "$platform" = Darwin ]; then
    rex_bin="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  fi
fi
# Missing prerequisites should offer a way forward without guessing a binary
# or automatically installing software on the user's behalf.
while [ ! -f "$rex_bin" ] || [ ! -x "$rex_bin" ]; do
  ask "Rex CLI was not found. Enter its absolute executable path: "
  rex_bin=$answer
done
rex_bin=$(command -v "$rex_bin")
case "$rex_bin" in /*) ;; *) rex_bin="$PWD/$rex_bin" ;; esac
valid_path "$rex_bin"

# Show the scope before requesting consent. Examples help users choose names,
# but must never silently opt their apps into automatic replay.
echo "Rex Recover — interactive user installation ($platform)"
echo "  Runtime:  $install_root"
echo "  Commands: $command_dir"
echo "  Config:   $config"
echo "  State:    $state_dir"
echo "  Rex CLI:  $rex_bin"
echo "Examples of app names: opencode, npm, nvim. These are examples, not defaults."
echo "Configured commands can be rerun after a crash; their arguments may contain secrets."
echo "Enter executable names only, not full commands or arguments."
echo "After installation, use 'rex-recover apps' to add/remove entries without retyping the list."
existing=
if [ -e "$config" ] && [ ! -f "$config" ]; then die "Config is not a regular file: $config"; fi
# A blank response should preserve a valid existing config, including comments.
# An invalid one needs an explicit replacement rather than partial acceptance.
if [ -f "$config" ]; then
  if existing=$("$source_root/bin/rex-recover-config" "$config"); then
    existing=$(printf '%s\n' "$existing" | paste -sd ' ' -)
  else
    existing=
    echo "The existing config is invalid. Enter a replacement list; the original will be backed up."
  fi
fi
# The prompt can be convenient about separators, but the saved format must stay
# identical to the one understood by capture and recovery. Reuse their parser
# instead of introducing installer-only app rules.
while :; do
  ask "Apps to monitor, separated by spaces or commas [${existing:-none}]: "
  if [ -z "$answer" ] && [ -f "$config" ] &&
    "$source_root/bin/rex-recover-config" "$config" >/dev/null 2>&1; then
    cp "$config" "$stage/apps.conf"
  else
    printf '%s\n' "$answer" | tr ',[:space:]' '\n' | awk 'NF' >"$stage/apps.conf"
  fi
  if "$source_root/bin/rex-recover-config" "$stage/apps.conf" >/dev/null; then break; fi
  echo "Enter bare executable names only, not commands or arguments."
done

# Shell edits are optional, and declining on reinstall must retain knowledge
# of an earlier managed block. Remembering whether the file was ours to create
# prevents uninstall from deleting an originally empty user-owned startup file.
old_shell=$(meta shell)
shell_file=$old_shell
shell_created=$(meta shell_created)
block_checksum=$(meta block_checksum)
edit_shell=no
login_shell=${SHELL:-}
# Bash startup conventions differ between macOS login shells and Linux terminal
# shells. Unsupported shells are not a reason to alter an unrelated rc file.
case "${login_shell##*/}" in
  zsh) startup="${ZDOTDIR:-$HOME}/.zshrc"; integration=zsh ;;
  bash)
    integration=bash
    if [ "$platform" = Darwin ]; then startup="$HOME/.bash_profile"; else startup="$HOME/.bashrc"; fi
    ;;
  *) startup=; echo "Automatic shell integration supports zsh and bash; other shells can use rex-recover-run." ;;
esac
if [ -n "$startup" ]; then valid_path "$startup"; fi
if [ -n "$startup" ] && confirm "Add/update the managed PATH and capture block in $startup?"; then
  edit_shell=yes
  shell_file=$startup
  if [ "$old_shell" != "$shell_file" ] || [ -z "$shell_created" ]; then
    shell_created=0
    if [ ! -e "$shell_file" ] && [ ! -L "$shell_file" ]; then shell_created=1; fi
  fi
fi

# Having the service-manager executable is not enough: headless macOS sessions
# may lack a GUI domain and Linux sessions may lack a user manager. A failed
# capability check should leave manual operation available, not require sudo.
old_service=$(meta service)
install_service=no
available=no
case "$platform" in
  Darwin)
    if command -v launchctl >/dev/null && launchctl print "gui/$uid" >/dev/null 2>&1; then available=yes; fi
    ;;
  Linux)
    if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then available=yes; fi
    ;;
esac
if [ "$available" = yes ]; then
  if confirm "Install/restart the watcher user service and start it automatically at login?"; then
    install_service=yes
  fi
else
  echo "No usable user service manager was detected; service setup will be skipped."
fi
if [ "$install_service" = no ]; then
  # "Do not change the service" is not "forget the previous service." Keep its
  # recorded path so a future uninstall can still stop and remove it.
  service_file=$old_service
  log_dir=$(meta logs)
fi
# No persistent installation changes belong above this final approval.
if ! confirm "Copy the runtime and commands, save this config, and apply the selected changes (backing up changed files)?"; then
  echo "Cancelled; no installation changes made."
  exit 0
fi

# A running service could read a mixture of old and new files during replacement.
# A manual watcher must also be stopped by its owner before we can proceed.
if [ "$install_service" = yes ]; then
  if service_loaded || [ -f "$service_file" ]; then stop_service; fi
fi
check_lock

# Copying the runtime frees users to move or delete the checkout later. Explicit
# file modes keep helpers executable without making every data file executable.
for relative in $runtime_files; do
  mode=644
  case "$relative" in bin/*|install.sh|uninstall.sh) mode=755 ;; esac
  copy_file "$source_root/$relative" "$install_root/$relative" "$mode"
done
mkdir -p "$state_dir"
copy_file "$stage/apps.conf" "$config" 600

# Small launchers keep the user-facing commands on PATH while the runtime lives
# in the platform's data directory. Saved defaults make them independent of rc
# files; environment overrides still allow deliberate manual customization.
{
  echo '#!/bin/sh'
  echo '# Managed by the Rex Recover installer.'
  printf 'if [ -z "${REX_BIN:-}" ]; then export REX_BIN=%s; fi\n' "$(quote "$rex_bin")"
  printf 'if [ -z "${REX_RECOVER_CONFIG:-}" ]; then export REX_RECOVER_CONFIG=%s; fi\n' "$(quote "$config")"
  printf 'if [ -z "${REX_RECOVER_STATE_DIR:-}" ]; then export REX_RECOVER_STATE_DIR=%s; fi\n' "$(quote "$state_dir")"
  printf 'exec %s "$@"\n' "$(quote "$install_root/bin/rex-recover")"
} >"$stage/command"
copy_file "$stage/command" "$command_dir/rex-recover" 755
# Uninstall must remain available even if the original checkout has gone away.
{
  echo '#!/bin/sh'
  echo '# Managed by the Rex Recover installer.'
  printf 'exec /bin/sh %s "$@"\n' "$(quote "$install_root/uninstall.sh")"
} >"$stage/uninstall-command"
copy_file "$stage/uninstall-command" "$command_dir/rex-recover-uninstall" 755

# Clear boundaries let removal leave surrounding personal settings alone. PATH
# is useful everywhere, but capture needs Rex's session/block identity, so the
# hook must not start intercepting commands in unrelated terminal applications.
if [ "$edit_shell" = yes ]; then
  {
    echo '# >>> Rex Recover >>>'
    echo '# Managed by the installer; keep personal settings outside this block.'
    printf 'case ":$PATH:" in *:%s:*) ;; *) export PATH=%s:"$PATH" ;; esac\n' \
      "$(quote "$command_dir")" "$(quote "$command_dir")"
    echo 'if [ -n "${REX_SESSION:-}" ] && [ -n "${REX_BLOCK:-}" ]; then'
    printf '  export REX_RECOVER_CONFIG=%s\n' "$(quote "$config")"
    printf '  export REX_RECOVER_STATE_DIR=%s\n' "$(quote "$state_dir")"
    printf '  . %s\n' "$(quote "$install_root/shell/rex-recover.$integration")"
    echo 'fi'
    echo '# <<< Rex Recover <<<'
  } >"$stage/shell-block"
  # A later edit inside our block belongs to the user too; removal must detect
  # that change rather than treating the markers as unconditional permission.
  block_checksum=$(cksum <"$stage/shell-block")
  # Switching shells should not leave the old startup file sourcing a second
  # integration after the user has chosen the replacement location.
  if [ -n "$old_shell" ] && [ "$old_shell" != "$shell_file" ]; then update_shell "$old_shell" ""; fi
  update_shell "$shell_file" "$stage/shell-block"
fi

# Both service formats need literal absolute paths: neither can be treated as
# an interactive shell command. Their escaping rules are different, so a
# shell-quoting helper would be incorrect here.
if [ "$install_service" = yes ]; then
  case "$platform" in
    Darwin)
      # Home directories can contain XML metacharacters. Escaping is necessary
      # even though launchd receives each argument as a separate array element.
      xml() {
        printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
          -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
      }
      # launchd will not create the parent directories of its output files.
      mkdir -p "$log_dir"
      cat >"$stage/service" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.rex-recover</string>
<key>ProgramArguments</key><array>
<string>/bin/sh</string><string>$(xml "$install_root/bin/rex-recover")</string>
<string>--rex</string><string>$(xml "$rex_bin")</string>
<string>--config</string><string>$(xml "$config")</string>
<string>--state-dir</string><string>$(xml "$state_dir")</string>
</array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>5</integer>
<key>StandardOutPath</key><string>$(xml "$log_dir/watcher.log")</string>
<key>StandardErrorPath</key><string>$(xml "$log_dir/watcher.error.log")</string>
</dict></plist>
EOF
      ;;
    Linux)
      # systemd expands percent specifiers and dollar expressions in ExecStart.
      # Doubling both prevents a literal path from changing before execution;
      # quotes alone do not suppress those expansions.
      unit_quote() {
        printf '"'
        printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g' -e 's/\$/$$/g'
        printf '"'
      }
      cat >"$stage/service" <<EOF
[Unit]
Description=Rex Recover watcher
[Service]
Type=exec
ExecStart=/bin/sh $(unit_quote "$install_root/bin/rex-recover") --rex $(unit_quote "$rex_bin") --config $(unit_quote "$config") --state-dir $(unit_quote "$state_dir")
Restart=on-failure
RestartSec=2
[Install]
WantedBy=default.target
EOF
      ;;
  esac
  copy_file "$stage/service" "$service_file" 644
fi

# Save the removal recipe before requesting service startup: if startup fails,
# users still need a record of the files and shell changes already installed.
# Content checksums distinguish installer-owned copies from later user edits.
{
  printf 'format\t1\nplatform\t%s\nconfig\t%s\nstate\t%s\n' "$platform" "$config" "$state_dir"
  printf 'shell\t%s\nshell_created\t%s\nservice\t%s\nlogs\t%s\n' \
    "$shell_file" "${shell_created:-0}" "$service_file" "$log_dir"
  printf 'block_checksum\t%s\n' "$block_checksum"
  for relative in $runtime_files; do owned "$install_root/$relative"; done
  owned "$command_dir/rex-recover"
  owned "$command_dir/rex-recover-uninstall"
  if [ "$install_service" = yes ]; then owned "$service_file"; else previous_owned "$service_file"; fi
} >"$stage/install.info"
copy_file "$stage/install.info" "$install_root/install.info" 600

# Register only the watcher after its files and manifest are ready. Rex itself
# remains under the user's control, including whether it is currently running.
if [ "$install_service" = yes ]; then
  case "$platform" in
    Darwin) launchctl bootstrap "gui/$uid" "$service_file" ;;
    Linux) systemctl --user daemon-reload; systemctl --user enable --now rex-recover.service ;;
  esac
  echo "Watcher user service installed; startup requested. Rex itself was not started or stopped."
fi
# Existing shells and already-running apps cannot retroactively supply their
# launch metadata; explain the one-time restart of those commands explicitly.
echo "Installed. Open new terminals to activate capture; relaunch newly monitored commands once."
echo "Start manually: $command_dir/rex-recover"
echo "Manage apps:    $command_dir/rex-recover apps"
if [ -n "$service_file" ]; then echo "Restart watcher: $command_dir/rex-recover service restart"; fi
echo "Uninstall:      $command_dir/rex-recover-uninstall"
