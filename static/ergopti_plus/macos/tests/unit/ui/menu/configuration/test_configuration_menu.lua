--- tests/unit/ui/menu/configuration/test_configuration_menu.lua

--- ==============================================================================
--- MODULE: The Configuration Submenu (macOS)
--- DESCRIPTION:
--- « Configuration » replaced « Actions globales » and the two top-level rows
--- that opened the folders editor and the setup wizard. It holds, in order: the
--- restore of Ergopti's recommended values and the clear to the system's
--- behaviour (the first group of every settings menu), a separator, the
--- config.toml cleanup, a separator, the folders editor and the setup wizard,
--- then a separator and the download proxy (moved from Debug on 2026-11-03).
--- Startup and Uninstall moved to Version / Updates
--- (test_menu_about_uninstall.lua), with no separator left dangling here.
---
--- PAUSE GATING: a pause stops typing, not configuration (EDD-1, maintainer
--- decision 2026-11-12), so every Configuration row stays live while paused.
---
--- Driven through Builder.generate, so the assertion is on what the menu offers.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The rows in the order the menu must draw them, by the key of their label.
local EXPECTED = {
	"common.restore_recommended",
	"common.clear_to_system",
	"-",
	"menu.global.clean_unused_keys",
	"-",
	"menu.global.config_folder",
	"menu.global.setup_wizard",
	"-",
	"menu.debug.proxy_override",
}

-- The rows that rewrite the configuration, and the action each one runs.
local GATED = {}

-- Rows that do not modify the running keyboard, and the action each one runs.
-- A pause stops typing, not configuration (EDD-1, maintainer decision
-- 2026-11-12): the whole-configuration restore and clear stay live.
local LIVE = {
	["common.restore_recommended"] = "reset_defaults",
	["common.clear_to_system"]     = "clear_to_system",
	["menu.global.clean_unused_keys"] = "clean_unused_keys",
	["menu.global.config_folder"] = "open_paths",
	["menu.global.setup_wizard"]  = "show_setup_wizard",
}

--- Actions that record which one ran.
--- @param fired table Receives the name of every action invoked.
--- @return table actions
local function recording_actions(fired)
	return setmetatable({}, { __index = function(_, name)
		return function() fired[#fired + 1] = name end
	end })
end

--- Builds the tray and returns the Configuration submenu.
--- @param paused boolean ctx.paused for this build.
--- @param fired table Action recorder.
--- @return table|nil rows
local function configuration_rows(paused, fired)
	local builder = helpers.load_with_stubs("ui.menu.builder")
	local i18n = require("core.i18n.engine.i18n")
	i18n.get = function(key) return key end
	i18n.build_language_menu_items = function() return {} end
	local ok, menu = pcall(builder.generate, { config = { log_level = 2 }, paused = paused }, {},
		recording_actions(fired))
	helpers.assert_true(ok, "Builder.generate raised: " .. tostring(menu))
	for _, item in ipairs(menu) do
		if item.title == "menu.configuration.title" then return item.menu end
	end
	return nil
end




-- ================================
-- ================================
-- ======= 1/ Content =============
-- ================================
-- ================================

helpers.describe("configuration submenu (macOS): its rows, in order", function()
	helpers.it("draws the five configuration rows in their declared groups", function()
		local rows = configuration_rows(false, {})
		helpers.assert_true(type(rows) == "table", "the tray must carry the Configuration submenu")
		local drawn = {}
		for index, row in ipairs(rows) do drawn[index] = row.title end
		helpers.assert_eq(table.concat(drawn, ", "), table.concat(EXPECTED, ", "))
	end)

	helpers.it("each row runs its own action", function()
		local fired = {}
		local rows = configuration_rows(false, fired)
		local expected = {}
		for _, row in ipairs(rows) do
			local action = GATED[row.title] or LIVE[row.title]
			if action then
				helpers.assert_eq(type(row.fn), "function", row.title .. " must carry its handler")
				helpers.assert_true(row.disabled ~= true, row.title .. " must be enabled while running")
				row.fn()
				expected[#expected + 1] = action
			end
		end
		helpers.assert_eq(#expected, 5, "all five rows must be drawn and wired")
		helpers.assert_eq(table.concat(fired, ", "), table.concat(expected, ", "))
	end)
end)




-- ================================
-- ================================
-- ======= 2/ Pause gating ========
-- ================================
-- ================================

helpers.describe("configuration submenu (macOS): a pause gates what rewrites the configuration", function()
	helpers.it("keeps every Configuration row live while paused (edd1-paused-writes)", function()
		local fired = {}
		local rows = configuration_rows(true, fired)
		helpers.assert_true(type(rows) == "table", "the Configuration submenu stays reachable while paused")
		local gated, live = 0, 0
		for _, row in ipairs(rows) do
			if GATED[row.title] then
				gated = gated + 1
				helpers.assert_true(row.disabled == true, row.title .. " must be DISABLED while paused")
				helpers.assert_nil(row.fn, row.title .. " must carry no handler while paused")
			elseif LIVE[row.title] then
				live = live + 1
				helpers.assert_true(row.disabled ~= true, row.title .. " must stay enabled while paused")
				helpers.assert_eq(type(row.fn), "function", row.title .. " must keep its handler")
			end
		end
		helpers.assert_eq(gated, 0, "no Configuration row greys while paused")
		helpers.assert_eq(live, 5, "all live rows must be drawn")
		helpers.assert_eq(#fired, 0, "building the menu must not run any action")
	end)
end)




-- ============================================
-- ============================================
-- ======= 3/ No Karabiner Switch =============
-- ============================================
-- ============================================

--- Builds the Configuration submenu over a remap owner double.
--- @param enabled boolean What the remap owner reports for `integration_enabled`.
--- @param calls table Receives the owner requests.
--- @return table|nil rows
local function rows_with_karabiner(enabled, calls)
	local builder = helpers.load_with_stubs("ui.menu.builder")
	local i18n = require("core.i18n.engine.i18n")
	i18n.get = function(key) return key end
	i18n.build_language_menu_items = function() return {} end
	local karabiner = {
		get_enabled = function() return enabled end,
		set_enabled = function(value, on_done)
			calls[#calls + 1] = "set_enabled:" .. tostring(value)
			on_done(true, "stopped")
			return true
		end,
	}
	local ctx = { config = { log_level = 2 }, paused = false, karabiner = karabiner, updateMenu = function() end }
	local ok, menu = pcall(builder.generate, ctx, {}, recording_actions({}))
	helpers.assert_true(ok, "Builder.generate raised: " .. tostring(menu))
	for _, item in ipairs(menu) do
		if item.title == "menu.configuration.title" then return item.menu end
	end
	return nil
end

--- Finds one row by the key of its label.
--- @param rows table Rendered rows.
--- @param title string Label key.
--- @return table|nil row
local function row_titled(rows, title)
	for _, row in ipairs(rows or {}) do
		if row.title == title then return row end
	end
	return nil
end

helpers.describe("configuration submenu (macOS): no row acts on the user's Karabiner", function()
	helpers.it("draws no Karabiner switch or removal, whatever the remap owner reports", function()
		-- Ergopti runs its own remapping runtime (ADR 011): « Ergopti uses
		-- Karabiner » and « Remove Ergopti from Karabiner » acted on the user's
		-- Karabiner-Elements and were deleted with the owned default.
		for _, enabled in ipairs({ true, false }) do
			local calls = {}
			local rows = rows_with_karabiner(enabled, calls)
			local drawn = {}
			for index, row in ipairs(rows) do drawn[index] = row.title end
			helpers.assert_eq(table.concat(drawn, ", "), table.concat({
				"common.restore_recommended",
				"common.clear_to_system",
				"-",
				"menu.global.clean_unused_keys",
				"-",
				"menu.global.config_folder",
				"menu.global.setup_wizard",
				"-",
				"menu.debug.proxy_override",
			}, ", "))
			helpers.assert_nil(row_titled(rows, "menu.global.karabiner_integration"))
			helpers.assert_nil(row_titled(rows, "menu.global.remove_from_karabiner"))
			helpers.assert_eq(#calls, 0, "building the menu asks nothing of the remap owner")
		end
	end)
end)


--- Replays structural admission through the actual complete tray and native action closures.
--- @param body function Independent source and finished-row assertions.
local function configuration_parent_fixture(body)
	local saved = {}
	for _, name in ipairs({ "ui.menu.builder", "core.i18n.engine.i18n", "core.i18n.engine.locale", "infra.manifest_menu" }) do saved[name] = package.loaded[name] end
	helpers.load_with_stubs("core.fs.engine.paths")
	for _, name in ipairs({ "ui.menu.builder", "core.i18n.engine.i18n", "core.i18n.engine.locale", "infra.manifest_menu" }) do package.loaded[name] = nil end
	local native = require("ui.menu.builder")
	local renderer, locale = require("infra.manifest_menu"), require("core.i18n.engine.locale")
	local language = locale.current_locale()
	local callbacks, actions = {}, {}
	local getter_observer = { calls = 0 }
	for key, label in pairs({ reset_defaults = "recommended", clear_to_system = "clear", clean_unused_keys = "cleanup",
		open_paths = "paths_editor", show_setup_wizard = "setup_wizard" }) do
		local value = label
		actions[key] = function() callbacks[#callbacks + 1] = value; return false end
	end
	local published_actions = setmetatable({}, { __index = function(_, key)
		local value = rawget(actions, key)
		if value ~= nil then getter_observer.calls = getter_observer.calls + 1 end
		return value
	end })
	local function build(paused) return native.generate({ paused = paused }, {}, published_actions) end
	local ok, detail = xpcall(function() body(renderer, build, callbacks, locale, getter_observer) end, debug.traceback)
	locale.set_locale(language)
	for _, name in ipairs({ "ui.menu.builder", "core.i18n.engine.i18n", "core.i18n.engine.locale", "infra.manifest_menu" }) do package.loaded[name] = saved[name] end
	if not ok then error(detail, 0) end
end

local configuration_parent_file = assert(io.open(require("core.fs.engine.paths").shared("tests/corpus/menus/configuration_parent.json"), "rb"))
local configuration_parent_raw = configuration_parent_file:read("*a")
configuration_parent_file:close()
require("tests.lua.settings.configuration_parent_contract").register(helpers, configuration_parent_fixture,
	assert(require("core.fs.adapters.json_codec").decode(configuration_parent_raw)), "hs")
