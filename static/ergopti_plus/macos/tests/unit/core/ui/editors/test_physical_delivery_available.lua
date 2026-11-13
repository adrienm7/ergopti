--- tests/unit/core/ui/editors/test_physical_delivery_available.lua

--- ==============================================================================
--- MODULE: Physical Shortcut Delivery Is Available (macOS)
--- DESCRIPTION:
--- LIN-004, turned on by the maintainer on 2026-11-11 on macOS as on Linux:
--- the production delivery getter answers true, so the real host and the
--- shared menu port open the editor once the window constructor is ready. The
--- safety refusals stay: a window that is not ready or a getter that answers
--- false keeps the editor closed with no scope captured
--- (physical-delivery-available). A pause does not (EDD-1).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs fn with the real keyboard module and host, restoring package state.
--- @param window_ready boolean What the host's native_available answers.
--- @param fn function Receives (keyboard, host).
local function with_host(window_ready, fn)
	local loaded, original_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local ok, err = pcall(function()
		local keyboard = helpers.load_with_stubs("modules.shortcuts.keyboard_shortcuts")
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = keyboard
		package.loaded["ui.physical_shortcuts"] = nil
		local host = require("ui.physical_shortcuts")
		host.native_available = function() return window_ready end
		fn(keyboard, host)
	end)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	_G.hs = original_hs
	if not ok then error(err, 0) end
end

--- The shared menu port over a host, counting captures and refusals.
--- @param host table
--- @return table menu, table counts
local function menu_over(host)
	local counts = { captured = 0, refused = 0 }
	local menu = require("shortcuts.engine.physical_editor_menu").new({
		host = function() return host end,
		scope = function() counts.captured = counts.captured + 1 return {} end,
		refused = function() counts.refused = counts.refused + 1 end,
	})
	return menu, counts
end

helpers.describe("macos physical delivery is available (physical-delivery-available)", function()
	helpers.it("physical-delivery: the real getter and host answer true and the menu is ready", function()
		with_host(true, function(keyboard, host)
			helpers.assert_eq(keyboard.physical_delivery_available(), true, "the production getter")
			helpers.assert_eq(host.physical_delivery_available(), true, "the host reads the getter")
			helpers.assert_eq(menu_over(host).ready(), true, "the editor row is enabled")
		end)
	end)

	helpers.it("physical-delivery: a window that is not ready keeps the editor closed", function()
		with_host(false, function(_, host)
			local menu, counts = menu_over(host)
			helpers.assert_eq(menu.ready(), false)
			helpers.assert_eq(menu.open(), false)
			helpers.assert_eq(counts.captured, 0, "no scope is captured")
			helpers.assert_eq(counts.refused, 1, "the refusal is told once")
		end)
	end)

	-- EDD-1 (maintainer, 2026-11-12): a pause stops typing, not configuration;
	-- the shared menu port reads no pause at all.
	helpers.it("physical-delivery: the editor opens without a pause owner (edd1-paused-writes)", function()
		with_host(true, function(_, host)
			local menu = menu_over(host)
			helpers.assert_eq(menu.ready(), true)
		end)
	end)

	helpers.it("physical-delivery: a getter answering false still refuses the editor", function()
		with_host(true, function(keyboard, host)
			keyboard.physical_delivery_available = function() return false end
			helpers.assert_eq(host.physical_delivery_available(), false, "the refusal is read live")
			local menu, counts = menu_over(host)
			helpers.assert_eq(menu.ready(), false)
			helpers.assert_eq(menu.open(), false)
			helpers.assert_eq(counts.captured, 0, "no scope is captured")
			helpers.assert_eq(counts.refused, 1, "the refusal is told once")
		end)
	end)
end)
