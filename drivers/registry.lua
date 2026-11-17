-- Discovery and common launch checks only. App protocols and configuration
-- belong exclusively in each driver file.
local M = {}
local source = debug.getinfo(1, "S").source
local directory = assert(source:match("^@?(.*)/[^/]+$"), "cannot locate driver directory from " .. source)
local entries, home_variables

local function path_variable(name)
  return type(name) == "string" and name:match("^[A-Z_][A-Z0-9_]*$")
    and name ~= "PATH" and not name:match("^REX_RECOVER_")
    and name ~= "REX_SESSION" and name ~= "REX_BLOCK"
    and name ~= "REX_SERVER" and name ~= "REX_BIN" and name ~= "REX_BIN_DIR"
end

local function discover(api)
  if entries then return end
  api = rawget(_G, "rex") or api
  assert(api and api.exec, "driver discovery requires the Rex Lua runtime")
  local files, err = api.exec({ "find", "-L", directory, "-maxdepth", "1", "-type", "f", "-name", "*.lua" },
    { timeout = 2 })
  assert(files and files.ok, err or (files and files.stderr) or "cannot discover driver files")
  local paths, found, variables = {}, {}, {}
  for path in files.stdout:gmatch("[^\r\n]+") do paths[#paths + 1] = path end
  table.sort(paths)
  for _, path in ipairs(paths) do
    local id = path:match("/([^/]+)%.lua$")
    assert(id and id:match("^[a-z0-9_%-]+$"), "invalid driver filename: " .. path)
    if id ~= "registry" and id:sub(1, 1) ~= "_" then
      local driver = require("drivers." .. id)
      assert(type(driver) == "table" and type(driver.capture) == "function",
        id .. " must export a driver definition with capture(context)")
      local app, home_env, default_home = driver.executable, driver.home_env, driver.default_home
      assert(type(app) == "string" and app:match("^[%w_][%w_.+%-]*$")
        and path_variable(home_env)
        and type(default_home) == "string" and default_home ~= "" and not default_home:find("%c")
        and default_home:sub(1, 1) ~= "/" and not ("/" .. default_home .. "/"):find("/../", 1, true),
        "invalid driver configuration: " .. id)
      assert(driver.environment == nil or type(driver.environment) == "table",
        "invalid driver environment: " .. id)
      local environment, seen, count = driver.environment or {}, {}, 0
      for index, name in pairs(environment) do
        assert(type(index) == "number" and index >= 1 and index % 1 == 0
          and index <= #environment and path_variable(name) and not seen[name],
          "invalid driver environment: " .. id)
        seen[name], variables[name], count = true, true, count + 1
      end
      assert(count == #environment, "driver environment contains holes: " .. id)
      assert(driver.validate == nil or type(driver.validate) == "function",
        "invalid driver validator: " .. id)
      assert(not found[app], "duplicate driver executable: " .. app)
      found[app] = { id = id, home_env = home_env, default_home = default_home, driver = driver }
      variables[home_env] = true
    end
  end
  entries, home_variables = found, variables
end

function M.lookup(app, api)
  discover(api)
  return entries[app]
end

function M.home_variable(name)
  discover()
  return home_variables[name] == true
end

function M.recorded(name, api)
  local fallback = require("recovery").recorded(name)
  local entry = M.lookup(name, api)
  if not entry then return fallback end
  return {
    name = name,
    validate = entry.driver.validate and function(record)
      if not record.env or record.env.REX_RECOVER_SESSIONS ~= "1" then return true end
      return entry.driver.validate(record, api)
    end,
    detect = function(process, launch, processes)
      if not launch or launch.app ~= name or process.pid ~= launch.pid then return nil end
      if not launch.driver then return fallback.detect(process, launch) end
      if launch.driver ~= entry.id then return nil end
      local command, err = entry.driver.capture({ api = api, launch = launch, processes = processes })
      if not command then return nil, err end
      command.cwd = command.cwd or launch.cwd
      command.tracked = true
      if command.env ~= nil and type(command.env) ~= "table" then
        return nil, "invalid session storage environment"
      end
      command.env = command.env or {}
      command.env[entry.home_env] = launch.home
      command.env.REX_RECOVER_SESSIONS = "1"
      return command
    end,
  }
end

return M
