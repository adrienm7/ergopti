--- infra/pause_layout_preferences.lua

--- ==============================================================================
--- MODULE: Pause Layout Preferences (Linux)
--- DESCRIPTION:
--- Owns the three [layout] settings of the automatic layout switch in
--- config.toml: the switch (layout.pause_switch_enabled) and the layout a pause
--- and a resume select (layout.on_pause, layout.on_resume). Paths, types and
--- valid targets come from the shared policy and the generated manifest.
---
--- FEATURES & RATIONALE:
--- 1. Read on every use. A pause reads the file it would switch for, so a hand
---    edit applies at the next pause without a reload.
--- 2. A leaf in another shape (a legacy `on_pause = false`, a text switch) is
---    outdated configuration for that leaf alone: warned once, read as its
---    manifest default, left for the cleanup.
--- 3. Sparse durable writes. A choice is written through the shared writer's
---    compare-and-swap publication; a value equal to its default deletes the key.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local ConfigPaths = require("infra.config_paths")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Logger = require("logger.shim")
local ConfigOutdated = require("config_outdated")
local Policy = require("layout.pause_switch_policy")
local LOG = "infra.pause_layout_preferences"

-- Role -> validator of a stored value: the switch is a boolean, a target is a
-- layout id or "" by the shared policy.
local VALIDATORS = {
	enabled = function(value)
		if type(value) == "boolean" then return true end
		return false, "the value is not a boolean"
	end,
	on_pause = Policy.valid_target,
	on_resume = Policy.valid_target,
}

--- The config.toml key of one role.
--- @param role string "enabled", "on_pause" or "on_resume".
--- @return string section, string key
local function leaf(role)
	local path = Policy.PATHS[role]
	assert(path ~= nil, "unknown pause layout setting: " .. tostring(role))
	local section, key = path:match("^([^.]+)%.([^.]+)$")
	assert(Manifest.find_entry_by_path(path) ~= nil, "the manifest does not declare " .. path)
	return section, key
end

--- Resolves the three settings from one parsed configuration, without effects.
--- @param config table Parsed config.toml.
--- @param mark function|nil Consumed-key collector of the unused-key cleanup:
---   a valid leaf is marked, an outdated one is left for the cleanup to offer.
--- @return table settings { enabled, on_pause, on_resume }
function M.resolve(config, mark)
	assert(type(config) == "table", "pause layout preferences contain malformed TOML")
	local settings = {}
	for role in pairs(VALIDATORS) do
		local section, key = leaf(role)
		local node = config[section]
		local value
		if type(node) == "table" then value = node[key] end
		if value ~= nil then
			local valid, detail = VALIDATORS[role](value)
			if not valid then
				ConfigOutdated.report({ section, key }, detail, Logger)
				value = nil
			end
		end
		if mark and value ~= nil then mark(section, key) end
		if value == nil then value = Manifest.default_for(Policy.PATHS[role]) end
		settings[role] = value
	end
	return settings
end

--- Reads the settings and the exact source they came from.
--- @return table settings { enabled, on_pause, on_resume }
--- @return table source Classified source bytes for a conditional write.
function M.snapshot()
	local bytes, status, detail = Writer.read_classified(ConfigPaths.config("config.toml"))
	assert(status == "ok" or status == "absent", "pause layout preferences are unreadable: " .. tostring(detail))
	return M.resolve(Codec.decode(bytes or "")), { status = status, content = bytes }
end

--- Reads the three settings.
--- @return table settings { enabled, on_pause, on_resume }
function M.settings()
	return (M.snapshot())
end

--- Publishes one choice while preserving the rest of config.toml.
--- @param role string "enabled", "on_pause" or "on_resume".
--- @param value any A value the role's validator accepts.
--- @return boolean committed
function M.set(role, value)
	local called, committed, detail = pcall(function()
		leaf(role)
		local valid, reason = VALIDATORS[role](value)
		assert(valid, "invalid pause layout setting " .. role .. ": " .. tostring(reason))
		local _, source = M.snapshot()
		local operation = Manifest.sparse_operation(Policy.PATHS[role], value)
		return Writer.batch_write(ConfigPaths.config("config.toml"), { operation }, nil, source)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "Pause layout setting '%s' was not persisted: %s.", tostring(role),
			tostring(called and detail or committed))
		return false
	end
	Logger.debug(LOG, "Pause layout setting '%s' persisted.", role)
	return true
end

return M
