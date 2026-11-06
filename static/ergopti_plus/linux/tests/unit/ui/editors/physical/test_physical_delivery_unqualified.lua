--- tests/unit/ui/editors/physical/test_physical_delivery_unqualified.lua

--- ==============================================================================
--- MODULE: Physical Shortcut Delivery Stays Unqualified (Linux)
--- DESCRIPTION:
--- LIN-004: the production delivery getter answers false until native source,
--- all-owner collision and output custody are qualified. The earlier tests
--- injected that answer; this one drives the real getter, the real bridge and
--- the shared menu port with the GUI ready, so turning the getter on without
--- that qualification fails here, and the editor never opens meanwhile.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("linux physical delivery is unqualified (physical-delivery-unqualified)", function()
	helpers.it("physical-delivery: the real getter, bridge and menu stay closed with the GUI ready", function()
		local saved_manager = package.loaded["ui.webview_manager"]
		local saved_bridge = package.loaded["ui.physical_shortcuts.bridge"]
		package.loaded["ui.webview_manager"] = { native_available = function() return true end }
		package.loaded["ui.physical_shortcuts.bridge"] = nil
		local ok, err = pcall(function()
			local keyboard = helpers.load_module("modules.shortcuts.keyboard_shortcuts")
			helpers.assert_eq(keyboard.physical_delivery_available(), false, "the production getter")
			local bridge = require("ui.physical_shortcuts.bridge")
			helpers.assert_eq(bridge.native_available(), true, "the GUI is ready")
			helpers.assert_eq(bridge.physical_delivery_available(), false, "readiness is no delivery")
			local captured, refused = 0, 0
			local menu = require("shortcuts.physical_editor_menu").new({
				host = function() return bridge end,
				scope = function() captured = captured + 1 return {} end,
				paused = function() return false end,
				refused = function() refused = refused + 1 end,
			})
			helpers.assert_eq(menu.ready(), false)
			helpers.assert_eq(menu.open(), false)
			helpers.assert_eq(captured, 0, "no scope is captured")
			helpers.assert_eq(refused, 1, "the refusal is told once")
		end)
		package.loaded["ui.webview_manager"] = saved_manager
		package.loaded["ui.physical_shortcuts.bridge"] = saved_bridge
		if not ok then error(err, 0) end
	end)
end)
