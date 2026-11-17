package.path = rex.args.runtime .. "/?.lua;" .. package.path

local runtime, directory, phase = rex.args.runtime, rex.args.test_dir, rex.args.phase

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
  assert(rex.json.encode(actual) == rex.json.encode(expected),
    "expected " .. tostring(rex.json.encode(expected)) .. ", got " .. tostring(rex.json.encode(actual)))
end

local function call(method, args)
  local result, err = rex.call(method, args)
  assert(result, err)
  return result
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

if phase == "invalid" then
  local ok, err = pcall(function()
    return require("drivers.registry").lookup("fixture-companion", rex)
  end)
  assert(not ok and err, "invalid driver descriptor was accepted by Lua registration")
  print("ok - invalid descriptor cannot register an executable")
  return
end

local registry = require("drivers.registry")
local recovery = require("recovery")

if phase == "discovery" or phase == "symlink" then
  local entry = assert(registry.lookup("fixture-companion"),
    phase == "symlink" and "a symlink-only provider definition did not register its executable"
      or "adding one provider-named file did not register its executable")
  equal(entry.id, "example-companion")
  equal(entry.home_env, "COMPANION_ARCHIVE_DIR")
  equal(entry.default_home, ".companion-archive")
  assert(registry.home_variable("COMPANION_ARCHIVE_DIR"),
    "new driver storage variable was not admitted for durable recovery")
  equal(registry.lookup("absent-tool"), nil)
  print("ok - " .. (phase == "symlink" and "symlink-only provider" or "one descriptor file") ..
    " registers its executable and unrelated storage variable")
  return
end

if phase == "ownership" then
  local adapter = registry.recorded("fixture-companion", rex)
  local launch = {
    session_id = "session:extension", block_id = "block:owner", app = "fixture-companion",
    pid = 7001, cwd = "/original", home = directory .. "/archive's store",
    driver = "example-companion", argv = { "/fixture/companion", "initial prompt" },
  }
  equal(recovery.capture("session:extension", "block:owner", {
    foreground = { pid = 7002, name = "other" },
  }, { adapter }, launch), nil)
  launch.driver = nil
  local generic = assert(recovery.capture("session:extension", "block:owner", {
    foreground = { pid = 7001, name = "fixture-companion" },
  }, { adapter }, launch))
  equal(generic.argv, { "/fixture/companion", "initial prompt" })
  equal(generic.env, nil)
  assert(not io.open(directory .. "/archive's store/capture-context.json", "r"),
    "generic or wrong-process capture called the provider")
  print("ok - driver callbacks require a matching live process; generic capture stays unchanged")
  return
end

if phase == "environment" or phase == "validation" then
  local home = directory .. "/archive's store"
  local state_path = directory .. "/context-checkpoint.json"
  local launch_dir = directory .. "/launches"
  local status = { host_id = "fixture-host", instance_id = "before" }
  local processes = { foreground = { pid = 7001, name = "fixture-companion" } }
  local writes = {}
  local api = {
    json = rex.json, log = function() end,
    exec = function(argv)
      if argv[1] ~= "ps" then return rex.exec(argv) end
      equal(argv, { "ps", "-p", "7001", "-o", "lstart=" })
      return { ok = true, stdout = "fixture-birth\n" }
    end,
    call = function(method, args)
      if method == "server.status" then return status end
      if method == "session.list" then return { sessions = { { session_id = "session:context" } } } end
      if method == "session.attach" then return {} end
      if method == "session.list_blocks" then return { blocks = { {
        block_id = "block:context", host_id = "fixture-host", creator_name = "com.superlogical.terminal",
      } } } end
      if method == "com.superlogical.terminal.process" then return processes end
      if method == "com.superlogical.terminal.write" then
        writes[#writes + 1] = args.args.data
        return {}
      end
      error("unexpected fixture API call: " .. method)
    end,
  }
  local options = {
    state_path = state_path, launch_dir = launch_dir, launcher = runtime .. "/bin/rex-recover-run",
    adapters = { registry.recorded("fixture-companion", api) },
  }
  if phase == "validation" then
    for _, scenario in ipairs({ "allow", "missing", "false", "error", "generic", "busy" }) do
      os.remove(state_path)
      writes = {}
      status = { host_id = "fixture-host", instance_id = "before" }
      processes = { foreground = { pid = 7001, name = "fixture-companion" } }
      local fields = {
        "rex-recover-launch-v2", "session:context", "block:context", "7001", "fixture-birth",
        "fixture-companion", "/original context", "example-companion", home,
        "/fixture/companion", "initial prompt",
      }
      if scenario == "generic" then
        fields[1] = "rex-recover-launch-v1"
        table.remove(fields, 8)
        table.remove(fields, 8)
      end
      write(launch_dir .. "/block:context", table.concat(fields, "\0") .. "\0")
      write(home .. "/selected-session", "validation-session\n")
      write(home .. "/validation-mode", "error\n")
      local m = assert(recovery.new(api, options))
      assert(m:tick(), "resume validation must not run during capture")
      status.instance_id = "after"
      processes = {
        child = { pid = 8001, name = "rex" }, foreground = { pid = 8001, name = "rex" },
      }
      assert(m:tick(), "resume validation must wait for a ready shell")
      equal(writes, {})
      assert(assert(recovery.load(state_path, rex.json)).pending["block:context"])
      processes = { foreground = { name = scenario == "busy" and "editor" or "zsh" } }
      local before = read(state_path)
      write(home .. "/validation-mode",
        (scenario == "generic" or scenario == "busy") and "error\n" or scenario .. "\n")
      local ok, err = m:tick()
      if scenario == "error" then
        assert(not ok and err == "fixture validation unavailable",
          "resume validation failure must fail the tick before consuming recovery")
        equal(read(state_path), before)
        equal(writes, {})
        write(home .. "/validation-mode", "allow\n")
        assert(assert(recovery.new(api, options)):tick())
        equal(#writes, 1)
        assert(writes[1]:find("'--resume' 'validation-session'\r", 1, true))
      elseif scenario == "missing" or scenario == "false" or scenario == "busy" then
        assert(ok, err)
        equal(writes, {})
        local saved = assert(recovery.load(state_path, rex.json))
        equal(saved.apps, {})
        equal(saved.pending, {})
        write(home .. "/validation-mode", "allow\n")
        processes = { foreground = { name = "zsh" } }
        assert(assert(recovery.new(api, options)):tick())
        equal(writes, {})
      else
        assert(ok, err)
        equal(#writes, 1)
        if scenario == "generic" then
          equal(writes[1], "cd -- '/original context' && REX_RECOVER_LAUNCH_DIR=" .. quote(launch_dir) ..
            " REX_SESSION='session:context' REX_BLOCK='block:context' " ..
            quote(options.launcher) .. " '/fixture/companion' 'initial prompt'\r")
        else
          assert(writes[1]:find("'--resume' 'validation-session'\r", 1, true))
        end
        assert(assert(recovery.new(api, options)):tick())
        equal(#writes, 1)
      end
    end
    print("ok - pre-resume validation allows, omits, or preserves recovery; capture, busy panes and v1 replay bypass it")
    return
  end
  options.launcher = directory .. "/context-launcher"
  write(launch_dir .. "/block:context", table.concat({
    "rex-recover-launch-v2", "session:context", "block:context", "7001", "fixture-birth",
    "fixture-companion", directory .. "/project", "example-companion", home, "/fixture/companion",
  }, "\0") .. "\0")
  write(home .. "/selected-session", "context-session\n")
  local environment = {
    XDG_CONFIG_HOME = "/private/config's store", XDG_DATA_HOME = "/private/data store",
    XDG_STATE_HOME = "/private/state", XDG_CACHE_HOME = "/private/cache",
    COMPANION_DB = "/private/database's store/main.db",
    COMPANION_CONFIG = false, COMPANION_INLINE_CONFIG = false,
  }
  write(home .. "/environment.json", assert(rex.json.encode(environment)))
  local m = assert(recovery.new(api, options))
  assert(m:tick())
  equal(assert(recovery.load(state_path, rex.json)).apps["block:context"].env, {
    COMPANION_ARCHIVE_DIR = home, REX_RECOVER_SESSIONS = "1",
    XDG_CONFIG_HOME = "/private/config's store", XDG_DATA_HOME = "/private/data store",
    XDG_STATE_HOME = "/private/state", XDG_CACHE_HOME = "/private/cache",
    COMPANION_DB = "/private/database's store/main.db",
    COMPANION_CONFIG = false, COMPANION_INLINE_CONFIG = false,
  })
  local before = read(state_path)
  for _, invalid in ipairs({
    { PATH = "/untrusted" }, { UNDECLARED_CONTEXT = "/private/unknown" },
    { PATH = false }, { UNDECLARED_CONTEXT = false },
    { XDG_CONFIG_HOME = "relative" }, { XDG_DATA_HOME = "/bad\nvalue" },
    { COMPANION_DB = 12 }, { XDG_STATE_HOME = {} },
    { ["BAD-NAME"] = "/private/bad" }, "not an environment",
  }) do
    write(home .. "/environment.json", assert(rex.json.encode(invalid)))
    local ok, err = m:tick()
    assert(not ok and err, "unsafe driver context entered the checkpoint")
    equal(read(state_path), before)
    equal(writes, {})
  end
  local orphan = assert(rex.json.decode(before))
  orphan.apps["block:context"].app = "retired-context"
  orphan.apps["block:context"].env = { REX_RECOVER_SESSIONS = "1", RETIRED_CONFIG = false }
  local orphan_text = assert(rex.json.encode(orphan))
  write(state_path, orphan_text)
  equal(assert(recovery.load(state_path, rex.json)).apps, {})
  equal(read(state_path), orphan_text)
  write(state_path, before)
  write(home .. "/environment.json", assert(rex.json.encode(environment)))
  status.instance_id = "after"
  processes = { foreground = { name = "zsh" } }
  m = assert(recovery.new(api, options))
  assert(m:tick())
  equal(writes, {
    "cd -- " .. quote(directory .. "/project") ..
    " && /usr/bin/env -u 'COMPANION_CONFIG' -u 'COMPANION_INLINE_CONFIG' COMPANION_ARCHIVE_DIR=" .. quote(home) ..
    " COMPANION_DB='/private/database'\\''s store/main.db' REX_RECOVER_SESSIONS='1'" ..
    " XDG_CACHE_HOME='/private/cache' XDG_CONFIG_HOME='/private/config'\\''s store'" ..
    " XDG_DATA_HOME='/private/data store' XDG_STATE_HOME='/private/state' " ..
    "REX_RECOVER_LAUNCH_DIR=" .. quote(launch_dir) ..
    " REX_SESSION='session:context' REX_BLOCK='block:context' " ..
    quote(options.launcher) .. " '/fixture/companion' '--resume' 'context-session'\r",
  })
  local scoped = assert(rex.exec({ "/bin/sh", "-c", writes[1]:sub(1, -2) ..
    "\nprintf '%s\\000' \"$COMPANION_CONFIG\" \"$COMPANION_INLINE_CONFIG\" \"$UNRELATED_CONTEXT\"" }, {
    env = {
      COMPANION_CONFIG = "/fixture/inherited config", COMPANION_INLINE_CONFIG = "fixture-inline",
      UNRELATED_CONTEXT = "untouched",
    },
  }))
  assert(scoped.ok, scoped.stderr)
  equal(scoped.stdout, "unset\0unset\0untouched\0/private/database's store/main.db\0" ..
    "/fixture/companion\0--resume\0context-session\0" ..
    "/fixture/inherited config\0fixture-inline\0untouched\0")
  os.remove(home .. "/environment.json")
  print("ok - declared paths and scoped unsets survive recovery without changing the shell; unsafe context is rejected")
  return
end

local fixture
local path = directory .. "/extension.json"
local function save()
  write(path, assert(rex.json.encode(fixture)))
end

local function process()
  return call("com.superlogical.terminal.process", {
    session_id = fixture.session_id, block_id = fixture.block_id,
  }).foreground
end

local function input(text)
  call("com.superlogical.terminal.write", {
    session_id = fixture.session_id, block_id = fixture.block_id, args = { data = text .. "\r" },
  })
end

local function state()
  return assert(recovery.load(directory .. "/watcher/checkpoint.json", rex.json))
end

if phase == "setup" then
  local created = call("session.create", { label = "driver-extension-test", initial_windows = {
    { window_label = "Invented provider", layout = rex.layout.block {
      flavor = "com.superlogical.terminal.shell",
      options = { command = { "/bin/zsh", "-f" }, shell = "none", cwd = directory .. "/project" },
    } },
  } })
  fixture = {
    session_id = created.session_id, block_id = created.initial_windows[1].block_ids[1],
    cwd = directory .. "/project", home = directory .. "/archive's store",
    executable = directory .. "/bin/fixture-companion", selected = "selection-one",
    instance_id = call("server.status").instance_id,
  }
  call("session.attach", { session_id = fixture.session_id })
  write(fixture.home .. "/selected-session", "selection-one\n")
  wait_for("extension shell", function() return process() and process().name == "zsh" end)
  input("unset REX_RECOVER_CONFIG REX_RECOVER_LAUNCH_DIR DRIVER_TEST_ONESHOT; " ..
    "export COMPANION_ARCHIVE_DIR=" .. quote(fixture.home) .. " REX_RECOVER_SESSIONS=1" ..
    " REX_RECOVER_STATE_DIR=" .. quote(directory .. "/watcher") ..
    " REX_BIN=" .. quote(rex.args.rex_bin) .. " REX_SERVER=" .. quote(rex.args.endpoint) ..
    " REX_SESSION=" .. quote(fixture.session_id) .. " REX_BLOCK=" .. quote(fixture.block_id) ..
    "; " .. quote(runtime .. "/bin/rex-recover-run") .. " " .. quote(fixture.executable) ..
    " --launch 'original prompt'")
  wait_for("extension app with changed cwd", function() return process() and process().cwd == "/" end)
  fixture.pid = process().pid
  equal(read(directory .. "/bin/logs/" .. fixture.block_id .. "." .. fixture.pid),
    fixture.cwd .. "\0" .. fixture.home .. "\0" .. "1\0--launch\0original prompt\0")
  save()
else
  fixture = assert(rex.json.decode(read(path)))
  call("session.attach", { session_id = fixture.session_id })
end

if phase == "checkpoint" then
  local context
  wait_for("extension-selected durable checkpoint", function()
    local current = state()
    local record = current.apps[fixture.block_id]
    if not record or record.argv[3] ~= fixture.selected then return false end
    equal(record.argv, { fixture.executable, "--resume", fixture.selected })
    equal(record.cwd, fixture.cwd)
    equal(record.env, { COMPANION_ARCHIVE_DIR = fixture.home, REX_RECOVER_SESSIONS = "1" })
    assert(record.tracked)
    if current.instance_id ~= call("server.status").instance_id then return false end
    -- Dispatch also saves the record. Wait for capture to observe the new PID.
    local file = io.open(fixture.home .. "/capture-context.json", "rb")
    if not file then return false end
    context = rex.json.decode(file:read("*a"))
    file:close()
    return context and context.foreground.pid == fixture.pid
  end)
  equal(context.launch.driver, "example-companion")
  equal(context.launch.home, fixture.home)
  equal(context.foreground.pid, fixture.pid)
  equal(context.foreground.cwd, "/")
  equal(context.selected, fixture.selected)
elseif phase == "select" then
  write(fixture.home .. "/selected-session", "unpersisted\n")
  wait_for("extension-declined session removed", function() return not state().apps[fixture.block_id] end)
  write(fixture.home .. "/selected-session", "selection-two\n")
  fixture.selected = "selection-two"
  save()
elseif phase == "restored" then
  assert(fixture.instance_id ~= call("server.status").instance_id, "server was not restarted")
  wait_for("actual extension resume invocation", function()
    local current = process()
    return current and current.pid ~= fixture.pid and current.cwd == "/"
      and io.open(directory .. "/bin/logs/" .. fixture.block_id .. "." .. current.pid, "rb")
  end)
  fixture.pid = process().pid
  equal(read(directory .. "/bin/logs/" .. fixture.block_id .. "." .. fixture.pid),
    fixture.cwd .. "\0" .. fixture.home .. "\0" .. "1\0--resume\0selection-two\0")
  fixture.instance_id = call("server.status").instance_id
  save()
elseif phase == "exit" then
  input("exit")
  wait_for("completed extension removed", function() return not state().apps[fixture.block_id] end)
elseif phase ~= "setup" then
  error("unknown extension phase: " .. tostring(phase))
end

print("ok - provider extension integration: " .. phase)
