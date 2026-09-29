--- tests/unit/ui/menu/test_configuration_menu.lua

--- ==============================================================================
--- MODULE: The Configuration Submenu (macOS)
--- DESCRIPTION:
--- « Configuration » replaced « Actions globales » and the two top-level rows
--- that opened the folders editor and the setup wizard. It holds, in order: the
--- restore of Ergopti's recommended values, the config.toml cleanup, a
--- separator, the folders editor, the setup wizard and login startup, and ends
--- there: Uninstall moved to the bottom of the Version / Updates submenu
--- (test_menu_about_uninstall.lua), with no separator left dangling here.
---
--- PAUSE GATING, carried over from the global actions: pause owns the bindings
--- axis for the whole pause window — pause_all() snapshots what was running and
--- resume_all() restores that snapshot — so a row that rewrites the
--- configuration mid-pause is either discarded on resume or breaks « pause =
--- tout éteint ». Those two rows are greyed AND stripped of their handler while
--- paused; the two that only open a window stay live, like every other tail row.
---
--- Driven through Builder.generate, so the assertion is on what the menu offers.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The rows in the order the menu must draw them, by the key of their label.
local EXPECTED = {
	"common.restore_recommended",
	"menu.global.clean_unused_keys",
	"-",
	"menu.global.config_folder",
	"menu.global.setup_wizard",
	"menu.global.start_at_login",
}

-- The rows that rewrite the configuration, and the action each one runs.
local GATED = {
	["common.restore_recommended"]   = "reset_defaults",
	["menu.global.clean_unused_keys"] = "clean_unused_keys",
}

-- Rows that do not modify the running keyboard, and the action each one runs.
local LIVE = {
	["menu.global.config_folder"] = "open_paths",
	["menu.global.setup_wizard"]  = "show_setup_wizard",
	["menu.global.start_at_login"] = "start_at_login",
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
	local i18n = require("infra.i18n")
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
	helpers.it("greys the two rewriting rows and keeps independent actions live", function()
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
		helpers.assert_eq(gated, 2, "both rewriting rows must be drawn")
		helpers.assert_eq(live, 3, "all independent rows must be drawn")
		helpers.assert_eq(#fired, 0, "building the menu must not run any action")
	end)
	for _, action in ipairs({ "start_at_login" }) do
		helpers.it(action .. " remains available without resuming keyboard features", function()
			local fired = {}
			local rows = configuration_rows(true, fired)
			local found
			for _, row in ipairs(rows) do
				if row.title == "menu.global." .. action then found = row end
			end
			helpers.assert_true(found ~= nil and not found.disabled)
			helpers.assert_eq(type(found.fn), "function")
			found.fn()
			helpers.assert_eq(fired, { action })
		end)
	end
end)




-- ============================================
-- ============================================
-- ======= 3/ Ergopti Uses Karabiner ==========
-- ============================================
-- ============================================

--- Builds the Configuration submenu over a remap owner double.
--- @param enabled boolean Current « Ergopti uses Karabiner » state.
--- @param calls table Receives the owner requests.
--- @return table|nil rows
local function rows_with_karabiner(enabled, calls)
	local builder = helpers.load_with_stubs("ui.menu.builder")
	local i18n = require("infra.i18n")
	i18n.get = function(key) return key end
	i18n.build_language_menu_items = function() return {} end
	local karabiner = {
		get_enabled = function() return enabled end,
		set_enabled = function(value, on_done)
			calls[#calls + 1] = "set_enabled:" .. tostring(value)
			on_done(true, "stopped")
			return true
		end,
		remove_from_karabiner = function(on_done)
			calls[#calls + 1] = "remove_from_karabiner"
			on_done(true, "removed", 2)
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

helpers.describe("configuration submenu (macOS): « Ergopti uses Karabiner »", function()
	helpers.it("draws the switch ticked from the remap owner and the removal after login startup", function()
		for _, enabled in ipairs({ true, false }) do
			local rows = rows_with_karabiner(enabled, {})
			local drawn = {}
			for index, row in ipairs(rows) do drawn[index] = row.title end
			helpers.assert_eq(table.concat(drawn, ", "), table.concat({
				"common.restore_recommended",
				"menu.global.clean_unused_keys",
				"-",
				"menu.global.config_folder",
				"menu.global.setup_wizard",
				"menu.global.start_at_login",
				"menu.global.karabiner_integration",
				"menu.global.remove_from_karabiner",
				"-",
				"menu.global.uninstall",
			}, ", "))
			helpers.assert_eq(row_titled(rows, "menu.global.karabiner_integration").checked, enabled)
		end
	end)

	helpers.it("turns the switch to the opposite state and removes through the owner", function()
		local calls = {}
		local rows = rows_with_karabiner(true, calls)
		row_titled(rows, "menu.global.karabiner_integration").fn()
		row_titled(rows, "menu.global.remove_from_karabiner").fn()
		helpers.assert_eq(table.concat(calls, ", "), "set_enabled:false, remove_from_karabiner")

		calls = {}
		rows = rows_with_karabiner(false, calls)
		row_titled(rows, "menu.global.karabiner_integration").fn()
		helpers.assert_eq(table.concat(calls, ", "), "set_enabled:true")
	end)
end)
