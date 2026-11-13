# Source this file from zsh; startup files are not modified automatically.
() {
  emulate -L zsh
  local root="${${(%):-%x}:A:h:h}"
  local config=${REX_RECOVER_CONFIG:-${XDG_CONFIG_HOME:-"$HOME/.config"}/rex-recover/apps.conf}
  local entries app expected
  if ! entries=$("$root/bin/rex-recover-config" "$config"); then return 1; fi

  typeset -g _REX_RECOVER_RUNNER="$root/bin/rex-recover-run"
  function _rex_recover_command {
    if [[ -x "$_REX_RECOVER_RUNNER" ]]; then
      "$_REX_RECOVER_RUNNER" "$@"
    else
      command "$@"
    fi
  }

  # Only remove our exact wrappers; keep functions the user created or modified.
  for app in ${(k)functions}; do
    expected="_rex_recover_command $app \"\$@\""
    if [[ "${functions[$app]//[[:space:]]/}" == "${expected//[[:space:]]/}" ]]; then
      unfunction "$app"
    fi
  done

  for app in ${(f)entries}; do
    if (( $+functions[$app] )); then
      print -u2 -- "Rex Recover: keeping existing function $app; it is not wrapped."
      continue
    fi
    functions[$app]="_rex_recover_command $app \"\$@\""
  done
  return 0
}
