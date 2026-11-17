-- Native ownership and hook input: Codex rust-v0.169.0, d32063f9.
local M = { executable = "codex", home_env = "CODEX_HOME", default_home = ".codex" }
local limit = 8192
local sources = { startup = true, resume = true, clear = true, fork = true }
local proof_fields = {
  version = true, event = true, source = true, session = true, block = true, pid = true,
  startedAt = true, home = true, cwd = true, executable = true, id = true, transcript = true,
  mode = true, configDisabled = true,
}
local values = {
  ["--model"] = "--model", ["-m"] = "--model", ["--sandbox"] = "--sandbox", ["-s"] = "--sandbox",
  ["--ask-for-approval"] = "--ask-for-approval", ["-a"] = "--ask-for-approval",
  ["--cd"] = "--cd", ["-C"] = "--cd", ["--add-dir"] = "--add-dir",
}
local noninteractive = {
  exec = true, e = true, review = true, login = true, logout = true, mcp = true,
  ["mcp-server"] = true, ["app-server"] = true, app = true, completion = true, update = true,
  sandbox = true, debug = true, ["apply"] = true, a = true, cloud = true, features = true,
  help = true, agents = true, ["remote-control"] = true, daemon = true, archive = true,
  unarchive = true, plugin = true, resume = true, fork = true, setup = true, doctor = true,
  ["tcp-tunnel"] = true, ["git-credential"] = true, execpolicy = true, queue = true,
  delete = true, ["migrate-rollouts"] = true, ["migrate-nfs-db"] = true, ["cloud-tasks"] = true,
  ["responses-api-proxy"] = true, ["stdio-to-uds"] = true, ["exec-server"] = true,
}

local function path(value)
  return type(value) == "string" and value:sub(1, 1) == "/" and not value:find("%c")
end

local function uuid(value)
  return type(value) == "string" and value:gsub("[0-9a-f]", "x") == "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
end

-- Allow only known interactive shapes. Strip the prompt and all old selectors
-- including picker/last/fork flags; do not reinterpret unknown option values.
local function resume_argv(argv, id)
  if not path(argv[1]) then return nil end
  local root, scoped, result = {}, {}, { argv[1] }
  local active, command, flag, ended, prompt, selector, picker, index = root, nil, false, false, false, false, false, 2
  while index <= #argv do
    local argument = argv[index]
    if argument == "--" and not ended then
      ended = true
    elseif argument:sub(1, 1) == "-" and not ended then
      local option, inline = argument:match("^(%-%-[^=]+)=(.*)$")
      option = option or argument
      local canonical = values[option]
      if canonical then
        if inline == nil then index = index + 1; inline = argv[index] end
        if not inline or inline == "" or inline:sub(1, 1) == "-" then return nil end
        if canonical ~= "--add-dir" then
          for _, pair in ipairs(active) do if pair[1] == canonical then return nil end end
        end
        active[#active + 1] = { canonical, inline }
      elseif argument == "--no-daemon" then
        flag = true
      elseif argument == "--no-alt-screen" then
        active[#active + 1] = { argument }
      elseif command and (argument == "--all" or argument == "--last") then
        picker = picker or argument == "--last"
      else
        return nil
      end
    elseif not ended and not prompt and not command and (argument == "resume" or argument == "fork") then
      command, active = argument, scoped
    elseif command and not selector and not picker then
      selector = true
    elseif prompt or (not ended and not command and noninteractive[argument]) then
      return nil
    else
      prompt = true
    end
    index = index + 1
  end
  if flag then result[#result + 1] = "--no-daemon" end
  -- Scoped CLI options win over the root equivalent, except additive --add-dir.
  local override = {}
  for _, pair in ipairs(scoped) do override[pair[1]] = true end
  result[#result + 1], result[#result + 2] = "resume", id
  for _, group in ipairs({ root, scoped }) do
    for _, pair in ipairs(group) do
      if group ~= root or not override[pair[1]] or pair[1] == "--add-dir" then
        result[#result + 1] = pair[1]
        if pair[2] then result[#result + 1] = pair[2] end
      end
    end
  end
  return result, flag and "flag" or "config"
end

local function decode(text, api)
  if type(text) ~= "string" then return nil end
  local ok, decoded = pcall(api.json.decode, text)
  if ok and type(decoded) == "table" then return decoded end
end

local function proof(text, api)
  if type(text) ~= "string" or #text == 0 or #text > limit then return nil end
  local signal = decode(text, api)
  if not signal or signal.version ~= 2 or signal.event ~= "SessionStart" or not sources[signal.source]
    or not uuid(signal.id) or not path(signal.home) or not path(signal.cwd) or not path(signal.executable)
    or type(signal.pid) ~= "number" or signal.pid < 1 or signal.pid % 1 ~= 0
    or type(signal.startedAt) ~= "string" or signal.startedAt == "" or signal.startedAt:find("%c")
    or (signal.configDisabled ~= nil and type(signal.configDisabled) ~= "boolean")
    or not path(signal.transcript) or signal.transcript:sub(1, #signal.home + 1) ~= signal.home .. "/" then
     return nil
  end
  for key in pairs(signal) do if not proof_fields[key] then return nil end end
  local year, month, day, date, name = signal.transcript:sub(#signal.home + 2):match(
    "^sessions/(%d%d%d%d)/(%d%d)/(%d%d)/rollout%-(%d%d%d%d%-%d%d%-%d%d)T%d%d%-%d%d%-%d%d%-(.+)%.jsonl$")
  if not name or date ~= year .. "-" .. month .. "-" .. day then return nil end
  if name ~= signal.id and not (name:sub(1, 37) == signal.id .. "_" and uuid(name:sub(38))) then return nil end
  return signal
end

-- `test -e` alone also says false for inaccessible paths. Confirm a negative
-- lookup without emitting the pathname or OS diagnostic.
local stat_path = [[
  missing() {
    detail=$(LC_ALL=C /usr/bin/stat "$1" 2>&1) && return 1
    case "$detail" in
      *": No such file or directory") return 0 ;;
      *) return 1 ;;
    esac
  }
]]

local function preflight(api, shell, command, label, pathname, ...)
  local result = api.exec({ shell, "-c", "exec 2>/dev/null\n" .. stat_path .. command,
    "codex-preflight", pathname, ... }, { timeout = 2 })
  if result and result.ok then return result.stdout end
  -- Status 3 is reserved by these scripts for confirmed absence/denial.
  if result and result.code == 3 then return nil end
  return nil, "Codex recovery could not check " .. label .. "; will retry"
end

local function bounded(api, pathname, first_line)
  -- No walk, no symlink/pipe, no transcript body parsing, and no app invocation.
  return preflight(api, "/bin/bash", [[
    set -o pipefail
    if [ -L "$1" ]; then exit 3; fi
    if [ ! -f "$1" ]; then
      if [ -e "$1" ] || missing "$1"; then exit 3; fi
      exit 1
    fi
    parent=$(CDPATH= cd -P -- "${1%/*}" && pwd -P) || exit 1
    [ "$parent" = "${1%/*}" ] || exit 3
    if [ "$2" = line ]; then
      # Drain the bounded remainder so SIGPIPE does not masquerade as a
      # read error on long rollouts. Only the first record reaches Rex.
      /usr/bin/head -c 65537 "$1" | { /usr/bin/head -n 1 && /bin/cat >/dev/null; } || exit 1
    else
      /usr/bin/head -c 65537 "$1" || exit 1
    fi
  ]], first_line and "the saved rollout" or "the daemon setting", pathname, first_line and "line" or "")
end

local function persisted(signal, api)
  local bytes, err = bounded(api, signal.transcript, true)
  if err then return nil, err end
  local metadata = decode(bytes and bytes:match("^([^\n]+)\n"), api)
  if not metadata or metadata.type ~= "session_meta" or type(metadata.payload) ~= "table" then return nil end
  local root = metadata.payload
  return root.id == signal.id and root.session_id == signal.id and root.source == "cli"
    and root.thread_source == "user" and root.parent_thread_id == nil
end

local function no_daemon_socket(home, api)
  -- `daemon_auto_start` does not turn off discovery of an existing daemon.
  -- Reject even a stale socket and never connect to, start, or stop one. This
  -- is a preflight, not an atomic guarantee about the future TUI's startup.
  local address = home .. "/app-server-control/app-server-control.sock"
  local absent, err = preflight(api, "/bin/sh", [[
    parent=${1%/*}
    if [ -L "$parent" ] || [ -e "$1" ] || [ -L "$1" ]; then exit 3; fi
    if [ -e "$parent" ] && [ ! -d "$parent" ]; then exit 3; fi
    missing "$1"
  ]], "the daemon socket", address)
  return absent ~= nil, err
end

local function daemon_disabled(home, api)
  local text, err = bounded(api, home .. "/config.toml")
  if err then return nil, err end
  -- ponytail: only recognize a literal unquoted [features] stanza. Avoid
  -- matching text inside multiline TOML strings; other forms can use the flag.
  if not text or #text > 65536 or text:find('"""', 1, true) or text:find("'''", 1, true) then return nil end
  local features, disabled
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%s*%[") then
      features = line:match("^%s*%[features%]%s*$") or line:match("^%s*%[features%]%s*#")
    elseif features and line:match("^%s*daemon_auto_start%s*=") then
      if disabled ~= nil then return nil end
      disabled = (line:match("^%s*daemon_auto_start%s*=%s*false%s*$")
        or line:match("^%s*daemon_auto_start%s*=%s*false%s*#")) ~= nil
    end
  end
  return disabled
end

function M.capture(context)
  local api, launch, foreground = context.api, context.launch, context.processes.foreground
  if not foreground or foreground.pid ~= launch.pid or foreground.name ~= "codex"
    or not path(launch.selection_path) then return nil end
  -- The producer publishes a private regular file by atomic rename. Read only
  -- that small commit here; revisit the transcript/config at restore, not on
  -- every watcher tick. No network or subprocess discovery in capture.
  local file, open_err, code = io.open(launch.selection_path, "rb")
  if not file then
    if code == 2 or (open_err and open_err:lower():match(": no such file or directory$")) then return nil end
    return nil, "Codex recovery could not open the live SessionStart record; will retry"
  end
  local text, read_err = file:read(limit + 1)
  file:close()
  if read_err then return nil, "Codex recovery could not read the live SessionStart record; will retry" end
  local signal = proof(text, api)
  if not signal or signal.mode ~= nil or signal.pid ~= launch.pid or signal.startedAt ~= launch.started_at
    or signal.session ~= launch.session_id or signal.block ~= launch.block_id
    or signal.home ~= launch.home or signal.cwd ~= launch.cwd or signal.executable ~= launch.argv[1] then return nil end
  local argv, mode = resume_argv(launch.argv, signal.id)
  if not argv or (mode == "config" and signal.configDisabled ~= true) then return nil end
  signal.mode = mode
  local saved = api.json.encode(signal)
  if saved and #saved <= limit then return { argv = argv, proof = saved } end
end

function M.validate(record, api)
  local signal = proof(record.proof, api)
  if not signal or not record.tracked or not record.env or signal.session ~= record.session_id
    or signal.block ~= record.block_id
    or signal.cwd ~= record.cwd or signal.home ~= record.env.CODEX_HOME
    or signal.executable ~= record.argv[1] then return nil end
  local argv, mode = resume_argv(record.argv, signal.id)
  if not argv or mode ~= signal.mode or #argv ~= #record.argv then return nil end
  for index, argument in ipairs(argv) do if argument ~= record.argv[index] then return nil end end
  if mode == "config" then
    if signal.configDisabled ~= true then return nil end
    local disabled, config_err = daemon_disabled(signal.home, api)
    if not disabled then return nil, config_err end
    local absent, socket_err = no_daemon_socket(signal.home, api)
    if not absent then return nil, socket_err end
  end
  return persisted(signal, api)
end

return M
