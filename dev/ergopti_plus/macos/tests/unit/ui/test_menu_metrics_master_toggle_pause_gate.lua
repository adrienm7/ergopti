--- tests/unit/ui/test_menu_metrics_master_toggle_pause_gate.lua

--- ==============================================================================
--- MODULE: Regression — metrics master toggle honours pause on re-enable (F-LOW-13)
--- DESCRIPTION:
--- test_menu_metrics_wpm_pause_gate (F-MED-6) and
--- test_menu_metrics_wpm_toggle_pause_gate (F-L10) already gate two other call
--- sites on pause: the re-sync done at every build() (« pause = tout éteint »),
--- and the five INTERACTIVE per-feature toggle handlers (dyn_wpm_menubar,
--- dyn_menubar_colors, dyn_wpm_widget, dyn_widget_colors, dyn_include_realtime).
---
--- The metrics MASTER toggle (the top-level "Metrics & Keylogger" checkbox
--- item's own fn, at the bottom of M.build) was the one remaining call site:
--- re-enabling it called WpmMenubar.start() / WpmWidget.start() unconditionally
--- whenever the corresponding keylogger_menubar_wpm / keylogger_float_wpm flags
--- were set, with no `paused_now()` check. Re-enabling Metrics while paused
--- therefore armed the widget's 0.2s render timer + global mouse eventtap and
--- the menubar's 0.5s timer even though everything else stays quiescent under
--- pause.
---
--- Fix: gate both master-toggle start() calls on `not paused_now()`, mirroring
--- the five sibling interactive handlers.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src()
	-- Selected by a declaration unique to ui/menu/menu_metrics.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local src = helpers.read_driver_source("\"dialog.metrics.security_warning_title\"")
	helpers.assert_true(src ~= nil, "ui/menu/menu_metrics.lua source must be locatable")
	return src
end

helpers.describe("menu_metrics: master toggle gates WPM start() on pause (F-LOW-13)", function()
	helpers.it("no longer starts WpmMenubar unconditionally on re-enable", function()
		local src = read_src()
		-- The exact ungated pattern the bug had: the feature flag alone gating
		-- WpmMenubar.start(), with nothing between the flag and the pcall call
		-- checking pause. Mirrors the assertion style of the sibling F-L10 test
		-- (test_menu_metrics_wpm_toggle_pause_gate.lua) for the interactive handlers.
		helpers.assert_true(
			src:find("state.keylogger_menubar_wpm and WpmMenubar and type(WpmMenubar.start)", 1, true) == nil,
			"the master toggle must not start WpmMenubar without a pause check between the flag and the call")
	end)

	helpers.it("no longer starts WpmWidget unconditionally on re-enable", function()
		local src = read_src()
		helpers.assert_true(
			src:find("state.keylogger_float_wpm and WpmWidget and type(WpmWidget.start)", 1, true) == nil,
			"the master toggle must not start WpmWidget without a pause check between the flag and the call")
	end)

	helpers.it("gates the master-toggle WpmMenubar.start() on not paused_now()", function()
		local src = read_src()
		helpers.assert_true(
			src:find("if state.keylogger_menubar_wpm and not paused_now() then", 1, true) ~= nil
				and src:find('call_wpm_lifecycle("WPM menubar", WpmMenubar, "start")', 1, true) ~= nil,
			"the master toggle must gate WpmMenubar.start() on `not paused_now()`, mirroring dyn_wpm_menubar")
	end)

	helpers.it("gates the master-toggle WpmWidget.start() on not paused_now()", function()
		local src = read_src()
		helpers.assert_true(
			src:find("if state.keylogger_float_wpm and not paused_now() then", 1, true) ~= nil
				and src:find('call_wpm_lifecycle("WPM widget", WpmWidget, "start",', 1, true) ~= nil,
			"the master toggle must gate WpmWidget.start() on `not paused_now()`, mirroring dyn_wpm_widget")
	end)
end)
