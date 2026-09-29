--- tests/unit/ui/menu/test_menu_about_uninstall.lua

--- ==============================================================================
--- MODULE: Uninstall Closes The Version / Updates Submenu (macOS)
--- DESCRIPTION:
--- « Désinstaller Ergopti » sat at the bottom of Configuration, between the
--- rows that tune the configuration, where removing the application read as
--- one more setting. It now closes the Version / Updates submenu, set apart by
--- a separator, next to the build it removes; it keeps its label key and runs
--- the same action (the menu session's uninstall transaction), and stays live
--- while the script is paused. Configuration ends on login startup, with no
--- dangling separator.
---
--- Driven through Builder.generate with the real About module, so the
--- assertion is on what the menu offers and on the action it is handed.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Actions that record which one ran.
--- @param fired table Receives the name of every action invoked.
--- @return table actions
local function recording_actions(fired)
	return setmetatable({}, { __index = function(_, name)
		return function() fired[#fired + 1] = name end
	end })
end

--- Builds the tray with the real About module and returns a submenu by title key.
--- @param paused boolean ctx.paused for this build.
--- @param fired table Action recorder.
--- @param title_key string Locale key of the submenu's row.
--- @return table|nil rows
local function submenu(paused, fired, title_key)
	local builder = helpers.load_with_stubs("ui.menu.builder")
	local About = require("ui.menu.menu_about")
	local i18n = require("infra.i18n")
	i18n.get = function(key) return key end
	i18n.build_language_menu_items = function() return {} end
	local owner = { get = function() return "dev" end, set = function() return true end, subscribe = function() end }
	local ok, menu = pcall(builder.generate, { config = { log_level = 2 }, paused = paused, channel_owner = owner },
		{ about = About }, recording_actions(fired))
	helpers.assert_true(ok, "Builder.generate raised: " .. tostring(menu))
	for _, item in ipairs(menu) do
		if item.title == title_key then return item.menu end
	end
	return nil
end

helpers.describe("about submenu (macOS): Uninstall closes it", function()
	for _, paused in ipairs({ false, true }) do
		helpers.it("is the last row, after a separator, and runs the uninstall action (paused=" .. tostring(paused) .. ")",
			function()
				local fired = {}
				local rows = submenu(paused, fired, "menu.about.title")
				helpers.assert_true(type(rows) == "table" and #rows >= 3, "the tray must carry the About submenu")
				local last = rows[#rows]
				helpers.assert_eq(last.title, "menu.global.uninstall", "Uninstall closes the submenu")
				helpers.assert_eq(rows[#rows - 1].title, "-", "a separator sets it apart")
				helpers.assert_eq(rows[#rows - 2].title, "menu.about.open_releases_page",
					"it follows the releases rows")
				helpers.assert_true(last.disabled ~= true, "Uninstall stays live")
				helpers.assert_eq(type(last.fn), "function", "Uninstall carries its handler")
				helpers.assert_eq(#fired, 0, "building the menu must not run any action")
				last.fn()
				helpers.assert_eq(fired, { "uninstall" }, "the row runs the session's uninstall action")
			end)
	end

	helpers.it("is drawn once in the whole tray, never in Configuration", function()
		local rows = submenu(false, {}, "menu.configuration.title")
		helpers.assert_true(type(rows) == "table", "the tray must carry the Configuration submenu")
		for _, row in ipairs(rows) do
			helpers.assert_true(row.title ~= "menu.global.uninstall", "Configuration no longer offers Uninstall")
		end
		helpers.assert_true(rows[#rows].title ~= "-", "Configuration ends on a row, not a separator")
	end)
end)
