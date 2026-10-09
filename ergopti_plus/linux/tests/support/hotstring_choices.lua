--- tests/support/hotstring_choices.lua

--- ==============================================================================
--- MODULE: Private Hotstring Choice Files
--- DESCRIPTION:
--- Routes the hotstring configuration owner to a private config.toml for one
--- test, seeded with explicit category and section choices, and removes every
--- file the scenario may have written. Tests never share the user's canonical
--- configuration, so their activations cannot leak into another module.
--- ==============================================================================

local M = {}
local _sequence = 0

--- A fresh absolute path inside the process scratch directory.
--- @param suffix string
--- @return string
local function scratch_path(suffix)
	local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
	_sequence = _sequence + 1
	return string.format("%s/ergopti_hotstring_choices_%d_%d_%d%s", base, os.time(),
		math.random(100000, 999999), _sequence, suffix)
end

--- Renders explicit group choices as the canonical inline table.
--- @param groups table|nil Map of group id to boolean.
--- @return string
local function render(groups)
	local ids = {}
	for id in pairs(groups or {}) do ids[#ids + 1] = id end
	table.sort(ids)
	if #ids == 0 then return "" end
	local parts = {}
	for _, id in ipairs(ids) do
		local key = id:match("^[A-Za-z0-9_%-]+$") and id or ('"' .. id .. '"')
		parts[#parts + 1] = key .. " = " .. tostring(groups[id])
	end
	return "[hotstrings]\ngroups = { " .. table.concat(parts, ", ") .. " }\n"
end

--- Runs body with the owner routed to a private configuration file.
--- Must be called before the owner's init(), which reads the choices.
--- @param Config table The hotstring configuration module.
--- @param source string|table|nil Exact bytes, a group map to enable, or nil for absence.
--- @param body function body(path) Test body.
function M.with_file(Config, source, body)
	local path = scratch_path(".toml")
	local content = type(source) == "table" and render(source) or source
	if content ~= nil then
		local handle = assert(io.open(path, "w"))
		assert(handle:write(content))
		assert(handle:close())
	end
	assert(Config._set_config_file_for_test(path), "the choice owner must accept a private file")
	local ok, err = pcall(body, path)
	Config._set_config_file_for_test(nil)
	os.remove(path)
	os.remove(path .. ".tmp")
	if not ok then error(err, 0) end
end

--- Reads the private file's exact bytes, or nil when absent.
--- @param path string
--- @return string|nil
function M.read(path)
	local handle = io.open(path, "r")
	if not handle then return nil end
	local content = handle:read("*a")
	handle:close()
	return content
end

return M
