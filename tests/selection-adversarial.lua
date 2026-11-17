package.path = rex.args.root .. "/?.lua;" .. package.path

local recovery = require("recovery")
local registry = require("drivers.registry")
local birth = "Mon Nov 16 12:00:00 2026"
local later_birth = "Mon Nov 16 12:00:01 2026"
local birth_hex = "4d6f6e204e6f762031362031323a30303a30302032303236"
local later_hex = "4d6f6e204e6f762031362031323a30303a30312032303236"
local failures, sequence, forbidden = {}, 0, 0
local native_sessions = {
  ['{"input":{"sessionID":"ses_alphaRoot"}}'] = { id = "ses_alphaRoot",
    location = { directory = "/workspace/shared project" } },
  ['{"input":{"sessionID":"ses_betaRoot"}}'] = { id = "ses_betaRoot",
    location = { directory = "/workspace/shared project" } },
  ['{"input":{"sessionID":"ses_otherRoot"}}'] = { id = "ses_otherRoot",
    location = { directory = "/workspace/shared project" } },
  ['{"input":{"sessionID":"ses_newLaunchRoot"}}'] = { id = "ses_newLaunchRoot",
    location = { directory = "/workspace/shared project" } },
  ['{"input":{"sessionID":"ses_absentRoot"}}'] = false,
}

local function equal(actual, expected)
  assert(rex.json.encode(actual) == rex.json.encode(expected),
    "expected " .. tostring(rex.json.encode(expected)) .. ", got " .. tostring(rex.json.encode(actual)))
end

local function write(path, text)
  local file = assert(io.open(path, "wb"))
  assert(file:write(text))
  assert(file:close())
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local text = assert(file:read("*a"))
  file:close()
  return text
end

local function utility(argv)
  local result = assert(rex.exec(argv))
  assert(result.ok, result.stderr)
  return result.stdout
end

local function publish(path, value)
  write(path .. ".staged", assert(rex.json.encode(value)))
  utility({ "/bin/chmod", "600", path .. ".staged" })
  assert(os.rename(path .. ".staged", path))
end

local function test(name, run)
  local before = forbidden
  local ok, err = pcall(run)
  if forbidden ~= before then ok, err = false, "forbidden title/API/application invocation" end
  print((ok and "ok - " or "FAIL - ") .. name .. (ok and "" or ": " .. tostring(err)))
  if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
end

local function fixture()
  sequence = sequence + 1
  local directory = rex.args.test_dir .. "/case-" .. sequence
  local f = {
    home = directory .. "/home's store", cwd = "/workspace/shared project",
    status = { host_id = "host:adversary", instance_id = "run:one" },
    input_mode = { canonical = false, echo = false, signals = true }, mode_reads = 0,
    panes = {}, writes = {}, births = {
      ["7001"] = "Mon Nov 16 12:00:00 2026",
      ["7002"] = "Mon Nov 16 12:00:00 2026",
      ["7011"] = "Mon Nov 16 12:00:02 2026",
    },
    options = { state_path = directory .. "/checkpoint.json", launch_dir = directory .. "/launches",
      launcher = "/fixture/rex-recover-run" },
  }
  utility({ "/bin/mkdir", "-p", f.home, f.options.launch_dir })
  f.env = { XDG_CONFIG_HOME = f.home .. "/config", XDG_DATA_HOME = f.home .. "/data",
    XDG_STATE_HOME = f.home .. "/state", XDG_CACHE_HOME = f.home .. "/cache",
    OPENCODE_DB = f.home .. "/conversation.db" }
  -- A header fixture, not a live database: no daemon or SDK is involved.
  write(f.env.OPENCODE_DB, "SQLite format 3\0fixture database\n")
  f.api = {
    json = {
      encode = rex.json.encode,
      decode = function(text)
        local value, err = rex.json.decode(text)
        if type(value) == "table" and value.launch and f.after_decode then
          local change = f.after_decode
          f.after_decode = nil
          change()
        end
        return value, err
      end,
    },
    log = function() end,
    exec = function(argv, options)
      if argv[1] == "ps" then
        equal({ argv[1], argv[2], argv[4], argv[5], #argv }, { "ps", "-p", "-o", "lstart=", 5 })
        assert(options and options.env and options.env.LC_ALL == "C", "birth lookup must use C locale")
        assert(f.births[argv[3]], "unrecognized fixture PID")
        return { ok = true, stdout = f.births[argv[3]] .. "\n" }
      end
      -- Recognize only the verified metadata-only CLI boundary; never execute it.
      local approved, result = pcall(function()
        local expected = {
          "/usr/bin/env", "-u", "OPENCODE_CONFIG_DIR", "-u", "OPENCODE_CONFIG",
          "-u", "OPENCODE_CONFIG_CONTENT", "-u", "OPENCODE_CLI_CONFIG_CONTENT",
          "-u", "OPENCODE_CONFIG_PROJECT_DISABLE", "-u", "OPENCODE_DISABLE_PROJECT_CONFIG",
          "-u", "OPENCODE_DISABLE_CLAUDE_CODE", "-u", "OPENCODE_DISABLE_CLAUDE_CODE_SKILLS",
          "-u", "OPENCODE_TEST_HOME", "-u", "OPENCODE_FLAGS", "-u", "OPENCODE_SIMULATE",
          "-u", "OPENCODE_SERVICE_FILE", "/not-installed/opencode",
        }
        local version_check = argv[#argv] == "--version"
        local session = native_sessions[argv[#argv]]
        assert(version_check or session ~= nil, "unrecognized fixture context request")
        local suffix = version_check and { "--version" } or {
          "--standalone", "api", "post", "/api/rpc/rex-recover/context", "--data", argv[#argv],
        }
        for _, argument in ipairs(suffix) do expected[#expected + 1] = argument end
        equal(argv, expected)
        local environment = { HOME = f.home }
        for name, value in pairs(f.env) do environment[name] = value end
        equal(options, { cwd = "/workspace/shared project", env = environment,
          timeout = version_check and 5 or 15 })
        if version_check then return { ok = true, stdout = "opencode v2.3.0\n" } end
        return { ok = true, stdout = assert(rex.json.encode({ output = {
          state = session and "ready" or "absent", pid = 9001, version = "2.3.0", channel = "latest",
          home = f.home, env = f.env, file = { dev = "1", ino = "2" }, session = session or nil,
        } })) }
      end)
      if not approved then
        forbidden = forbidden + 1
        error("unrecognized execution is forbidden: " .. tostring(result))
      end
      return result
    end,
    call = function(method, args)
      if method == "server.status" then return f.status end
      if method == "session.list" then return { sessions = { { session_id = "session:adversary" } } } end
      if method == "session.attach" then return {} end
      if method == "session.list_blocks" then
        local blocks = {}
        for _, pane in ipairs(f.panes) do
          blocks[#blocks + 1] = { block_id = pane.block, host_id = "host:adversary",
            creator_name = "com.superlogical.terminal" }
        end
        return { blocks = blocks }
      end
      for _, pane in ipairs(f.panes) do
        if args and args.block_id == pane.block then
          if method == "com.superlogical.terminal.process" then return pane.tree end
          if method == "com.superlogical.terminal.input_mode" then
            assert(args.session_id == "session:adversary")
            assert(args.args == nil or (type(args.args) == "table" and next(args.args) == nil),
              "input_mode must remain a read-only query")
            f.mode_reads = f.mode_reads + 1
            if f.mode_error then return nil, f.mode_error end
            return f.input_mode
          end
          if method == "com.superlogical.terminal.write" then
            f.writes[#f.writes + 1] = args
            return { bytes_written = #args.args.data }
          end
        end
      end
      forbidden = forbidden + 1
      error("forbidden recovery API: " .. method)
    end,
  }
  f.options.adapters = { registry.recorded("opencode", f.api) }
  function f.record(pane, started_at, suffix)
    local arguments = { "/not-installed/opencode" }
    if pane.private then arguments[#arguments + 1] = "--standalone" end
    for _, argument in ipairs({ "--session", "ses_launchWrong", "--prompt", "do not replay request",
      "--auto", "../project" }) do arguments[#arguments + 1] = argument end
    local fields = { "rex-recover-launch-v2", "session:adversary", pane.block,
      tostring(pane.pid), started_at, "opencode", f.cwd, "anomalyco-opencode", f.home }
    for _, argument in ipairs(arguments) do fields[#fields + 1] = argument end
    local path = f.options.launch_dir .. "/" .. pane.block
    write(path, table.concat(fields, "\0") .. "\0")
    pane.launch = assert(recovery.read_launch(path))
    pane.path = path .. "." .. pane.pid .. "." .. suffix .. ".session"
  end
  function f.selection(pane, id, state)
    return { version = 1, launch = { pid = pane.pid, started_at = pane.launch.started_at,
      session_id = "session:adversary", block_id = pane.block, app = "opencode" },
      owner_pid = pane.pid, owner_started_at = pane.launch.started_at,
      state = state or "ready", id = id, home = f.home, env = f.env, managed = not pane.private }
  end
  function f.capture(pane)
    return recovery.capture("session:adversary", pane.block, pane.tree, f.options.adapters, pane.launch)
  end
  function f.checkpoint() return assert(recovery.load(f.options.state_path, rex.json)) end
  function f.monitor() return assert(recovery.new(f.api, f.options)) end
  for index, block in ipairs({ "block:alpha", "block:beta" }) do
    local pane = { block = block, pid = 7000 + index, private = index == 2,
      tree = { foreground = { pid = 7000 + index, name = "opencode", cwd = "/" } } }
    f.panes[index] = pane
    f.record(pane, birth, birth_hex)
    publish(pane.path, f.selection(pane, index == 1 and "ses_alphaRoot" or "ses_betaRoot"))
  end
  return f, f.panes[1], f.panes[2]
end

test("v2 selection filenames bind PID and literal UTF-8 start-time bytes", function()
  local f, pane = fixture()
  equal(pane.launch.selection_path, pane.path)
  f.record(pane, "Té", "54c3a9")
  equal(pane.launch.selection_path, f.options.launch_dir .. "/block:alpha.7001.54c3a9.session")
end)

test("same-project panes retain distinct IDs, modes and storage without checkpoint rewrites", function()
  local f, alpha, beta = fixture()
  local m = f.monitor()
  assert(m:tick())
  local state = f.checkpoint()
  equal(state.apps[alpha.block].argv,
    { "/not-installed/opencode", "--session", "ses_alphaRoot", "--auto", "../project" })
  equal(state.apps[beta.block].argv,
    { "/not-installed/opencode", "--standalone", "--session", "ses_betaRoot", "--auto", "../project" })
  for _, pane in ipairs(f.panes) do
    local record = state.apps[pane.block]
    equal(record.cwd, "/workspace/shared project")
    equal(record.env.HOME, f.home)
    for name, value in pairs(f.env) do equal(record.env[name], value) end
  end
  local inode = utility({ "/bin/ls", "-id", f.options.state_path })
  local saved = read(f.options.state_path)
  assert(m:tick())
  assert(f.monitor():tick())
  equal(utility({ "/bin/ls", "-id", f.options.state_path }), inode)
  equal(read(f.options.state_path), saved)
  equal(f.writes, {})
end)

test("A to B to none and deleted live-owner metadata cannot resurrect launch prompts", function()
  local f, alpha, beta = fixture()
  local m = f.monitor()
  assert(m:tick())
  publish(alpha.path, f.selection(alpha, "ses_otherRoot"))
  assert(m:tick())
  equal(f.checkpoint().apps[alpha.block].argv[3], "ses_otherRoot")
  publish(alpha.path, f.selection(alpha, nil, "none"))
  assert(m:tick())
  equal(f.checkpoint().apps[alpha.block], nil)
  publish(alpha.path, f.selection(alpha, "ses_alphaRoot"))
  assert(m:tick())
  assert(os.remove(alpha.path))
  assert(m:tick())
  equal(f.checkpoint().apps[alpha.block], nil)
  f.status.instance_id = "run:two"
  for _, pane in ipairs(f.panes) do pane.tree = { foreground = { name = "zsh" } } end
  assert(m:tick())
  assert(f.monitor():tick())
  equal(#f.writes, 1)
  equal(f.writes[1].block_id, beta.block)
  local command = f.writes[1].args.data
  assert(command:find("'--standalone' '--session' 'ses_betaRoot' '--auto' '../project'", 1, true))
  assert(not command:find("ses_launchWrong", 1, true))
  assert(not command:find("do not replay request", 1, true))
end)

test("deleted selection metadata clears the old checkpoint while its launch owner remains live", function()
  local f, alpha, beta = fixture()
  local m = f.monitor()
  assert(m:tick())
  assert(os.remove(alpha.path))
  local ok, err = m:tick()
  assert(ok, err)
  equal(f.checkpoint().apps[alpha.block], nil)
  assert(f.checkpoint().apps[beta.block], "the other pane lost its independent selection")
  equal(f.writes, {})
end)

test("pending, error, invalid JSON, oversize and unreadable sidecars preserve durable recovery", function()
  local f, pane = fixture()
  local m = f.monitor()
  assert(m:tick())
  local saved = read(f.options.state_path)
  local inode = utility({ "/bin/ls", "-id", f.options.state_path })
  for _, state in ipairs({ "pending", "error", "json", "oversize", "unreadable" }) do
    local selection_state = (state == "pending" or state == "error") and state or "ready"
    publish(pane.path, f.selection(pane, "ses_alphaRoot", selection_state))
    if state == "json" then write(pane.path, "{not JSON") end
    if state == "oversize" then
      local value = f.selection(pane, "ses_alphaRoot")
      value.padding = string.rep("x", 65536)
      publish(pane.path, value)
    end
    if state == "unreadable" then utility({ "/bin/chmod", "000", pane.path }) end
    local ok, err = m:tick()
    if state == "unreadable" then utility({ "/bin/chmod", "600", pane.path }) end
    assert(not ok and err, state .. " must report a discovery error")
    equal(read(f.options.state_path), saved)
    equal(utility({ "/bin/ls", "-id", f.options.state_path }), inode)
    equal(f.writes, {})
  end
end)

test("wrong launch and owner bindings are rejected before interpreting error state", function()
  local f, pane = fixture()
  for _, mismatch in ipairs({ "block", "session", "launch-birth", "owner", "owner-birth" }) do
    local value = f.selection(pane, nil, "error")
    if mismatch == "block" then value.launch.block_id = "block:beta"
    elseif mismatch == "session" then value.launch.session_id = "session:foreign"
    elseif mismatch == "launch-birth" then value.launch.started_at = later_birth
    elseif mismatch == "owner" then value.owner_pid = 6999
    else value.owner_started_at = later_birth end
    publish(pane.path, value)
    local record, err = f.capture(pane)
    assert(not record and not err, mismatch .. " must not poison capture with a foreign error")
  end
  pane.tree = { foreground = { pid = 7011, name = "opencode" },
    ancestors = { { pid = 7001, name = "node" }, { pid = 6999, name = "opencode" } } }
  local value = f.selection(pane, "ses_alphaRoot")
  value.owner_pid, value.owner_started_at = 7011, "Mon Nov 16 12:00:02 2026"
  publish(pane.path, value)
  assert(f.capture(pane), "a verified descendant owner was rejected")
  f.births["7011"] = "Mon Nov 16 13:00:00 2026"
  local record, err = f.capture(pane)
  assert(not record and not err, "a reused descendant PID attached stale metadata")
  value.owner_pid, value.owner_started_at, value.state = 6999, birth, "error"
  publish(pane.path, value)
  record, err = f.capture(pane)
  assert(not record and not err, "an ancestor outside the launch subtree owned the selection")
end)

test("PID reuse and old-launch publications cannot replace the current launch selection", function()
  local f, pane = fixture()
  local m = f.monitor()
  assert(m:tick())
  local old_path, old_value = pane.path, f.selection(pane, nil, "none")
  f.births["7001"] = "Mon Nov 16 12:00:01 2026"
  assert(m:tick())
  equal(f.checkpoint().apps[pane.block], nil)
  f.record(pane, later_birth, later_hex)
  publish(pane.path, f.selection(pane, "ses_newLaunchRoot"))
  publish(old_path, old_value)
  assert(m:tick())
  equal(f.checkpoint().apps[pane.block].argv[3], "ses_newLaunchRoot")
  equal(f.writes, {})
end)

test("metadata changed during validation cannot yield the previous ready selection", function()
  local f, pane = fixture()
  f.after_decode = function() publish(pane.path, f.selection(pane, nil, "none")) end
  local record = f.capture(pane)
  assert(not record, "capture accepted a ready snapshot that was replaced before validation completed")
  equal(f.writes, {})
end)

test("a failed final process read cannot consume recovery before any command was dispatched", function()
  local f, pane = fixture()
  f.panes = { pane }
  f.options.adapters = { recovery.recorded("sample-worker") }
  write(f.options.launch_dir .. "/" .. pane.block, table.concat({
    "rex-recover-launch-v1", "session:adversary", "block:alpha", "7001", birth,
    "sample-worker", "/workspace/shared project", "/not-installed/sample-worker", "--label", "safe",
  }, "\0") .. "\0")
  local m = f.monitor()
  assert(m:tick())
  f.status.instance_id = "run:two"
  pane.tree = { foreground = { name = "zsh" } }
  local call, reads = f.api.call, 0
  f.api.call = function(method, args)
    if method == "com.superlogical.terminal.process" and args.block_id == pane.block then
      reads = reads + 1
      if reads == 2 then return nil, "fixture process unavailable before dispatch" end
    end
    return call(method, args)
  end
  local ok, err = m:tick()
  assert(not ok and err == "fixture process unavailable before dispatch")
  equal(f.writes, {})
  f.api.call = call
  assert(f.monitor():tick())
  equal(#f.writes, 1)
  equal(f.writes[1].block_id, "block:alpha")
  assert(f.writes[1].args.data:find(
    "'/not-installed/sample-worker' '--label' 'safe'\r", 1, true))
  equal(f.mode_reads, 0)
end)

test("long generic recovery waits for noncanonical input and preserves pending state on mode errors", function()
  local f, pane = fixture()
  f.panes = { pane }
  f.options.adapters = { recovery.recorded("sample-worker") }
  local padding = string.rep("x", 1728)
  write(f.options.launch_dir .. "/" .. pane.block, table.concat({
    "rex-recover-launch-v1", "session:adversary", "block:alpha", "7001", birth,
    "sample-worker", "/workspace/shared project", "/not-installed/sample-worker",
    "--label", padding .. " literal space's",
  }, "\0") .. "\0")
  local expected = "cd -- '/workspace/shared project' && REX_RECOVER_LAUNCH_DIR='" ..
    f.options.launch_dir .. "' REX_SESSION='session:adversary' REX_BLOCK='block:alpha' " ..
    "'/fixture/rex-recover-run' '/not-installed/sample-worker' '--label' '" ..
    padding .. " literal space'\\''s'\r"
  local m = f.monitor()
  assert(m:tick())
  equal(f.mode_reads, 0)
  f.status.instance_id = "run:two"
  pane.tree = { foreground = { name = "zsh" } }
  f.input_mode = { canonical = true, echo = true, signals = true }
  assert(m:tick())
  assert(f.checkpoint().pending[pane.block], "canonical input consumed the pending command")
  local saved = read(f.options.state_path)
  local inode = utility({ "/bin/ls", "-id", f.options.state_path })
  for _ = 1, 5 do
    assert(m:tick())
    equal(read(f.options.state_path), saved)
    equal(utility({ "/bin/ls", "-id", f.options.state_path }), inode)
    equal(f.writes, {})
  end
  assert(f.mode_reads > 0, "long recovery never queried the native input mode")
  f.mode_error = "fixture input mode unavailable"
  local ok, err = m:tick()
  assert(not ok and err == "fixture input mode unavailable")
  equal(read(f.options.state_path), saved)
  equal(f.writes, {})
  f.mode_error = nil
  f.input_mode = { canonical = "false", echo = false, signals = true }
  ok, err = m:tick()
  assert(not ok and err, "malformed input-mode metadata consumed recovery")
  equal(read(f.options.state_path), saved)
  equal(utility({ "/bin/ls", "-id", f.options.state_path }), inode)
  equal(f.writes, {})
  f.input_mode = { canonical = false, echo = false, signals = true }
  assert(m:tick())
  equal(#f.writes, 1)
  equal(f.writes[1].args.data, expected)
  assert(f.monitor():tick())
  equal(#f.writes, 1)
end)

assert(#failures == 0, table.concat(failures, "\n"))
print("Selection adversary: 10 public-contract checks passed; no live application/TUI claims.")
