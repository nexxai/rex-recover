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
plugin_stage_parent=
trap 'rm -rf "$stage"; if [ -n "$plugin_stage_parent" ]; then rm -rf "$plugin_stage_parent"; fi' EXIT
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

install_opencode=no
opencode_plugin=$(meta opencode_plugin)
opencode_cli=$(meta opencode_cli)
priorTitle=$(meta priorTitle)
priorTerminal=$(meta priorTerminal)
validate_opencode_ownership
opencode_bin=$(command -v opencode 2>/dev/null || :)
if [ -n "$opencode_bin" ] && [ -f "$opencode_bin" ] && [ -x "$opencode_bin" ]; then
  echo "OpenCode detected."
  echo "After a Rex crash, this helper lets Rex reopen the saved conversation you were using,"
  echo "rather than just relaunching OpenCode."
  echo "  Helper location: $config_home/opencode/plugins/rex-recover"
  echo "Other OpenCode settings and plugins are preserved."
  echo "Installing the helper does not add monitored apps or start OpenCode."
  if confirm "Install/update the optional OpenCode recovery helper?"; then
    [ -z "${OPENCODE_CONFIG_DIR:-}" ] ||
      die "OPENCODE_CONFIG_DIR is set. Resolve its global CLI/plugin paths and install manually, or unset it before setup."
    [ "${OPENCODE_CLI_CONFIG_CONTENT+x}" != x ] ||
      die "OPENCODE_CLI_CONFIG_CONTENT is authoritative. Resolve inline CLI settings manually before companion setup."
    if [ -n "$opencode_plugin" ] && [ "$opencode_plugin" != "$config_home/opencode/plugins/rex-recover" ]; then
      die "The previous companion uses another config directory; remove/migrate that installation manually before changing its location."
    fi
    opencode_interpreter
    opencode_plugin="$config_home/opencode/plugins/rex-recover"
    opencode_cli="$config_home/opencode/cli.json"
    valid_path "$opencode_plugin"
    valid_path "$opencode_cli"
    [ ! -L "$opencode_plugin" ] || die "The OpenCode companion directory is symlinked; install manually without replacing it."
    if [ -e "$opencode_plugin" ] && [ ! -d "$opencode_plugin" ]; then
      die "The OpenCode companion path is not a directory: $opencode_plugin"
    fi
    for companion in $opencode_files; do
      [ ! -d "$opencode_plugin/$companion" ] || die "Companion file is a directory: $opencode_plugin/$companion"
    done
    "$javascript" "$source_root/scripts/opencode-config.mjs" install "$opencode_cli" \
      "$install_root/plugins/opencode-recover" "$opencode_plugin" "$stage/opencode.json" \
      "$stage/opencode.snapshot" "${priorTitle:--}" "${priorTerminal:--}"
    priorTitle=
    priorTerminal=
    validate_opencode_ownership
    install_opencode=yes
  fi
fi

install_codex=no
edit_codex_daemon=no
codex_hooks=$(meta codex_hooks)
codex_hook_command=$(meta codex_hook_command)
codex_daemon_config=$(meta codex_daemon_config)
codex_bin=$(command -v codex 2>/dev/null || :)
if [ -n "$codex_bin" ] && [ -f "$codex_bin" ] && [ -x "$codex_bin" ]; then
  case "$codex_bin" in /*) ;; *) codex_bin="$PWD/$codex_bin" ;; esac
  codex_home=${CODEX_HOME:-"$HOME/.codex"}
  codex_home=${codex_home%/}
  echo "Codex detected."
  echo "For better crash recovery, the optional hook helps Rex reopen the Codex conversation in the right terminal."
  echo "Codex's shared daemon can give hooks the environment of the terminal that started it, not the one you use."
  echo "Rex uses the hook to match your terminal only when Codex runs without the shared daemon."
  echo "Skip either option to leave that part of Codex unchanged."
  echo "  Per launch: run 'codex --no-daemon' in Rex. Remember the flag each time; other launches can still use the daemon."
  echo "  Persistent: set [features] daemon_auto_start=false in $codex_home/config.toml."
  echo "    This prevents normal 'codex' launches from starting the daemon, including outside Rex."
  echo "    After you stop any existing daemon yourself, normal 'codex' can run without the flag."
  echo "    An already-running daemon can still be used. Rex Recover does not start or stop it."
  echo "    Without a shared daemon, persistent remote connections and background tasks may be unavailable or interrupted."
  echo "    'codex queue' cannot use --no-daemon for local queuing."
  if confirm "Set daemon_auto_start=false for normal Codex launches?"; then
    edit_codex_daemon=yes
  fi
  echo "  Hook location: $codex_home/hooks.json (Codex hook trust and monitored apps are unchanged)."
  if confirm "Install the optional Codex SessionStart hook?"; then
    install_codex=yes
  fi
  if [ "$edit_codex_daemon" = yes ] || [ "$install_codex" = yes ]; then
    codex_settings="$codex_home/config.toml"
    codex_hook_target="$codex_home/hooks.json"
    valid_path "$codex_settings"
    valid_path "$codex_hook_target"
    valid_path "$codex_bin"
    if [ "$edit_codex_daemon" = yes ] && [ -n "$codex_daemon_config" ] &&
      [ "$codex_daemon_config" != "$codex_settings" ]; then
      die "A previous daemon setting change was recorded for another Codex home; resolve it manually first."
    fi
    if [ "$install_codex" = yes ] && [ -n "$codex_hooks" ] && [ "$codex_hooks" != "$codex_hook_target" ]; then
      die "The previous Codex hook uses another Codex home; remove/migrate it manually before changing its location."
    fi
    codex_js=$(command -v node 2>/dev/null || command -v bun 2>/dev/null || :)
    [ -f "$codex_js" ] && [ -x "$codex_js" ] ||
      die "Codex setup needs Node.js or Bun. Install either, then rerun; or decline both Codex settings changes."
    case "$codex_js" in /*) ;; *) codex_js="$PWD/$codex_js" ;; esac
    valid_path "$codex_js"
    codex_editor="$source_root/scripts/codex-config.mjs"
    if [ "$edit_codex_daemon" = yes ]; then
      "$codex_js" "$codex_editor" snapshot "$codex_settings" "$stage/codex-daemon"
    fi
    if [ "$install_codex" = yes ]; then
      codex_runtime_hook="$install_root/scripts/codex-session-start.mjs"
      [ -f "$source_root/scripts/codex-session-start.mjs" ] || die "Missing runtime source: scripts/codex-session-start.mjs"
      # Version managers can put a short-lived shell symlink on PATH.
      hook_js=$("$codex_js" --eval 'process.stdout.write(require("node:fs").realpathSync(process.execPath))')
      valid_path "$hook_js"
      new_codex_command="exec $(quote "$hook_js") $(quote "$codex_runtime_hook")"
      "$codex_js" "$codex_editor" install-hooks "$codex_hook_target" "$stage/codex-hooks" \
        "$new_codex_command" "$codex_runtime_hook" "$codex_hook_command"
    fi
  fi
fi
# A damaged source package must fail before any persistent installation change.
for relative in $runtime_files; do
  [ -f "$source_root/$relative" ] || die "Missing runtime source: $relative"
done
# No persistent installation changes belong above this final approval.
if ! confirm "Copy the runtime and commands, save this config, and apply the selected changes (backing up changed files)?"; then
  echo "Cancelled; no installation changes made."
  exit 0
fi
if [ -f "$stage/opencode.json" ]; then
  "$javascript" "$source_root/scripts/opencode-config.mjs" check "$opencode_cli" "$stage/opencode.snapshot"
fi
if [ "$edit_codex_daemon" = yes ]; then
  "$codex_js" "$codex_editor" edit-daemon "$codex_settings" "$stage/codex-daemon" "$codex_bin"
fi
if [ "$install_codex" = yes ]; then
  "$codex_js" "$codex_editor" check "$codex_hook_target" "$stage/codex-hooks"
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
if [ "$install_opencode" = yes ]; then
  publish_opencode
  if [ -f "$stage/opencode.json" ]; then
    "$javascript" "$source_root/scripts/opencode-config.mjs" check "$opencode_cli" "$stage/opencode.snapshot"
    copy_file "$stage/opencode.json" "$opencode_cli" ""
  fi
fi
if [ "$edit_codex_daemon" = yes ] && [ -f "$stage/codex-daemon/updated" ]; then
  "$codex_js" "$codex_editor" publish "$codex_settings" "$stage/codex-daemon"
  codex_daemon_config=$codex_settings
fi
if [ "$install_codex" = yes ]; then
  "$codex_js" "$codex_editor" publish "$codex_hook_target" "$stage/codex-hooks"
  codex_hooks=$codex_hook_target
  codex_hook_command=$(cat "$stage/codex-hooks/owned-command")
  active_codex_hook=$(cat "$stage/codex-hooks/active-command")
fi

# Select only configured companions, and respect explicit user overrides.
session_apps=
if [ -n "$opencode_plugin" ]; then session_apps=opencode; fi
if [ -n "$codex_hooks" ]; then session_apps="${session_apps:+$session_apps,}codex"; fi

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
    if [ -n "$session_apps" ]; then
      printf '  if [ -z "${REX_RECOVER_SESSIONS:-}" ]; then export REX_RECOVER_SESSIONS=%s; fi\n' "$session_apps"
    fi
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
  printf 'opencode_plugin\t%s\nopencode_cli\t%s\npriorTitle\t%s\npriorTerminal\t%s\n' \
    "$opencode_plugin" "$opencode_cli" "$priorTitle" "$priorTerminal"
  if [ -n "$codex_daemon_config" ]; then printf 'codex_daemon_config\t%s\n' "$codex_daemon_config"; fi
  if [ -n "$codex_hooks" ]; then printf 'codex_hooks\t%s\n' "$codex_hooks"; fi
  if [ -n "$codex_hook_command" ]; then printf 'codex_hook_command\t%s\n' "$codex_hook_command"; fi
  for relative in $runtime_files; do owned "$install_root/$relative"; done
  owned "$command_dir/rex-recover"
  owned "$command_dir/rex-recover-uninstall"
  if [ "$install_service" = yes ]; then owned "$service_file"; else previous_owned "$service_file"; fi
  if [ -n "$opencode_plugin" ]; then
    for companion in $opencode_files; do
      if [ "$install_opencode" = yes ]; then
        owned "$opencode_plugin/$companion"
      else
        previous_owned "$opencode_plugin/$companion"
      fi
    done
  fi
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
if [ "$install_opencode" = yes ]; then
  echo "OpenCode companion installed; native config watching activates it without a service restart."
fi
if [ -n "$session_apps" ]; then
  if [ "$edit_shell" = yes ]; then
    echo "New Rex terminals enable session recovery for $session_apps only when REX_RECOVER_SESSIONS is unset/empty; existing explicit values are preserved."
  else
    echo "To enable session recovery for $session_apps, export REX_RECOVER_SESSIONS=$session_apps before capture setup."
  fi
fi
if [ -n "$opencode_plugin" ]; then
  echo "Add opencode with 'rex-recover apps' if not already monitored; other apps are unchanged."
fi
if [ "$install_codex" = yes ]; then
  echo "In Codex, open /hooks, choose SessionStart, select the command below, and press t to trust only this hook."
  printf '  %s\n' "$active_codex_hook"
  if [ "$active_codex_hook" != "$new_codex_command" ]; then
    echo "Kept the previously registered command so its trust is unchanged."
  fi
  echo "If its interpreter is no longer installed, remove only this hook from hooks.json, rerun setup, and review the new command."
  echo "Add codex with 'rex-recover apps' if not already monitored; other apps are unchanged."
fi
if [ "$edit_codex_daemon" = yes ]; then
  if [ -f "$stage/codex-daemon/updated" ]; then
    echo "Set daemon_auto_start=false in $codex_settings. No running daemon was changed."
    echo "To undo this, remove the daemon_auto_start=false entry under [features] to restore the default, or set it back to true."
  else
    echo "The native Codex editor left $codex_settings unchanged."
  fi
fi
if [ -n "$service_file" ]; then echo "Restart watcher: $command_dir/rex-recover service restart"; fi
echo "Uninstall:      $command_dir/rex-recover-uninstall"
