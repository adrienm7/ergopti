--- infra/layout_emulation_preferences.lua

--- ==============================================================================
--- MODULE: Layout Emulation Preferences (macOS)
--- DESCRIPTION:
--- Reads and writes the [layout] settings of the layout emulation in
--- config.toml: which layout is emulated (emulated_layout, ergopti_variant,
--- ergopti_base), its AltGr layer (ergopti_alt_gr) and its four row switches
--- (emulate_<row>). The emulation (modules/keymap/layout_emulation.lua) reads
--- them through the shared resolver; this module writes them for the menu.
---
--- FEATURES & RATIONALE:
--- 1. Read on every use, so a hand edit applies the next time the emulation reloads.
--- 2. Owned leaves outside the menu state: published through
---    Preferences.publish_owned, the conditional writer tap keys use, so a
---    concurrent save of the menu state never overwrites them.
--- 3. Which leaves a choice writes is the shared resolver's, as on Linux.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local ConfigPaths = require("infra.config_paths")
local FileSystem = require("adapters.file_system")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Logger = require("infra.logger")
local ConfigOutdated = require("config_outdated")
local Settings = require("layouts.emulation_settings")
local LOG = "infra.layout_emulation_preferences"

--- Reads config.toml and its exact source.
--- @return table config Parsed config.toml.
--- @return table source Classified source bytes for a conditional write.
function M.snapshot()
	local content, status, detail = Writer.read_classified(ConfigPaths.get("ConfigTomlPath"), FileSystem)
	assert(status == "ok" or status == "absent", "layout emulation preferences are unreadable: " .. tostring(detail))
	return Codec.decode(content or ""), { status = status, content = content }
end

--- The emulation settings in force.
--- @return table settings layouts/emulation_settings.lua's resolve result.
function M.settings()
	return Settings.resolve((M.snapshot()), Manifest.default_for,
		function(segments, detail) ConfigOutdated.report(segments, detail, Logger) end)
end

--- The value of one switch in force.
--- @param path string One of the shared resolver's SWITCHES.
--- @return boolean
function M.switch(path)
	return Settings.switch_value(M.settings(), path)
end

--- Publishes several leaves in one batch while preserving the rest of config.toml.
--- @param values table path -> value.
--- @return boolean committed
local function publish(values)
	local called, committed = pcall(function()
		local _, source = M.snapshot()
		return require("infra.preferences").publish_owned(ConfigPaths.get("ConfigTomlPath"),
			Settings.operations(values, Manifest.sparse_operation), source)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "Layout emulation settings were not persisted: %s.", tostring(committed))
		return false
	end
	Logger.debug(LOG, "Layout emulation settings persisted.")
	return true
end

--- Sets one switch.
--- @param path string One of the shared resolver's SWITCHES.
--- @param value boolean
--- @return boolean committed
function M.set_switch(path, value)
	if Settings.SWITCHES[path] == nil or type(value) ~= "boolean" then
		Logger.error(LOG, "Refused layout emulation switch %s = %s.", tostring(path), tostring(value))
		return false
	end
	return publish({ [path] = value })
end

--- Chooses the emulated layout: "none", a built-in Ergopti variant or a registry id.
--- @param choice string
--- @return boolean committed
function M.choose(choice)
	local values = Settings.choice_values(choice)
	if values == nil then
		Logger.error(LOG, "Refused emulated layout choice %s.", tostring(choice))
		return false
	end
	return publish(values)
end

return M
