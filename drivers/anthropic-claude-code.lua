-- First-party contract: https://code.claude.com/docs/en/agent-view#list-sessions-as-json
-- This driver uses documented CLI output, not proprietary transcript fields.
local M = {
  executable = "claude",
  home_env = "CLAUDE_CONFIG_DIR",
  default_home = ".claude",
}

local function uuid(value)
  return type(value) == "string"
    and value:lower():gsub("%x", "x") == "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
end

local function safe_path(value)
  return type(value) == "string" and value:sub(1, 1) == "/" and not value:find("%c")
end

local values = { ["--model"] = true, ["--permission-mode"] = true, ["--agent"] = true }
local flags = {
  ["--dangerously-skip-permissions"] = true,
  ["--allow-dangerously-skip-permissions"] = true, ["--verbose"] = true,
}
local commands = {
  agents = true, mcp = true, auth = true, update = true, help = true, doctor = true,
  install = true, attach = true, ["remote-control"] = true, rc = true, daemon = true,
  gateway = true, ["auto-mode"] = true, import = true, logs = true, plugin = true,
  plugins = true, purge = true, respawn = true, rm = true, stop = true, kill = true,
  ["self-hosted-runner"] = true, completion = true, ultrareview = true, ["setup-token"] = true,
}

local function resume_argv(argv, id)
  local kept, prompts, ended, index = {}, 0, false, 2
  while index <= #argv do
    local argument = argv[index]
    if argument == "--" and not ended then
      ended = true
    elseif not ended and argument:sub(1, 1) == "-" then
      local option, inline = argument:match("^(%-%-[^=]+)=(.*)$")
      option = option or argument
      if argument:sub(1, 2) == "-r" and #argument > 2 then
        option, inline = "-r", argument:sub(3):gsub("^=", "")
      end
      if values[option] or option == "--add-dir" then
        kept[#kept + 1] = argument
        if inline == nil then
          index = index + 1
          local value = argv[index]
          if value == nil or value == "" or value:sub(1, 1) == "-" then return nil end
          kept[#kept + 1] = value
        elseif inline == "" then
          return nil
        end
        -- --add-dir is variadic. Its remaining values are directories, not a
        -- fresh prompt that may be silently discarded.
        if option == "--add-dir" then
          while argv[index + 1] and argv[index + 1]:sub(1, 1) ~= "-" do
            index = index + 1
            if argv[index] == "" then return nil end
            kept[#kept + 1] = argv[index]
          end
        end
      elseif flags[option] and inline == nil then
        kept[#kept + 1] = argument
      elseif option == "--resume" or option == "-r" or option == "--session-id" then
        if inline ~= nil then
          if inline == "" then return nil end
        elseif argv[index + 1] and argv[index + 1]:sub(1, 1) ~= "-" then
          index = index + 1
          if argv[index] == "" then return nil end
        elseif option == "--session-id" then
          return nil
        end
      elseif (option == "--continue" or option == "-c" or option == "--fork-session")
        and inline == nil then
        -- Replace every original selector with the observed UUID.
      else
        return nil
      end
    else
      if not ended and prompts == 0 and commands[argument] then return nil end
      prompts = prompts + 1
      if prompts > 1 then return nil end
    end
    index = index + 1
  end
  local result = { argv[1], "--resume", id }
  for _, argument in ipairs(kept) do result[#result + 1] = argument end
  return result
end

local function allowed_processes(launch, tree)
  local chain = { tree.foreground }
  for _, process in ipairs(tree.ancestors or {}) do chain[#chain + 1] = process end
  local allowed, natives = {}, 0
  for _, process in ipairs(chain) do
    if process.name == "claude" then
      natives = natives + 1
      allowed[process.pid] = true
    end
    if process.pid == launch.pid then
      if natives > 1 then return nil end
      allowed[launch.pid] = true
      return allowed
    end
  end
end

local function current_id(api, launch, allowed)
  local result, err = api.exec({ launch.argv[1], "agents", "--json" }, {
    cwd = launch.cwd, env = { [M.home_env] = launch.home }, timeout = 2,
  })
  if not result then return nil, err end
  if not result.ok then
    local message = (result.stderr or ""):lower()
    if message:find("agents", 1, true)
      and (message:find("unknown command", 1, true) or message:find("unrecognized command", 1, true)) then
      return nil -- Explicitly unavailable CLI capability.
    end
    return nil, "Claude session discovery failed: " .. (result.stderr or "")
  end
  local entries = api.json.decode(result.stdout)
  if type(entries) ~= "table" then return nil end
  for key in pairs(entries) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #entries then return nil end
  end
  local selected, owner
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and allowed[entry.pid] then
      if entry.kind ~= "interactive" or not uuid(entry.sessionId) or not safe_path(entry.cwd)
        or type(entry.startedAt) ~= "number" or entry.startedAt <= 0
        or entry.startedAt == math.huge then return nil end
      local id = entry.sessionId:lower()
      if selected and (selected ~= id or owner ~= entry.pid) then return nil end
      selected, owner = id, entry.pid
    end
  end
  return selected
end

local function persisted(api, home, id)
  local root = home .. "/projects"
  local directory, directory_err, code = io.open(root, "rb")
  if not directory then
    if code == 2 or (directory_err and directory_err:lower():match("no such file or directory$")) then
      return nil
    end
    return nil, directory_err
  end
  directory:close()
  local files, err = api.exec({ "find", root, "-type", "f", "-name", id .. ".jsonl" }, { timeout = 2 })
  if not files then return nil, err end
  if not files.ok then return nil, "Claude transcript discovery failed: " .. (files.stderr or "") end
  local selected
  for path in files.stdout:gmatch("[^\r\n]+") do
    if not safe_path(path) or path:sub(1, #root + 1) ~= root .. "/"
      or path:match("/([^/]+)$") ~= id .. ".jsonl" then return nil end
    if selected and selected ~= path then return nil end
    local file, open_err = io.open(path, "rb")
    if not file then return nil, open_err end
    local byte, read_err = file:read(1)
    file:close()
    if read_err then return nil, read_err end
    if not byte then return nil end
    selected = path
  end
  return selected ~= nil
end

function M.capture(context)
  local api, launch = context.api, context.launch
  if not safe_path(launch.home) or not resume_argv(launch.argv, "pending") then return nil end
  local allowed = allowed_processes(launch, context.processes)
  if not allowed then return nil end
  local id, err = current_id(api, launch, allowed)
  if err then return nil, err end
  if not id then return nil end
  local saved, save_err = persisted(api, launch.home, id)
  if save_err then return nil, save_err end
  if not saved then return nil end
  local current, current_err = current_id(api, launch, allowed)
  if current_err then return nil, current_err end
  if current ~= id then return nil end
  return { argv = resume_argv(launch.argv, id) }
end

return M
