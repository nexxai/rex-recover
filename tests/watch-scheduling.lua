local runtime, root = rex, rex.args.root
package.path = root .. "/?.lua;" .. package.path
local recovery = require("recovery")
require("drivers.registry").lookup("sample-worker", runtime)

local function test(name, run)
  run()
  print("ok - " .. name)
end

local function equal(actual, expected)
  assert(runtime.json.encode(actual) == runtime.json.encode(expected),
    "expected " .. runtime.json.encode(expected) .. ", got " .. runtime.json.encode(actual))
end

local function fixture(interval)
  local temporary = assert(runtime.exec({ "mktemp", "-d", runtime.args.test_dir .. "/watch.XXXXXX" }))
  assert(temporary.ok, temporary.stderr)
  local directory = temporary.stdout:match("^%s*(.-)%s*$")
  assert(runtime.exec({ "mkdir", directory .. "/launches" }).ok)
  local f = {
    scans = 0, process_reads = 0, status_reads = 0,
    writes = {}, warnings = {}, handlers = {}, timers = {},
    status = { host_id = "host-a", instance_id = "run-a" },
    processes = { foreground = { pid = 7001, name = "sample-worker" } },
    path = directory .. "/checkpoint.json",
  }
  function f.select(selection)
    local file = assert(io.open(directory .. "/launches/block:worker", "wb"))
    assert(file:write(table.concat({
      "rex-recover-launch-v1", "session:work", "block:worker", "7001", "fixture-birth",
      "sample-worker", "/workspace/original", "/fixture/sample-worker", "--selection", selection,
    }, "\0") .. "\0"))
    assert(file:close())
  end
  function f.checkpoint()
    return assert(recovery.load(f.path, runtime.json))
  end
  function f.emit(name)
    for _, callback in ipairs(f.handlers[name] or {}) do
      callback({ session_id = "session:work", block_id = "block:worker" })
    end
  end
  local api
  function f.tick()
    assert(#f.timers == 1, "watching needs one configured fallback, not extra metadata heartbeats")
    local previous = rex
    rex = api
    local ok, err = pcall(f.timers[1].run)
    rex = previous
    assert(ok, err)
  end
  api = {
    args = {
      interval = interval, state_path = f.path, config = "/fixture/apps.conf",
      config_reader = "/fixture/config-reader", launcher = "/fixture/rex-recover-run",
    },
    json = runtime.json,
    log = function(level, message)
      if level == "warn" then f.warnings[#f.warnings + 1] = message end
    end,
    exec = function(argv)
      if argv[1] == "/fixture/config-reader" then
        equal(argv, { "/fixture/config-reader", "/fixture/apps.conf" })
        return { ok = true, stdout = "sample-worker\n" }
      end
      equal(argv, { "ps", "-p", "7001", "-o", "lstart=" })
      return { ok = true, stdout = "fixture-birth\n" }
    end,
    call = function(method, args)
      if method == "server.status" then
        f.status_reads = f.status_reads + 1
        if f.status_error then return nil, f.status_error end
        return f.status
      end
      if method == "session.list" then
        f.scans = f.scans + 1
        if f.on_scan then f.on_scan() end
        return { sessions = { { session_id = "session:work" } } }
      end
      if method == "session.attach" then return {} end
      if method == "session.list_blocks" then
        return { blocks = { {
          block_id = "block:worker", creator_name = "com.superlogical.terminal", host_id = "host-a",
        } } }
      end
      if method == "com.superlogical.terminal.process" then
        f.process_reads = f.process_reads + 1
        if f.process_error then return nil, f.process_error end
        return f.processes
      end
      if method == "com.superlogical.terminal.write" then
        f.writes[#f.writes + 1] = args.args.data
        return {}
      end
      error("unexpected watcher API call: " .. method)
    end,
    on = function(name, callback)
      f.handlers[name] = f.handlers[name] or {}
      f.handlers[name][#f.handlers[name] + 1] = callback
    end,
    every = function(seconds, callback)
      f.timers[#f.timers + 1] = { seconds = seconds, run = callback }
    end,
  }
  f.select("first")
  rex = api
  local ok, err = pcall(dofile, root .. "/watch.lua")
  rex = runtime
  assert(ok, err)
  return f
end

local function burst(f)
  local events = { "terminal.process_changed", "terminal.title_changed", "block_closed", "session_destroyed" }
  for index = 1, 1000 do f.emit(events[(index - 1) % #events + 1]) end
end

test("terminal event bursts wait for one interval scan that captures the latest state without replay", function()
  local f = fixture()
  equal(f.scans, 1)
  burst(f)
  f.select("latest")
  burst(f)
  equal(f.scans, 1)
  equal(f.process_reads, 1)
  assert(not f.handlers["terminal.title_changed"], "session discovery must not depend on terminal titles")
  equal(f.timers[1].seconds, 2)
  f.tick()
  equal(f.scans, 2)
  equal(f.process_reads, 2)
  equal(f.checkpoint().apps["block:worker"].argv,
    { "/fixture/sample-worker", "--selection", "latest" })
  f.status.instance_id = "run-b"
  f.processes = { foreground = { name = "zsh" } }
  burst(f)
  equal(f.scans, 2)
  f.tick()
  equal(f.writes, {
    "cd -- '/workspace/original' && REX_RECOVER_LAUNCH_DIR='" ..
      f.path:match("^(.*)/") .. "/launches' REX_SESSION='session:work' REX_BLOCK='block:worker' " ..
      "'/fixture/rex-recover-run' '/fixture/sample-worker' '--selection' 'latest'\r",
  })
  burst(f)
  f.tick()
  equal(#f.writes, 1)
end)

test("timer delivery during a scan cannot overlap it or queue a follow-up scan", function()
  local f = fixture(0.2)
  equal(f.timers[1].seconds, 0.2)
  f.select("during-scan")
  f.on_scan = function()
    if f.scans ~= 2 then return end
    burst(f)
    for _ = 1, 100 do f.tick() end
  end
  f.tick()
  equal(f.scans, 2)
  equal(f.process_reads, 2)
  equal(f.checkpoint().apps["block:worker"].argv,
    { "/fixture/sample-worker", "--selection", "during-scan" })
  f.on_scan = nil
  f.tick()
  equal(f.scans, 3)
  equal(f.writes, {})
end)

test("a failed health check after a tick error exits the callback so the supervisor can reconnect", function()
  local f = fixture()
  local file = assert(io.open(f.path, "rb"))
  local saved = file:read("*a")
  file:close()
  f.process_error = "fixture process connection lost"
  f.on_scan = function() f.status_error = "fixture control stream unavailable" end
  local ok, err = pcall(f.tick)
  assert(not ok, "a dead control stream left the watcher alive instead of allowing reconnection")
  assert(tostring(err):find("fixture control stream unavailable", 1, true),
    "the failed health check was not reported")
  equal(f.scans, 2)
  equal(f.process_reads, 2)
  equal(f.status_reads, 4)
  equal(f.warnings, {})
  equal(f.writes, {})
  file = assert(io.open(f.path, "rb"))
  equal(file:read("*a"), saved)
  file:close()
  burst(f)
  equal(f.scans, 2)
  equal(f.status_reads, 4)
end)

test("recoverable tick failures wait for the same configured timer without throwing or changing the checkpoint", function()
  local f = fixture()
  local timer = f.timers[1]
  local file = assert(io.open(f.path, "rb"))
  local saved = file:read("*a")
  file:close()
  local inode = assert(runtime.exec({ "ls", "-id", f.path })).stdout
  f.select("after-error")
  f.process_error = "fixture session selection pending"
  for index = 1, 2 do
    local ok, err = pcall(f.tick)
    assert(ok, "recoverable tick failure escaped the watcher callback: " .. tostring(err))
    equal(f.scans, index + 1)
    equal(f.process_reads, index + 1)
    equal(f.status_reads, (index + 1) * 2)
    equal(#f.warnings, index)
    equal(f.warnings[index], "fixture session selection pending")
    file = assert(io.open(f.path, "rb"))
    equal(file:read("*a"), saved)
    file:close()
    equal(assert(runtime.exec({ "ls", "-id", f.path })).stdout, inode)
    burst(f)
    equal(f.scans, index + 1)
    equal(#f.warnings, index)
    equal(f.writes, {})
  end
  f.process_error = nil
  f.tick()
  equal(f.scans, 4)
  equal(f.process_reads, 4)
  equal(f.status_reads, 8)
  assert(#f.timers == 1 and f.timers[1] == timer, "a recoverable failure replaced the configured timer")
  equal(timer.seconds, 2)
  equal(f.checkpoint().apps["block:worker"].argv,
    { "/fixture/sample-worker", "--selection", "after-error" })
  f.tick()
  equal(f.scans, 5)
  equal(f.status_reads, 10)
  equal(#f.warnings, 2)
  equal(f.writes, {})
end)

print("All watcher scheduling tests passed")
