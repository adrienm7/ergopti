--- layouts/engine/registry/emulation_preferences.lua

--- ==============================================================================
--- MODULE: Layout Emulation Preferences (Linux)
--- DESCRIPTION:
--- Reads and writes the [layout] settings of the layout emulation in
--- config.toml: which layout is emulated (emulated_layout, ergopti_variant,
--- ergopti_base), its AltGr layer (ergopti_alt_gr) and its four row switches
--- (emulate_<row>). The emulation (layouts/engine/registry/emulation.lua) reads
--- them through the shared resolver; this module writes them for the menu.
---
--- FEATURES & RATIONALE:
--- 1. Read on every use, so a hand edit applies the next time the emulation reloads.
--- 2. Sparse durable writes through the shared writer's compare-and-swap
---    publication, several leaves in one batch; a value equal to its default
---    deletes the key. Which leaves a choice writes is the shared resolver's.
--- ==============================================================================

local M = {}
local Manifest = require("menu.engine.manifest_reader")
local ConfigPaths = require("settings.engine.paths")
local Writer = require("core.text.engine.toml_codec.writer")
local Codec = require("core.text.engine.toml_codec")
local Logger = require("core.logger.engine.shim")
local ConfigOutdated = require("settings.engine.migration.outdated")
local Settings = require("layouts.engine.emulation.settings")
local LOG = "layouts.engine.registry.emulation_preferences"

--- Reads config.toml and its exact source.
--- @return table config Parsed config.toml.
--- @return table source Classified source bytes for a conditional write.
function M.snapshot()
	local bytes, status, detail = Writer.read_classified(ConfigPaths.config("config.toml"))
	assert(status == "ok" or status == "absent", "layout emulation preferences are unreadable: " .. tostring(detail))
	return Codec.decode(bytes or ""), { status = status, content = bytes }
end

--- The emulation settings in force.
--- @return table settings layouts/engine/emulation/settings.lua's resolve result.
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
	local called, committed, detail = pcall(function()
		local _, source = M.snapshot()
		return Writer.batch_write(ConfigPaths.config("config.toml"),
			Settings.operations(values, Manifest.sparse_operation), nil, source)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "Layout emulation settings were not persisted: %s.", tostring(called and detail or committed))
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
