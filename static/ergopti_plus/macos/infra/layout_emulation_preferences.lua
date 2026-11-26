--- infra/layout_emulation_preferences.lua

--- ==============================================================================
--- MODULE: Layout Emulation Preferences (macOS)
--- DESCRIPTION:
--- Reads and writes the [layout] settings of the layout emulation through the
--- menu's preference state (settings/engine/preferences/preferences.lua flat keys layout_emulated_layout,
--- layout_ergopti_variant, layout_ergopti_base, layout_ergopti_alt_gr,
--- layout_emulate_<row> and the « Touches de jeu » layout_game_keys and
--- layout_game_keys_apps), so the keyboard-layout scope's restore and clear, the
--- session demotions and every save see them like any other row. The emulation
--- (modules/keymap/layout_emulation.lua) reads config.toml through the shared
--- resolver after each save.
--- ==============================================================================

local M = {}
local Manifest = require("menu.engine.manifest_reader")
local Logger = require("core.logger.engine.logger")
local Settings = require("layouts.engine.emulation.settings")
local GameKeys = require("layouts.engine.emulation.game_keys")
local ConfigKeys = require("settings.engine.keys")
local LOG = "infra.layout_emulation_preferences"

--- The flat state key of one [layout] path.
local function flat_key(path)
	return assert(require("settings.engine.preferences.preferences").flat_key_for(path), "no preference owner for " .. tostring(path))
end

--- The emulation settings the menu state holds.
--- @param state table The menu preference state.
--- @return table settings layouts/engine/emulation/settings.lua's resolve result.
function M.settings(state)
	local layout = {}
	for _, leaf in ipairs(Settings.LEAVES) do
		local section, key = leaf.path:match("^([^.]+)%.([^.]+)$")
		if section == "layout" and type(state) == "table" then layout[key] = state[flat_key(leaf.path)] end
	end
	return Settings.resolve({ layout = layout }, Manifest.default_for)
end

--- The value of one switch in the state.
--- @param state table
--- @param path string One of the shared resolver's SWITCHES.
--- @return boolean
function M.switch(state, path)
	return Settings.switch_value(M.settings(state), path)
end

--- Stores several leaves in the state and saves them; the state is rolled back
--- when the save is refused.
--- @return boolean committed
local function publish(state, save_prefs, values)
	if type(state) ~= "table" or type(save_prefs) ~= "function" then
		Logger.error(LOG, "No preference state to store the layout emulation settings in.")
		return false
	end
	-- A list, not a key → value map: a leaf that was absent has a nil previous
	-- value, which a map would drop, leaving the refused value in the state.
	local previous = {}
	for path, value in pairs(values) do
		local key = flat_key(path)
		previous[#previous + 1] = { key = key, value = state[key] }
		state[key] = value
	end
	if save_prefs() ~= true then
		for _, entry in ipairs(previous) do state[entry.key] = entry.value end
		Logger.error(LOG, "Layout emulation settings were not persisted.")
		return false
	end
	Logger.debug(LOG, "Layout emulation settings persisted.")
	return true
end

--- Sets one switch.
--- @param state table
--- @param save_prefs function
--- @param path string One of the shared resolver's SWITCHES.
--- @param value boolean
--- @return boolean committed
function M.set_switch(state, save_prefs, path, value)
	if Settings.SWITCHES[path] == nil or type(value) ~= "boolean" then
		Logger.error(LOG, "Refused layout emulation switch %s = %s.", tostring(path), tostring(value))
		return false
	end
	return publish(state, save_prefs, { [path] = value })
end

--- Chooses the emulated layout: "none", a built-in Ergopti variant or a registry id.
--- The layout chosen leads the recent layouts, saved with it.
--- @param state table
--- @param save_prefs function
--- @param choice string
--- @return boolean committed
function M.choose(state, save_prefs, choice)
	local values = Settings.choice_values(choice, M.settings(state).recents)
	if values == nil then
		Logger.error(LOG, "Refused emulated layout choice %s.", tostring(choice))
		return false
	end
	return publish(state, save_prefs, values)
end

--- The « Touches de jeu » settings the menu state holds.
--- @param state table The menu preference state.
--- @return table settings layouts/engine/emulation/game_keys.lua's resolve result.
function M.game_keys(state)
	local layout = {}
	if type(state) == "table" then
		layout[ConfigKeys.LEAF.GAME_KEYS] = state[flat_key(ConfigKeys.KEY.LAYOUT_GAME_KEYS)]
		layout[ConfigKeys.LEAF.GAME_KEYS_APPS] = state[flat_key(ConfigKeys.KEY.LAYOUT_GAME_KEYS_APPS)]
	end
	return GameKeys.resolve({ layout = layout }, Manifest.default_for, function(segments, detail)
		require("settings.engine.migration.outdated").report(segments, detail, Logger)
	end)
end

--- Saves the global « Touches de jeu » choice, or an application's own.
--- @param state table
--- @param save_prefs function
--- @param app string|nil The application's bundle identifier; nil for the global choice.
--- @param choice string|nil "physical" or "letters"; nil to follow the global one again.
--- @return boolean committed
function M.set_game_keys(state, save_prefs, app, choice)
	local values = GameKeys.write_values(M.game_keys(state), "macos", app, choice)
	return values ~= nil and publish(state, save_prefs, values)
end

return M
