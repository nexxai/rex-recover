#!/bin/sh
# Extend a private runtime with one self-describing provider module. Never
# install anything or discover a real AI app.
set -eu
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rex-driver-loading.XXXXXX")
temporary=$(CDPATH= cd -- "$temporary" && pwd -P)
runtime="$temporary/runtime"
rex_bin=$(command -v "${REX_BIN:-rex}")
endpoint="unix://$temporary/rex.sock"
watcher_pid=
unset REX_RECOVER_CONFIG REX_RECOVER_STATE_DIR REX_RECOVER_LAUNCH_DIR REX_RECOVER_SESSIONS
unset ENV BASH_ENV
unset COMPANION_ARCHIVE_DIR
test_shell=$(command -v zsh)
mkdir "$temporary/zsh"

rex_test() {
  "$rex_bin" --autostart=false --server "$endpoint" "$@"
}

private_server_pid() {
  status=$(rex_test api call server.status) || return 1
  if ! printf '%s' "$status" | grep -Fq "\"endpoint\":\"$endpoint\""; then return 1; fi
  private_pid=$(printf '%s' "$status" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')
  normal_status=$("$rex_bin" --autostart=false api call server.status 2>/dev/null || :)
  normal_pid=$(printf '%s' "$normal_status" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')
  case "$private_pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
  [ "$private_pid" != "$normal_pid" ] || return 1
  printf '%s\n' "$private_pid"
}

start_server() {
  # Restored login shells must not read the user's startup files.
  rex_test server start --state-dir "$temporary/server" \
    --env "ZDOTDIR=$temporary/zsh" --env "SHELL=$test_shell" \
    --config "$temporary/no-config.lua" >/dev/null
  private_server_pid >/dev/null
}

cleanup() {
  status=$?
  if [ "$status" -ne 0 ] && [ -f "$temporary/watcher.log" ]; then
    cat "$temporary/watcher.log"
  fi
  if [ -n "$watcher_pid" ]; then
    kill "$watcher_pid" 2>/dev/null || :
    wait "$watcher_pid" 2>/dev/null || :
  fi
  if private_server_pid >/dev/null 2>&1; then rex_test server stop >/dev/null 2>&1 || :; fi
  echo "Driver loading test artifacts: $temporary"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$runtime/bin" "$runtime/scripts" "$runtime/drivers" "$temporary/bin/logs" \
  "$temporary/original/bin" "$temporary/original/scripts" "$temporary/original/drivers" \
  "$temporary/home/.companion-archive" "$temporary/archive's store" "$temporary/project"
for file in recovery.lua watch.lua bin/rex-recover bin/rex-recover-run \
  bin/rex-recover-config scripts/driver-context.lua drivers/registry.lua drivers/openai-codex.lua; do
  cp "$root/$file" "$temporary/original/$file"
  cp "$temporary/original/$file" "$runtime/$file"
done

cat >"$temporary/bin/fixture-companion" <<'SH'
#!/bin/sh
set -eu
printf '%s\000' "$PWD" "${COMPANION_ARCHIVE_DIR:-}" "${REX_RECOVER_SESSIONS:-}" "$@" \
  >"${0%/*}/logs/$REX_BLOCK.$$"
: >"${0%/*}/app-permissions"
[ "${DRIVER_TEST_ONESHOT:-}" != 1 ] || exit 0
cd /
while IFS= read -r input; do
  [ "$input" != exit ] || exit 0
done
SH
chmod +x "$temporary/bin/fixture-companion"

cat >"$temporary/context-launcher" <<'SH'
#!/bin/sh
printf '%s\000' "${COMPANION_CONFIG-unset}" "${COMPANION_INLINE_CONFIG-unset}" \
  "$UNRELATED_CONTEXT" "$COMPANION_DB" "$@"
SH
chmod +x "$temporary/context-launcher"

run_app() (
  cd "$temporary/project"
  umask 022
  env HOME="$temporary/home" PATH="$temporary/bin:/usr/bin:/bin" \
    REX_SESSION=session:extension REX_BLOCK="block:$1" REX_RECOVER_SESSIONS=1 \
    REX_BIN="$rex_bin" REX_SERVER="$endpoint" \
    REX_RECOVER_LAUNCH_DIR="$temporary/launches" DRIVER_TEST_ONESHOT=1 \
    "$runtime/bin/rex-recover-run" "${2:-fixture-companion}" --launch "space value" "a'b" '$(touch never)' ''
)

cat >"$runtime/drivers/example-companion.lua" <<'LUA'
local function validate(record, api)
  local result, err = api.exec({ "cat", record.env.COMPANION_ARCHIVE_DIR .. "/validation-mode" })
  if not result or not result.ok then return nil, err or "fixture validation read failed" end
  local mode = result.stdout:match("^%s*(.-)%s*$")
  if mode == "error" then return nil, "fixture validation unavailable" end
  if mode == "missing" then return nil end
  return mode == "allow"
end

return {
  executable = "fixture-companion",
  home_env = "COMPANION_ARCHIVE_DIR",
  default_home = ".companion-archive",
  capture = function(context)
    local launch, api, processes = context.launch, context.api, context.processes
    local file = assert(io.open(launch.home .. "/selected-session", "r"))
    local selected = file:read("*l")
    file:close()
    if selected == "unpersisted" then return nil end
    local result, err = api.exec({ "test", "-f", launch.home .. "/selected-session" })
    assert(result, err)
    assert(result.ok, result.stderr)
    local evidence = assert(io.open(launch.home .. "/capture-context.json", "w"))
    evidence:write(assert(api.json.encode({
      launch = launch, foreground = processes.foreground, selected = selected,
    })))
    evidence:close()
    local environment = io.open(launch.home .. "/environment.json", "r")
    local env
    if environment then
      env = assert(api.json.decode(environment:read("*a")))
      environment:close()
    end
    return { argv = { launch.argv[1], "--resume", selected }, env = env }
  end,
}
LUA
# Non-driver siblings and underscore-prefixed Lua helpers are not registrations.
printf 'error("underscore helper was loaded as a driver")\n' >"$runtime/drivers/_helper.lua"
printf 'not Lua\n' >"$runtime/drivers/notes.txt"
printf 'not Lua\n' >"$runtime/drivers/README.md"
start_server
lua_test() {
  rex_test do "$root/tests/driver-loading.lua" --all \
    runtime="$runtime" test_dir="$temporary" phase="$1" rex_bin="$rex_bin" endpoint="$endpoint"
}
lua_test discovery

# Installation accepts symlinks to regular Lua files. Discover the same plugin
# afresh with its definition outside drivers/ and only its symlink inside it.
mv "$runtime/drivers/example-companion.lua" "$temporary/provider-definition.lua"
ln -s "$temporary/provider-definition.lua" "$runtime/drivers/example-companion.lua"
[ -L "$runtime/drivers/example-companion.lua" ]
lua_test symlink

# The descriptor supplies its launch context through the shared metadata helper.

export COMPANION_ARCHIVE_DIR="$temporary/archive's store"
run_app registered
tr '\000' '\n' <"$temporary/launches/block:registered" >"$temporary/registered.txt"
pid=$(sed -n '4p' "$temporary/registered.txt")
printf '%s\000' rex-recover-launch-v2 session:extension block:registered "$pid" \
  "$(sed -n '5p' "$temporary/registered.txt")" fixture-companion "$temporary/project" \
  example-companion "$temporary/archive's store" "$temporary/bin/fixture-companion" \
  --launch "space value" "a'b" '$(touch never)' '' >"$temporary/expected-launch"
cmp "$temporary/expected-launch" "$temporary/launches/block:registered"
printf '%s\000' "$temporary/project" "$temporary/archive's store" 1 \
  --launch "space value" "a'b" '$(touch never)' '' >"$temporary/expected-arguments"
cmp "$temporary/expected-arguments" "$temporary/bin/logs/block:registered.$pid"
[ "$(ls -ld "$temporary/launches" | cut -c1-10)" = drwx------ ]
[ "$(ls -l "$temporary/launches/block:registered" | cut -c1-10)" = -rw------- ]
[ "$(ls -l "$temporary/bin/app-permissions" | cut -c1-10)" = -rw-r--r-- ]
[ -z "$(find "$temporary/launches" -name '.context.*' -print)" ]
[ ! -e "$temporary/project/never" ]
echo "ok - new storage variable records private v2 context without changing argv or app permissions"

unset COMPANION_ARCHIVE_DIR
run_app default-home
tr '\000' '\n' <"$temporary/launches/block:default-home" >"$temporary/default.txt"
[ "$(sed -n '9p' "$temporary/default.txt")" = "$temporary/home/.companion-archive" ]
echo "ok - an unset extension storage variable uses its descriptor default under fixture HOME"
cp "$temporary/provider-definition.lua" "$temporary/provider-before-default.lua"
sed "s/default_home = \".companion-archive\"/default_home = \".companion archive's store\"/" \
  "$temporary/provider-before-default.lua" >"$temporary/provider-definition.tmp"
mv "$temporary/provider-definition.tmp" "$temporary/provider-definition.lua"
mkdir "$temporary/home/.companion archive's store"
run_app spaced-default
if [ ! -f "$temporary/launches/block:spaced-default" ]; then
  echo "FAIL: a default storage path containing spaces was not recorded" >&2
  exit 1
fi
tr '\000' '\n' <"$temporary/launches/block:spaced-default" >"$temporary/spaced-default.txt"
[ "$(sed -n '9p' "$temporary/spaced-default.txt")" = "$temporary/home/.companion archive's store" ]
mv "$temporary/provider-before-default.lua" "$temporary/provider-definition.lua"
echo "ok - descriptor default storage paths preserve spaces and apostrophes"
lua_test ownership

# Optional path context is declared only after exercising the unchanged default.
sed '/default_home = ".companion-archive",/a\
  environment = { "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "COMPANION_DB", "COMPANION_CONFIG", "COMPANION_INLINE_CONFIG" },
' "$temporary/provider-definition.lua" >"$temporary/provider-definition.tmp"
mv "$temporary/provider-definition.tmp" "$temporary/provider-definition.lua"
lua_test environment
sed '/  capture = function(context)/i\
  validate = validate,
' "$temporary/provider-definition.lua" >"$temporary/provider-definition.tmp"
mv "$temporary/provider-definition.tmp" "$temporary/provider-definition.lua"
lua_test validation
printf 'allow\n' >"$temporary/archive's store/validation-mode"

# Unsafe descriptors cannot enable capture; recording still fails open so the
# original harmless app receives its arguments rather than being blocked.
reject_driver() {
  label=$1
  descriptor=$2
  printf '%s\n' "$descriptor" >"$runtime/drivers/zz-invalid.lua"
  run_app "$label" >"$temporary/$label.app.out" 2>"$temporary/$label.app.err"
  [ ! -e "$temporary/launches/block:$label" ]
  grep -Fq 'running it without argument recovery' "$temporary/$label.app.err"
  printf '%s\000' "$temporary/project" '' 1 --launch "space value" "a'b" '$(touch never)' '' \
    >"$temporary/$label.expected-app"
  for log in "$temporary/bin/logs/block:$label."*; do
    cmp "$temporary/$label.expected-app" "$log"
  done
  [ -z "$(find "$temporary/launches" -name '.context.*' -print)" ]
  lua_test invalid >"$temporary/$label.lua.out" 2>"$temporary/$label.lua.err"
  rm "$runtime/drivers/zz-invalid.lua"
  echo "ok - $label descriptor rejects recording and registration without blocking the app"
}

reject_driver missing-field 'return { executable="broken", home_env="BROKEN_HOME", capture=function() end }'
reject_driver duplicate 'return { executable="fixture-companion", home_env="OTHER_HOME", default_home=".other", capture=function() end }'
reject_driver executable-traversal 'return { executable="../escape", home_env="ESCAPE_HOME", default_home=".escape", capture=function() end }'
reject_driver absolute-home 'return { executable="escape", home_env="ESCAPE_HOME", default_home="/escape", capture=function() end }'
reject_driver home-traversal 'return { executable="escape", home_env="ESCAPE_HOME", default_home="nested/../escape", capture=function() end }'
reject_driver control-home 'return { executable="escape", home_env="ESCAPE_HOME", default_home="nested\nescape", capture=function() end }'
reject_driver invalid-variable 'return { executable="escape", home_env="ESCAPE-HOME", default_home=".escape", capture=function() end }'
reject_driver missing-capture 'return { executable="escape", home_env="ESCAPE_HOME", default_home=".escape" }'
reject_driver environment-type 'return { executable="escape", home_env="ESCAPE_HOME", default_home=".escape", environment="XDG_CONFIG_HOME", capture=function() end }'
reject_driver environment-false 'return { executable="escape", home_env="ESCAPE_HOME", default_home=".escape", environment=false, capture=function() end }'
reject_driver environment-map 'return { executable="escape", home_env="ESCAPE_HOME", default_home=".escape", environment={XDG_CONFIG_HOME=true}, capture=function() end }'
reject_driver environment-hole 'return { executable="escape", home_env="ESCAPE_HOME", default_home=".escape", environment={[1]="XDG_CONFIG_HOME",[3]="XDG_DATA_HOME"}, capture=function() end }'
reject_driver environment-index 'return { executable="escape", home_env="ESCAPE_HOME", default_home=".escape", environment={[0]="XDG_CONFIG_HOME"}, capture=function() end }'
reject_driver environment-duplicate 'return { executable="escape", home_env="ESCAPE_HOME", default_home=".escape", environment={"XDG_CONFIG_HOME","XDG_CONFIG_HOME"}, capture=function() end }'
reject_driver environment-invalid-name 'return { executable="escape", home_env="ESCAPE_HOME", default_home=".escape", environment={"bad-name"}, capture=function() end }'
reject_driver environment-value 'return { executable="escape", home_env="ESCAPE_HOME", default_home=".escape", environment={12}, capture=function() end }'
reject_driver invalid-validator 'return { executable="escape", home_env="ESCAPE_HOME", default_home=".escape", validate=true, capture=function() end }'
for reserved in PATH REX_RECOVER_SESSIONS REX_RECOVER_LAUNCH_DIR REX_RECOVER_STATE_DIR \
  REX_RECOVER_CONFIG REX_SESSION REX_BLOCK REX_SERVER REX_BIN REX_BIN_DIR; do
  reject_driver "environment-reserved-$reserved" "return { executable='escape', home_env='ESCAPE_HOME', default_home='.escape', environment={'$reserved'}, capture=function() end }"
  reject_driver "home-reserved-$reserved" "return { executable='escape', home_env='$reserved', default_home='.escape', capture=function() end }"
done

cp "$temporary/bin/fixture-companion" "$temporary/bin/unregistered-tool"
run_app unregistered unregistered-tool
tr '\000' '\n' <"$temporary/launches/block:unregistered" >"$temporary/unregistered.txt"
[ "$(sed -n '1p' "$temporary/unregistered.txt")" = rex-recover-launch-v1 ]
echo "ok - an executable without a driver still records its generic v1 invocation"

printf 'fixture-companion\n' >"$temporary/apps.conf"
lua_test setup
sh "$runtime/bin/rex-recover" --rex "$rex_bin" --server "$endpoint" \
  --state-dir "$temporary/watcher" --config "$temporary/apps.conf" \
  --interval 0.2 >"$temporary/watcher.log" 2>&1 &
watcher_pid=$!
lua_test checkpoint
lua_test select
lua_test checkpoint
private_server_pid >/dev/null
rex_test server stop >/dev/null
start_server
lua_test restored
lua_test checkpoint
lua_test exit

# Verify the shared runtime stays unchanged when using the provider extension.
for file in recovery.lua watch.lua bin/rex-recover bin/rex-recover-run \
  bin/rex-recover-config scripts/driver-context.lua drivers/registry.lua drivers/openai-codex.lua; do
  cmp "$temporary/original/$file" "$runtime/$file"
done
echo "All file-only driver extension tests passed."
