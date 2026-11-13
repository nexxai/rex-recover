# Source this file from bash; startup files are not modified automatically.
# Setup must not clobber variables or shell options in the user's interactive
# session. Its temporary variables therefore belong to a function, not the shell.
_rex_recover_load() {
  local root config entries app expected
  # $0 identifies the caller, so using it would make runtime discovery depend
  # on how bash was launched rather than where this integration was installed.
  root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  config=${REX_RECOVER_CONFIG:-${XDG_CONFIG_HOME:-"$HOME/.config"}/rex-recover/apps.conf}
  # Check the complete list before removing anything from an earlier load.
  entries=$("$root/bin/rex-recover-config" "$config") || return 1
  # Wrappers outlive setup; a local runner path would vanish before the first
  # command uses it.
  _REX_RECOVER_RUNNER="$root/bin/rex-recover-run"
  _rex_recover_command() {
    if [[ -x "$_REX_RECOVER_RUNNER" ]]; then
      "$_REX_RECOVER_RUNNER" "$@"
    else
      # Loaded wrappers can outlive an uninstall. "command" bypasses the
      # wrapper and keeps the user's original command usable without recording.
      command "$@"
    fi
  }

  # Config reloads must stop intercepting removed names without deleting user
  # functions that replaced our wrappers. Names alone do not prove ownership;
  # the body must still match the generated form.
  while read -r _ _ app; do
    expected="_rex_recover_command $app \"\$@\""
    if [[ "$(declare -f "$app")" == *"$expected"* ]]; then
      # bash adds formatting when reporting function definitions. That should
      # not prevent a match, but any additional user statement must.
      if [[ "$(declare -f "$app" | sed '1,2d;$d' | tr -d '[:space:];')" == \
        "$(printf '%s' "$expected" | tr -d '[:space:];')" ]]; then
        unset -f "$app"
      fi
    fi
  done < <(declare -F)
  # Wrapping every executable would be intrusive. Only the explicit app list
  # is eligible, and existing user functions take precedence over capture.
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    if declare -F "$app" >/dev/null; then
      printf 'Rex Recover: keeping existing function %s; it is not wrapped.\n' "$app" >&2
      continue
    fi
    # bash needs generated syntax to define a dynamically named function.
    # Parser validation keeps the name from injecting code; delaying "$@"
    # expansion preserves the future invocation rather than setup's arguments.
    eval "function $app { _rex_recover_command $app \"\$@\"; }"
  done <<<"$entries"
}
# Sourcing must be enough to activate capture; users should not need a second
# initialization command or a different command prefix.
_rex_recover_load
