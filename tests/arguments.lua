local root = rex.args.test_dir
local phase = rex.args.phase
local apps = { "sample-worker", "sample-editor", "custom-worker" }

local function call(method, args)
  local result, err = rex.call(method, args)
  assert(result, err)
  return result
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

local function save(fixture)
  local file = assert(io.open(root .. "/arguments.json", "w"))
  file:write(assert(rex.json.encode(fixture)))
  file:close()
end

local function quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function wait_for(description, check)
  for _ = 1, 200 do
    if check() then return end
    rex.sleep(0.1)
  end
  error("timed out: " .. description)
end

local function process(fixture, index)
  return call("com.superlogical.terminal.process", {
    session_id = fixture.session_id, block_id = fixture.blocks[index],
  }).foreground
end

local fixture
if phase == "setup" then
  local windows, directories = {}, {}
  for index, app in ipairs(apps) do
    directories[index] = root .. (index % 2 == 0 and "/project'two" or "/project one")
    windows[index] = {
      window_label = app,
      layout = rex.layout.block {
        flavor = "com.superlogical.terminal.shell",
        options = { command = { "/bin/zsh", "-f" }, shell = "none", cwd = directories[index] },
      },
    }
  end
  local created = call("session.create", { label = "argument-recovery-test", initial_windows = windows })
  fixture = {
    session_id = created.session_id, blocks = {}, directories = directories, pids = {},
    instance_id = call("server.status").instance_id,
  }
  call("session.attach", { session_id = fixture.session_id })
  for index, app in ipairs(apps) do
    fixture.blocks[index] = created.initial_windows[index].block_ids[1]
    wait_for("initial zsh for " .. app, function()
      local current = process(fixture, index)
      return current and current.name == "zsh"
    end)
    call("com.superlogical.terminal.write", {
      session_id = fixture.session_id, block_id = fixture.blocks[index],
      args = { data = "unalias sample-worker sample-editor custom-worker 2>/dev/null; " ..
        "unfunction sample-worker sample-editor custom-worker 2>/dev/null; " ..
        "export REX_RECOVER_CONFIG=" .. quote(root .. "/apps.conf") .. "; " ..
        "source " .. quote(rex.args.root .. "/shell/rex-recover.zsh") ..
        "; export PATH=" .. quote(root .. "/apps") .. ":\"$PATH\"" ..
        "; export REX_RECOVER_STATE_DIR=" .. quote(root .. "/watcher") ..
        "; " .. app .. " run dev -- 'a b' 'a'\\''b' '$(touch nope)' ''\r" },
    })
  end
else
  fixture = assert(rex.json.decode(read(root .. "/arguments.json")))
  call("session.attach", { session_id = fixture.session_id })
end

if phase == "setup" or phase == "restored" then
  wait_for("all configured command processes", function()
    for index in ipairs(apps) do
      local current = process(fixture, index)
      if not current or current.name ~= "cat" then return false end
    end
    return true
  end)
  for index, app in ipairs(apps) do
    local current = process(fixture, index)
    assert(current.pid ~= fixture.pids[index], "command was not restarted: " .. app)
    -- The fixture changes its cwd to / after launch. Recovery must use launch cwd.
    assert(current.cwd == "/")
    local expected = fixture.directories[index] .. "\0run\0dev\0--\0a b\0a'b\0$(touch nope)\0\0"
    assert(read(root .. "/apps/logs/" .. app .. "." .. current.pid) == expected,
      "arguments or launch directory changed for " .. app)
    fixture.pids[index] = current.pid
  end
  if phase == "restored" then
    assert(fixture.instance_id ~= call("server.status").instance_id)
  end
  fixture.instance_id = call("server.status").instance_id
  save(fixture)
elseif phase == "checkpoint" then
  wait_for("all configured argument checkpoints", function()
    local state = assert(rex.json.decode(read(root .. "/watcher/checkpoint.json")))
    for index, app in ipairs(apps) do
      local record = state.apps[fixture.blocks[index]]
      if not record or not record.tracked or record.app ~= app
        or record.cwd ~= fixture.directories[index] then return false end
      local expected = { root .. "/apps/" .. app, "run", "dev", "--", "a b", "a'b", "$(touch nope)", "" }
      assert(rex.json.encode(record.argv) == rex.json.encode(expected), "changed arguments for " .. app)
    end
    return state.instance_id == call("server.status").instance_id
  end)
elseif phase == "exit" then
  for index in ipairs(apps) do
    local current = assert(process(fixture, index))
    assert(current.name == "cat")
    assert(rex.exec({ "kill", "-TERM", tostring(current.pid) }).ok)
  end
  wait_for("completed commands removed", function()
    local state = assert(rex.json.decode(read(root .. "/watcher/checkpoint.json")))
    for index in ipairs(apps) do
      if state.apps[fixture.blocks[index]] then return false end
    end
    return true
  end)
elseif phase == "not-restored" then
  rex.sleep(1)
  for index in ipairs(apps) do
    local current = assert(process(fixture, index))
    assert(current.name == "zsh", "completed command was restarted")
  end
else
  error("unknown phase: " .. tostring(phase))
end

print("ok - argument integration: " .. phase)
