--- tools/lib/layout_source_read.lua

--- ==============================================================================
--- MODULE: Layout Source Canonical Read Adapter
--- DESCRIPTION:
--- Sends an explicit source payload through the shared conversion admission and
--- canonical reader. It reads no user files and publishes no artifacts.
--- ==============================================================================

if #arg ~= 1 then error("usage: lua layout_source_read.lua <shared root>", 0) end
package.path = arg[1] .. "/lua/?.lua;" .. arg[1] .. "/lua/?/init.lua;" .. package.path
local Json = require("json")
local Keylayout = require("layouts.keylayout")

local function read()
	local input = assert(Json.decode(io.read("*a")))
	local canonical, reason = Keylayout.parse_conversion(input.xml)
	if not canonical then return { ok = false, reason = reason } end
	return { ok = true, canonical = canonical }
end

local called, result = pcall(read)
if not called then io.stderr:write(tostring(result), "\n"); os.exit(2) end
io.write(Json.encode(result))
