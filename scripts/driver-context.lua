-- The shell cannot evaluate Lua definitions. Use Rex's existing Lua runtime
-- only to return validated descriptor metadata, never the server's environment.
local source = debug.getinfo(1, "S").source
local root = assert(source:match("^@?(.*)/scripts/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path
local registry = require("drivers.registry")
local output = assert(rex.args.output)
assert(type(output) == "string" and output:sub(1, 1) == "/" and not output:find("%c"),
  "an absolute private output path is required")
local entry = registry.lookup(rex.args.app, rex)
local file = assert(io.open(output, "wb"))
if entry then
  assert(file:write(entry.id .. "\t" .. entry.home_env .. "\t" .. entry.default_home .. "\n"))
end
assert(file:close())
