--- tests/support/keyboard_config_fixture.lua

--- Installs the canonical conditional file port while preserving each native fixture.
local M = {}
local Codec = require("toml_codec")

--- Keeps parsed assignment observations attached to one exact TOML source.
--- @param assignments table Initial canonical slot map, updated after successful writes.
--- @param before_write function|nil Explicit conditional-publication failure hook.
function M.install(assignments, before_write)
	local files = assert(package.loaded["adapters.file_system"])
	local content = Codec.encode({ shortcuts = { keyboard = assignments } })
	files.read_with_status = function() return content, "ok" end
	files.write = function() error("keyboard owner must publish conditionally") end
	files.write_if_unchanged = function(_, candidate, source)
		if source.content ~= content then return false end
		if before_write then before_write() end
		local next_values = Codec.decode(candidate).shortcuts
		next_values = next_values and next_values.keyboard or {}
		for key in pairs(assignments) do assignments[key] = nil end
		for key, value in pairs(next_values) do assignments[key] = value end
		content = candidate
		return true
	end
	package.loaded["infra.config_paths"] = { get = function() return "keyboard-fixture-config" end }
	package.loaded["infra.preferences"] = nil
end

return M
