local recovery = require("recovery")
local drivers = require("drivers.registry")
local interval = rex.args.interval or 2
assert(type(interval) == "number" and interval > 0, "interval must be positive")
assert(type(rex.args.state_path) == "string", "state_path is required")

assert(type(rex.args.config) == "string", "config is required")
assert(type(rex.args.config_reader) == "string", "config_reader is required")
local result, err = rex.exec({ rex.args.config_reader, rex.args.config }, { timeout = 5 })
assert(result, err)
assert(result.ok, result.stderr)
local adapters = {}
for name in result.stdout:gmatch("[^\r\n]+") do
  adapters[#adapters + 1] = drivers.recorded(name, rex)
end

local monitor = assert(recovery.new(rex, {
  state_path = rex.args.state_path,
  adapters = adapters,
  launcher = rex.args.launcher,
}))

local scanning = false
local function checkpoint()
  if scanning then return end
  scanning = true
  local ok, err = monitor:tick()
  scanning = false
  if not ok then
    local status, status_err = rex.call("server.status")
    assert(status, status_err)
    rex.log("warn", err)
  end
end

-- Process and session metadata are polled even when no terminal event occurs.
-- Using that same interval for all changes bounds scans during event bursts.
rex.every(interval, checkpoint)
checkpoint()
rex.log("info", "App recovery is monitoring this Rex server")
