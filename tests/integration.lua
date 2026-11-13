local root = rex.args.test_dir
local phase = rex.args.phase

local function call(method, args)
  local result, err = rex.call(method, args)
  assert(result, err)
  return result
end

local function read_json(path)
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(rex.json.decode(text))
end

local function load_fixture()
  local fixture = read_json(root .. "/fixture.json")
  call("session.attach", { session_id = fixture.session_id })
  return fixture
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

local function is_test_shell(foreground)
  -- macOS reports /bin/sh as bash. Rex restores the user's login shell.
  return foreground and (foreground.name == "sh" or foreground.name == "bash"
    or foreground.name == "dash" or foreground.name == "zsh"
    or foreground.name == "fish" or foreground.name == "ksh")
end

if phase == "setup" then
  local directories = { root .. "/project one", root .. "/project'two", root }
  local function terminal(index)
    return rex.layout.block {
      flavor = "com.superlogical.terminal.shell",
      options = {
        command = { "/bin/sh", "-i" }, shell = "none", cwd = directories[index],
      },
    }
  end
  local created = call("session.create", {
    label = "recovery-test",
    initial_windows = {
      { window_label = "two apps", layout = rex.layout.horizontal(0.4, terminal(1), terminal(2)) },
      { window_label = "unmonitored", layout = terminal(3) },
    },
  })
  local fixture = {
    session_id = created.session_id,
    blocks = {
      created.initial_windows[1].block_ids[1], created.initial_windows[1].block_ids[2],
      created.initial_windows[2].block_ids[1],
    },
    directories = directories,
  }
  call("session.attach", { session_id = fixture.session_id })
  for index = 1, 3 do
    wait_for("initial shell", function()
      local foreground = process(fixture, index)
      return is_test_shell(foreground)
    end)
    local executable = index == 3 and "/bin/cat" or root .. "/sample-viewer"
    local command = "'" .. executable .. "'\r"
    if index ~= 3 then
      command = "REX_RECOVER_STATE_DIR='" .. root .. "/watcher' '" ..
        rex.args.root .. "/bin/rex-recover-run' " .. command
    end
    call("com.superlogical.terminal.write", {
      session_id = fixture.session_id, block_id = fixture.blocks[index],
      args = { data = command },
    })
  end
  wait_for("two monitored apps", function()
    for index = 1, 2 do
      local foreground = process(fixture, index)
      if not foreground or foreground.name ~= "cat" then return false end
    end
    return true
  end)
  local file = assert(io.open(root .. "/fixture.json", "w"))
  file:write(assert(rex.json.encode(fixture)))
  file:close()
elseif phase == "checkpoint" then
  local fixture = load_fixture()
  wait_for("durable checkpoint of both panes", function()
    local file = io.open(root .. "/watcher/checkpoint.json", "r")
    if not file then return false end
    local state = rex.json.decode(file:read("*a"))
    file:close()
    if not state then return false end
    for index = 1, 2 do
      local record = state.apps[fixture.blocks[index]]
      if not record or not record.tracked or record.cwd ~= fixture.directories[index] then return false end
      assert(rex.json.encode(record.argv) == rex.json.encode({ root .. "/sample-viewer" }),
        "a zero-argument launch changed")
    end
    assert(not state.apps[fixture.blocks[3]], "unconfigured cat was tracked")
    return state.instance_id == call("server.status").instance_id
  end)
elseif phase == "restored" then
  local fixture = load_fixture()
  wait_for("apps in original split panes and working directories", function()
    for index = 1, 2 do
      local foreground = process(fixture, index)
      if not foreground or foreground.name ~= "cat" or foreground.cwd ~= "/" then return false end
    end
    return true
  end)
  for index = 1, 2 do
    local foreground = process(fixture, index)
    local file = assert(io.open(root .. "/viewer-launch." .. foreground.pid, "rb"))
    assert(file:read("*a") == fixture.directories[index] .. "\0" .. "0\0",
      "a zero-argument app did not restart from its original launch folder")
    file:close()
  end
  local other = process(fixture, 3)
  assert(is_test_shell(other), "unconfigured app was relaunched")
  local view = call("session.view", { session_id = fixture.session_id })
  assert(#view.windows == 2 and view.windows[1].label == "two apps", "layout changed")
elseif phase == "exit-apps" then
  local fixture = load_fixture()
  for index = 1, 2 do
    local foreground = assert(process(fixture, index))
    assert(foreground.name == "cat")
    assert(rex.exec({ "kill", "-TERM", tostring(foreground.pid) }).ok)
  end
  wait_for("intentional exits removed from checkpoint", function()
    local state = read_json(root .. "/watcher/checkpoint.json")
    return not state.apps[fixture.blocks[1]] and not state.apps[fixture.blocks[2]]
  end)
elseif phase == "not-restored" then
  local fixture = load_fixture()
  rex.sleep(1)
  for index = 1, 2 do
    local foreground = process(fixture, index)
    assert(is_test_shell(foreground), "an intentionally exited app was restored")
  end
else
  error("unknown test phase: " .. tostring(phase))
end

print("ok - integration: " .. phase)
