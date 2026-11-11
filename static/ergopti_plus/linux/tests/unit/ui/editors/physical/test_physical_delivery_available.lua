--- tests/unit/ui/editors/physical/test_physical_delivery_available.lua

--- ==============================================================================
--- MODULE: Physical Shortcut Delivery Is Available (Linux)
--- DESCRIPTION:
--- LIN-004, turned on by the maintainer on 2026-11-11: the production delivery
--- getter answers true, so the real bridge and the shared menu port open the
--- editor once the GUI is ready. The safety refusals stay: a GUI that is not
--- ready, a paused script or a getter that answers false keeps the editor
--- closed with no scope captured, and the refusal is told once.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs fn with the real keyboard module and bridge over a stubbed GUI.
--- @param gui_ready boolean What webview_manager.native_available answers.
--- @param fn function Receives (keyboard, bridge).
local function with_bridge(gui_ready, fn)
	local saved_manager = package.loaded["ui.webview_manager"]
	local saved_bridge = package.loaded["ui.physical_shortcuts.bridge"]
	package.loaded["ui.webview_manager"] = { native_available = function() return gui_ready end }
	package.loaded["ui.physical_shortcuts.bridge"] = nil
	local ok, err = pcall(function()
		local keyboard = helpers.load_module("modules.shortcuts.keyboard_shortcuts")
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = keyboard
		fn(keyboard, require("ui.physical_shortcuts.bridge"))
	end)
	package.loaded["ui.webview_manager"] = saved_manager
	package.loaded["ui.physical_shortcuts.bridge"] = saved_bridge
	if not ok then error(err, 0) end
end

--- The shared menu port over a bridge, counting captures and refusals.
--- @param bridge table
--- @param paused boolean
--- @return table menu, table counts
local function menu_over(bridge, paused)
	local counts = { captured = 0, refused = 0 }
	local menu = require("shortcuts.physical_editor_menu").new({
		host = function() return bridge end,
		scope = function() counts.captured = counts.captured + 1 return {} end,
		paused = function() return paused end,
		refused = function() counts.refused = counts.refused + 1 end,
	})
	return menu, counts
end

helpers.describe("linux physical delivery is available (physical-delivery-available)", function()
	helpers.it("physical-delivery: the real getter and bridge answer true and the menu is ready", function()
		with_bridge(true, function(keyboard, bridge)
			helpers.assert_eq(keyboard.physical_delivery_available(), true, "the production getter")
			helpers.assert_eq(bridge.physical_delivery_available(), true, "the bridge reads the getter")
			local menu = menu_over(bridge, false)
			helpers.assert_eq(menu.ready(), true, "the editor row is enabled")
		end)
	end)

	helpers.it("physical-delivery: a GUI that is not ready keeps the editor closed", function()
		with_bridge(false, function(_, bridge)
			local menu, counts = menu_over(bridge, false)
			helpers.assert_eq(menu.ready(), false)
			helpers.assert_eq(menu.open(), false)
			helpers.assert_eq(counts.captured, 0, "no scope is captured")
			helpers.assert_eq(counts.refused, 1, "the refusal is told once")
		end)
	end)

	helpers.it("physical-delivery: a paused script keeps the editor closed", function()
		with_bridge(true, function(_, bridge)
			local menu, counts = menu_over(bridge, true)
			helpers.assert_eq(menu.ready(), false)
			helpers.assert_eq(menu.open(), false)
			helpers.assert_eq(counts.captured, 0, "no scope is captured")
		end)
	end)

	helpers.it("physical-delivery: a getter answering false still refuses the editor and the binding", function()
		with_bridge(true, function(keyboard, bridge)
			local original = keyboard.physical_delivery_available
			keyboard.physical_delivery_available = function() return false end
			local ok, err = pcall(function()
				helpers.assert_eq(bridge.physical_delivery_available(), false, "the refusal is read live")
				local menu, counts = menu_over(bridge, false)
				helpers.assert_eq(menu.ready(), false)
				helpers.assert_eq(menu.open(), false)
				helpers.assert_eq(counts.captured, 0, "no scope is captured")
				helpers.assert_eq(counts.refused, 1, "the refusal is told once")
			end)
			keyboard.physical_delivery_available = original
			if not ok then error(err, 0) end
		end)
	end)
end)
