--- _shared/lua/script_override_projection.lua

--- ==============================================================================
--- MODULE: Script Override Projection
--- DESCRIPTION:
--- Lists the scalar settings of the `[script]` table of a decoded config.toml as
--- override candidates, each with the exact source path it was read from, so the
--- loader that writes them and the unused-key scan that marks them read agree on
--- one identity.
---
--- WHY ONLY `[script]`:
--- The `[features]` layer that used to project dotted feature paths onto flat
--- settings was retired: a second way to set what the menu and the sparse
--- `config.toml` leaves already set, kept only for files written before the
--- project had a schema. Every declared feature has one canonical leaf.
--- ==============================================================================

local M = {}
local TableUtil = require("table_util")

local function is_scalar(value)
	local kind = type(value)
	return kind == "string" or kind == "number" or kind == "boolean"
end

local function keys(values)
	return TableUtil.sorted_keys(values, TableUtil.by_text)
end

--- Builds every `[script]` candidate before native settings or read marks publish.
--- Tables and arrays stay non-scalar candidates, so a loader can refuse them.
--- @param decoded table Parsed configuration document.
--- @return table|nil rows Exact section, setting key, value and source segments.
--- @return string|nil error Reason the document cannot be projected.
function M.prepare(decoded)
	if type(decoded) ~= "table" then return nil, "Override document is not a table" end
	local rows = {}
	local script = decoded.script
	if type(script) == "table" then
		for _, key in ipairs(keys(script)) do
			rows[#rows + 1] = {
				section = "script", key = key, path = { key }, value = script[key],
				accepted = type(key) == "string" and key ~= "" and is_scalar(script[key]),
			}
		end
	end
	return rows
end

return M
