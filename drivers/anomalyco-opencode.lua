-- The opt-in TUI companion publishes the selected route after same-client
-- metadata validation. Native titles and server activity do not identify it.
local paths = { "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "OPENCODE_DB" }
local cleared = {
  "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT", "OPENCODE_CLI_CONFIG_CONTENT",
  "OPENCODE_CONFIG_PROJECT_DISABLE", "OPENCODE_DISABLE_PROJECT_CONFIG", "OPENCODE_DISABLE_CLAUDE_CODE",
  "OPENCODE_DISABLE_CLAUDE_CODE_SKILLS", "OPENCODE_TEST_HOME", "OPENCODE_FLAGS", "OPENCODE_SIMULATE",
  "OPENCODE_SERVICE_FILE",
}
local M = {
  executable = "opencode",
  home_env = "HOME",
  default_home = ".",
  environment = {},
}
for _, name in ipairs(paths) do M.environment[#M.environment + 1] = name end
for _, name in ipairs(cleared) do M.environment[#M.environment + 1] = name end

local function safe_path(value)
  return type(value) == "string" and value:sub(1, 1) == "/" and not value:find("%c")
end

local function session_id(value)
  return type(value) == "string" and #value <= 256 and value:match("^ses[%w_%-]+$") ~= nil
end

local function resume_argv(argv, id)
  local kept, standalone, directory, ended, index = {}, false, false, false, 2
  while index <= #argv do
    local argument = argv[index]
    local option, inline = argument:match("^(%-%-[^=]+)=(.*)$")
    option = option or argument
    if argument:match("^%-s.") then option, inline = "-s", argument:sub(3):gsub("^=", "") end
    if not ended and argument == "--" then
      ended = true
      kept[#kept + 1] = argument
    elseif not ended and (option == "--session" or option == "-s" or option == "--prompt") then
      if inline == nil then index = index + 1; inline = argv[index] end
      if type(inline) ~= "string" or inline == "" or inline:sub(1, 1) == "-" then return nil end
    elseif not ended and (argument == "--continue" or argument == "-c") then
      -- Only the observed durable ID survives.
    elseif not ended and (argument == "--standalone" or argument == "--auto" or argument == "--yolo"
      or argument == "--dangerously-skip-permissions" or argument == "--print-logs") then
      standalone = standalone or argument == "--standalone"
      kept[#kept + 1] = argument
    elseif argument:sub(1, 1) == "-" or directory
      or (not ended and argument:sub(1, 1) ~= "/" and argument:sub(1, 1) ~= ".") then
      -- Path-like directory arguments avoid guessing which bare words are
      -- management subcommands. Use ./project or -- project for a relative path.
      return nil
    else
      directory = true
      kept[#kept + 1] = argument
    end
    index = index + 1
  end
  if ended and not directory then return nil end
  local result = { argv[1] }
  if standalone then result[#result + 1] = "--standalone" end
  result[#result + 1], result[#result + 2] = "--session", id
  for _, argument in ipairs(kept) do
    if argument ~= "--standalone" then result[#result + 1] = argument end
  end
  return result, standalone
end

local function owned(signal, launch, tree, api)
  if type(signal.owner_pid) ~= "number" or signal.owner_pid < 1 or signal.owner_pid % 1 ~= 0
    or type(signal.owner_started_at) ~= "string" or signal.owner_started_at == ""
    or signal.owner_started_at:find("%c") then return false end
  local chain = { tree.foreground }
  for _, process in ipairs(tree.ancestors or {}) do chain[#chain + 1] = process end
  local owner_index, launch_index, natives = nil, nil, 0
  for index, process in ipairs(chain) do
    if process.name == "opencode" then natives = natives + 1 end
    if process.pid == signal.owner_pid
      and (process.pid == launch.pid or process.name == "opencode") then owner_index = index end
    if process.pid == launch.pid then launch_index = index; break end
  end
  if not owner_index or not launch_index or owner_index > launch_index or natives > 1 then return false end
  if signal.owner_pid == launch.pid then return signal.owner_started_at == launch.started_at end
  local result, err = api.exec({ "ps", "-p", tostring(signal.owner_pid), "-o", "lstart=" },
    { env = { LC_ALL = "C" }, timeout = 2 })
  if not result then return nil, err end
  return result.ok and result.stdout:match("^%s*(.-)%s*$") == signal.owner_started_at
end

local function environment_valid(environment)
  if type(environment) ~= "table" then return false end
  local allowed = {}
  for _, name in ipairs(paths) do
    allowed[name] = true
    if not safe_path(environment[name]) then return false end
  end
  for _, name in ipairs(cleared) do
    allowed[name] = true
    if environment[name] ~= false then return false end
  end
  for name in pairs(environment) do if not allowed[name] then return false end end
  return true
end

local function selection(path)
  local file, err, code = io.open(path, "rb")
  if not file then
    if code == 2 or (err and err:lower():match("no such file or directory$")) then return nil end
    return nil, err
  end
  local text, read_err = file:read(65537)
  file:close()
  if not text or #text > 65536 then return nil, read_err or "invalid OpenCode selection file" end
  return text
end

local function database_exists(path)
  local file, err, code = io.open(path, "rb")
  if not file then
    if code == 2 or (err and err:lower():match("no such file or directory$")) then return nil end
    return nil, err
  end
  local header, read_err = file:read(16)
  file:close()
  if read_err then return nil, read_err end
  return header == "SQLite format 3\0"
end

function M.capture(context)
  local api, launch = context.api, context.launch
  local normalized, standalone = resume_argv(launch.argv, "pending")
  if not safe_path(launch.home) or not safe_path(launch.selection_path) or not normalized then return nil end
  local text, err = selection(launch.selection_path)
  if not text then return nil, err end
  local signal = api.json.decode(text)
  if type(signal) ~= "table" or signal.version ~= 1 or type(signal.launch) ~= "table" then
    return nil, "invalid OpenCode selection metadata"
  end
  local bindings = { pid = true, started_at = true, session_id = true, block_id = true, app = true }
  for key in pairs(bindings) do if signal.launch[key] ~= launch[key] then return nil end end
  for key in pairs(signal.launch) do if not bindings[key] then return nil end end
  local owner, owner_err = owned(signal, launch, context.processes, api)
  if not owner then return nil, owner_err end
  local allowed = { version = true, launch = true, owner_pid = true, owner_started_at = true, state = true,
    id = true, home = true, env = true, managed = true }
  for key in pairs(signal) do if not allowed[key] then return nil, "invalid OpenCode selection fields" end end
  if signal.state == "none" then return nil end
  if signal.state ~= "ready" then return nil, "OpenCode selection metadata is not ready" end
  if not session_id(signal.id) or type(signal.managed) ~= "boolean"
    or not safe_path(signal.home) or type(signal.env) ~= "table" then
    return nil, "invalid OpenCode ready metadata"
  end
  if signal.managed == standalone or signal.home ~= launch.home then return nil end
  local environment, names = {}, {}
  for _, name in ipairs(paths) do
    if not safe_path(signal.env[name]) then return nil, "invalid OpenCode storage context" end
    environment[name], names[name] = signal.env[name], true
  end
  for name in pairs(signal.env) do
    if not names[name] then return nil, "invalid OpenCode storage context" end
  end
  for _, name in ipairs(cleared) do environment[name] = false end
  local exists, database_err = database_exists(environment.OPENCODE_DB)
  if database_err then return nil, database_err end
  if not exists then return nil end
  local current, current_err = selection(launch.selection_path)
  if not current then return nil, current_err end
  if current ~= text then return nil, "OpenCode selection changed during capture" end
  return { argv = resume_argv(launch.argv, signal.id), env = environment }
end

function M.validate(record, api)
  local standalone = record.argv[2] == "--standalone"
  local selector = standalone and 3 or 2
  local id = record.argv[selector + 1]
  if record.argv[selector] ~= "--session" or not session_id(id)
    or not record.env or not safe_path(record.env.HOME) then return nil end
  local environment, context = {}, {}
  for _, name in ipairs(M.environment) do context[name] = record.env[name] end
  if not environment_valid(context) then return nil end
  for _, name in ipairs(paths) do environment[name] = record.env[name] end
  local exists, database_err = database_exists(environment.OPENCODE_DB)
  if database_err then return nil, database_err end
  if not exists then return nil end
  environment.HOME = record.env.HOME
  local function command(arguments)
    local argv = { "/usr/bin/env" }
    for _, name in ipairs(cleared) do argv[#argv + 1], argv[#argv + 2] = "-u", name end
    argv[#argv + 1] = record.argv[1]
    for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
    return argv
  end
  local version, version_err = api.exec(command({ "--version" }),
    { cwd = record.cwd, env = environment, timeout = 5 })
  if not version then return nil, version_err end
  local client_version = version.ok and (version.stdout or ""):match("^opencode v([^%s]+)%s*$")
  if not client_version then return nil, "OpenCode version could not be verified before recovery" end
  local arguments = {}
  if standalone then arguments[#arguments + 1] = "--standalone" end
  for _, argument in ipairs({ "api", "post", "/api/rpc/rex-recover/context", "--data",
    assert(api.json.encode({ input = { sessionID = id } })) }) do
    arguments[#arguments + 1] = argument
  end
  -- The API command reuses a healthy shared service without replacing it.
  -- Compare its attested store/version before the TUI is allowed to reconnect.
  local argv = command(arguments)
  local result, err = api.exec(argv, { cwd = record.cwd, env = environment, timeout = 15 })
  if not result then return nil, err end
  if not result.ok then
    return nil, "OpenCode recovery validation failed: " .. (result.stderr or "")
  end
  local response = api.json.decode(result.stdout)
  local attestation = type(response) == "table" and response.output
  if type(attestation) ~= "table" then
    return nil, "OpenCode recovery validation returned invalid session metadata"
  end
  if attestation.state == "unsupported" then return nil, "OpenCode service storage could not be verified" end
  local info = attestation.session
  if (attestation.state ~= "ready" and attestation.state ~= "absent")
    or type(attestation.pid) ~= "number" or attestation.pid <= 0 or attestation.pid % 1 ~= 0
    or type(attestation.version) ~= "string" or type(attestation.env) ~= "table"
    or type(attestation.channel) ~= "string" or attestation.channel == ""
    or type(attestation.file) ~= "table" or type(attestation.file.dev) ~= "string"
    or attestation.file.dev == "" or type(attestation.file.ino) ~= "string"
    or attestation.file.ino == "" then
    return nil, "OpenCode recovery validation returned invalid session metadata"
  end
  if attestation.version ~= client_version then
    return nil, "OpenCode version mismatch; refusing to replace the running service"
  end
  if attestation.home ~= record.env.HOME then return nil, "OpenCode service home differs from the checkpoint" end
  for _, name in ipairs(paths) do
    if attestation.env[name] ~= environment[name] then
      return nil, "OpenCode service storage differs from the checkpoint"
    end
  end
  if attestation.state == "absent" then return nil end
  if type(info) ~= "table" or info.id ~= id or type(info.location) ~= "table"
    or not safe_path(info.location.directory) then
    return nil, "OpenCode recovery validation returned invalid session metadata"
  end
  return info.parentID == nil
end

return M
