--- infra/number_row_preferences.lua

--- ==============================================================================
--- MODULE: Number Row Preferences (Linux)
--- DESCRIPTION:
--- Owns the two [layout] settings of the number-row options in config.toml: the
--- ordering (layout.direct_access_digits: native, digits or symbols) and the
--- switch that brings the three edge keys along (layout.number_row_reorder_edges).
--- Paths, types and defaults come from the shared policy and the generated
--- manifest; the layout manager applies what is stored (modules/keymap/number_row_live).
---
--- FEATURES & RATIONALE:
--- 1. Read on every use, so a hand edit applies the next time the options are applied.
--- 2. A leaf in another shape is outdated configuration for that leaf alone: warned
---    once, read as its manifest default, left for the cleanup.
--- 3. Sparse durable writes through the shared writer's compare-and-swap
---    publication; a value equal to its default deletes the key.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local ConfigPaths = require("infra.config_paths")
local ConfigKeys = require("config_keys")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Logger = require("logger.shim")
local ConfigOutdated = require("config_outdated")
local Policy = require("layout.number_row_policy")
local LOG = "infra.number_row_preferences"

-- Role -> the config.toml path and the validator of a stored value.
local ROLES = {
	order = {
		path = ConfigKeys.KEY.LAYOUT_DIRECT_ACCESS_DIGITS,
		valid = function(value)
			if Policy.mode(value) ~= nil then return true end
			return false, "the value is not native, digits or symbols"
		end,
	},
	edges = {
		path = ConfigKeys.KEY.LAYOUT_NUMBER_ROW_REORDER_EDGES,
		valid = function(value)
			if type(value) == "boolean" then return true end
			return false, "the value is not a boolean"
		end,
	},
}

--- The config.toml section and key of one role.
--- @param role string "order" or "edges".
--- @return string section, string key
local function leaf(role)
	local spec = ROLES[role]
	assert(spec ~= nil, "unknown number-row setting: " .. tostring(role))
	assert(Manifest.find_entry_by_path(spec.path) ~= nil, "the manifest does not declare " .. spec.path)
	return spec.path:match("^([^.]+)%.([^.]+)$")
end

--- Resolves the settings from one parsed configuration, without effects.
--- @param config table Parsed config.toml.
--- @param mark function|nil Consumed-key collector of the unused-key cleanup.
--- @return table settings { order, edges }
function M.resolve(config, mark)
	assert(type(config) == "table", "number-row preferences contain malformed TOML")
	local settings = {}
	for role, spec in pairs(ROLES) do
		local section, key = leaf(role)
		local node = config[section]
		local value
		if type(node) == "table" then value = node[key] end
		if value ~= nil then
			local valid, detail = spec.valid(value)
			if not valid then
				ConfigOutdated.report({ section, key }, detail, Logger)
				value = nil
			end
		end
		if mark and value ~= nil then mark(section, key) end
		if value == nil then value = Manifest.default_for(spec.path) end
		settings[role] = value
	end
	return settings
end

--- Reads the settings and the exact source they came from.
--- @return table settings { order, edges }
--- @return table source Classified source bytes for a conditional write.
function M.snapshot()
	local bytes, status, detail = Writer.read_classified(ConfigPaths.config("config.toml"))
	assert(status == "ok" or status == "absent", "number-row preferences are unreadable: " .. tostring(detail))
	return M.resolve(Codec.decode(bytes or "")), { status = status, content = bytes }
end

--- Reads the two settings.
--- @return table settings { order, edges }
function M.settings()
	return (M.snapshot())
end

--- Publishes one choice while preserving the rest of config.toml.
--- @param role string "order" or "edges".
--- @param value any A value the role's validator accepts.
--- @return boolean committed
function M.set(role, value)
	local called, committed, detail = pcall(function()
		leaf(role)
		local valid, reason = ROLES[role].valid(value)
		assert(valid, "invalid number-row setting " .. role .. ": " .. tostring(reason))
		local _, source = M.snapshot()
		local operation = Manifest.sparse_operation(ROLES[role].path, value)
		return Writer.batch_write(ConfigPaths.config("config.toml"), { operation }, nil, source)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "Number-row setting '%s' was not persisted: %s.", tostring(role),
			tostring(called and detail or committed))
		return false
	end
	Logger.debug(LOG, "Number-row setting '%s' persisted.", role)
	return true
end

return M
