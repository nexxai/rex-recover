package.path = rex.args.root .. "/?.lua;" .. package.path

local recovery = require("recovery")
local drivers = require("drivers.registry")
local directory = rex.args.test_dir
local phase = rex.args.phase or "unit"
local alpha = "550e8400-e29b-41d4-a716-446655440000"
local beta = "9d73450d-598c-4d30-b866-824a08df2201"
local fresh = "f074f2c9-4cf0-458a-86de-08d167818003"

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

local function quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- Option order relative to --resume is not material. Retained options must keep
-- their own order, and no selector, fork flag or initial prompt may survive.
local function exact_resume(argv, executable, id, options)
  equal(argv[1], executable)
  local kept, selectors, index = {}, 0, 2
  while index <= #argv do
    if argv[index] == "--resume" then
      equal(argv[index + 1], id)
      selectors = selectors + 1
      index = index + 2
    else
      kept[#kept + 1] = argv[index]
      index = index + 1
    end
  end
  equal(selectors, 1)
  equal(kept, options or {})
end

if phase == "unit" then
  local sequence, failures = 0, {}
  local birth = "Mon Nov 16 12:00:00 2026"
  local made = assert(rex.exec({ "mktemp", "-d", directory .. "/claude-unit.XXXXXX" }))
  assert(made.ok, made.stderr)
  local base = made.stdout:match("^%s*(.-)%s*$")

  local function test(name, run)
    if rex.args.only and not name:find(rex.args.only, 1, true) then return end
    local ok, err = pcall(run)
    if ok then
      print("ok - " .. name)
    else
      failures[#failures + 1] = name .. ": " .. tostring(err)
      print("FAIL - " .. failures[#failures])
    end
  end

  local function launch(f, generic)
    local fields = {
      generic and "rex-recover-launch-v1" or "rex-recover-launch-v2",
      "session:selected", "block:claude", "7001", birth, "claude", f.cwd,
    }
    if not generic then fields[#fields + 1], fields[#fields + 2] = "anthropic-claude-code", f.home end
    for _, argument in ipairs(f.argv) do fields[#fields + 1] = argument end
    write(f.options.launch_dir .. "/block:claude", table.concat(fields, "\0") .. "\0")
  end

  local function fixture()
    sequence = sequence + 1
    local path = base .. "/case-" .. sequence
    local f = {
      home = path .. "/agent's home", cwd = "/workspace/project's same",
      argv = { "/fixture/claude", "--resume", alpha, "launch prompt must not replay" },
      tree = { foreground = { pid = 7001, name = "claude", cwd = "/changed/cwd" } },
      status = { host_id = "host:private", instance_id = "run:one" },
      writes = {}, native_calls = {}, started_at = birth,
      options = { state_path = path .. "/checkpoint.json", launch_dir = path .. "/launches",
        launcher = rex.args.root .. "/bin/rex-recover-run" },
    }
    assert(rex.exec({ "mkdir", "-p", f.home .. "/projects/not-derived-from-cwd",
      f.options.launch_dir }).ok)
    f.transcript = f.home .. "/projects/not-derived-from-cwd/" .. beta .. ".jsonl"
    -- The public filename/location contract suffices; entry fields are private.
    write(f.transcript, "opaque persisted conversation\n")
    write(f.home .. "/projects/not-derived-from-cwd/" .. alpha .. ".jsonl", "other history\n")
    f.entries = {
      { pid = 9999, kind = "interactive", cwd = f.cwd, startedAt = 1794830000000, sessionId = alpha },
      { pid = 7002, kind = "background", cwd = f.cwd, startedAt = 1794830000001, sessionId = alpha },
      { pid = 7001, kind = "interactive", cwd = f.cwd, startedAt = 1794830000002, sessionId = beta },
    }
    f.api = {
      json = rex.json, log = function() end,
      exec = function(argv, options)
        if argv[1] == "ps" then return { ok = true, stdout = f.started_at .. "\n" } end
        if argv[1] == "/fixture/claude" then
          equal(argv, { "/fixture/claude", "agents", "--json" })
          equal(options, { cwd = "/workspace/project's same",
            env = { CLAUDE_CONFIG_DIR = f.home }, timeout = 2 })
          f.native_calls[#f.native_calls + 1] = argv
          if f.native_failure_at == #f.native_calls then return f.native_failure_result end
          if f.native_error then return nil, "native discovery disconnected" end
          if f.native_result then return f.native_result end
          return { ok = true, stdout = f.native_json or assert(rex.json.encode(f.entries)) }
        end
        assert(argv[1] == "find", "unexpected discovery executable: " .. tostring(argv[1]))
        if f.on_find then f.on_find() end
        if f.find_error then return nil, "transcript discovery disconnected" end
        if f.find_result then return f.find_result end
        if f.find_output then return { ok = true, stdout = f.find_output } end
        return rex.exec(argv, options)
      end,
      call = function(method, args)
        if method == "server.status" then return f.status end
        if method == "session.list" then return { sessions = { { session_id = "session:selected" } } } end
        if method == "session.attach" then return {} end
        if method == "session.list_blocks" then
          return { blocks = { { block_id = "block:claude",
            creator_name = "com.superlogical.terminal", host_id = "host:private" } } }
        end
        if method == "com.superlogical.terminal.process" then return f.tree end
        if method == "com.superlogical.terminal.write" then
          f.writes[#f.writes + 1] = args
          return { bytes_written = #args.args.data }
        end
        error("unexpected recovery API (Claude must not depend on terminal titles): " .. method)
      end,
    }
    f.options.adapters = { drivers.recorded("claude", f.api) }
    launch(f)
    return f
  end

  local function tick(f)
    return assert(recovery.new(f.api, f.options)):tick()
  end

  local function checkpoint(f)
    return assert(recovery.load(f.options.state_path, rex.json))
  end

  local function selected(f)
    assert(tick(f))
    return checkpoint(f).apps["block:claude"]
  end

  test("native live foreground Beta wins over launch Alpha, background and other same-cwd panes", function()
    local f = fixture()
    local record = assert(selected(f), "live Claude session was not checkpointed")
    exact_resume(record.argv, "/fixture/claude", "9d73450d-598c-4d30-b866-824a08df2201")
    equal(record.cwd, "/workspace/project's same")
    equal(record.env, { CLAUDE_CONFIG_DIR = f.home, REX_RECOVER_SESSIONS = "1" })
    equal(record.tracked, true)
    assert(#f.native_calls >= 1, "recorded executable was never queried")
    equal(f.writes, {})
  end)

  test("selection changes replace the saved ID; an unpersisted new session clears it", function()
    local f = fixture()
    exact_resume(assert(selected(f)).argv, "/fixture/claude", beta)
    f.entries[3].sessionId = alpha
    exact_resume(assert(selected(f)).argv, "/fixture/claude", alpha)
    f.entries[3].sessionId = fresh
    equal(selected(f), nil)
    equal(checkpoint(f).pending, {})
    f.status.instance_id = "run:two"
    f.tree = { foreground = { pid = 8001, name = "zsh" } }
    assert(tick(f))
    equal(f.writes, {})
  end)

  test("missing or malformed native IDs and noninteractive entries clear stale checkpoints", function()
    for _, scenario in ipairs({ "missing", "empty", "prefix", "object", "background", "subagent",
      "string-pid", "missing-pid", "missing-cwd", "missing-start", "invalid-start" }) do
      local f = fixture()
      assert(selected(f))
      local entry = f.entries[3]
      if scenario == "missing" then entry.sessionId = nil
      elseif scenario == "empty" then entry.sessionId = ""
      elseif scenario == "prefix" then entry.sessionId = "9d73450d"
      elseif scenario == "object" then entry.sessionId = { beta }
      elseif scenario == "background" then entry.kind = "background"
      elseif scenario == "subagent" then entry.kind = "subagent"
      elseif scenario == "string-pid" then entry.pid = "7001"
      elseif scenario == "missing-pid" then entry.pid = nil
      elseif scenario == "missing-cwd" then entry.cwd = nil
      elseif scenario == "missing-start" then entry.startedAt = nil
      else entry.startedAt = "not Unix milliseconds" end
      equal(selected(f), nil)
      equal(f.writes, {})
    end
  end)

  test("corrupt, wrapped and non-array native output decline instead of replaying launch argv", function()
    for _, output in ipairs({ "", "not JSON", "null", "true", "7", "{}", '{"sessions":[]}',
      '{"pid":7001,"kind":"interactive","sessionId":"' .. beta .. '"}', "[false,7,null]" }) do
      local f = fixture()
      assert(selected(f))
      f.native_json = output
      equal(selected(f), nil)
      equal(f.writes, {})
    end
  end)

  test("unavailable native command is unsupported, not a generic replay fallback", function()
    local f = fixture()
    assert(selected(f))
    f.native_result = { ok = false, exit_code = 2, stdout = "", stderr = "unknown command: agents" }
    equal(selected(f), nil)
    equal(f.writes, {})
  end)

  test("foreign panes, ancestors above the launch and background descendants cannot hijack it", function()
    for _, scenario in ipairs({ "foreign", "above-launch", "background-child", "reused-pid" }) do
      local f = fixture()
      if scenario == "foreign" then f.entries[3].pid = 9999
      elseif scenario == "above-launch" then
        f.tree = { foreground = { pid = 7003, name = "cat" },
          ancestors = { { pid = 7001, name = "sh" }, { pid = 7000, name = "claude" } } }
        f.entries[3].pid = 7000
      elseif scenario == "background-child" then
        f.tree = { foreground = { pid = 7002, name = "claude" },
          ancestors = { { pid = 7001, name = "node" } } }
        f.entries = { { pid = 7002, kind = "background", cwd = f.cwd,
          startedAt = 1794830000002, sessionId = beta } }
      else f.started_at = "Mon Nov 16 13:00:00 2026" end
      equal(selected(f), nil)
      equal(f.writes, {})
    end
  end)

  test("one live interactive native descendant inside a verified launcher subtree can recover", function()
    local f = fixture()
    f.tree = { foreground = { pid = 7003, name = "cat" },
      ancestors = { { pid = 7002, name = "claude" }, { pid = 7001, name = "node" },
        { pid = 7000, name = "zsh" } } }
    f.entries[2].pid = 7004
    f.entries[3].pid = 7002
    exact_resume(assert(selected(f)).argv, "/fixture/claude", beta)
  end)

  test("conflicting same-PID IDs reject regardless of background eligibility", function()
    for _, kind in ipairs({ "interactive", "background" }) do
      local f = fixture()
      f.entries[#f.entries + 1] = { pid = 7001, kind = kind, cwd = f.cwd,
        startedAt = 1794830000003, sessionId = alpha }
      equal(selected(f), nil)
    end
  end)

  test("identical duplicate native observations do not manufacture another session", function()
    local f = fixture()
    f.entries[#f.entries + 1] = { pid = 7001, kind = "interactive", cwd = f.cwd,
      startedAt = 1794830000002, sessionId = beta }
    exact_resume(assert(selected(f)).argv, "/fixture/claude", beta)
  end)

  test("two interactive Claude processes below one launch are ambiguous", function()
    local f = fixture()
    f.tree = { foreground = { pid = 7002, name = "claude" },
      ancestors = { { pid = 7001, name = "claude" } } }
    f.entries[2] = { pid = 7002, kind = "interactive", cwd = f.cwd,
      startedAt = 1794830000003, sessionId = alpha }
    equal(selected(f), nil)
  end)

  test("exactly one nonempty transcript is required; filename and project cwd guesses do not count", function()
    for _, scenario in ipairs({ "missing", "empty", "duplicate", "wrong-filename", "outside-home" }) do
      local f = fixture()
      assert(selected(f))
      if scenario == "missing" then assert(os.remove(f.transcript))
      elseif scenario == "empty" then write(f.transcript, "")
      elseif scenario == "duplicate" then
        assert(rex.exec({ "mkdir", "-p", f.home .. "/projects/another-project" }).ok)
        write(f.home .. "/projects/another-project/" .. beta .. ".jsonl", "second history\n")
      elseif scenario == "wrong-filename" then
        assert(os.rename(f.transcript, f.home .. "/projects/not-derived-from-cwd/arbitrary.jsonl"))
      else
        local outside = base .. "/" .. beta .. ".jsonl"
        write(outside, "foreign history\n")
        f.find_output = outside .. "\n"
      end
      equal(selected(f), nil)
      equal(f.writes, {})
    end
  end)

  test("a missing projects directory is a valid unpersisted session", function()
    local f = fixture()
    assert(os.rename(f.home .. "/projects", f.home .. "/no-projects-yet"))
    equal(selected(f), nil)
  end)

  test("a selection change during transcript scanning cannot save the previous conversation", function()
    local f = fixture()
    f.on_find = function() f.entries[3].sessionId = alpha end
    equal(selected(f), nil)
  end)

  test("supported basic options survive without old selectors, fork flags or initial prompts", function()
    local f = fixture()
    f.argv = { "/fixture/claude", "--model", "sonnet", "--permission-mode=plan",
      "--agent", "reviewer", "--add-dir", "/another/project",
      "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--verbose",
      "--resume", alpha, "--continue", "--session-id", alpha, "--fork-session", "old prompt" }
    launch(f)
    exact_resume(assert(selected(f)).argv, "/fixture/claude", beta, {
      "--model", "sonnet", "--permission-mode=plan", "--agent", "reviewer",
      "--add-dir", "/another/project", "--dangerously-skip-permissions",
      "--allow-dangerously-skip-permissions", "--verbose",
    })
  end)

  test("documented variadic --add-dir retains every directory rather than dropping one as a prompt", function()
    local f = fixture()
    f.argv = { "/fixture/claude", "initial prompt", "--add-dir", "/first/project", "/second/project",
      "--model", "sonnet" }
    launch(f)
    exact_resume(assert(selected(f)).argv, "/fixture/claude", beta, {
      "--add-dir", "/first/project", "/second/project", "--model", "sonnet",
    })
  end)

  test("new, picker, continue, named resume and inline selectors become only exact --resume", function()
    for _, arguments in ipairs({
      {}, { "original prompt" }, { "--", "-literal prompt" },
      { "--resume" }, { "-r" }, { "--continue", "old prompt" }, { "-c" },
      { "-r", "session name", "old prompt" }, { "--resume=" .. alpha, "old prompt" },
      { "--session-id=" .. alpha, "old prompt" },
    }) do
      local f = fixture()
      f.argv = { "/fixture/claude" }
      for _, argument in ipairs(arguments) do f.argv[#f.argv + 1] = argument end
      launch(f)
      exact_resume(assert(selected(f)).argv, "/fixture/claude", beta)
    end
  end)

  test("headless, subcommands, settings, worktree, remote and unknown invocations decline", function()
    for _, arguments in ipairs({
      { "-p", "prompt" }, { "--print", "prompt" }, { "agents", "--json" },
      { "mcp" }, { "auth", "status" }, { "update" }, { "help" }, { "doctor" }, { "install" },
      { "ultrareview" }, { "setup-token" },
      { "attach", alpha }, { "remote-control" }, { "--remote" }, { "--remote-control" },
      { "--worktree" }, { "-w", "name" }, { "--bare" }, { "--no-session-persistence" },
      { "--settings", "/private/settings.json" }, { "--settings={}" }, { "--setting-sources", "user" },
      { "--unknown" }, { "--help" }, { "-h" }, { "--version" },
      { "--model" }, { "--model=" }, { "--agent", "" }, { "--permission-mode", "--verbose" },
      { "--session-id" }, { "--session-id=" }, { "--continue=false" },
      { "first prompt", "second prompt" },
    }) do
      local f = fixture()
      f.argv = { "/fixture/claude" }
      for _, argument in ipairs(arguments) do f.argv[#f.argv + 1] = argument end
      launch(f)
      equal(selected(f), nil)
      equal(f.native_calls, {})
      equal(f.writes, {})
    end
  end)

  test("native API and transcript execution failures preserve durable state byte-for-byte", function()
    for _, failure in ipairs({ "native", "find", "find-exit", "find-timeout", "unreadable" }) do
      local f = fixture()
      assert(selected(f))
      local before = read(f.options.state_path)
      if failure == "native" then f.native_error = true
      elseif failure == "find" then f.find_error = true
      elseif failure == "unreadable" then
        assert(rex.exec({ "chmod", "000", f.transcript }).ok)
        local file = io.open(f.transcript, "rb")
        assert(not file, "fixture transcript is still readable; permission failure cannot be tested")
      else
        f.find_result = { ok = false, exit_code = 1, stdout = "",
          stderr = failure == "find-timeout" and "command timed out" or "find: permission denied" }
      end
      local ok, err = tick(f)
      if failure == "unreadable" then assert(rex.exec({ "chmod", "600", f.transcript }).ok) end
      assert(not ok and err, failure .. " was treated as no selection instead of an execution failure")
      equal(read(f.options.state_path), before)
      equal(f.writes, {})
    end
  end)

  test("failed native executions at either snapshot preserve the durable checkpoint", function()
    for _, offset in ipairs({ 1, 2 }) do
      for _, message in ipairs({ "permission denied", "command timed out" }) do
        local f = fixture()
        assert(selected(f))
        local before = read(f.options.state_path)
        f.native_failure_at = #f.native_calls + offset
        f.native_failure_result = { ok = false, exit_code = 1, stdout = "", stderr = message }
        local ok, err = tick(f)
        assert(not ok and err, "a failed native execution was treated as no selection")
        equal(read(f.options.state_path), before)
        equal(f.writes, {})
      end
    end
  end)

  test("restoration types the selected UUID and literal home/mode into only the original pane", function()
    local f = fixture()
    assert(selected(f))
    f.status.instance_id = "run:two"
    f.tree = { foreground = { pid = 8001, name = "zsh" } }
    assert(tick(f))
    equal(f.writes, { {
      session_id = "session:selected", block_id = "block:claude",
      args = { data = "cd -- '/workspace/project'\\''s same' && CLAUDE_CONFIG_DIR=" .. quote(f.home) ..
        " REX_RECOVER_SESSIONS='1' REX_RECOVER_LAUNCH_DIR=" .. quote(f.options.launch_dir) ..
        " REX_SESSION='session:selected' REX_BLOCK='block:claude' " .. quote(f.options.launcher) ..
        " '/fixture/claude' '--resume' '9d73450d-598c-4d30-b866-824a08df2201'\r" },
    } })
    assert(tick(f))
    equal(#f.writes, 1)
  end)

  test("without opt-in generic recording retains argv and never queries native state", function()
    local f = fixture()
    launch(f, true)
    local record = assert(selected(f))
    equal(record.argv, { "/fixture/claude", "--resume", alpha, "launch prompt must not replay" })
    equal(record.env, nil)
    equal(f.native_calls, {})
  end)

  print("Claude mock session contract artifacts: " .. base)
  assert(#failures == 0, table.concat(failures, "\n"))
  print("Claude mock session contract tests passed")
  return
end

local function call(method, args)
  local result, err = rex.call(method, args)
  assert(result, err)
  return result
end

local function wait_for(description, check)
  for _ = 1, 200 do
    if check() then return end
    rex.sleep(0.1)
  end
  error("timed out: " .. description)
end

local fixture_path = directory .. "/claude-sessions.json"
local fixture
local function save()
  write(fixture_path, assert(rex.json.encode(fixture)))
end

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

local function observed(index)
  local current = process(index)
  if not current then return nil end
  local file = io.open(directory .. "/claude-app/native/" .. current.pid, "rb")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return rex.json.decode(text)
end

local function checkpointed()
  local current = state()
  for index = 1, 2 do
    local record = current.apps[fixture.blocks[index]]
    if not record or record.argv[3] ~= fixture.selected[index] then return false end
    equal(record.argv, { fixture.executable, "--resume", fixture.selected[index] })
    equal(record.cwd, fixture.cwd)
    equal(record.env, { CLAUDE_CONFIG_DIR = fixture.home, REX_RECOVER_SESSIONS = "1" })
  end
  return current.instance_id == call("server.status").instance_id
end

if phase == "setup" then
  local windows = {}
  for index = 1, 2 do
    windows[index] = { window_label = "Claude mock " .. index, layout = rex.layout.block {
      flavor = "com.superlogical.terminal.shell",
      options = { command = { "/bin/zsh", "-f" }, shell = "none", cwd = directory .. "/claude project" },
    } }
  end
  local created = call("session.create", { label = "claude-mock-contract", initial_windows = windows })
  local status = call("server.status")
  fixture = { session_id = created.session_id, blocks = {}, pids = {}, selected = { beta, alpha },
    cwd = directory .. "/claude project", home = directory .. "/claude's home",
    executable = directory .. "/claude-app/claude", instance_id = status.instance_id,
    endpoint = assert(rex.args.endpoint) }
  write(fixture.home .. "/projects/not-derived-from-cwd/" .. alpha .. ".jsonl", "opaque Alpha history\n")
  write(fixture.home .. "/projects/not-derived-from-cwd/" .. beta .. ".jsonl", "opaque Beta history\n")
  call("session.attach", { session_id = fixture.session_id })
  for index = 1, 2 do
    fixture.blocks[index] = created.initial_windows[index].block_ids[1]
    wait_for("fixture shell", function() return process(index) and process(index).name == "zsh" end)
    input(index, "unset REX_RECOVER_CONFIG REX_RECOVER_LAUNCH_DIR; export CLAUDE_CONFIG_DIR=" ..
      quote(fixture.home) .. " REX_RECOVER_SESSIONS=1 REX_RECOVER_STATE_DIR=" ..
      quote(directory .. "/watcher") .. " REX_SESSION=" .. quote(fixture.session_id) ..
      " REX_BLOCK=" .. quote(fixture.blocks[index]) .. " REX_BIN=" .. quote(assert(rex.args.rex_bin)) ..
      " REX_SERVER=" .. quote(fixture.endpoint) .. "; " .. quote(rex.args.root .. "/bin/rex-recover-run") ..
      " " .. quote(fixture.executable) .. " --resume " .. alpha .. " " ..
      quote("launch prompt must not replay"))
  end
  for index = 1, 2 do
    wait_for("live native interactive observation", function()
      local entry = observed(index)
      return entry and entry.sessionId == alpha and entry.kind == "interactive"
    end)
    local current = process(index)
    fixture.pids[index] = current.pid
    equal(read(directory .. "/claude-app/logs/" .. fixture.blocks[index] .. "." .. current.pid),
      fixture.cwd .. "\0" .. fixture.home .. "\0" .. "1\0--resume\0" .. alpha ..
      "\0launch prompt must not replay\0")
    equal(current.cwd, "/")
  end
  input(1, "beta")
  wait_for("same-process switch from launch Alpha to selected Beta", function()
    local entry = observed(1)
    return entry and entry.sessionId == beta and process(1).pid == fixture.pids[1]
  end)
  save()
else
  fixture = assert(rex.json.decode(read(fixture_path)))
  call("session.attach", { session_id = fixture.session_id })
end

if phase == "setup" then
  -- The watcher, not setup, must now derive each selected UUID from native output.
elseif phase == "checkpoint" then
  wait_for("distinct same-cwd Claude checkpoints", checkpointed)
  local queries = assert(rex.exec({ "find", directory .. "/claude-app/queries", "-type", "f" }))
  assert(queries.ok and queries.stdout ~= "", "no native executable query was observed")
  for path in queries.stdout:gmatch("[^\r\n]+") do
    equal(read(path), fixture.cwd .. "\0" .. fixture.home .. "\0agents\0--json\0")
  end
elseif phase == "invalidate" then
  for _, command in ipairs({ "noid", "new", "background" }) do
    input(1, command)
    wait_for(command .. " removes only the stale pane checkpoint", function()
      local entry, current = observed(1), state()
      local changed = entry and ((command == "noid" and entry.sessionId == nil)
        or (command == "new" and entry.sessionId == fresh)
        or (command == "background" and entry.kind == "background"))
      return changed and not current.apps[fixture.blocks[1]] and not current.pending[fixture.blocks[1]]
        and current.apps[fixture.blocks[2]] ~= nil
    end)
    equal(process(1).pid, fixture.pids[1])
    input(1, "beta")
    wait_for("Beta can be checkpointed again after " .. command, checkpointed)
  end
  local transcript = fixture.home .. "/projects/not-derived-from-cwd/" .. beta .. ".jsonl"
  assert(os.remove(transcript))
  wait_for("missing selected transcript invalidates only Beta", function()
    local current = state()
    return not current.apps[fixture.blocks[1]] and not current.pending[fixture.blocks[1]]
      and current.apps[fixture.blocks[2]] ~= nil
  end)
  write(transcript, "opaque Beta history restored\n")
  wait_for("persisted Beta returns without relaunching its process", checkpointed)
  equal(process(1).pid, fixture.pids[1])
elseif phase == "restored" then
  assert(fixture.instance_id ~= call("server.status").instance_id, "server instance did not change")
  for index = 1, 2 do
    wait_for("selected Claude mock restored in its original pane", function()
      local current, entry = process(index), observed(index)
      return current and current.pid ~= fixture.pids[index] and entry
        and entry.sessionId == fixture.selected[index] and entry.kind == "interactive"
    end)
    local current = process(index)
    equal(read(directory .. "/claude-app/logs/" .. fixture.blocks[index] .. "." .. current.pid),
      fixture.cwd .. "\0" .. fixture.home .. "\0" .. "1\0--resume\0" .. fixture.selected[index] .. "\0")
    equal(current.cwd, "/")
    fixture.pids[index] = current.pid
  end
  fixture.instance_id = call("server.status").instance_id
  save()
elseif phase == "exit" then
  for index = 1, 2 do input(index, "exit") end
  wait_for("intentional Claude exits remove checkpoints", function()
    local current = state()
    return not current.apps[fixture.blocks[1]] and not current.apps[fixture.blocks[2]]
  end)
  local logs = assert(rex.exec({ "ls", "-1", directory .. "/claude-app/logs" }))
  assert(logs.ok, logs.stderr)
  fixture.logs = logs.stdout
  save()
elseif phase == "not-restored" then
  rex.sleep(1)
  local logs = assert(rex.exec({ "ls", "-1", directory .. "/claude-app/logs" }))
  assert(logs.ok, logs.stderr)
  equal(logs.stdout, fixture.logs)
  for index = 1, 2 do
    assert(process(index).pid ~= fixture.pids[index], "exited Claude fixture remained alive")
    assert(not state().apps[fixture.blocks[index]], "completed Claude regained a checkpoint")
  end
else
  error("unknown Claude session integration phase: " .. phase)
end

print("ok - Claude mock session integration: " .. phase)
