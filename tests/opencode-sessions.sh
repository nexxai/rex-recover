#!/bin/sh
# Mock OpenCode's CLI and the launch-bound selection file protocol. This
# fixture never discovers or executes an installed OpenCode.
set -eu
umask 077
[ "${1:-}" = prepare ]
directory=$2
mkdir -p "$directory/opencode-app/logs" "$directory/opencode-project" \
  "$directory/opencode-home/config" "$directory/opencode-home/data" \
  "$directory/opencode-home/state" "$directory/opencode-home/cache"
printf 'SQLite format 3\000fixture database\n' >"$directory/opencode-home/data/opencode.db"
printf '%s\n' ses_alphaRoot ses_betaRoot >"$directory/opencode-home/data/opencode.db.sessions"
cat >"$directory/opencode-app/opencode" <<'SH'
#!/bin/bash
set -eu
base=${0%/*}
if [ "${1:-}" = --version ]; then
  printf 'opencode v2.3.0\n'
  exit 0
fi
managed=true
[ "${1:-}" != --standalone ] || managed=false
if [ "${1:-}" = api ] || { [ "${1:-}" = --standalone ] && [ "${2:-}" = api ]; }; then
  [ "${1:-}" != --standalone ] || shift
  [ "$2" = post ] && [ "$3" = /api/rpc/rex-recover/context ] && [ "$4" = --data ]
  id=$(printf '%s' "$5" | sed -n 's/^{"input":{"sessionID":"\([^"]*\)"}}$/\1/p')
  [ -n "$id" ]
  state=ready
  if ! grep -Fxq "$id" "$OPENCODE_DB.sessions"; then state=absent; fi
  printf '{"output":{"state":"%s","pid":9001,"version":"2.3.0","channel":"latest","home":"%s","env":{' "$state" "$HOME"
  printf '"XDG_CONFIG_HOME":"%s","XDG_DATA_HOME":"%s","XDG_STATE_HOME":"%s",' \
    "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
  printf '"XDG_CACHE_HOME":"%s","OPENCODE_DB":"%s"},"file":{"dev":"1","ino":"2"}' "$XDG_CACHE_HOME" "$OPENCODE_DB"
  if [ "$state" = ready ]; then
    printf ',"session":{"id":"%s","location":{"directory":"/fixture/project"}}' "$id"
  fi
  printf '}}\n'
  exit 0
fi
printf '%s\000' "$PWD" "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" \
  "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$OPENCODE_DB" "${OPENCODE_CONFIG_CONTENT-unset}" \
  "${REX_RECOVER_SESSIONS:-}" "$@" >"$base/logs/$REX_BLOCK.$$"
id=ses_betaRoot
[ ! -f "$base/$REX_BLOCK.selected" ] || id=$(cat "$base/$REX_BLOCK.selected")
launch_dir=${REX_RECOVER_LAUNCH_DIR:-${REX_RECOVER_STATE_DIR:-${XDG_STATE_HOME:-"$HOME/.local/state"}/rex-recover}/launches}
fields=()
while IFS= read -r -d '' field; do fields[${#fields[@]}]=$field; done <"$launch_dir/$REX_BLOCK"
[ "${fields[0]}" = rex-recover-launch-v2 ] && [ "${fields[3]}" = "$$" ]
birth=${fields[4]}
hex=$(printf '%s' "$birth" | od -An -tx1 | tr -d ' \n')
selection="$launch_dir/$REX_BLOCK.$$.${hex}.session"
publish() {
  temporary="$selection.tmp"
  {
    printf '{"version":1,"launch":{"pid":%s,"started_at":"%s","session_id":"%s","block_id":"%s","app":"opencode"},' \
      "$$" "$birth" "$REX_SESSION" "$REX_BLOCK"
    printf '"owner_pid":%s,"owner_started_at":"%s",' "$$" "$birth"
    if [ "$id" = none ]; then
      printf '"state":"none"}'
    else
      printf '"state":"ready","id":"%s","home":"%s","managed":%s,"env":{' "$id" "$HOME" "$managed"
      printf '"XDG_CONFIG_HOME":"%s","XDG_DATA_HOME":"%s","XDG_STATE_HOME":"%s",' \
        "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
      printf '"XDG_CACHE_HOME":"%s","OPENCODE_DB":"%s"}}' "$XDG_CACHE_HOME" "$OPENCODE_DB"
    fi
  } >"$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$selection"
}
publish
cd /
while IFS= read -r input; do
  case "$input" in
    beta) id=ses_betaRoot ;;
    alpha) id=ses_alphaRoot ;;
    new) id=none ;;
    exit) id=none; publish; exit 0 ;;
    *) continue ;;
  esac
  printf '%s\n' "$id" >"$base/$REX_BLOCK.selected"
  publish
done
SH
chmod +x "$directory/opencode-app/opencode"
