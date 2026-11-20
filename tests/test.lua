package.path = rex.args.root .. "/?.lua;" .. package.path

local recovery = require("recovery")
local count, sequence = 0, 0
local birth = "Fri Nov 13 14:00:00 2026"
local temporary = assert(rex.exec({ "mktemp", "-d", rex.args.test_dir .. "/unit.XXXXXX" }))
assert(temporary.ok, temporary.stderr)
local run_directory = temporary.stdout:match("^%s*(.-)%s*$")

local function equal(actual, expected)
  assert(rex.json.encode(actual) == rex.json.encode(expected),
    "expected " .. rex.json.encode(expected) .. ", got " .. rex.json.encode(actual))
end

local function test(name, run)
  run()
  count = count + 1
  print("ok - " .. name)
end

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

local function command()
  return {
    session_id = "session:work", block_id = "block:worker", app = "sample-worker",
    cwd = "/workspace/it's here",
    argv = { "/usr/local/bin/sample-worker", "--label", "a b", "a'b", "$(touch never)", "" },
    tracked = true,
  }
end

local long_argument =
  "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" ..
  "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" ..
  "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" ..
  "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" ..
  "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" ..
  "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" ..
  "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

local function launch_file(path, record, pid, started_at)
  local fields = {
    "rex-recover-launch-v1", record.session_id, record.block_id, tostring(pid),
    started_at or birth, record.app, record.cwd,
  }
  for _, argument in ipairs(record.argv) do fields[#fields + 1] = argument end
  write(path, table.concat(fields, "\0") .. "\0")
end

local function fixture()
  sequence = sequence + 1
  local directory = run_directory .. "/case-" .. sequence
  assert(rex.exec({ "mkdir", "-p", directory .. "/launches" }).ok)
  local f = {
    status = { host_id = "host-a", instance_id = "run-a" },
    sessions = { { session_id = "session:work" } },
    blocks = {
      { block_id = "block:worker", creator_name = "com.superlogical.terminal", host_id = "host-a" },
      { block_id = "block:other", creator_name = "com.superlogical.terminal", host_id = "host-a" },
    },
    processes = {
      ["block:worker"] = { foreground = { pid = 7001, name = "runtime", cwd = "/changed/directory" } },
      ["block:other"] = { foreground = { pid = 7002, name = "unlisted-tool" } },
    },
    writes = {}, input_reads = {}, attached = {}, started_at = birth,
    options = {
      state_path = directory .. "/checkpoint.json", launch_dir = directory .. "/launches",
      launcher = "/plugin/bin/rex-recover-run",
      adapters = { recovery.recorded("sample-worker"), recovery.recorded("sample-viewer") },
    },
  }
  f.api = {
    json = rex.json,
    log = function() end,
    exec = function(argv)
      equal(argv, { "ps", "-p", "7001", "-o", "lstart=" })
      return { ok = true, stdout = f.started_at .. "\n" }
    end,
    call = function(method, args)
      if method == "server.status" then return f.status end
      if method == "session.list" then return { sessions = f.sessions } end
      if method == "session.attach" then
        f.attached[args.session_id] = true
        return {}
      end
      if method == "session.list_blocks" then return { blocks = f.blocks } end
      assert(f.attached[args.session_id], "session was not attached")
      if method == "com.superlogical.terminal.process" then
        if f.process_error then return nil, "connection lost" end
        return f.processes[args.block_id]
      end
      if method == "com.superlogical.terminal.input_mode" then
        f.input_reads[#f.input_reads + 1] = args.block_id
        return f.input_mode, f.input_error
      end
      if method == "com.superlogical.terminal.write" then
        f.writes[#f.writes + 1] = args
        return { bytes_written = #args.args.data }
      end
      error("unexpected API call: " .. method)
    end,
  }
  launch_file(f.options.launch_dir .. "/block:worker", command(), 7001)
  return f
end

local function monitor(f)
  return assert(recovery.new(f.api, f.options))
end

local function checkpoint(f)
  return assert(recovery.load(f.options.state_path, rex.json))
end

local function restarted(f)
  f.status.instance_id = "run-b"
  f.processes["block:worker"] = { foreground = { name = "zsh" } }
end

local function long_launch(f)
  local record = command()
  record.cwd = "/workspace/long"
  record.argv = { "/usr/local/bin/sample-worker", "--payload", long_argument }
  launch_file(f.options.launch_dir .. "/block:worker", record, 7001)
  return record
end

local function retired_record(block_id)
  return {
    session_id = "session:work", block_id = block_id, app = "retired-agent",
    cwd = "/workspace/retired", argv = { "/retired/agent", "--resume", "saved-session" },
    tracked = true, env = { RETIRED_AGENT_HOME = "/private/retired store", REX_RECOVER_SESSIONS = "1" },
  }
end

local function retired_launch()
  return {
    "rex-recover-launch-v2", "session:work", "block:other", "7002", birth,
    "retired-agent", "/workspace/retired", "example-retired-agent", "/private/retired store",
    "/retired/agent", "--resume", "saved-session",
  }
end

test("configured commands capture their original folder and exact argument array", function()
  local launch = command()
  launch.pid = 7001
  equal(recovery.capture("session:work", "block:worker", {
    foreground = { pid = 7001, name = "runtime", cwd = "/changed/directory" },
  }, { recovery.recorded("sample-worker") }, launch), command())
end)

test("commands with no arguments use exactly the same capture path", function()
  local launch = {
    session_id = "session:work", block_id = "block:viewer", pid = 7001,
    app = "sample-viewer", cwd = "/workspace/original",
    argv = { "/usr/local/bin/sample-viewer" },
  }
  equal(recovery.capture("session:work", "block:viewer", {
    foreground = { pid = 7001, name = "sample-viewer", cwd = "/changed" },
  }, { recovery.recorded("sample-viewer") }, launch), {
    session_id = "session:work", block_id = "block:viewer", app = "sample-viewer",
    cwd = "/workspace/original", argv = { "/usr/local/bin/sample-viewer" }, tracked = true,
  })
end)

test("a recorded parent takes priority over a different configured foreground child", function()
  local launch = command()
  launch.pid = 7001
  equal(recovery.capture("session:work", "block:worker", {
    foreground = { pid = 7002, name = "sample-viewer" },
    ancestors = { { pid = 7001, name = "runtime" } },
  }, { recovery.recorded("sample-viewer"), recovery.recorded("sample-worker") }, launch), command())
end)

test("unlisted commands and records for other processes or terminals are ignored", function()
  for _, mismatch in ipairs({ "app", "pid", "session_id", "block_id" }) do
    local launch = command()
    launch.pid = 7001
    launch[mismatch] = mismatch == "pid" and 9999 or "different"
    equal(recovery.capture("session:work", "block:worker", {
      foreground = { pid = 7001, name = "runtime" },
    }, { recovery.recorded("sample-worker") }, launch), nil)
  end
  equal(recovery.capture("session:work", "block:worker", {
    foreground = { pid = 7001, name = "sample-worker" },
  }, { recovery.recorded("sample-worker") }), nil)
end)

test("launch records preserve empty arguments and shell metacharacters without parsing a command line", function()
  local f = fixture()
  local launch = assert(recovery.read_launch(f.options.launch_dir .. "/block:worker"))
  equal(launch.argv, {
    "/usr/local/bin/sample-worker", "--label", "a b", "a'b", "$(touch never)", "",
  })
  equal({ launch.pid, launch.started_at, launch.cwd }, { 7001, birth, "/workspace/it's here" })
end)

test("incomplete or unsupported launch files fail closed", function()
  local f = fixture()
  local path = f.options.launch_dir .. "/block:worker"
  for _, text in ipairs({ "", "rex-recover-launch-v1", "unknown\0", "rex-recover-launch-v1\0short\0" }) do
    write(path, text)
    local launch, err = recovery.read_launch(path)
    assert(not launch and err)
  end
end)

test("unsafe arguments and relative working directories cannot enter checkpoints", function()
  for _, invalid in ipairs({
    { cwd = "/workspace/bad\ncommand", argv = { "/bin/sample-worker" } },
    { cwd = "/workspace", argv = { "/bin/sample-worker", "bad\rargument" } },
    { cwd = "/workspace", argv = {} },
    { cwd = "relative", argv = { "/bin/sample-worker" } },
  }) do
    local f = fixture()
    local record = command()
    record.cwd, record.argv = invalid.cwd, invalid.argv
    local ok, err = recovery.save(f.options.state_path, {
      version = 1, host_id = "host-a", instance_id = "run-a",
      apps = { ["block:worker"] = record }, pending = {},
    }, rex.json)
    assert(not ok and err)
  end
end)

test("the monitor checkpoints only configured live launches from their original folders", function()
  local f = fixture()
  assert(monitor(f):tick())
  equal(checkpoint(f), {
    version = 1, host_id = "host-a", instance_id = "run-a",
    apps = { ["block:worker"] = command() }, pending = {},
  })
  equal(f.writes, {})
end)

test("unchanged scans and watcher reconnects leave the checkpoint file untouched", function()
  for _, configured in ipairs({ true, false }) do
    local f = fixture()
    if not configured then f.options.adapters = {} end
    local m = monitor(f)
    assert(m:tick())
    local before = assert(rex.exec({ "ls", "-id", f.options.state_path })).stdout
    local saved = read(f.options.state_path)
    assert(m:tick())
    equal(assert(rex.exec({ "ls", "-id", f.options.state_path })).stdout, before)
    assert(monitor(f):tick())
    equal(assert(rex.exec({ "ls", "-id", f.options.state_path })).stdout, before)
    equal(read(f.options.state_path), saved)
    equal(f.writes, {})
  end
end)

test("a changed session selection replaces the checkpoint once and unchanged polling leaves it alone", function()
  local f = fixture()
  local selected = "first-session"
  f.options.adapters = { {
    name = "sample-worker",
    detect = function(process, launch)
      if launch and process.pid == launch.pid then
        return { cwd = launch.cwd, argv = { launch.argv[1], "resume", selected }, tracked = true }
      end
    end,
  } }
  local m = monitor(f)
  assert(m:tick())
  local before = assert(rex.exec({ "ls", "-id", f.options.state_path })).stdout
  selected = "latest-session"
  assert(m:tick())
  local changed = assert(rex.exec({ "ls", "-id", f.options.state_path })).stdout
  assert(changed ~= before, "a changed session selection was not saved")
  equal(checkpoint(f).apps["block:worker"].argv,
    { "/usr/local/bin/sample-worker", "resume", "latest-session" })
  assert(m:tick())
  equal(assert(rex.exec({ "ls", "-id", f.options.state_path })).stdout, changed)
  assert(monitor(f):tick())
  equal(assert(rex.exec({ "ls", "-id", f.options.state_path })).stdout, changed)
end)

test("launch owner start times prevent a reused PID from reviving an old record", function()
  local f = fixture()
  f.started_at = "Fri Nov 13 15:00:00 2026"
  assert(monitor(f):tick())
  equal(checkpoint(f).apps, {})
end)

test("the original launch stays active while a foreground child is running", function()
  local f = fixture()
  f.processes["block:worker"] = {
    foreground = { pid = 7003, name = "child-tool" },
    ancestors = { { pid = 7001, name = "runtime" } },
  }
  assert(monitor(f):tick())
  equal(checkpoint(f).apps["block:worker"], command())
end)

test("server recovery targets the same terminal and re-records a correctly quoted launch", function()
  local f = fixture()
  assert(monitor(f):tick())
  restarted(f)
  assert(monitor(f):tick())
  equal(f.writes, { {
    session_id = "session:work", block_id = "block:worker",
    args = { data = "cd -- '/workspace/it'\\''s here' && REX_RECOVER_LAUNCH_DIR='" ..
      f.options.launch_dir .. "' REX_SESSION='session:work' REX_BLOCK='block:worker' " ..
      "'/plugin/bin/rex-recover-run' '/usr/local/bin/sample-worker' " ..
      "'--label' 'a b' 'a'\\''b' '$(touch never)' ''\r" },
  } })
  equal(f.input_reads, {})
end)

test("long recovery input waits in canonical mode and dispatches its exact arguments once noncanonical", function()
  local f = fixture()
  local record = long_launch(f)
  local m = monitor(f)
  assert(m:tick())
  restarted(f)
  f.input_mode = { canonical = true, echo = true, signals = true }
  assert(m:tick())
  equal(f.writes, {})
  equal(checkpoint(f).pending["block:worker"], record)
  local waiting = read(f.options.state_path)
  local inode = assert(rex.exec({ "ls", "-id", f.options.state_path })).stdout
  assert(m:tick())
  assert(monitor(f):tick())
  equal(f.writes, {})
  equal(read(f.options.state_path), waiting)
  equal(assert(rex.exec({ "ls", "-id", f.options.state_path })).stdout, inode)
  f.input_mode.canonical = false
  assert(m:tick())
  equal(f.writes, { {
    session_id = "session:work", block_id = "block:worker",
    args = { data = "cd -- '/workspace/long' && REX_RECOVER_LAUNCH_DIR='" ..
      f.options.launch_dir .. "' REX_SESSION='session:work' REX_BLOCK='block:worker' " ..
      "'/plugin/bin/rex-recover-run' '/usr/local/bin/sample-worker' '--payload' '" ..
      long_argument .. "'\r" },
  } })
  equal(checkpoint(f).pending, {})
  assert(monitor(f):tick())
  equal(#f.writes, 1)
end)

test("the canonical input limit counts UTF-8 bytes and the final carriage return", function()
  -- The literal command framing cd -- '/w' && '/x' '...' plus CR is 22 bytes.
  for _, scenario in ipairs({
    { argument = string.rep("a", 1001), writes = 1, reads = {}, bytes = 1023 },
    { argument = string.rep("é", 501), writes = 0, reads = { "block:worker" } },
  }) do
    local f = fixture()
    local record = command()
    record.cwd, record.argv, record.tracked = "/w", { "/x", scenario.argument }, nil
    assert(recovery.save(f.options.state_path, {
      version = 1, host_id = "host-a", instance_id = "run-a",
      apps = { ["block:worker"] = record }, pending = {},
    }, rex.json))
    restarted(f)
    f.input_mode = { canonical = true, echo = true, signals = true }
    assert(monitor(f):tick())
    equal(#f.writes, scenario.writes)
    equal(f.input_reads, scenario.reads)
    if scenario.writes == 1 then
      equal(f.writes[1].args.data, "cd -- '/w' && '/x' '" .. scenario.argument .. "'\r")
      equal(#f.writes[1].args.data, scenario.bytes)
    else
      equal(checkpoint(f).pending["block:worker"], record)
    end
  end
end)

test("unavailable or malformed input modes cannot consume a long recovery command", function()
  for _, scenario in ipairs({
    { error = "input_mode is unsupported" },
    {},
    { mode = {} },
    { mode = "noncanonical" },
    { mode = { canonical = "false" } },
    { mode = { canonical = 0 } },
  }) do
    local f = fixture()
    long_launch(f)
    local m = monitor(f)
    assert(m:tick())
    local saved = read(f.options.state_path)
    local inode = assert(rex.exec({ "ls", "-id", f.options.state_path })).stdout
    restarted(f)
    f.input_mode, f.input_error = scenario.mode, scenario.error
    local ok, err = m:tick()
    assert(not ok and err, "an unknown input mode was treated as safe")
    equal(f.writes, {})
    equal(f.input_reads, { "block:worker" })
    equal(read(f.options.state_path), saved)
    equal(assert(rex.exec({ "ls", "-id", f.options.state_path })).stdout, inode)
    f.input_mode, f.input_error = { canonical = false, echo = false, signals = true }, nil
    assert(m:tick())
    equal(#f.writes, 1)
    assert(monitor(f):tick())
    equal(#f.writes, 1)
  end
end)

test("a canonical-mode blocked target stays pending while another terminal recovers", function()
  local f = fixture()
  local record = long_launch(f)
  local viewer = {
    session_id = "session:work", block_id = "block:other", app = "sample-viewer",
    cwd = "/workspace/viewer", argv = { "/usr/local/bin/sample-viewer", "--resume", "saved-session" },
    tracked = true,
  }
  launch_file(f.options.launch_dir .. "/block:other", viewer, 7002)
  local execute = f.api.exec
  f.api.exec = function(argv)
    if argv[3] == "7002" then
      equal(argv, { "ps", "-p", "7002", "-o", "lstart=" })
      return { ok = true, stdout = birth .. "\n" }
    end
    return execute(argv)
  end
  local m = monitor(f)
  assert(m:tick())
  restarted(f)
  f.processes["block:other"] = { foreground = { name = "zsh" } }
  f.input_mode = { canonical = true, echo = true, signals = true }
  assert(m:tick())
  equal(#f.writes, 1)
  equal(f.writes[1].block_id, "block:other")
  equal(checkpoint(f).pending, { ["block:worker"] = record })
  equal(checkpoint(f).apps, { ["block:other"] = viewer })
  equal(f.input_reads, { "block:worker" })
  f.input_mode.canonical = false
  assert(monitor(f):tick())
  equal(#f.writes, 2)
  equal(f.writes[2].block_id, "block:worker")
  assert(monitor(f):tick())
  equal(#f.writes, 2)
end)

test("reconnecting the watcher never queues the same recovery twice", function()
  local f = fixture()
  assert(monitor(f):tick())
  restarted(f)
  assert(monitor(f):tick())
  assert(monitor(f):tick())
  equal(#f.writes, 1)
end)

test("already-running launches are not duplicated after reconnection or server restart", function()
  local f = fixture()
  assert(monitor(f):tick())
  assert(monitor(f):tick())
  f.status.instance_id = "run-b"
  assert(monitor(f):tick())
  equal(f.writes, {})
end)

test("completed commands are removed rather than treated as server failures", function()
  local f = fixture()
  local m = monitor(f)
  assert(m:tick())
  f.processes["block:worker"] = { foreground = { name = "zsh" } }
  assert(m:tick())
  equal(checkpoint(f).apps, {})
  restarted(f)
  assert(m:tick())
  equal(f.writes, {})
end)

test("a completed terminal program is distinct from temporarily unknown process metadata", function()
  local f = fixture()
  local m = monitor(f)
  assert(m:tick())
  f.processes["block:worker"] = { last_exit = { exit_code = 0 } }
  assert(m:tick())
  restarted(f)
  assert(m:tick())
  equal(f.writes, {})
end)

test("unknown process metadata preserves a live checkpoint and delays recovery until ready", function()
  local f = fixture()
  local m = monitor(f)
  assert(m:tick())
  f.processes["block:worker"] = {}
  assert(m:tick())
  equal(checkpoint(f).apps["block:worker"], command())
  f.status.instance_id = "run-b"
  assert(m:tick())
  equal(f.writes, {})
  f.processes["block:worker"] = { foreground = { name = "zsh" } }
  assert(m:tick())
  equal(#f.writes, 1)
end)

test("restored terminal bootstrap stages preserve recovery until the shell is ready", function()
  local f = fixture()
  local m = monitor(f)
  assert(m:tick())
  restarted(f)
  f.processes["block:worker"] = {
    child = { pid = 8001, name = "rex" },
    foreground = { pid = 8001, name = "rex" },
  }
  assert(m:tick())
  equal(f.writes, {})
  equal(checkpoint(f).pending["block:worker"], command())
  assert(monitor(f):tick())
  equal(f.writes, {})
  f.processes["block:worker"] = {
    child = { pid = 8001, name = "login" },
    foreground = { pid = 8001, name = "login" },
  }
  assert(monitor(f):tick())
  equal(f.writes, {})
  equal(checkpoint(f).pending["block:worker"], command())
  f.processes["block:worker"] = {
    child = { pid = 8001, name = "login" },
    foreground = { pid = 8002, name = "zsh" },
    ancestors = { { pid = 8001, name = "login" } },
  }
  assert(monitor(f):tick())
  equal(#f.writes, 1)
  equal(f.writes[1].block_id, "block:worker")
  assert(monitor(f):tick())
  equal(#f.writes, 1)
end)

test("Rex and login commands inside a shell remain busy rather than deferred", function()
  for _, name in ipairs({ "rex", "login" }) do
    local f = fixture()
    local m = monitor(f)
    assert(m:tick())
    restarted(f)
    f.processes["block:worker"] = {
      child = { pid = 8001, name = "zsh" },
      foreground = { pid = 8002, name = name },
      ancestors = { { pid = 8001, name = "zsh" } },
    }
    assert(m:tick())
    equal(f.writes, {})
    equal(checkpoint(f).pending, {})
    f.processes["block:worker"] = { foreground = { pid = 8001, name = "zsh" } }
    assert(m:tick())
    equal(f.writes, {})
  end
end)

test("busy, missing, remote, completed, and nested-program terminals are skipped", function()
  for _, scenario in ipairs({ "busy", "missing", "remote", "completed", "nested" }) do
    local f = fixture()
    local m = monitor(f)
    assert(m:tick())
    restarted(f)
    if scenario == "busy" then f.processes["block:worker"] = { foreground = { name = "unlisted-tool" } }
    elseif scenario == "missing" then f.blocks = {}
    elseif scenario == "remote" then f.blocks[1].host_id = "another-host"
    elseif scenario == "completed" then f.processes["block:worker"] = { last_exit = { exit_code = 0 } }
    else f.processes["block:worker"] = {
      foreground = { name = "sh" }, ancestors = { { name = "unlisted-tool" } },
    } end
    assert(m:tick())
    equal(f.writes, {})
  end
end)

test("a target is checked again before typing if another program starts during recovery", function()
  local f = fixture()
  local m = monitor(f)
  assert(m:tick())
  restarted(f)
  local original, reads = f.api.call, 0
  f.api.call = function(method, args)
    if method == "com.superlogical.terminal.process" and args.block_id == "block:worker" then
      reads = reads + 1
      if reads > 1 then return { foreground = { name = "unlisted-tool" } } end
    end
    return original(method, args)
  end
  assert(m:tick())
  equal(f.writes, {})
end)

test("removing a configured app prevents its saved launch from being recovered", function()
  local f = fixture()
  assert(monitor(f):tick())
  restarted(f)
  f.options.adapters = {}
  assert(monitor(f):tick())
  equal(f.writes, {})
  equal(checkpoint(f).apps, {})
end)

test("without configured apps nothing is monitored or recovered", function()
  local f = fixture()
  f.options.adapters = nil
  local m = monitor(f)
  assert(m:tick())
  restarted(f)
  assert(m:tick())
  equal(checkpoint(f).apps, {})
  equal(f.writes, {})
end)

test("API failures and host mismatches leave the last durable checkpoint untouched", function()
  for _, failure in ipairs({ "api", "host" }) do
    local f = fixture()
    local m = monitor(f)
    assert(m:tick())
    local saved = read(f.options.state_path)
    if failure == "api" then f.process_error = true else f.status.host_id = "another-host" end
    local ok, err = m:tick()
    assert(not ok and err)
    equal(read(f.options.state_path), saved)
    equal(f.writes, {})
  end
end)

test("a process read failure before dispatch leaves recovery retryable after watcher reconnection", function()
  for _, failed_read in ipairs({ 1, 2 }) do
    local f = fixture()
    f.blocks = { f.blocks[1] }
    local m = monitor(f)
    assert(m:tick())
    local saved = read(f.options.state_path)
    restarted(f)
    local original, reads = f.api.call, 0
    f.api.call = function(method, args)
      if method == "com.superlogical.terminal.process" then
        reads = reads + 1
        if reads == failed_read then return nil, "process unavailable before dispatch" end
      end
      return original(method, args)
    end
    local ok, err = m:tick()
    assert(not ok and err == "process unavailable before dispatch")
    equal(f.writes, {})
    equal(read(f.options.state_path), saved)
    f.api.call = original
    assert(monitor(f):tick())
    equal(#f.writes, 1)
    equal(f.writes[1].block_id, "block:worker")
    assert(monitor(f):tick())
    equal(#f.writes, 1)
  end
end)

test("a later recovery failure preserves unattempted launches without replaying an attempted command", function()
  for _, failure in ipairs({ "process", "save", "acknowledgement" }) do
    local f = fixture()
    local viewer = {
      session_id = "session:work", block_id = "block:other", app = "sample-viewer",
      cwd = "/workspace/viewer", argv = { "/usr/local/bin/sample-viewer", "--resume", "saved-session" },
      tracked = true,
    }
    launch_file(f.options.launch_dir .. "/block:other", viewer, 7002)
    local execute = f.api.exec
    f.api.exec = function(argv)
      if argv[3] == "7002" then
        equal(argv, { "ps", "-p", "7002", "-o", "lstart=" })
        return { ok = true, stdout = birth .. "\n" }
      end
      return execute(argv)
    end
    local m = monitor(f)
    assert(m:tick())
    restarted(f)
    f.processes["block:other"] = { foreground = { name = "zsh" } }
    local original, reads, guards, saved = f.api.call, {}, 0, nil
    f.api.call = function(method, args)
      if method == "com.superlogical.terminal.process" then
        reads[args.block_id] = (reads[args.block_id] or 0) + 1
        if reads[args.block_id] == 2 then
          guards = guards + 1
          if failure == "process" and guards == 2 then
            return nil, "later process unavailable before dispatch"
          end
        end
      end
      local result = original(method, args)
      if method == "com.superlogical.terminal.write" and #f.writes == 1 then
        saved = read(f.options.state_path)
        if failure == "save" then
          assert(rex.exec({ "mkdir", f.options.state_path .. ".tmp" }).ok)
        elseif failure == "acknowledgement" then
          return nil, "write acknowledgement lost"
        end
      end
      return result
    end
    local ok, err = m:tick()
    assert(not ok and err, "the injected " .. failure .. " failure was ignored")
    equal(#f.writes, 1)
    local attempted = f.writes[1].block_id
    local unattempted = attempted == "block:worker" and "block:other" or "block:worker"
    equal(checkpoint(f).apps[attempted].block_id, attempted)
    assert(checkpoint(f).pending[unattempted], "an unattempted command was consumed")
    equal(read(f.options.state_path), saved)
    f.api.call = original
    if failure == "save" then
      assert(rex.exec({ "rmdir", f.options.state_path .. ".tmp" }).ok)
      assert(m:tick())
    else
      assert(monitor(f):tick())
    end
    equal(#f.writes, 2)
    equal(f.writes[2].block_id, unattempted)
    assert(monitor(f):tick())
    equal(#f.writes, 2)
  end
end)

test("losing Rex during the final process check cannot erase the last checkpoint", function()
  local f = fixture()
  f.blocks = { f.blocks[1] }
  local m = monitor(f)
  assert(m:tick())
  local saved = read(f.options.state_path)
  local original_call, original_exec = f.api.call, f.api.exec
  local disconnected = false
  f.api.call = function(method, args)
    if disconnected then return nil, "server went away" end
    return original_call(method, args)
  end
  f.api.exec = function(argv)
    equal(argv, { "ps", "-p", "7001", "-o", "lstart=" })
    disconnected = true
    return { ok = false, stdout = "" }
  end
  local ok, err = m:tick()
  assert(not ok and err, "a disconnected scan was saved as successful")
  equal(read(f.options.state_path), saved)
  equal(f.writes, {})
  f.api.call, f.api.exec = original_call, original_exec
  restarted(f)
  assert(monitor(f):tick())
  equal(#f.writes, 1)
end)

test("a server identity change during a scan leaves the previous checkpoint untouched", function()
  for _, changed in ipairs({ "host", "instance" }) do
    local f = fixture()
    f.blocks = { f.blocks[1] }
    local m = monitor(f)
    assert(m:tick())
    local saved = read(f.options.state_path)
    local original_exec = f.api.exec
    f.api.exec = function(argv)
      local result = original_exec(argv)
      f.status = {
        host_id = changed == "host" and "host-b" or "host-a",
        instance_id = changed == "instance" and "run-b" or "run-a",
      }
      return result
    end
    local ok, err = m:tick()
    assert(not ok and err, "a scan spanning different servers was accepted")
    equal(read(f.options.state_path), saved)
    equal(f.writes, {})
  end
end)

test("failed saves prevent command execution and can be retried after storage is repaired", function()
  local f = fixture()
  local m = monitor(f)
  assert(m:tick())
  local saved = read(f.options.state_path)
  restarted(f)
  assert(rex.exec({ "mkdir", f.options.state_path .. ".tmp" }).ok)
  local ok, err = m:tick()
  assert(not ok and err)
  equal(f.writes, {})
  equal(read(f.options.state_path), saved)
  equal(checkpoint(f).instance_id, "run-a")
  assert(rex.exec({ "rmdir", f.options.state_path .. ".tmp" }).ok)
  assert(m:tick())
  equal(#f.writes, 1)
  assert(monitor(f):tick())
  equal(#f.writes, 1)
end)

test("malformed and unsupported checkpoints are not overwritten", function()
  for _, text in ipairs({ "not JSON", '{"version":99,"apps":{},"pending":{}}' }) do
    local f = fixture()
    write(f.options.state_path, text)
    local m, err = recovery.new(f.api, f.options)
    assert(not m and err)
    equal(read(f.options.state_path), text)
  end
end)

test("duplicate configured identities and invalid tracking flags are rejected", function()
  local f = fixture()
  f.options.adapters = { recovery.recorded("sample-worker"), recovery.recorded("sample-worker") }
  local m, err = recovery.new(f.api, f.options)
  assert(not m and err)
  f.options.adapters = { recovery.recorded("sample-worker") }
  assert(monitor(f):tick())
  local state = checkpoint(f)
  state.apps["block:worker"].tracked = "yes"
  local ok
  ok, err = recovery.save(f.options.state_path, state, rex.json)
  assert(not ok and err)
end)

test("unsafe launcher and recording paths cannot become terminal input", function()
  for _, field in ipairs({ "launcher", "launch_dir" }) do
    local f = fixture()
    assert(monitor(f):tick())
    restarted(f)
    f.options[field] = "/private/unsafe\ncommand"
    local ok, err = monitor(f):tick()
    assert(not ok and err)
    equal(f.writes, {})
  end
end)

test("driver launch records retain original arguments and the selected storage home", function()
  local f = fixture()
  write(f.options.launch_dir .. "/block:worker", table.concat({
    "rex-recover-launch-v2", "session:work", "block:worker", "7001", birth,
    "codex", "/workspace/original", "openai-codex", "/private/agent home",
    "/usr/local/bin/codex", "--model", "model-name", "initial prompt", "",
  }, "\0") .. "\0")
  local launch = assert(recovery.read_launch(f.options.launch_dir .. "/block:worker"))
  equal({ launch.driver, launch.home, launch.argv }, {
    "openai-codex", "/private/agent home",
    { "/usr/local/bin/codex", "--model", "model-name", "initial prompt", "" },
  })
end)

test("only v2 driver launches expose a selection path bound to the PID and exact start time", function()
  local f = fixture()
  local path = f.options.launch_dir .. "/block:worker"
  assert(not assert(recovery.read_launch(path)).selection_path)
  write(path, table.concat({
    "rex-recover-launch-v2", "session:work", "block:worker", "7001", "Fri Nov 13 14:00:00 2026",
    "codex", "/workspace/original", "openai-codex", "/private/agent-home", "/usr/local/bin/codex",
  }, "\0") .. "\0")
  local launch = assert(recovery.read_launch(path))
  -- ASCII bytes for "Fri Nov 13 14:00:00 2026", including spaces and colons.
  equal(launch.selection_path,
    path .. ".7001.467269204e6f762031332031343a30303a30302032303236.session")
end)

test("a session driver's storage home survives checkpointing and quoted recovery", function()
  local f = fixture()
  f.options.adapters = { {
    name = "sample-worker",
    detect = function(process, launch)
      if launch and process.pid == launch.pid then
        return { cwd = launch.cwd, argv = launch.argv, tracked = true,
          env = { CODEX_HOME = "/private/agent's home" } }
      end
    end,
  } }
  local m = monitor(f)
  assert(m:tick())
  equal(checkpoint(f).apps["block:worker"].env, { CODEX_HOME = "/private/agent's home" })
  restarted(f)
  assert(m:tick())
  assert(f.writes[1].args.data:find("CODEX_HOME='/private/agent'\\''s home' ", 1, true),
    "the captured storage home was not restored as a literal environment value")
end)

test("driver metadata cannot attach a different app or an unsafe storage environment", function()
  local f = fixture()
  local path = f.options.launch_dir .. "/block:worker"
  write(path, table.concat({
    "rex-recover-launch-v2", "session:work", "block:worker", "7001", birth,
    "codex", "/workspace/original", "anthropic-claude-code", "/private/agent-home", "/usr/local/bin/codex",
  }, "\0") .. "\0")
  local launch, err = recovery.read_launch(path)
  assert(not launch and err, "a different application's driver was accepted")
  for _, env in ipairs({
    { PATH = "/untrusted" }, { CODEX_HOME = "relative" }, { CODEX_HOME = "/bad\nvalue" },
  }) do
    local record = command()
    record.env = env
    local ok, save_err = recovery.save(f.options.state_path, {
      version = 1, host_id = "host-a", instance_id = "run-a",
      apps = { ["block:worker"] = record }, pending = {},
    }, rex.json)
    assert(not ok and save_err, "an unsafe storage environment entered a checkpoint")
  end
end)

test("driver proof reaches restart validation but never becomes terminal input", function()
  local f = fixture()
  local proof = '{"test":"validate from disk only"}'
  local validated
  local launch = command()
  launch.app, launch.argv = "codex", { "/fixture/codex", "resume", "known-id" }
  launch_file(f.options.launch_dir .. "/block:worker", launch, 7001)
  f.options.adapters = { {
    name = "codex",
    detect = function(process, launch)
      if launch and process.pid == launch.pid then
        return { cwd = launch.cwd, argv = launch.argv, tracked = true, proof = proof,
          env = { CODEX_HOME = "/private/history", REX_RECOVER_SESSIONS = "1" } }
      end
    end,
    validate = function(record)
      validated = record.proof
      return validated == proof
    end,
  } }
  assert(monitor(f):tick())
  equal(checkpoint(f).apps["block:worker"].proof, proof)
  restarted(f)
  assert(monitor(f):tick())
  equal(validated, proof)
  equal(#f.writes, 1)
  assert(not f.writes[1].args.data:find("validate from disk only", 1, true))
end)

test("malformed or generic checkpoint proofs fail before replacing saved state", function()
  local f = fixture()
  assert(monitor(f):tick())
  local before = read(f.options.state_path)
  local state = checkpoint(f)
  local record = state.apps["block:worker"]
  for _, invalid in ipairs({ {}, "", "line\nbreak", string.rep("x", 8193) }) do
    record.env = { REX_RECOVER_SESSIONS = "1" }
    record.proof = invalid
    assert(not recovery.save(f.options.state_path, state, rex.json))
  end
  record.env = nil
  record.proof = "unverified generic proof"
  assert(not recovery.save(f.options.state_path, state, rex.json))
  equal(read(f.options.state_path), before)
end)

test("session discovery can bind a foreground descendant to its verified launch", function()
  local f = fixture()
  f.processes["block:worker"] = {
    foreground = { pid = 7003, name = "native-app" },
    ancestors = { { pid = 7001, name = "launcher" } },
  }
  f.options.adapters = { {
    name = "sample-worker",
    detect = function(process, launch, tree)
      if launch and process.pid == launch.pid and tree and tree.foreground.pid == 7003 then
        return { cwd = launch.cwd, argv = { launch.argv[1], "resume", "selected-session" }, tracked = true }
      end
    end,
  } }
  assert(monitor(f):tick())
  equal(checkpoint(f).apps["block:worker"].argv,
    { "/usr/local/bin/sample-worker", "resume", "selected-session" })
end)

test("failed session discovery cannot erase the last durable recovery command", function()
  local f = fixture()
  assert(monitor(f):tick())
  local saved = read(f.options.state_path)
  f.options.adapters = { {
    name = "sample-worker",
    detect = function() return nil, "session discovery unavailable" end,
  } }
  local ok, err = monitor(f):tick()
  assert(not ok and err == "session discovery unavailable")
  equal(read(f.options.state_path), saved)
end)

local function two_panes(f)
  local worker = command()
  local viewer = {
    session_id = "session:work", block_id = "block:other", app = "sample-viewer",
    cwd = "/workspace/viewer", argv = { "/usr/local/bin/sample-viewer", "--resume", "first-session" },
    tracked = true,
  }
  launch_file(f.options.launch_dir .. "/block:other", viewer, 7002)
  local execute = f.api.exec
  f.api.exec = function(argv)
    if argv[3] == "7002" then return { ok = true, stdout = birth .. "\n" } end
    return execute(argv)
  end
  return worker, viewer
end

-- Fails only for the given PIDs, so the other pane's discovery still works.
local function failing_worker(pids)
  return {
    name = "sample-worker",
    detect = function(process, launch)
      if pids[process.pid] then return nil, "session discovery unavailable" end
      if launch and launch.app == "sample-worker" and launch.pid == process.pid then
        return { cwd = launch.cwd, argv = launch.argv, tracked = true }
      end
    end,
  }
end

test("one pane's failed discovery keeps its saved command while other panes are still saved", function()
  local f = fixture()
  local worker, viewer = two_panes(f)
  assert(monitor(f):tick())
  equal(checkpoint(f).apps, { ["block:worker"] = worker, ["block:other"] = viewer })
  viewer.argv = { "/usr/local/bin/sample-viewer", "--resume", "second-session" }
  launch_file(f.options.launch_dir .. "/block:other", viewer, 7002)
  f.options.adapters = { failing_worker({ [7001] = true }), recovery.recorded("sample-viewer") }
  local ok, err = monitor(f):tick()
  assert(not ok and err == "session discovery unavailable", "the failed discovery was not reported")
  equal(checkpoint(f).apps, { ["block:worker"] = worker, ["block:other"] = viewer })
  equal(f.writes, {})
end)

test("after a restart, a lone pane whose discovery fails keeps its command pending until it can be checked", function()
  local f = fixture()
  local worker = command()
  assert(monitor(f):tick())
  restarted(f)
  f.processes["block:worker"] = { foreground = { pid = 7005, name = "not-ready-yet" } }
  f.options.adapters = { failing_worker({ [7005] = true }) }
  local ok, err = monitor(f):tick()
  assert(not ok and err == "session discovery unavailable", "the failed discovery was not reported")
  -- Saved under the new server run, like a successful scan would, but never typed.
  equal(checkpoint(f).instance_id, "run-b")
  equal(checkpoint(f).pending, { ["block:worker"] = worker })
  equal(checkpoint(f).apps, {})
  equal(f.writes, {})
  f.processes["block:worker"] = { foreground = { name = "zsh" } }
  f.options.adapters = { recovery.recorded("sample-worker") }
  assert(monitor(f):tick())
  equal(#f.writes, 1)
  equal(f.writes[1].block_id, "block:worker")
end)

test("after a restart, a pane whose discovery fails stays pending while another pane recovers", function()
  local f = fixture()
  local worker, viewer = two_panes(f)
  assert(monitor(f):tick())
  restarted(f)
  f.processes["block:worker"] = { foreground = { pid = 7005, name = "not-ready-yet" } }
  f.processes["block:other"] = { foreground = { name = "zsh" } }
  f.options.adapters = { failing_worker({ [7005] = true }), recovery.recorded("sample-viewer") }
  local ok, err = monitor(f):tick()
  assert(not ok and err == "session discovery unavailable", "the failed discovery was not reported")
  equal(#f.writes, 1)
  equal(f.writes[1].block_id, "block:other")
  equal(checkpoint(f).pending, { ["block:worker"] = worker })
  equal(checkpoint(f).apps, { ["block:other"] = viewer })
  f.processes["block:worker"] = { foreground = { name = "zsh" } }
  f.options.adapters = { recovery.recorded("sample-worker"), recovery.recorded("sample-viewer") }
  assert(monitor(f):tick())
  equal(#f.writes, 2)
  equal(f.writes[2].block_id, "block:worker")
end)

test("removed drivers are omitted from apps and pending while generic commands still recover", function()
  local f = fixture()
  local registry = require("drivers.registry")
  assert(not registry.lookup("retired-agent"))
  assert(registry.home_variable("CODEX_HOME"), "shared home variable must still belong to an installed driver")
  local viewer = {
    session_id = "session:work", block_id = "block:other", app = "sample-viewer",
    cwd = "/workspace/viewer", argv = { "/usr/local/bin/sample-viewer", "--saved" }, tracked = true,
  }
  local state = {
    version = 1, host_id = "host-a", instance_id = "run-a",
    apps = { ["block:worker"] = command(), ["block:retired-app"] = retired_record("block:retired-app") },
    pending = { ["block:other"] = viewer, ["block:retired-pending"] = retired_record("block:retired-pending") },
  }
  -- An installed driver can share the former storage variable. Its presence
  -- must not authenticate a different app whose descriptor has been removed.
  for _, location in ipairs({ "apps", "pending" }) do
    local block_id = "block:retired-shared-" .. location
    local record = retired_record(block_id)
    record.env = { CODEX_HOME = "/private/shared store", REX_RECOVER_SESSIONS = "1" }
    state[location][block_id] = record
  end
  write(f.options.state_path, assert(rex.json.encode(state)) .. "\n")
  local before = read(f.options.state_path)
  local loaded, err = recovery.load(f.options.state_path, rex.json)
  assert(loaded, err)
  equal(loaded.apps, { ["block:worker"] = command() })
  equal(loaded.pending, { ["block:other"] = viewer })
  equal(read(f.options.state_path), before)
  -- Even leaving the removed executable configured cannot convert its former
  -- session command into generic replay.
  f.options.adapters[#f.options.adapters + 1] = recovery.recorded("retired-agent")
  for _, block_id in ipairs({
    "block:retired-app", "block:retired-pending", "block:retired-shared-apps", "block:retired-shared-pending",
  }) do
    f.blocks[#f.blocks + 1] = {
      block_id = block_id, creator_name = "com.superlogical.terminal", host_id = "host-a",
    }
    f.processes[block_id] = { foreground = { name = "zsh" } }
  end
  restarted(f)
  f.processes["block:other"] = { foreground = { name = "zsh" } }
  assert(monitor(f):tick())
  equal(checkpoint(f).apps, { ["block:worker"] = command(), ["block:other"] = viewer })
  equal(checkpoint(f).pending, {})
  local writes = {}
  for _, sent in ipairs(f.writes) do writes[sent.block_id] = sent.args.data end
  equal(writes, {
    ["block:worker"] = "cd -- '/workspace/it'\\''s here' && REX_RECOVER_LAUNCH_DIR='" ..
      f.options.launch_dir .. "' REX_SESSION='session:work' REX_BLOCK='block:worker' " ..
      "'/plugin/bin/rex-recover-run' '/usr/local/bin/sample-worker' " ..
      "'--label' 'a b' 'a'\\''b' '$(touch never)' ''\r",
    ["block:other"] = "cd -- '/workspace/viewer' && REX_RECOVER_LAUNCH_DIR='" ..
      f.options.launch_dir .. "' REX_SESSION='session:work' REX_BLOCK='block:other' " ..
      "'/plugin/bin/rex-recover-run' '/usr/local/bin/sample-viewer' '--saved'\r",
  })
  equal(#f.writes, 2)
end)

test("valid orphan driver launches cannot block scans whether their app is enabled or disabled", function()
  for _, enabled in ipairs({ false, true }) do
    local f = fixture()
    local path = f.options.launch_dir .. "/block:other"
    write(path, table.concat(retired_launch(), "\0") .. "\0")
    if enabled then f.options.adapters[#f.options.adapters + 1] = recovery.recorded("retired-agent") end
    local launch, err = recovery.read_launch(path)
    assert(not launch and not err, "a valid removed-driver launch must be ignored, not rejected: " .. tostring(err))
    assert(monitor(f):tick())
    equal(checkpoint(f).apps, { ["block:worker"] = command() })
    equal(f.writes, {})
  end
end)

test("orphan checkpoint records must pass structural validation before they can be omitted", function()
  for _, location in ipairs({ "apps", "pending" }) do
    for _, invalid in ipairs({
      "key", "argv", "argv-type", "environment", "mode", "relative-home",
      "unsafe-home", "environment-name", "tracked", "envelope",
    }) do
      local f = fixture()
      local record = retired_record("block:other")
      local state = {
        version = 1, host_id = "host-a", instance_id = "run-a",
        apps = { ["block:worker"] = command() }, pending = {},
      }
      local key = "block:other"
      if invalid == "key" then key = "block:wrong"
      elseif invalid == "argv" then record.argv = { "/retired/agent", "bad\nargument" }
      elseif invalid == "argv-type" then record.argv = "not an argument array"
      elseif invalid == "environment" then record.env = "not an environment"
      elseif invalid == "mode" then record.env.REX_RECOVER_SESSIONS = "0"
      elseif invalid == "relative-home" then record.env.RETIRED_AGENT_HOME = "relative"
      elseif invalid == "unsafe-home" then record.env.RETIRED_AGENT_HOME = "/private/bad\rhome"
      elseif invalid == "environment-name" then record.env["BAD-NAME"] = "/private/home"
      elseif invalid == "tracked" then record.tracked = "yes"
      else state.version = 99 end
      state[location][key] = record
      local before = assert(rex.json.encode(state)) .. "\n"
      write(f.options.state_path, before)
      local m, err = recovery.new(f.api, f.options)
      assert(not m and err, "malformed " .. location .. " orphan was ignored: " .. invalid)
      equal(read(f.options.state_path), before)
      equal(f.writes, {})
    end
  end
end)

test("retained checkpoint records still reject unknown environment variables and PATH", function()
  for _, scenario in ipairs({
    { app = "sample-worker", env = { RETIRED_AGENT_HOME = "/private/unknown" } },
    { app = "sample-worker", env = { PATH = "/untrusted" } },
    { app = "codex", env = { REX_RECOVER_SESSIONS = "1", CODEX_HOME = "/private/codex", PATH = "/untrusted" } },
    { app = "codex", env = { REX_RECOVER_SESSIONS = "1", RETIRED_AGENT_HOME = "/private/unknown" } },
  }) do
    local f = fixture()
    local record = command()
    record.app, record.env = scenario.app, scenario.env
    local before = assert(rex.json.encode({
      version = 1, host_id = "host-a", instance_id = "run-a",
      apps = { ["block:worker"] = record }, pending = {},
    })) .. "\n"
    write(f.options.state_path, before)
    local m, err = recovery.new(f.api, f.options)
    assert(not m and err, "a retained record admitted an unregistered environment variable")
    equal(read(f.options.state_path), before)
    equal(f.writes, {})
  end
end)

test("malformed orphan launches and registered driver mismatches preserve the durable checkpoint", function()
  for _, invalid in ipairs({
    { 2, "session:" }, { 2, "session:../foreign" }, { 3, "block:../foreign" },
    { 4, "0" }, { 4, "-1" }, { 4, "not-a-pid" }, { 5, "" },
    { 6, "retired/agent" }, { 7, "relative" }, { 7, "/workspace/bad\ncwd" },
    { 8, "../foreign" }, { 8, "Uppercase-Agent" }, { 8, "invalid.module" }, { 8, "" },
    { 9, "relative" }, { 9, "/private/bad\nhome" }, { 10, "" }, { 11, "bad\rargument" },
    { "incomplete" }, { "missing-argv" }, { "registered-mismatch" },
  }) do
    local f = fixture()
    local m = monitor(f)
    assert(m:tick())
    local before = read(f.options.state_path)
    local fields = retired_launch()
    if invalid[1] == "missing-argv" then
      fields[10], fields[11], fields[12] = nil, nil, nil
    elseif invalid[1] == "registered-mismatch" then
      fields[6] = "codex"
    elseif type(invalid[1]) == "number" then
      fields[invalid[1]] = invalid[2]
    end
    local text = table.concat(fields, "\0") .. (invalid[1] == "incomplete" and "" or "\0")
    local path = f.options.launch_dir .. "/block:other"
    write(path, text)
    local launch, read_err = recovery.read_launch(path)
    assert(not launch and read_err, "malformed v2 launch was ignored: " .. tostring(invalid[1]))
    local ok, err = m:tick()
    assert(not ok and err, "an invalid launch was allowed to overwrite the checkpoint")
    equal(read(f.options.state_path), before)
    equal(f.writes, {})
  end
end)

print(count .. " tests passed")
