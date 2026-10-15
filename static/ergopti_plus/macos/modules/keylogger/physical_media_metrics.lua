--- modules/keylogger/physical_media_metrics.lua

--- Pure optional metrics ports prepared before native intake. This constructor
--- grants no source, capture, lifecycle or READY authority and starts no observer.
local M = {}
local function port(source, name)
	assert(type(source) == "table" and getmetatable(source) == nil
		and type(rawget(source, name)) == "function", "Missing prepared physical media port: " .. name)
	return rawget(source, name)
end

--- Reads the admitted catalogue once and snapshots exact FIFO/policy functions.
---@return table ports Closed optional Capture dependency, not a native capability.
function M.new()
	local core = require("modules.keylogger.aggregator.core")
	local policy = port(core, "media_policy")()
	local resolve, known = port(policy, "resolve_hid"), port(policy, "is_known")
	local sink = port(require("modules.keylogger.log_manager"), "log_physical_media")
	return { resolve = resolve, is_known = known,
		emit = function(press) return sink("physical_media_press", press) == true end,
		emit_release = function(release) return sink("physical_media_release", release) == true end }
end
return M
