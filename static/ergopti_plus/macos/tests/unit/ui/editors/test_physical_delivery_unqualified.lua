--- tests/unit/ui/editors/test_physical_delivery_unqualified.lua

--- ==============================================================================
--- MODULE: Physical Shortcut Delivery Stays Unqualified (macOS)
--- DESCRIPTION:
--- The production delivery getter answers false until native source,
--- all-owner collision and output custody are qualified. This drives the real
--- getter, the real host and the shared menu port with the window constructor
--- ready, so turning the getter on without that qualification fails here, and
--- the editor never opens meanwhile (physical-delivery-unqualified).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("macos physical delivery is unqualified (physical-delivery-unqualified)", function()
	helpers.it("physical-delivery: the real getter, host and menu stay closed with the window ready", function()
		local loaded, original_hs = {}, _G.hs
		for name, value in pairs(package.loaded) do loaded[name] = value end
		local ok, err = pcall(function()
			local keyboard = helpers.load_with_stubs("modules.shortcuts.keyboard_shortcuts")
			helpers.assert_eq(keyboard.physical_delivery_available(), false, "the production getter")
			package.loaded["ui.physical_shortcuts"] = nil
			local host = require("ui.physical_shortcuts")
			host.native_available = function() return true end
			helpers.assert_eq(host.physical_delivery_available(), false, "a ready window is no delivery")
			local captured, refused = 0, 0
			local menu = require("shortcuts.physical_editor_menu").new({
				host = function() return host end,
				scope = function() captured = captured + 1 return {} end,
				paused = function() return false end,
				refused = function() refused = refused + 1 end,
			})
			helpers.assert_eq(menu.ready(), false)
			helpers.assert_eq(menu.open(), false)
			helpers.assert_eq(captured, 0, "no scope is captured")
			helpers.assert_eq(refused, 1, "the refusal is told once")
		end)
		for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(loaded) do package.loaded[name] = value end
		_G.hs = original_hs
		if not ok then error(err, 0) end
	end)
end)
