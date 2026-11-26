--- tests/unit/menu/ui/tray/test_suspend_row.lua

--- ==============================================================================
--- MODULE: Tray « Suspendre » Row
--- DESCRIPTION:
--- macOS shows the Windows « Suspendre » row right before Reload (maintainer,
--- 2026-11-24): ticked while Ergopti is paused, and a click runs the same pause
--- transaction as the pause key and the « Ergopti+ » title pill, which keeps
--- toggling too.
---
--- ROOT CAUSE ENCODED: the macOS tray could only pause or resume from its title
--- pill, where the Windows tray offers a row next to Reload.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the real tray root over a script-control double.
--- @param paused boolean The pause state the build reads.
--- @param control table|nil The script-control double.
--- @return table rows
local function root(paused, control)
	local builder = helpers.load_with_stubs("menu.ui.builder.builder")
	local i18n = require("core.i18n.engine.i18n")
	i18n.build_language_menu_items = function() return {} end
	local actions = { reload = function() end, quit = function() end }
	return builder.generate({ paused = paused, script_control = control }, {}, actions)
end

--- The position of the row titled with a locale key's caption, read from the
--- i18n module the build used.
--- @param rows table
--- @param key string
--- @return number|nil
local function position(rows, key)
	local caption = require("core.i18n.engine.i18n").get(key)
	for index, row in ipairs(rows) do
		if row.title == caption then return index end
	end
	return nil
end

helpers.describe("macOS tray « Suspendre » row", function()
	helpers.it("sits right before Reload, unticked while Ergopti runs", function()
		local rows = root(false, { toggle_script_control = function() return true end })
		local suspend = position(rows, "menu.global.suspend")
		local reload = position(rows, "menu.global.reload_macos")
		helpers.assert_true(suspend ~= nil, "the tray draws the Suspendre row")
		helpers.assert_eq(reload, suspend + 1, "Reload follows Suspendre")
		helpers.assert_eq(rows[suspend].checked, false)
		helpers.assert_nil(rows[suspend].menu, "the row is one switch, not a submenu")
	end)

	helpers.it("reads ticked while paused and runs the pause transaction on a click", function()
		local toggles = 0
		local rows = root(true, { toggle_script_control = function() toggles = toggles + 1; return true end })
		local row = rows[position(rows, "menu.global.suspend")]
		helpers.assert_eq(row.checked, true, "a paused Ergopti ticks Suspendre")
		helpers.assert_eq(row.fn(), true)
		helpers.assert_eq(toggles, 1, "one click, one pause transaction")
	end)

	helpers.it("refuses a click without a script-control owner instead of claiming a pause", function()
		local rows = root(false, nil)
		local row = rows[position(rows, "menu.global.suspend")]
		helpers.assert_eq(row.fn(), false)
	end)
end)
