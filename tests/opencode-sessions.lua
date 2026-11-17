package.path = rex.args.root .. "/?.lua;" .. package.path

local function equal(actual, expected)
  assert(rex.json.encode(actual) == rex.json.encode(expected),
    "expected " .. tostring(rex.json.encode(expected)) .. ", got " .. tostring(rex.json.encode(actual)))
end

local function write(path, text)
  local file = assert(io.open(path, "wb"))
  assert(file:write(text))
  assert(file:close())
end

if rex.args.phase and rex.args.phase ~= "unit" then
  local directory, phase = rex.args.test_dir, rex.args.phase
  local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
  end
  local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
  local function call(method, arguments)
    local result, err = rex.call(method, arguments)
    assert(result, err)
    return result
  end
  local function wait_for(description, check)
    for _ = 1, 250 do
      if check() then return end
      rex.sleep(0.1)
    end
    error("timed out: " .. description)
  end
  local fixture_file = directory .. "/opencode-fixture.json"
  local fixture
  local function save() write(fixture_file, assert(rex.json.encode(fixture))) end
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
  local recovery = require("recovery")
  local function state() return assert(recovery.load(directory .. "/watcher/checkpoint.json", rex.json)) end
  if phase == "setup" then
    local windows = {}
    for index = 1, 2 do
      windows[index] = { window_label = "OpenCode mock " .. index, layout = rex.layout.block {
        flavor = "com.superlogical.terminal.shell",
        options = { command = { "/bin/zsh", "-f" }, shell = "none", cwd = directory .. "/opencode-project" },
      } }
    end
    local created = call("session.create", { label = "opencode-mock", initial_windows = windows })
    fixture = {
      session_id = created.session_id, blocks = {}, pids = {}, selected = { "ses_betaRoot", "ses_alphaRoot" },
      standalone = { false, true },
      home = directory .. "/opencode-home", cwd = directory .. "/opencode-project",
      executable = directory .. "/opencode-app/opencode", instance_id = call("server.status").instance_id,
    }
    call("session.attach", { session_id = fixture.session_id })
    for index = 1, 2 do
      fixture.blocks[index] = created.initial_windows[index].block_ids[1]
      write(directory .. "/opencode-app/" .. fixture.blocks[index] .. ".selected", fixture.selected[index])
      wait_for("OpenCode mock shell", function() return process(index) and process(index).name == "zsh" end)
      input(index, "unset REX_RECOVER_CONFIG REX_RECOVER_LAUNCH_DIR; export HOME=" .. quote(fixture.home) ..
        " XDG_CONFIG_HOME=" .. quote(fixture.home .. "/config") ..
        " XDG_DATA_HOME=" .. quote(fixture.home .. "/data") ..
        " XDG_STATE_HOME=" .. quote(fixture.home .. "/state") ..
        " XDG_CACHE_HOME=" .. quote(fixture.home .. "/cache") ..
        " OPENCODE_DB=" .. quote(fixture.home .. "/data/opencode.db") ..
        " REX_RECOVER_SESSIONS=1 REX_RECOVER_STATE_DIR=" .. quote(directory .. "/watcher") ..
        " REX_SESSION=" .. quote(fixture.session_id) .. " REX_BLOCK=" .. quote(fixture.blocks[index]) ..
        "; " .. quote(rex.args.root .. "/bin/rex-recover-run") .. " " .. quote(fixture.executable) ..
        (index == 1 and "" or " --standalone") ..
        " --session ses_launchAlpha --prompt 'never replay the initial request' --auto")
      wait_for("OpenCode mock launch", function() return process(index) and process(index).cwd == "/" end)
      fixture.pids[index] = process(index).pid
    end
    save()
  else
    fixture = assert(rex.json.decode(read(fixture_file)))
    call("session.attach", { session_id = fixture.session_id })
  end
  if phase == "checkpoint" then
    wait_for("exact OpenCode checkpoints", function()
      local current = state()
      if current.instance_id ~= call("server.status").instance_id then return false end
      for index = 1, 2 do
        local record = current.apps[fixture.blocks[index]]
        local expected = index == 1
          and { fixture.executable, "--session", "ses_betaRoot", "--auto" }
          or { fixture.executable, "--standalone", "--session", "ses_alphaRoot", "--auto" }
        if not record or record.argv[index == 1 and 3 or 4] ~= fixture.selected[index] then return false end
        equal(record.argv, expected)
        equal(record.cwd, fixture.cwd)
        equal(record.env.HOME, fixture.home)
        equal(record.env.OPENCODE_DB, fixture.home .. "/data/opencode.db")
        equal(record.env.OPENCODE_CONFIG_CONTENT, false)
      end
      return true
    end)
  elseif phase == "invalidate" then
    input(1, "new")
    wait_for("empty home removes prior checkpoint", function() return not state().apps[fixture.blocks[1]] end)
    input(1, "beta")
  elseif phase == "restored" then
    assert(fixture.instance_id ~= call("server.status").instance_id)
    for index = 1, 2 do
      wait_for("OpenCode exact mock resume", function()
        local current = process(index)
        return current and current.pid ~= fixture.pids[index] and current.cwd == "/"
          and io.open(directory .. "/opencode-app/logs/" .. fixture.blocks[index] .. "." .. current.pid, "rb")
      end)
      fixture.pids[index] = process(index).pid
      local expected = { fixture.cwd, fixture.home, fixture.home .. "/config", fixture.home .. "/data",
          fixture.home .. "/state", fixture.home .. "/cache", fixture.home .. "/data/opencode.db",
          "unset", "1" }
      local arguments = index == 1 and { "--session", "ses_betaRoot", "--auto", "" }
        or { "--standalone", "--session", "ses_alphaRoot", "--auto", "" }
      for _, argument in ipairs(arguments) do expected[#expected + 1] = argument end
      equal(read(directory .. "/opencode-app/logs/" .. fixture.blocks[index] .. "." .. fixture.pids[index]),
        table.concat(expected, "\0"))
    end
    fixture.instance_id = call("server.status").instance_id
    save()
  elseif phase == "exit" then
    for index = 1, 2 do input(index, "exit") end
    wait_for("completed OpenCode mocks removed", function()
      local current = state()
      return not current.apps[fixture.blocks[1]] and not current.apps[fixture.blocks[2]]
    end)
  elseif phase == "not-restored" then
    rex.sleep(0.5)
    for index = 1, 2 do
      local name = process(index).name
      assert(name == "zsh" or name == "bash", "expected a restored login shell, got " .. name)
    end
  elseif phase ~= "setup" then error("unknown OpenCode phase: " .. phase) end
  print("ok - OpenCode mock integration: " .. phase)
  return
end

local directory = rex.args.test_dir .. "/opencode-unit"
assert(rex.exec({ "mkdir", "-p", directory }).ok)
local database = directory .. "/conversation's store.db"
write(database, "SQLite format 3\0fixture database")
local selected = "ses_selectedBeta"
local environment = {
  XDG_CONFIG_HOME = "/fixture/config", XDG_DATA_HOME = "/fixture/data",
  XDG_STATE_HOME = "/fixture/state", XDG_CACHE_HOME = "/fixture/cache",
  OPENCODE_DB = database,
  OPENCODE_CONFIG_DIR = false, OPENCODE_CONFIG = false, OPENCODE_CONFIG_CONTENT = false,
  OPENCODE_CLI_CONFIG_CONTENT = false, OPENCODE_CONFIG_PROJECT_DISABLE = false,
  OPENCODE_DISABLE_PROJECT_CONFIG = false, OPENCODE_DISABLE_CLAUDE_CODE = false,
  OPENCODE_DISABLE_CLAUDE_CODE_SKILLS = false, OPENCODE_TEST_HOME = false,
  OPENCODE_FLAGS = false, OPENCODE_SIMULATE = false, OPENCODE_SERVICE_FILE = false,
}
local rpc_context = {
  state = "ready", pid = 9001, version = "2.3.0", channel = "latest", home = "/fixture/home",
  env = { XDG_CONFIG_HOME = "/fixture/config", XDG_DATA_HOME = "/fixture/data",
    XDG_STATE_HOME = "/fixture/state", XDG_CACHE_HOME = "/fixture/cache", OPENCODE_DB = database },
  file = { dev = "1", ino = "2" },
  session = { id = "ses_selectedBeta", location = { directory = "/workspace/project" } },
}
local function absent_context()
  local context = assert(rex.json.decode(assert(rex.json.encode(rpc_context))))
  context.state, context.session = "absent", nil
  return context
end
local launch = {
  app = "opencode", home = "/fixture/home", cwd = "/workspace/original",
  argv = { "/fixture/opencode", "--standalone", "--session", "ses_launchAlpha",
    "--prompt", "never submit this twice", "--auto", "../project" },
  pid = 7001, session_id = "session:opencode", block_id = "block:opencode",
  started_at = "Mon Nov 16 12:00:00 2026", selection_path = directory .. "/selected.session",
}
local api = { json = rex.json }
local function sidecar(signal, binding, owner_pid, owner_started_at)
  local value = {
    version = 1,
    launch = binding or {
      pid = 7001, started_at = launch.started_at, session_id = "session:opencode",
      block_id = "block:opencode", app = "opencode",
    },
    owner_pid = owner_pid or 7001, owner_started_at = owner_started_at or launch.started_at,
  }
  for key, entry in pairs(signal) do value[key] = entry end
  return assert(rex.json.encode(value))
end
write(launch.selection_path, sidecar({
  state = "ready", id = selected, home = "/fixture/home", env = rpc_context.env, managed = false,
}))
api.call = function() error("OpenCode identity must not read terminal titles") end
local driver = require("drivers.anomalyco-opencode")
local record = assert(driver.capture({
  api = api, launch = launch, processes = { foreground = { pid = 7001, name = "opencode" } },
}), "the selected OpenCode session was not captured")
equal(record.argv, { "/fixture/opencode", "--standalone", "--session", "ses_selectedBeta", "--auto", "../project" })
equal(record.env, environment)
equal(record.cwd, nil)
print("ok - OpenCode captures selected Beta with exact storage context and without replaying the prompt")

record.cwd = launch.cwd
record.env.HOME = launch.home
local validation_calls = 0
api.exec = function(argv, options)
  validation_calls = validation_calls + 1
  local expected = {
    "/usr/bin/env", "-u", "OPENCODE_CONFIG_DIR", "-u", "OPENCODE_CONFIG", "-u", "OPENCODE_CONFIG_CONTENT",
    "-u", "OPENCODE_CLI_CONFIG_CONTENT", "-u", "OPENCODE_CONFIG_PROJECT_DISABLE",
    "-u", "OPENCODE_DISABLE_PROJECT_CONFIG", "-u", "OPENCODE_DISABLE_CLAUDE_CODE",
    "-u", "OPENCODE_DISABLE_CLAUDE_CODE_SKILLS", "-u", "OPENCODE_TEST_HOME",
    "-u", "OPENCODE_FLAGS", "-u", "OPENCODE_SIMULATE", "-u", "OPENCODE_SERVICE_FILE",
    "/fixture/opencode",
  }
  local version_check = argv[#argv] == "--version"
  local suffix = version_check and { "--version" } or {
    "--standalone", "api", "post", "/api/rpc/rex-recover/context",
    "--data", '{"input":{"sessionID":"ses_selectedBeta"}}',
  }
  for _, value in ipairs(suffix) do expected[#expected + 1] = value end
  equal(argv, expected)
  equal(options, { cwd = "/workspace/original", env = {
    HOME = "/fixture/home", XDG_CONFIG_HOME = "/fixture/config", XDG_DATA_HOME = "/fixture/data",
    XDG_STATE_HOME = "/fixture/state", XDG_CACHE_HOME = "/fixture/cache", OPENCODE_DB = database,
  }, timeout = version_check and 5 or 15 })
  return { ok = true, stdout = version_check and "opencode v2.3.0\n"
    or assert(rex.json.encode({ output = rpc_context })) }
end
assert(driver.validate(record, api), "the existing exact session was not validated before recovery")
equal(validation_calls, 2)
print("ok - OpenCode verifies the binary version and attested store before recovery")

local failures = {}
local function test(name, run)
  local ok, err = pcall(run)
  if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
  print((ok and "ok - " or "FAIL - ") .. name .. (ok and "" or ": " .. tostring(err)))
end

local function capture(signal, arguments, owner, processes, binding)
  local current_launch = {}
  for key, value in pairs(launch) do current_launch[key] = value end
  current_launch.argv = arguments or launch.argv
  write(launch.selection_path, type(signal) == "string" and signal
    or sidecar(signal, binding, owner and owner.pid, owner and owner.started_at))
  return driver.capture({
    launch = current_launch,
    processes = processes or { foreground = { pid = 7001, name = "opencode" } },
    api = { json = rex.json, call = function() error("unexpected title lookup") end,
      exec = function(argv, options)
        equal(argv, { "ps", "-p", tostring(owner.pid), "-o", "lstart=" })
        equal(options, { env = { LC_ALL = "C" }, timeout = 2 })
        return { ok = true, stdout = (owner.actual_started_at or launch.started_at) .. "\n" }
      end },
  })
end

local function ready()
  return { state = "ready", id = "ses_selectedBeta", home = launch.home, managed = false,
    env = assert(rex.json.decode(assert(rex.json.encode(rpc_context.env)))) }
end

test("home, pending, unsupported, malformed and native display strings never select old history", function()
  for _, signal in ipairs({
    { state = "none" }, { state = "pending" }, {}, { state = "ready" },
    "OC | project title", "rex-recover:opencode:1:not JSON",
  }) do equal(capture(signal), nil) end
  for _, id in ipairs({ "", "other_id", "ses_bad/../path", "ses_bad\ninput" }) do
    local signal = ready()
    signal.id = id
    equal(capture(signal), nil)
  end
end)

test("every state rejects wrong pane, launch generation and reused owner start before interpretation", function()
  for _, state in ipairs({ "ready", "none", "pending", "error" }) do
    for _, field in ipairs({ "pid", "started_at", "session_id", "block_id", "app" }) do
      local binding = { pid = 7001, started_at = launch.started_at, session_id = launch.session_id,
        block_id = launch.block_id, app = "opencode" }
      binding[field] = field == "pid" and 7002 or "wrong"
      local signal = state == "ready" and ready() or { state = state }
      local result, err = capture(signal, nil, nil, nil, binding)
      assert(not result and not err, "foreign " .. state .. " metadata affected checkpoint")
    end
    local result, err = capture(state == "ready" and ready() or { state = state },
      nil, { pid = 7001, started_at = "old process" })
    assert(not result and not err)
  end
end)

test("foreign owners, ancestors above the launch and nested OpenCode processes cannot supply the ID", function()
  equal(capture(ready(), nil, { pid = 9001, name = "opencode" }), nil)
  equal(capture(ready(), nil, { pid = 7000, name = "opencode" }, {
    foreground = { pid = 7001, name = "sh" }, ancestors = { { pid = 7000, name = "opencode" } },
  }), nil)
  equal(capture(ready(), nil, { pid = 7002, name = "opencode" }, {
    foreground = { pid = 7002, name = "opencode" }, ancestors = { { pid = 7001, name = "opencode" } },
  }), nil)
  assert(capture(ready(), nil, { pid = 7002, name = "opencode" }, {
    foreground = { pid = 7002, name = "opencode" }, ancestors = { { pid = 7001, name = "node" } },
  }))
  equal(capture(ready(), nil, { pid = 7002, started_at = "prior child" }, {
    foreground = { pid = 7002, name = "opencode" }, ancestors = { { pid = 7001, name = "node" } },
  }), nil)
end)

test("the full selected ID, not cwd or launch selector, distinguishes same-project panes", function()
  local other = ready()
  other.id = "ses_otherPaneAlpha"
  equal(capture(ready()).argv[4], "ses_selectedBeta")
  equal(capture(other).argv[4], "ses_otherPaneAlpha")
end)

test("an attested managed session resumes without injecting standalone or replaying the initial prompt", function()
  local signal = ready()
  signal.managed = true
  local captured = assert(capture(signal, {
    "/fixture/opencode", "--session", "ses_launchAlpha", "--prompt", "never replay", "--auto", "./project",
  }), "the managed session was not captured")
  equal(captured.argv, { "/fixture/opencode", "--session", "ses_selectedBeta", "--auto", "./project" })
  equal(captured.env, environment)
  equal(capture(signal), nil)
end)

test("unattested shared, remote, headless, management and unknown-option launches are unsupported", function()
  for _, arguments in ipairs({
    {}, { "--session", "ses_old" }, { "run", "--session", "ses_old" },
    { "--standalone", "--server", "http://localhost:4096" },
    { "--standalone", "mini" }, { "--standalone", "api" }, { "--standalone", "debug" },
    { "--standalone", "--unknown" }, { "--standalone", "--fork" },
    { "--standalone", "--prompt" }, { "--standalone", "--session=" },
    { "--standalone", "first", "second" }, { "--standalone=false" },
  }) do
    local argv = { "/fixture/opencode" }
    for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
    equal(capture(ready(), argv), nil)
  end
end)

test("resume and continue selectors are replaced while path and permission flags keep their meaning", function()
  equal(capture(ready(), {
    "/fixture/opencode", "--standalone", "-sOLD", "-c", "--prompt=old request",
    "--yolo", "--print-logs", "--", "project",
  }).argv, { "/fixture/opencode", "--standalone", "--session", "ses_selectedBeta",
    "--yolo", "--print-logs", "--", "project" })
end)

test("missing roots, changed home, invalid relative paths and injected environments are rejected", function()
  for _, scenario in ipairs({ "home", "missing", "relative", "memory", "extra", "control" }) do
    local signal = ready()
    if scenario == "home" then signal.home = "/other/home"
    elseif scenario == "missing" then signal.env.XDG_STATE_HOME = nil
    elseif scenario == "relative" then signal.env.XDG_STATE_HOME = "relative"
    elseif scenario == "memory" then signal.env.OPENCODE_DB = ":memory:"
    elseif scenario == "extra" then signal.env.OPENCODE_CONFIG_CONTENT = "/not-preserved"
    else signal.env.XDG_CONFIG_HOME = "/config\ninjected" end
    equal(capture(signal), nil)
  end
end)

test("oversized selection files are errors but an absent companion has no selection", function()
  local result, err = capture(string.rep("x", 65537))
  assert(not result and err)
  assert(os.remove(launch.selection_path))
  result, err = driver.capture({ launch = launch, api = api,
    processes = { foreground = { pid = 7001, name = "opencode" } } })
  assert(not result and not err)
end)

test("database deletion or non-SQLite storage clears the resumable selection", function()
  local signal = ready()
  signal.env.OPENCODE_DB = directory .. "/missing.db"
  equal(capture(signal), nil)
  write(database, "not a sqlite database")
  equal(capture(ready()), nil)
  write(database, "SQLite format 3\0fixture database")
end)

test("pending/error and corrupt metadata preserve checkpoints; capture rejects concurrent selection changes", function()
  for _, signal in ipairs({ { state = "error" }, { state = "pending" }, "not JSON", "{}" }) do
    local result, err = capture(signal)
    assert(not result and err)
  end
  capture(ready())
  local calls = 0
  local result, err
  result = driver.capture({
    launch = launch, processes = { foreground = { pid = 7001, name = "opencode" } },
    api = { json = { decode = function(text)
      calls = calls + 1
      write(launch.selection_path, sidecar({ state = "none" }))
      return rex.json.decode(text)
    end } },
  })
  equal(result, nil)
  equal(calls, 1)
end)

local function validation_api(result)
  return { json = rex.json, exec = function(argv)
    if argv[#argv] == "--version" then return { ok = true, stdout = "opencode v2.3.0\n" } end
    return result
  end }
end

test("preflight distinguishes confirmed absent sessions from discovery and execution failures", function()
  for _, result in ipairs({
    { ok = true, stdout = assert(rex.json.encode({ output = absent_context() })) },
  }) do
    local accepted, err = driver.validate(record, validation_api(result))
    assert(not accepted and not err)
  end
  for _, message in ipairs({ "HTTP 404 Not Found", "HTTP 401 Unauthorized", "database is locked", "command timed out" }) do
    local accepted, err = driver.validate(record, validation_api({ ok = false, stdout = "", stderr = message }))
    assert(not accepted and err)
  end
end)

local function recovery_fixture(label, managed)
  local recovery = require("recovery")
  local registry = require("drivers.registry")
  local path = directory .. "/" .. label
  assert(rex.exec({ "mkdir", "-p", path .. "/launches" }).ok)
  local birth = "Mon Nov 16 12:00:00 2026"
  local fields = { "rex-recover-launch-v2", "session:opencode", "block:opencode", "7001", birth,
    "opencode", "/workspace/original", "anomalyco-opencode", "/fixture/home" }
  local arguments = managed and { "/fixture/opencode", "--session", "ses_launchAlpha",
    "--prompt", "never submit this twice", "--auto", "../project" } or launch.argv
  for _, argument in ipairs(arguments) do fields[#fields + 1] = argument end
  write(path .. "/launches/block:opencode", table.concat(fields, "\0") .. "\0")
  local fixture = {
    instance = "run:one", tree = { foreground = { pid = 7001, name = "opencode" } },
    writes = {}, preflights = 0,
  }
  local signal = ready()
  signal.managed = managed == true
  local hex = birth:gsub(".", function(byte) return string.format("%02x", byte:byte()) end)
  local selection_path = path .. "/launches/block:opencode.7001." .. hex .. ".session"
  write(selection_path, sidecar(signal))
  fixture.selection_path = selection_path
  local api = {
    json = rex.json, log = function() end,
    exec = function(argv)
      if argv[1] == "ps" then return { ok = true, stdout = birth .. "\n" } end
      if argv[#argv] == "--version" then return { ok = true, stdout = "opencode v2.3.0\n" } end
      fixture.preflights = fixture.preflights + 1
      assert(argv[1] == "/usr/bin/env" and argv[#argv] == '{"input":{"sessionID":"ses_selectedBeta"}}')
      if fixture.preflight_error then return nil, fixture.preflight_error end
      return fixture.preflight_result or {
        ok = true, stdout = assert(rex.json.encode({ output = rpc_context })),
      }
    end,
    call = function(method, request)
      if method == "server.status" then return { host_id = "host:fixture", instance_id = fixture.instance } end
      if method == "session.list" then return { sessions = { { session_id = "session:opencode" } } } end
      if method == "session.attach" then return {} end
      if method == "session.list_blocks" then
        local blocks = {
          { block_id = "block:opencode", creator_name = "com.superlogical.terminal", host_id = "host:fixture" },
        }
        if fixture.other then blocks[#blocks + 1] = {
          block_id = "block:other", creator_name = "com.superlogical.terminal", host_id = "host:fixture",
        } end
        return { blocks = blocks }
      end
      if method == "com.superlogical.terminal.process" then
        if request.block_id == "block:other" then
          return { foreground = { pid = 7101, name = "sample-viewer", cwd = "/workspace/other" } }
        end
        return fixture.tree
      end
      if method == "com.superlogical.terminal.input_mode" then
        return { canonical = false, echo = false, signals = true }
      end
      if method == "com.superlogical.terminal.write" then
        fixture.writes[#fixture.writes + 1] = request
        return { bytes_written = #request.args.data }
      end
      error("unexpected recovery method: " .. method)
    end,
  }
  fixture.options = {
    state_path = path .. "/checkpoint.json", launch_dir = path .. "/launches",
    launcher = rex.args.root .. "/bin/rex-recover-run", adapters = { registry.recorded("opencode", api) },
  }
  fixture.options.adapters[#fixture.options.adapters + 1] = {
    name = "sample-viewer", detect = function(process)
      if process.name == "sample-viewer" then return { argv = { "/fixture/viewer" }, cwd = process.cwd } end
    end,
  }
  function fixture.tick() return assert(recovery.new(api, fixture.options)):tick() end
  function fixture.checkpoint() return assert(recovery.load(fixture.options.state_path, rex.json)) end
  function fixture.bytes()
    local file = assert(io.open(fixture.options.state_path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
  end
  function fixture.restart()
    fixture.instance = "run:two"
    fixture.tree = { foreground = { pid = 8001, name = "zsh" } }
  end
  return fixture
end

test("a missing OpenCode companion does not block another application's checkpoint", function()
  local fixture = recovery_fixture("missing-companion-capture")
  assert(os.remove(fixture.selection_path))
  fixture.other = true
  assert(fixture.tick(), "an absent companion blocked the global scan")
  equal(fixture.checkpoint().apps["block:opencode"], nil)
  equal(fixture.checkpoint().apps["block:other"].argv, { "/fixture/viewer" })
end)

test("same-owned none clears a checkpoint without interpreting unused optional context", function()
  local fixture = recovery_fixture("none-unused-context")
  assert(fixture.tick())
  local signal = ready()
  signal.state, signal.id = "none", nil
  write(fixture.selection_path, sidecar(signal))
  assert(fixture.tick())
  equal(fixture.checkpoint().apps["block:opencode"], nil)
end)

test("pending, errors and malformed observer files preserve the existing checkpoint byte for byte", function()
  for index, signal in ipairs({ { state = "pending" }, { state = "error" }, "corrupt JSON",
    { state = "ready", id = "ses_selectedBeta", home = "/fixture/home", env = {}, managed = false },
  }) do
    local fixture = recovery_fixture("observer-error-" .. index)
    assert(fixture.tick())
    local before = fixture.bytes()
    write(fixture.selection_path, type(signal) == "string" and signal or sidecar(signal))
    local ok, err = fixture.tick()
    assert(not ok and err)
    equal(fixture.bytes(), before)
    equal(fixture.writes, {})
  end
end)

test("deleted sessions are removed before typing; OpenCode cannot silently create a replacement", function()
  local fixture = recovery_fixture("deleted")
  assert(fixture.tick())
  equal(fixture.checkpoint().apps["block:opencode"].argv,
    { "/fixture/opencode", "--standalone", "--session", "ses_selectedBeta", "--auto", "../project" })
  equal(fixture.preflights, 0)
  fixture.restart()
  fixture.preflight_result = { ok = true, stdout = assert(rex.json.encode({ output = absent_context() })) }
  assert(fixture.tick())
  equal(fixture.preflights, 1)
  equal(fixture.writes, {})
  equal(fixture.checkpoint().apps, {})
  equal(fixture.checkpoint().pending, {})
end)

test("OpenCode preflight execution failures preserve checkpoint bytes and never type a command", function()
  for index, message in ipairs({ "database is locked", "command timed out", "private child unavailable" }) do
    local fixture = recovery_fixture("preflight-error-" .. index)
    assert(fixture.tick())
    local before = fixture.bytes()
    fixture.restart()
    if index == 3 then fixture.preflight_error = message
    else fixture.preflight_result = { ok = false, stdout = "", stderr = message } end
    local ok, err = fixture.tick()
    assert(not ok and err)
    equal(fixture.bytes(), before)
    equal(fixture.writes, {})
  end
end)

test("malformed or mismatched preflight responses preserve the durable checkpoint", function()
  for index, output in ipairs({
    "not JSON", "null", "{}", '{"output":false}', '{"output":{"state":"absent"}}',
    '{"output":{"state":"ready","session":{"id":"ses_other","location":{"directory":"/workspace"}}}}',
    '{"output":{"state":"ready","session":{"id":"ses_selectedBeta","location":{"directory":"relative"}}}}',
  }) do
    local fixture = recovery_fixture("malformed-preflight-" .. index)
    assert(fixture.tick())
    local before = fixture.bytes()
    fixture.restart()
    fixture.preflight_result = { ok = true, stdout = output }
    local ok, err = fixture.tick()
    assert(not ok and err, "malformed API output consumed recovery")
    equal(fixture.bytes(), before)
    equal(fixture.writes, {})
  end
end)

test("managed recovery preserves the normal invocation and never requests a private service", function()
  local fixture = recovery_fixture("managed", true)
  assert(fixture.tick())
  equal(fixture.checkpoint().apps["block:opencode"].argv,
    { "/fixture/opencode", "--session", "ses_selectedBeta", "--auto", "../project" })
  fixture.restart()
  assert(fixture.tick())
  equal(fixture.preflights, 1)
  equal(#fixture.writes, 1)
  local command = fixture.writes[1].args.data
  assert(command:find("'/fixture/opencode' '--session' 'ses_selectedBeta' '--auto' '../project'", 1, true))
  assert(not command:find("--standalone", 1, true))
end)

test("a different managed store or binary version never consumes the checkpoint or replaces a service", function()
  for _, scenario in ipairs({ "database", "home", "version", "unsupported", "missing-companion" }) do
    local fixture = recovery_fixture("managed-mismatch-" .. scenario, true)
    assert(fixture.tick())
    local before = fixture.bytes()
    fixture.restart()
    local response = assert(rex.json.decode(assert(rex.json.encode(rpc_context))))
    if scenario == "database" then response.env.OPENCODE_DB = "/another/store.db"
    elseif scenario == "home" then response.home = "/another/home"
    elseif scenario == "version" then response.version = "2.4.0"
    elseif scenario == "unsupported" then response = { state = "unsupported" } end
    fixture.preflight_result = scenario == "missing-companion"
      and { ok = false, stdout = "", stderr = "HTTP 404 Not Found\n" }
      or { ok = true, stdout = assert(rex.json.encode({ output = response })) }
    local ok, err = fixture.tick()
    assert(not ok and err)
    equal(fixture.bytes(), before)
    equal(fixture.writes, {})
  end
end)

test("an absent session on a different managed store or version cannot discard the saved recovery", function()
  for _, scenario in ipairs({ "database", "version" }) do
    local fixture = recovery_fixture("absent-mismatch-" .. scenario, true)
    assert(fixture.tick())
    local before = fixture.bytes()
    fixture.restart()
    local response = absent_context()
    if scenario == "database" then response.env.OPENCODE_DB = "/another/store.db"
    else response.version = "2.4.0" end
    fixture.preflight_result = { ok = true, stdout = assert(rex.json.encode({ output = response })) }
    local ok, err = fixture.tick()
    assert(not ok and err, "an unrelated daemon discarded the saved recovery")
    equal(fixture.bytes(), before)
    equal(fixture.writes, {})
  end
end)

test("successful RPC responses without a database proof identity are discovery errors", function()
  local response = assert(rex.json.decode(assert(rex.json.encode(rpc_context))))
  response.file = nil
  local accepted, err = driver.validate(record, validation_api({
    ok = true, stdout = assert(rex.json.encode({ output = response })),
  }))
  assert(not accepted and err)
end)

assert(#failures == 0, table.concat(failures, "\n"))
