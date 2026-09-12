--- tests/unit/ui/test_webview_focus_reentrancy.lua

--- ==============================================================================
--- MODULE: WebView Focus Reentrancy Tests
--- DESCRIPTION:
--- Verifies exact owner authority across native focus lookup boundaries.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs the real focus controller with independently recorded native effects.
--- @param boundary string Native boundary that retires the owner.
--- @param scenario function Assertions over the native effect records.
local function with_focus(boundary, scenario)
	local loaded, prior_hs = {}, _G.hs
	for key, value in pairs(package.loaded) do loaded[key] = value end
	local records = { current = true, moves = 0, raises = 0, focuses = 0, app_focuses = 0 }
	local ok, err = xpcall(function()
		package.loaded["infra.logger"] = {
			debug = function() end, info = function() end, warn = function() end,
			error = function() end,
		}
		package.loaded["infra.paths"] = { shared = function() return "/virtual/shared" end }
		package.loaded["infra.deferred_work"] = { after = function()
			error("A ready window must not schedule a retry")
		end }
		_G.hs = {
			screen = { mainScreen = function()
				if boundary == "screen" then records.current = false end
				return {}
			end },
			focus = function() records.app_focuses = records.app_focuses + 1 end,
		}
		local window = {
			moveToScreen = function() records.moves = records.moves + 1 end,
			raise = function() records.raises = records.raises + 1 end,
			focus = function() records.focuses = records.focuses + 1 end,
		}
		local view = { hswindow = function()
			if boundary == "window" then records.current = false end
			return window
		end }
		package.loaded["ui.ui_builder"] = nil
		require("ui.ui_builder").force_focus(view, true, {
			is_current = function() return records.current end,
		})
		scenario(records)
	end, debug.traceback)
	_G.hs = prior_hs
	for key in pairs(package.loaded) do if loaded[key] == nil then package.loaded[key] = nil end end
	for key, value in pairs(loaded) do package.loaded[key] = value end
	if not ok then error(err, 0) end
end

for _, boundary in ipairs({ "window", "screen" }) do
	helpers.it("focus-native-reentrancy stops after owner retirement at " .. boundary, function()
		with_focus(boundary, function(records)
			helpers.assert_eq(records.moves, 0, "Retired owner must not move a native window")
			helpers.assert_eq(records.raises, 0)
			helpers.assert_eq(records.focuses, 0)
			helpers.assert_eq(records.app_focuses, 0)
		end)
	end)
end

helpers.it("focus-native-reentrancy preserves current owner focus", function()
	with_focus("none", function(records)
		helpers.assert_eq(records.moves, 1)
		helpers.assert_eq(records.raises, 1)
		helpers.assert_eq(records.focuses, 1)
		helpers.assert_eq(records.app_focuses, 1)
	end)
end)
