--- tests/unit/menu/structure/test_suspend_row.lua

--- ==============================================================================
--- MODULE: Tray « Suspendre » Row (Linux)
--- DESCRIPTION:
--- Linux shows the « Suspendre » row Windows and macOS show right before Reload
--- (maintainer, 2026-11-24): ticked while the daemon is paused, and a click asks
--- the daemon's pause toggle. The paused header row keeps resuming too.
---
--- ROOT CAUSE ENCODED: the Linux tray could only resume from its paused header
--- and had no row to pause from, where the other two trays offer one.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the real tray root.
--- @param ctx_fields table Context fields added to the build context.
--- @return table rows
local function build(ctx_fields)
	local ctx = { _version = "9.9.9", on_quit = function() end }
	for name, value in pairs(ctx_fields) do ctx[name] = value end
	return helpers.load_module("menu.ui.builder.builder").build(ctx)
end

--- The position of the row titled with a locale key's caption.
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

helpers.describe("Linux tray « Suspendre » row", function()
	helpers.it("sits right before Reload, unticked while the daemon runs", function()
		local rows = build({ paused = false, on_toggle_pause = function() return true end })
		local suspend = position(rows, "menu.global.suspend")
		helpers.assert_true(suspend ~= nil, "the tray draws the Suspendre row")
		helpers.assert_eq(position(rows, "menu.global.reload"), suspend + 1, "Reload follows Suspendre")
		helpers.assert_eq(rows[suspend].checked, false)
		helpers.assert_nil(rows[suspend].menu, "the row is one switch, not a submenu")
	end)

	helpers.it("reads ticked while paused and asks the daemon's pause toggle on a click", function()
		local toggles = 0
		local rows = build({ paused = true, on_toggle_pause = function() toggles = toggles + 1; return true end })
		local row = rows[position(rows, "menu.global.suspend")]
		helpers.assert_eq(row.checked, true, "a paused daemon ticks Suspendre")
		helpers.assert_eq(row.fn(), true)
		helpers.assert_eq(toggles, 1, "one click, one pause toggle")
	end)

	helpers.it("refuses a click without the daemon's pause toggle instead of claiming a pause", function()
		local rows = build({ paused = false })
		helpers.assert_eq(rows[position(rows, "menu.global.suspend")].fn(), false)
	end)
end)

return true
