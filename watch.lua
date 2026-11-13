local recovery = require("recovery")
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
  adapters[#adapters + 1] = recovery.recorded(name)
end

local monitor = assert(recovery.new(rex, {
  state_path = rex.args.state_path,
  adapters = adapters,
  launcher = rex.args.launcher,
}))

local function checkpoint()
  local ok, err = monitor:tick()
  assert(ok, err)
end

rex.on("terminal.process_changed", checkpoint)
rex.on("block_closed", checkpoint)
rex.on("session_destroyed", checkpoint)
rex.every(interval, checkpoint)
checkpoint()
rex.log("info", "App recovery is monitoring this Rex server")
