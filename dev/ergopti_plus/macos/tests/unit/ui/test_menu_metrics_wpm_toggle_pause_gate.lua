--- tests/unit/ui/test_menu_metrics_wpm_toggle_pause_gate.lua

--- ==============================================================================
--- MODULE: Regression — WPM toggle handlers honour pause (F-L10)
--- DESCRIPTION:
--- Audit finding F-L10. The build path gates WPM start/stop on script_control
--- is_paused (test_menu_metrics_wpm_pause_gate covers it), but the five INTERACTIVE
--- toggle handlers (dyn_wpm_menubar/_colors, dyn_wpm_widget/_colors, dyn_include_realtime)
--- called WpmWidget.start()/WpmMenubar.start() with NO pause check, arming the 0.2s
--- render timer + global mouse eventtap while paused. Fix: gate every interactive
--- start on a live paused_now() re-derived at click time. The handlers are deep
--- closures inside build(); the gate is pinned at source.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu_metrics WPM toggle handlers gate start() on pause", function()
	local function read_src()
		local fh = assert(io.open(helpers.driver_root() .. "ui/menu/menu_metrics.lua", "r"))
		local s = fh:read("*a"); fh:close()
		return s
	end

	helpers.it("provides a live paused_now() helper for the click-time handlers", function()
		helpers.assert_true(read_src():find("local function paused_now()", 1, true) ~= nil,
			"build() must expose a live paused_now() re-derived at click time")
	end)

	helpers.it("no interactive WPM start() is left ungated by pause", function()
		local src = read_src()
		-- The ungated patterns the bug had must be gone: a WPM start gated only on the
		-- feature flag with no `and not paused`/`and not paused_now()`.
		helpers.assert_true(src:find("keylogger_float_wpm then WpmWidget.start", 1, true) == nil,
			"a WPM widget start is not pause-gated")
		helpers.assert_true(src:find("keylogger_menubar_wpm then WpmMenubar.start", 1, true) == nil,
			"a WPM menubar start is not pause-gated")
		-- And the gated form must be present for the interactive handlers.
		helpers.assert_true(src:find("not paused_now() then WpmWidget.start", 1, true) ~= nil,
			"interactive widget handlers must gate start on paused_now()")
		helpers.assert_true(src:find("not paused_now() then WpmMenubar.start", 1, true) ~= nil,
			"interactive menubar handlers must gate start on paused_now()")
	end)
end)
