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
    writes = {}, attached = {}, started_at = birth,
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

test("failed saves prevent command execution and can be retried after storage is repaired", function()
  local f = fixture()
  local m = monitor(f)
  assert(m:tick())
  restarted(f)
  assert(rex.exec({ "mkdir", f.options.state_path .. ".tmp" }).ok)
  local ok, err = m:tick()
  assert(not ok and err)
  equal(f.writes, {})
  equal(checkpoint(f).instance_id, "run-a")
  assert(rex.exec({ "rmdir", f.options.state_path .. ".tmp" }).ok)
  assert(m:tick())
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

print(count .. " tests passed")
