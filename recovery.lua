local M = {}

local shells = { sh = true, bash = true, zsh = true, fish = true, dash = true, ksh = true }

local function idle_shell(processes)
  if not processes.foreground or not shells[processes.foreground.name] then return false end
  for _, ancestor in ipairs(processes.ancestors or {}) do
    if not shells[ancestor.name] and ancestor.name ~= "login" then return false end
  end
  return true
end

local function starting_shell(processes)
  local foreground, child = processes.foreground, processes.child
  -- A terminal briefly identifies as Rex, then login, before its shell exists.
  -- Consuming recovery here loses it during startup. Only defer for the root
  -- child: an actual command inside a user's shell must still be treated as busy.
  return foreground and child and foreground.pid == child.pid
    and (foreground.name == "rex" or foreground.name == "login")
end

local function safe_text(value, allow_empty)
  return type(value) == "string" and (allow_empty or value ~= "")
    and not value:find("%c")
end

local function valid_record(record)
  if type(record) ~= "table" or not safe_text(record.session_id)
    or not record.session_id:match("^session:")
    or not safe_text(record.block_id) or not record.block_id:match("^block:")
    or not safe_text(record.app) or not safe_text(record.cwd)
    or record.cwd:sub(1, 1) ~= "/" or type(record.argv) ~= "table"
    or not safe_text(record.argv[1])
    or (record.tracked ~= nil and type(record.tracked) ~= "boolean") then
    return nil, "invalid restart record (absolute cwd and nonempty argv required)"
  end
  local count = 0
  for index, argument in pairs(record.argv) do
    if type(index) ~= "number" or index < 1 or index % 1 ~= 0
      or index > #record.argv or not safe_text(argument, true) then
      return nil, "invalid argument array (control characters are not allowed)"
    end
    count = count + 1
  end
  if count ~= #record.argv then return nil, "argument array contains holes" end
  return true
end

local function valid_state(state)
  if type(state) ~= "table" or state.version ~= 1
    or not safe_text(state.host_id) or not safe_text(state.instance_id)
    or type(state.apps) ~= "table" or type(state.pending) ~= "table" then
    return nil, "invalid or unsupported checkpoint"
  end
  for _, records in ipairs({ state.apps, state.pending }) do
    for key, record in pairs(records) do
      local ok, err = valid_record(record)
      if not ok then return nil, err end
      if key ~= record.block_id then return nil, "checkpoint block ID mismatch" end
    end
  end
  return true
end

function M.recorded(name)
  return {
    name = name,
    detect = function(process, launch)
      if launch and launch.app == name and launch.pid == process.pid then
        return { cwd = launch.cwd, argv = launch.argv, tracked = true }
      end
    end,
  }
end

local function candidates(processes)
  local result = {}
  if processes.foreground then
    result[#result + 1] = processes.foreground
  end
  for _, process in ipairs(processes.ancestors or {}) do
    result[#result + 1] = process
  end
  return result
end

function M.capture(session_id, block_id, processes, adapters, launch)
  local processes_to_check = candidates(processes)
  if launch and launch.session_id == session_id and launch.block_id == block_id then
    for _, process in ipairs(processes_to_check) do
      if process.pid == launch.pid then
        table.insert(processes_to_check, 1, process)
        break
      end
    end
  else
    launch = nil
  end
  for _, process in ipairs(processes_to_check) do
    for _, adapter in ipairs(adapters or {}) do
      local command = adapter.detect(process, launch)
      if command then
        local record = {
          session_id = session_id,
          block_id = block_id,
          app = adapter.name,
          cwd = command.cwd,
          argv = command.argv,
          tracked = command.tracked,
        }
        local ok, err = valid_record(record)
        if not ok then return nil, err end
        return record
      end
    end
  end
end

function M.read_launch(path)
  local file, err = io.open(path, "rb")
  if not file then
    if err:lower():find("no such file or directory", 1, true) then return nil end
    return nil, err
  end
  local text = file:read("*a")
  file:close()
  if not text or text:sub(-1) ~= "\0" then return nil, "incomplete launch record" end
  local fields = {}
  for field in text:gmatch("([^%z]*)%z") do fields[#fields + 1] = field end
  if fields[1] ~= "rex-recover-launch-v1" or #fields < 8
    or not fields[4]:match("^[1-9]%d*$") or not safe_text(fields[5]) then
    return nil, "invalid launch record"
  end
  local argv = {}
  for index = 8, #fields do argv[#argv + 1] = fields[index] end
  local record = {
    session_id = fields[2], block_id = fields[3], pid = tonumber(fields[4]),
    started_at = fields[5], app = fields[6], cwd = fields[7], argv = argv,
    tracked = true,
  }
  local ok
  ok, err = valid_record(record)
  if not ok then return nil, err end
  return record
end

function M.load(path, json)
  local file, err = io.open(path, "r")
  if not file then
    if err:lower():find("no such file or directory", 1, true) then
      return { version = 1, apps = {}, pending = {} }
    end
    return nil, err
  end
  local text = file:read("*a")
  file:close()
  local state
  state, err = json.decode(text)
  if not state then return nil, err end
  local ok
  ok, err = valid_state(state)
  if not ok then return nil, err end
  return state
end

function M.save(path, state, json)
  local valid, validation_err = valid_state(state)
  if not valid then return nil, validation_err end
  local text, err = json.encode(state)
  if not text then return nil, err end
  local temporary = path .. ".tmp"
  local file
  file, err = io.open(temporary, "w")
  if not file then return nil, err end
  local written, write_err = file:write(text .. "\n")
  local closed, close_err = file:close()
  if not written or not closed then
    os.remove(temporary)
    return nil, write_err or close_err
  end
  local renamed
  renamed, err = os.rename(temporary, path)
  if not renamed then os.remove(temporary) end
  return renamed, err
end

function M.new(api, options)
  local state, err = M.load(options.state_path, api.json)
  if not state then return nil, err end
  local enabled = {}
  for _, adapter in ipairs(options.adapters or {}) do
    if type(adapter) ~= "table" or not safe_text(adapter.name)
      or type(adapter.detect) ~= "function" then
      return nil, "each adapter needs a name and a detect function"
    end
    if enabled[adapter.name] then return nil, "adapter names must be unique" end
    enabled[adapter.name] = true
  end
  local monitor = {}
  local attached, attached_instance = {}, nil
  local launch_dir = options.launch_dir or
    ((options.state_path:match("^(.*)/") or ".") .. "/launches")

  local function verified_launch(session_id, block_id, processes)
    local launch, read_err = M.read_launch(launch_dir .. "/" .. block_id)
    if read_err then return nil, read_err end
    if not launch or launch.session_id ~= session_id or launch.block_id ~= block_id
      or not enabled[launch.app] then return nil end
    for _, process in ipairs(candidates(processes)) do
      if process.pid == launch.pid then
        local result, exec_err = api.exec({ "ps", "-p", tostring(launch.pid), "-o", "lstart=" },
          { env = { LC_ALL = "C" }, timeout = 2 })
        if not result then return nil, exec_err end
        if result.ok and result.stdout:match("^%s*(.-)%s*$") == launch.started_at then
          return launch
        end
        return nil
      end
    end
  end

  function monitor:tick()
    local status, call_err = api.call("server.status")
    if not status then return nil, call_err end
    if not safe_text(status.host_id) or not safe_text(status.instance_id) then
      return nil, "server must report host_id and instance_id"
    end
    if state.host_id and state.host_id ~= status.host_id then
      return nil, "checkpoint belongs to another host; use a separate state directory"
    end
    if attached_instance ~= status.instance_id then
      attached, attached_instance = {}, status.instance_id
    end
    local sessions
    sessions, call_err = api.call("session.list")
    if not sessions then return nil, call_err end
    local apps, observations = {}, {}
    for _, session in ipairs(sessions.sessions or {}) do
      if not attached[session.session_id] then
        local result
        result, call_err = api.call("session.attach", { session_id = session.session_id })
        if not result then return nil, call_err end
        attached[session.session_id] = true
      end
      local blocks
      blocks, call_err = api.call("session.list_blocks", { session_id = session.session_id })
      if not blocks then return nil, call_err end
      for _, block in ipairs(blocks.blocks or {}) do
        if block.creator_name == "com.superlogical.terminal"
          and block.host_id == status.host_id then
          local processes
          processes, call_err = api.call("com.superlogical.terminal.process", {
            session_id = session.session_id, block_id = block.block_id,
          })
          if not processes then return nil, call_err end
          observations[block.block_id] = {
            session_id = session.session_id, processes = processes,
          }
          local launch
          launch, call_err = verified_launch(session.session_id, block.block_id, processes)
          if call_err then return nil, call_err end
          local record
          record, call_err = M.capture(session.session_id, block.block_id,
            processes, options.adapters, launch)
          if call_err then return nil, call_err end
          if record then
            apps[block.block_id] = record
          elseif not processes.foreground and not processes.last_exit
            and state.instance_id == status.instance_id then
            apps[block.block_id] = state.apps[block.block_id]
          end
        end
      end
    end
    local pending = {}
    for key, record in pairs(state.pending) do pending[key] = record end
    if state.instance_id and state.instance_id ~= status.instance_id then
      for key, record in pairs(state.apps) do pending[key] = record end
    end
    local launches = {}
    for key, record in pairs(pending) do
      local observation = observations[key]
      if not enabled[record.app] or not observation
        or observation.session_id ~= record.session_id or apps[key]
        or observation.processes.last_exit then
        pending[key] = nil
      elseif observation.processes.foreground and not starting_shell(observation.processes) then
        pending[key] = nil
        if idle_shell(observation.processes) then
          if record.tracked and (not safe_text(options.launcher)
            or options.launcher:sub(1, 1) ~= "/"
            or not safe_text(launch_dir) or launch_dir:sub(1, 1) ~= "/") then
            return nil, "recorded command recovery requires safe absolute launcher and recording paths"
          end
          apps[key] = record
          launches[#launches + 1] = record
        else
          api.log("warn", "[DEBUG-ci-startup] " .. api.json.encode(observation.processes))
          api.log("warn", "Not restoring " .. record.app .. ": terminal " .. key .. " is busy")
        end
      end
    end
    local next_state = {
      version = 1, host_id = status.host_id, instance_id = status.instance_id,
      apps = apps, pending = pending,
    }
    local saved, save_err = M.save(options.state_path, next_state, api.json)
    if not saved then return nil, save_err end
    state = next_state
    for _, record in ipairs(launches) do
      local current
      current, call_err = api.call("com.superlogical.terminal.process", {
        session_id = record.session_id, block_id = record.block_id,
      })
      if not current then return nil, call_err end
      if idle_shell(current) then
        local function quote(value)
          return "'" .. value:gsub("'", "'\\''") .. "'"
        end
        local argv = {}
        for _, argument in ipairs(record.argv) do argv[#argv + 1] = quote(argument) end
        local prefix = ""
        if record.tracked then
          table.insert(argv, 1, quote(options.launcher))
          prefix = "REX_RECOVER_LAUNCH_DIR=" .. quote(launch_dir) ..
            " REX_SESSION=" .. quote(record.session_id) ..
            " REX_BLOCK=" .. quote(record.block_id) .. " "
        end
        -- Persist consumption before typing: reconnecting must not queue a command twice.
        local result
        result, call_err = api.call("com.superlogical.terminal.write", {
          session_id = record.session_id, block_id = record.block_id,
          args = { data = "cd -- " .. quote(record.cwd) .. " && " .. prefix ..
            table.concat(argv, " ") .. "\r" },
        })
        if not result then return nil, call_err end
        api.log("info", "Restoring " .. record.app .. " in " .. record.block_id)
      else
        api.log("warn", "Not restoring " .. record.app .. ": terminal became busy")
      end
    end
    return true
  end

  return monitor
end

return M
