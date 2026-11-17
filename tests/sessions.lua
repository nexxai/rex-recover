package.path = rex.args.root .. "/?.lua;" .. package.path

local recovery = require("recovery")
local drivers = require("drivers.registry")
local directory = rex.args.test_dir
local phase = rex.args.phase or "unit"
local alpha = "019a80b1-1234-7000-8000-111111111111"
local beta = "019a80b2-1234-7000-8000-222222222222"
local config = 'model_reasoning_effort="low"'

local function read(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

local function write(path, text)
  local file = assert(io.open(path, "wb"))
  assert(file:write(text))
  assert(file:close())
end

local function equal(actual, expected)
  local a, b = rex.json.encode(actual), rex.json.encode(expected)
  assert(a == b, "expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function call(method, args)
  local result, err = rex.call(method, args)
  assert(result, err)
  return result
end

local function quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

if phase == "unit" then
  local sequence, failures = 0, {}
  local birth = "Mon Nov 16 12:00:00 2026"
  local made = assert(rex.exec({ "mktemp", "-d", directory .. "/sessions-unit.XXXXXX" }))
  assert(made.ok, made.stderr)
  local base = made.stdout:match("^%s*(.-)%s*$")

  local function test(name, run)
    if rex.args.only and not name:find(rex.args.only, 1, true) then return end
    local ok, err = pcall(run)
    if ok then print("ok - " .. name)
    else
      failures[#failures + 1] = name .. ": " .. tostring(err)
      print("FAIL - " .. failures[#failures])
    end
  end

  local function launch(f, generic)
    local fields = {
      generic and "rex-recover-launch-v1" or "rex-recover-launch-v2",
      "session:selected", "block:codex", "7001", birth, "codex", f.cwd,
    }
    if not generic then
      fields[#fields + 1], fields[#fields + 2] = "openai-codex", f.home
    end
    for _, argument in ipairs(f.argv) do fields[#fields + 1] = argument end
    write(f.options.launch_dir .. "/block:codex", table.concat(fields, "\0") .. "\0")
  end

  local function fixture()
    sequence = sequence + 1
    local path = base .. "/case-" .. sequence
    local f = {
      home = path .. "/agent's home", cwd = "/workspace/project's same",
      argv = { "/fixture/codex", "--model", "model name", "--config", config,
        "a'b", "$(touch never)", "" },
      tree = { foreground = { pid = 7001, name = "codex", cwd = "/changed/cwd" } },
      status = { host_id = "host:private", instance_id = "run:one" },
      writes = {},
      options = { state_path = path .. "/checkpoint.json", launch_dir = path .. "/launches",
        launcher = rex.args.root .. "/bin/rex-recover-run" },
    }
    assert(rex.exec({ "mkdir", "-p", f.home .. "/sessions", f.options.launch_dir }).ok)
    -- Full canonical saved identities still cannot prove this pane's selection.
    f.transcripts = {}
    assert(rex.exec({ "mkdir", "-p", f.home .. "/sessions/2026/11/16" }).ok)
    for _, id in ipairs({ alpha, beta }) do
      f.transcripts[id] = f.home .. "/sessions/2026/11/16/rollout-2026-11-16T12-00-00-" .. id .. ".jsonl"
      write(f.transcripts[id], assert(rex.json.encode({
        type = "session_meta", payload = { id = id, session_id = id, source = "cli", cwd = f.cwd,
          thread_source = "user", cli_version = "0.168.0" },
      })) .. "\n")
    end
    f.api = {
      json = rex.json, log = function() end,
      exec = function(argv, options)
        if argv[1] == "ps" then return { ok = true, stdout = birth .. "\n" } end
        assert(argv[1] == "/bin/sh" or argv[1] == "/bin/bash",
          "forbidden Codex discovery command: " .. tostring(argv[1]))
        assert(f.status.instance_id ~= "run:one", "capture must not spawn preflight commands during an idle scan")
        return rex.exec(argv, options)
      end,
      call = function(method, args)
        if method == "server.status" then return f.status end
        if method == "session.list" then return { sessions = { { session_id = "session:selected" } } } end
        if method == "session.attach" then return {} end
        if method == "session.list_blocks" then
          return { blocks = { { block_id = "block:codex",
            creator_name = "com.superlogical.terminal", host_id = "host:private" } } }
        end
        if method == "com.superlogical.terminal.process" then return f.tree end
        if method == "com.superlogical.terminal.write" then
          f.writes[#f.writes + 1] = args
          return { bytes_written = #args.args.data }
        end
        error("forbidden Codex app/title API: " .. method)
      end,
    }
    f.options.adapters = { drivers.recorded("codex", f.api) }
    launch(f)
    return f
  end

  local function legacy_sidecar(f, id)
    local recorded = assert(recovery.read_launch(f.options.launch_dir .. "/block:codex"))
    f.transcript = f.home .. "/sessions/" .. id .. ".jsonl"
    write(recorded.selection_path, assert(rex.json.encode({
      version = 1, event = "SessionStart",
      launch = { session_id = "session:selected", block_id = "block:codex",
        pid = 7001, started_at = birth, app = "codex" },
      id = id, home = f.home, transcript_path = f.transcript,
    })) .. "\n")
    return recorded.selection_path
  end

  local function scan(f, open_fixture)
    local open = io.open
    io.open = function(path, ...)
      assert(path:sub(1, #f.home) ~= f.home,
        "forbidden Codex history discovery: " .. path)
      return (open_fixture or open)(path, ...)
    end
    local ok, result, err = pcall(function()
      return assert(recovery.new(f.api, f.options)):tick()
    end)
    io.open = open
    assert(ok, result)
    return result, err
  end

  local function tick(f)
    local result, err = scan(f)
    assert(result, err)
  end

  local function checkpoint(f)
    return assert(recovery.load(f.options.state_path, rex.json))
  end

  local function session_start(f, id, overrides)
    local recorded = assert(recovery.read_launch(f.options.launch_dir .. "/block:codex"))
    local signal = { version = 2, event = "SessionStart", session = "session:selected", block = "block:codex",
      pid = 7001, startedAt = birth, home = f.home, cwd = f.cwd, executable = "/fixture/codex",
      id = id, transcript = f.transcripts[id], source = "resume" }
    for key, value in pairs(overrides or {}) do signal[key] = value end
    write(recorded.selection_path, assert(rex.json.encode(signal)))
    return recorded.selection_path
  end

  test("the last qualifying start survives restart and replaces an old selector without replaying a prompt", function()
    local f = fixture()
    f.argv = { "/fixture/codex", "--no-daemon", "--model", "root-model", "resume", alpha,
      "--model", "session model", "launch prompt must not replay" }
    launch(f)
    session_start(f, alpha)
    local function capture() assert(assert(recovery.new(f.api, f.options)):tick()) end
    capture()
    equal(assert(checkpoint(f).apps["block:codex"], "root start was not captured").argv,
      { "/fixture/codex", "--no-daemon", "resume", alpha, "--model", "session model" })
    session_start(f, beta)
    capture()
    local record = assert(checkpoint(f).apps["block:codex"])
    equal(record.argv, { "/fixture/codex", "--no-daemon", "resume", beta, "--model", "session model" })
    equal(record.env, { CODEX_HOME = f.home, REX_RECOVER_SESSIONS = "1" })
    assert(type(record.proof) == "string" and #record.proof <= 8192)
    f.status.instance_id = "run:two"
    f.tree = { foreground = { pid = 8001, name = "zsh" } }
    capture()
    equal(f.writes, { {
      session_id = "session:selected", block_id = "block:codex",
      args = { data = "cd -- '/workspace/project'\\''s same' && CODEX_HOME=" .. quote(f.home) ..
        " REX_RECOVER_SESSIONS='1' REX_RECOVER_LAUNCH_DIR=" .. quote(f.options.launch_dir) ..
        " REX_SESSION='session:selected' REX_BLOCK='block:codex' " .. quote(f.options.launcher) ..
        " '/fixture/codex' '--no-daemon' 'resume' '" .. beta .. "' '--model' 'session model'\r" },
    } })
    capture()
    equal(#f.writes, 1)
  end)

  test("flagless restore keeps explicit daemon config, never adding a flag", function()
    local f = fixture()
    f.argv = { "/fixture/codex", "initial prompt" }
    launch(f)
    local contents = "[features]\ndaemon_auto_start = false # keep this\n"
    write(f.home .. "/config.toml", contents)
    session_start(f, alpha, { configDisabled = true })
    tick(f)
    equal(assert(checkpoint(f).apps["block:codex"], "flagless start was not captured").argv,
      { "/fixture/codex", "resume", alpha })
    f.status.instance_id = "run:two"
    f.tree = { foreground = { pid = 8001, name = "zsh" } }
    tick(f)
    equal(#f.writes, 1)
    local suffix = "'resume' '" .. alpha .. "'\r"
    equal(f.writes[1].args.data:sub(-#suffix), suffix)
    assert(not f.writes[1].args.data:find("--no-daemon", 1, true))
    equal(read(f.home .. "/config.toml"), contents)
  end)

  test("a transient restore read failure retains the checkpoint and retries exact resume", function()
    for _, failure in ipairs({ "api", "unreadable", "config", "socket" }) do
      local f = fixture()
      local flag = failure == "api" or failure == "unreadable"
      f.argv = flag and { "/fixture/codex", "--no-daemon", "do not replay" }
        or { "/fixture/codex", "do not replay" }
      launch(f)
      write(f.home .. "/config.toml", "[features]\ndaemon_auto_start=false\n")
      session_start(f, beta, { configDisabled = not flag })
      tick(f)
      local previous = read(f.options.state_path)
      f.status.instance_id = "run:two"
      f.tree = { foreground = { pid = 8001, name = "zsh" } }
      local exec = f.api.exec
      local secret = f.transcripts[beta] .. " raw private marker"
      if failure == "unreadable" then
        assert(rex.exec({ "chmod", "000", f.transcripts[beta] }).ok)
      else
        f.api.exec = function(argv, options)
          if failure == "api" or (failure == "config" and argv[5] == f.home .. "/config.toml")
            or (failure == "socket" and argv[5] == f.home .. "/app-server-control/app-server-control.sock") then
            return nil, secret
          end
          return exec(argv, options)
        end
      end
      local ok, err = scan(f)
      assert(not ok and type(err) == "string", failure .. ": bad read was treated as successful no-restore")
      assert(not err:find(f.home, 1, true) and not err:find("raw private marker", 1, true))
      equal(read(f.options.state_path), previous)
      equal(f.writes, {})
      f.api.exec = exec
      assert(rex.exec({ "chmod", "600", f.transcripts[beta] }).ok)
      assert(rex.exec({ "touch", "-t", "202001010000", f.transcripts[beta] }).ok)
      tick(f)
      local suffix = (flag and "'--no-daemon' " or "") .. "'resume' '" .. beta .. "'\r"
      equal(#f.writes, 1)
      equal(f.writes[1].args.data:sub(-#suffix), suffix)
      assert(not f.writes[1].args.data:find("do not replay", 1, true))
      tick(f)
      equal(#f.writes, 1)
    end
  end)

  test("an unreadable live sidecar preserves the previous capture but an absent one does not", function()
    local f = fixture()
    f.argv = { "/fixture/codex", "--no-daemon" }
    launch(f)
    local sidecar = session_start(f, beta)
    tick(f)
    local previous = read(f.options.state_path)
    local open = io.open
    local ok, err = scan(f, function(path, ...)
      if path == sidecar then return nil, path .. ": Permission denied", 13 end
      return open(path, ...)
    end)
    assert(not ok and type(err) == "string", "sidecar error was treated as an absent event")
    assert(not err:find(sidecar, 1, true))
    equal(read(f.options.state_path), previous)
    assert(os.remove(sidecar))
    tick(f)
    equal(checkpoint(f).apps, {})
  end)

  test("a daemon socket or missing or reenabled config blocks flagless restart without connecting", function()
    for _, change in ipairs({ "socket", "removed", "reenabled" }) do
      local f = fixture()
      f.argv = { "/fixture/codex" }
      launch(f)
      local config_path = f.home .. "/config.toml"
      write(config_path, "[features]\ndaemon_auto_start=false\n")
      session_start(f, beta, { configDisabled = true })
      tick(f)
      assert(checkpoint(f).apps["block:codex"])
      if change == "socket" then
        assert(rex.exec({ "mkdir", f.home .. "/app-server-control" }).ok)
        write(f.home .. "/app-server-control/app-server-control.sock", "socket path must remain untouched")
      elseif change == "removed" then
        assert(os.remove(config_path))
      else
        write(config_path, "[features]\ndaemon_auto_start=true\n")
      end
      f.status.instance_id = "run:two"
      f.tree = { foreground = { pid = 8001, name = "zsh" } }
      tick(f)
      equal(f.writes, {})
      equal(checkpoint(f).apps, {})
      equal(checkpoint(f).pending, {})
    end
  end)

  test("stale process, wrong store and deleted rollout never produce a resume command", function()
    local stale = fixture()
    stale.argv = { "/fixture/codex", "--no-daemon" }
    launch(stale)
    session_start(stale, alpha, { startedAt = "Sun Nov 15 12:00:00 2026" })
    tick(stale)
    equal(checkpoint(stale).apps, {})
    session_start(stale, alpha, { home = stale.home .. "-elsewhere" })
    tick(stale)
    equal(checkpoint(stale).apps, {})
    session_start(stale, alpha)
    tick(stale)
    assert(os.remove(stale.transcripts[alpha]))
    stale.status.instance_id = "run:two"
    stale.tree = { foreground = { pid = 8001, name = "zsh" } }
    tick(stale)
    equal(stale.writes, {})
    equal(checkpoint(stale).apps, {})
    equal(checkpoint(stale).pending, {})
  end)

  test("unproven Codex capture never accesses titles or scans history", function()
    local f = fixture()
    local recorded = assert(recovery.read_launch(f.options.launch_dir .. "/block:codex"))
    equal(recorded.driver, "openai-codex")
    equal(recorded.home, f.home)
    local driver = require("drivers.openai-codex")
    equal({ driver.executable, driver.home_env, driver.default_home },
      { "codex", "CODEX_HOME", ".codex" })
    tick(f)
    equal(checkpoint(f).apps, {})
  end)

  test("Codex ignores the legacy prototype sidecar and record", function()
    local f = fixture()
    f.argv = { "/fixture/codex", "--no-daemon", "--model", "root-model", "resume", alpha,
      "--model", "session-model", "launch prompt must not replay" }
    launch(f)
    local path = legacy_sidecar(f, beta)
    tick(f)
    equal(checkpoint(f).apps, {})
    local driver = require("drivers.openai-codex")
    local function forbidden() error("legacy checkpoint must not cause preflight I/O") end
    equal(driver.validate({
      session_id = "session:selected", block_id = "block:codex", app = "codex",
      argv = { "/fixture/codex", "--no-daemon", "resume", beta },
      env = { CODEX_HOME = f.home, REX_RECOVER_SESSIONS = "1", REX_CODEX_SESSION_FILE = path },
    }, { call = forbidden, exec = forbidden, json = { decode = forbidden } }), nil)
  end)

  test("opted-in v2 never checkpoints or replays the original prompt", function()
    local f = fixture()
    tick(f)
    equal(checkpoint(f).apps, {})
    equal(checkpoint(f).pending, {})
    f.status.instance_id = "run:two"
    f.tree = { foreground = { pid = 8001, name = "zsh" } }
    tick(f)
    equal(checkpoint(f).apps, {})
    equal(checkpoint(f).pending, {})
    equal(f.writes, {})
  end)

  test("legacy title-derived opted-in records cannot revive from apps or pending", function()
    for _, kind in ipairs({ "apps", "pending" }) do
      local f = fixture()
      local previous = {
        version = 1, host_id = "host:private", instance_id = "run:old",
        apps = {}, pending = {},
      }
      previous[kind]["block:codex"] = {
        session_id = "session:selected", block_id = "block:codex", app = "codex",
        cwd = f.cwd, tracked = true, argv = { "/fixture/codex", "resume", beta },
        env = { CODEX_HOME = f.home, REX_RECOVER_SESSIONS = "1" },
      }
      assert(recovery.save(f.options.state_path, previous, rex.json))
      f.tree = { foreground = { pid = 8001, name = "zsh" } }
      tick(f)
      equal(f.writes, {})
      equal(checkpoint(f).apps, {})
      equal(checkpoint(f).pending, {})
    end
  end)

  test("non-opted-in v1 retains and restores exact literal argv once", function()
    local f = fixture()
    launch(f, true)
    tick(f)
    local record = assert(checkpoint(f).apps["block:codex"])
    equal(record.argv, { "/fixture/codex", "--model", "model name", "--config",
      'model_reasoning_effort="low"', "a'b", "$(touch never)", "" })
    equal(record.cwd, "/workspace/project's same")
    equal(record.env, nil)
    f.status.instance_id = "run:two"
    f.tree = { foreground = { pid = 8001, name = "zsh" } }
    tick(f)
    equal(f.writes, { {
      session_id = "session:selected", block_id = "block:codex",
      args = { data = "cd -- '/workspace/project'\\''s same' && REX_RECOVER_LAUNCH_DIR=" ..
        quote(f.options.launch_dir) .. " REX_SESSION='session:selected' REX_BLOCK='block:codex' " ..
        quote(f.options.launcher) .. " '/fixture/codex' '--model' 'model name' '--config' " ..
        "'model_reasoning_effort=\"low\"' 'a'\\''b' '$(touch never)' ''\r" },
    } })
    tick(f)
    equal(#f.writes, 1)
  end)

  print("Codex session contract artifacts: " .. base)
  assert(#failures == 0, table.concat(failures, "\n"))
  print("Codex session contract tests passed")
  return
end

local function wait_for(description, check)
  for _ = 1, 200 do
    if check() then return end
    rex.sleep(0.1)
  end
  error("timed out: " .. description)
end

local fixture_path = directory .. "/sessions.json"
local fixture
local function save() write(fixture_path, assert(rex.json.encode(fixture))) end
local function process(index)
  return call("com.superlogical.terminal.process", {
    session_id = fixture.session_id, block_id = fixture.blocks[index],
  }).foreground
end
local function input(index, text)
  call("com.superlogical.terminal.write", {
    session_id = fixture.session_id, block_id = fixture.blocks[index], args = { data = text .. "\r" },
  })
end
local function state()
  return assert(recovery.load(directory .. "/watcher/checkpoint.json", rex.json))
end
local function log(index, pid)
  return directory .. "/sessions-app/logs/" .. fixture.blocks[index] .. "." .. pid
end
local targets = { [3] = alpha, [4] = beta }
local daemon_config = "[features]\ndaemon_auto_start = false\n"
local function home(index)
  return targets[index] and fixture.home .. " " .. index or fixture.home
end
local function arguments(index, restored)
  if index <= 2 then return { "--config", config, "launch prompt stays literal" } end
  local argv = index == 3 and { "--no-daemon" } or {}
  if restored then
    argv[#argv + 1], argv[#argv + 2] = "resume", targets[index]
  else
    argv[#argv + 1] = "launch prompt must not replay in pane " .. index
  end
  return argv
end
local function received(index, restored)
  return table.concat({ fixture.cwd, home(index), index ~= 2 and "1" or "",
    table.concat(arguments(index, restored), "\0") }, "\0") .. "\0"
end
local function logs()
  local result = assert(rex.exec({ "ls", "-1", directory .. "/sessions-app/logs" }))
  assert(result.ok, result.stderr)
  return result.stdout
end
local function no_blocked_launch()
  local count = 0
  for name in logs():gmatch("[^\n]+") do
    if name:sub(1, #fixture.blocks[1] + 1) == fixture.blocks[1] .. "." then count = count + 1 end
  end
  equal(count, 1)
  assert(not state().apps[fixture.blocks[1]], "opted-in Codex became generic recovery")
  assert(not state().pending[fixture.blocks[1]], "opted-in Codex gained pending recovery")
end

if phase == "setup" then
  local endpoint
  for _, listener in ipairs(call("server.status").listeners or {}) do
    if listener.primary and listener.transport == "unix" then endpoint = listener.endpoint end
  end
  assert(endpoint, "private fixture requires its primary Unix endpoint")
  local windows = {}
  for index = 1, 4 do
    windows[index] = { window_label = "Codex fixture " .. index, layout = rex.layout.block {
      flavor = "com.superlogical.terminal.shell",
      options = { command = { "/bin/zsh", "-f" }, shell = "none", cwd = directory .. "/session project" },
    } }
  end
  local created = call("session.create", { label = "codex-recovery", initial_windows = windows })
  fixture = { session_id = created.session_id, blocks = {}, pids = {},
    cwd = directory .. "/session project", home = directory .. "/session's home",
    executable = directory .. "/sessions-app/codex", instance_id = call("server.status").instance_id }
  call("session.attach", { session_id = fixture.session_id })
  for index = 1, 4 do
    fixture.blocks[index] = created.initial_windows[index].block_ids[1]
    local id = targets[index]
    if id then
      local rollouts = home(index) .. "/sessions/2026/11/16"
      assert(rex.exec({ "mkdir", "-p", rollouts }).ok)
      local transcript = rollouts .. "/rollout-2026-11-16T12-00-00-" .. id .. ".jsonl"
      write(transcript, assert(rex.json.encode({
        type = "session_meta", payload = { id = id, session_id = id, source = "cli", thread_source = "user" },
      })) .. "\n")
      for _, source in ipairs({ "startup", "resume" }) do
        write(home(index) .. "/fixture-" .. source .. ".json", assert(rex.json.encode({
          hook_event_name = "SessionStart", session_id = id, transcript_path = transcript,
          cwd = fixture.cwd, model = "fixture", permission_mode = "default", source = source,
        })))
      end
      if index == 4 then write(home(index) .. "/config.toml", daemon_config) end
    end
    wait_for("fixture shell", function() return process(index) and process(index).name == "zsh" end)
    local quoted = {}
    for _, argument in ipairs(arguments(index)) do quoted[#quoted + 1] = quote(argument) end
    input(index, "unset REX_RECOVER_CONFIG REX_RECOVER_LAUNCH_DIR REX_RECOVER_SESSIONS; " ..
      "export CODEX_HOME=" .. quote(home(index)) ..
      (index ~= 2 and " REX_RECOVER_SESSIONS=1" or "") ..
      " REX_SERVER=" .. quote(endpoint) ..
      " REX_RECOVER_STATE_DIR=" .. quote(directory .. "/watcher") ..
      " REX_SESSION=" .. quote(fixture.session_id) .. " REX_BLOCK=" .. quote(fixture.blocks[index]) ..
      "; " .. quote(rex.args.root .. "/bin/rex-recover-run") .. " " .. quote(fixture.executable) ..
      " " .. table.concat(quoted, " "))
    wait_for("fixture launch log", function()
      local current = process(index)
      local file = current and io.open(log(index, current.pid), "rb")
      if file then
        local text = file:read("*a")
        file:close()
        if text == received(index) then
          fixture.pids[index] = current.pid
          return true
        end
      end
    end)
    equal(read(log(index, fixture.pids[index])), received(index))
    local recorded = assert(recovery.read_launch(directory .. "/watcher/launches/" .. fixture.blocks[index]))
    equal(recorded.driver, index ~= 2 and "openai-codex" or nil)
    if id then
      equal(process(index).name, "codex")
      input(index, "start")
    end
  end
  save()
else
  fixture = assert(rex.json.decode(read(fixture_path)))
  call("session.attach", { session_id = fixture.session_id })
end

if phase == "setup" then
  -- Launch logs were checked above; discovery runs in checkpoint.
elseif phase == "checkpoint" then
  wait_for("two scoped SessionStart checkpoints and the generic pane", function()
    local current = state()
    if current.instance_id ~= call("server.status").instance_id then return false end
    local record = current.apps[fixture.blocks[2]]
    if not record then return false end
    equal(record.argv, { fixture.executable, "--config", 'model_reasoning_effort="low"',
      "launch prompt stays literal" })
    equal(record.cwd, fixture.cwd)
    equal(record.env, nil)
    for index = 3, 4 do
      local selected = current.apps[fixture.blocks[index]]
      if not selected then return false end
      local expected = arguments(index, true)
      table.insert(expected, 1, fixture.executable)
      equal(selected.argv, expected)
      equal(selected.cwd, fixture.cwd)
      equal(selected.env, { CODEX_HOME = home(index), REX_RECOVER_SESSIONS = "1" })
      assert(type(selected.proof) == "string")
    end
    no_blocked_launch()
    return true
  end)
elseif phase == "new" then
  input(1, "new")
  wait_for("fake app activity", function()
    local file = io.open(directory .. "/sessions-app/inputs/" .. fixture.blocks[1], "rb")
    if file then file:close(); return true end
  end)
  equal(process(1).pid, fixture.pids[1])
  no_blocked_launch()
  assert(state().apps[fixture.blocks[2]], "blocked app activity erased generic recovery")
elseif phase == "restored" then
  assert(fixture.instance_id ~= call("server.status").instance_id, "server instance did not change")
  wait_for("opted-in pane remains an idle shell", function()
    -- Rex restores a login shell, not the explicit zsh used at setup.
    local current = process(1)
    return current and (current.name == "zsh" or current.name == "bash")
  end)
  wait_for("generic Codex fixture restores exact original argv", function()
    local current = process(2)
    if not current or current.pid == fixture.pids[2] then return false end
    local file = io.open(log(2, current.pid), "rb")
    if not file then return false end
    local text = file:read("*a")
    file:close()
    -- Generic v1 preserves argv/cwd, not the original app-specific environment.
    local cwd, _, mode, arguments = text:match("^([^%z]*)%z([^%z]*)%z([^%z]*)%z(.*)$")
    if cwd ~= fixture.cwd or mode ~= "" or arguments ~=
      "--config\0model_reasoning_effort=\"low\"\0launch prompt stays literal\0" then return false end
    fixture.pids[2] = current.pid
    return true
  end)
  for index = 3, 4 do
    wait_for("Codex pane " .. index .. " restores its own UUID and store", function()
      local current = process(index)
      if not current or current.pid == fixture.pids[index] then return false end
      local file = io.open(log(index, current.pid), "rb")
      if not file then return false end
      local text = file:read("*a")
      file:close()
      if text:sub(-1) ~= "\0" then return false end
      equal(text, received(index, true))
      fixture.pids[index] = current.pid
      return true
    end)
    -- Opening a restored session does not emit a hook until the first turn.
    input(index, "start")
  end
  equal(read(home(4) .. "/config.toml"), daemon_config)
  no_blocked_launch()
  fixture.instance_id = call("server.status").instance_id
  save()
elseif phase == "exit" then
  for index = 2, 4 do input(index, "exit") end
  wait_for("intentional exits removed", function()
    local current = state()
    for index = 2, 4 do if current.apps[fixture.blocks[index]] then return false end end
    return true
  end)
  no_blocked_launch()
  fixture.logs = logs()
  save()
elseif phase == "not-restored" then
  rex.sleep(1)
  equal(logs(), fixture.logs)
  no_blocked_launch()
  for index = 2, 4 do
    assert(not state().apps[fixture.blocks[index]], "completed app regained a checkpoint")
  end
else
  error("unknown session integration phase: " .. phase)
end

print("ok - Codex recorder and recovery integration: " .. phase)
