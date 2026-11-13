# Source this file from bash; startup files are not modified automatically.
_rex_recover_load() {
  local root config entries app expected
  root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  config=${REX_RECOVER_CONFIG:-${XDG_CONFIG_HOME:-"$HOME/.config"}/rex-recover/apps.conf}
  entries=$("$root/bin/rex-recover-config" "$config") || return 1
  _REX_RECOVER_RUNNER="$root/bin/rex-recover-run"
  _rex_recover_command() {
    if [[ -x "$_REX_RECOVER_RUNNER" ]]; then
      "$_REX_RECOVER_RUNNER" "$@"
    else
      command "$@"
    fi
  }

  # Compare function bodies before removing only wrappers we generated.
  while read -r _ _ app; do
    expected="_rex_recover_command $app \"\$@\""
    if [[ "$(declare -f "$app")" == *"$expected"* ]]; then
      # Extra user statements mean this is no longer one of our wrappers.
      if [[ "$(declare -f "$app" | sed '1,2d;$d' | tr -d '[:space:];')" == \
        "$(printf '%s' "$expected" | tr -d '[:space:];')" ]]; then
        unset -f "$app"
      fi
    fi
  done < <(declare -F)
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    if declare -F "$app" >/dev/null; then
      printf 'Rex Recover: keeping existing function %s; it is not wrapped.\n' "$app" >&2
      continue
    fi
    # Names come from the shared parser's restricted executable-name alphabet.
    eval "function $app { _rex_recover_command $app \"\$@\"; }"
  done <<<"$entries"
}
_rex_recover_load
