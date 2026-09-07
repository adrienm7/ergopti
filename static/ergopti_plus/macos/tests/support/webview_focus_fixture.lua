--- tests/support/webview_focus_fixture.lua

--- ==============================================================================
--- MODULE: Deferred WebView Focus Fixture
--- DESCRIPTION:
--- Runs the real focus scheduler against a native view invalidated by its owner.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}

--- Verifies that retirement revokes an already-scheduled native focus retry.
--- @param view table Exact native window double.
--- @param activate function Public open or reuse request.
--- @param retire function Public close or native closing callback.
--- @param factory_lifecycle table|nil Exact options passed to the native factory.
function M.check(view, activate, retire, factory_lifecycle)
	local builder = package.loaded["ui.ui_builder"]
	local previous_deferred = package.loaded["infra.deferred_work"]
	local previous_focus, previous_hs_focus = builder.force_focus, hs.focus
	local previous_window, previous_front = view.hswindow, view.bringToFront
	local pending, invalid, reads, focuses = {}, false, 0, 0
	local ok, err = xpcall(function()
		package.loaded["infra.deferred_work"] = { after = function(_, callback, label)
			if label == "webview focus retry" then pending[#pending + 1] = callback end
			return true
		end }
		builder.force_focus = assert(loadfile(helpers.driver_root() .. "ui/ui_builder.lua"))().force_focus
		view.hswindow = function()
			if invalid then reads = reads + 1; error("native window deleted") end
			return nil
		end
		view.bringToFront = function()
			if invalid then reads = reads + 1; error("native window deleted") end
			return view
		end
		hs.focus = function() focuses = focuses + 1 end
		helpers.assert_true(activate() ~= false)
		helpers.assert_eq(#pending, 1, "the actual focus scheduler must own a pending retry")
		if factory_lifecycle then
			helpers.assert_type(factory_lifecycle.is_current, "function")
			helpers.assert_true(builder.force_focus(view, true, factory_lifecycle))
			helpers.assert_eq(#pending, 2, "factory focus must also own a pending retry")
		end
		retire()
		invalid = true
		local steps = 0
		while #pending > 0 and steps < 30 do
			steps = steps + 1
			table.remove(pending, 1)()
		end
		helpers.assert_eq(reads, 0, "retired focus must not touch the invalid native window")
		helpers.assert_eq(focuses, 0, "retired focus must not foreground Hammerspoon")
		helpers.assert_eq(#pending, 0)
	end, debug.traceback)
	package.loaded["infra.deferred_work"] = previous_deferred
	builder.force_focus, hs.focus = previous_focus, previous_hs_focus
	view.hswindow, view.bringToFront = previous_window, previous_front
	if not ok then error(err, 0) end
end

return M
