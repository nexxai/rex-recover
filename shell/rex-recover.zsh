# Source this file from zsh; startup files are not modified automatically.
# Setup must not overwrite variables in the user's long-lived interactive shell.
() {
  # User shell options can change parsing; changing them globally would instead
  # break the user's environment. Local emulation avoids both problems.
  emulate -L zsh
  # $0 names the caller's shell, not necessarily this file. Capture must keep
  # working regardless of where the user was when they sourced the integration.
  local root="${${(%):-%x}:A:h:h}"
  local config=${REX_RECOVER_CONFIG:-${XDG_CONFIG_HOME:-"$HOME/.config"}/rex-recover/apps.conf}
  local entries app expected
  # Validate the entire list before touching any existing wrappers. A failed
  # reload leaves the previous, working configuration in place.
  if ! entries=$("$root/bin/rex-recover-config" "$config"); then return 1; fi

  # Wrappers outlive setup, so a local runner path would disappear too early.
  typeset -g _REX_RECOVER_RUNNER="$root/bin/rex-recover-run"
  function _rex_recover_command {
    if [[ -x "$_REX_RECOVER_RUNNER" ]]; then
      "$_REX_RECOVER_RUNNER" "$@"
    else
      # Existing shells can outlive an uninstall. Bypass our wrapper function
      # and run the original command instead of leaving a broken interception.
      command "$@"
    fi
  }

  # A removed config entry must stop being intercepted on reload. A user may
  # also have replaced a wrapper with their own function; name matching alone
  # would delete that work. Exact body matching distinguishes the two.
  for app in ${(k)functions}; do
    expected="_rex_recover_command $app \"\$@\""
    if [[ "${functions[$app]//[[:space:]]/}" == "${expected//[[:space:]]/}" ]]; then
      unfunction "$app"
    fi
  done

  # Users should keep typing their normal commands. Thin wrappers provide
  # capture without inventing a command prefix or per-app invocation rules.
  # Keeping "$@" intact prevents quoting changes and lost empty arguments;
  # direct function-body assignment avoids an extra eval during setup.
  for app in ${(f)entries}; do
    if (( $+functions[$app] )); then
      print -u2 -- "Rex Recover: keeping existing function $app; it is not wrapped."
      continue
    fi
    functions[$app]="_rex_recover_command $app \"\$@\""
  done
  return 0
}
