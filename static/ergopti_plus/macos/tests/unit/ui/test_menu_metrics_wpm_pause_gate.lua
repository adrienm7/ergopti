--- tests/unit/ui/test_menu_metrics_wpm_pause_gate.lua

--- ==============================================================================
--- MODULE: Regression — WPM widget/menubar quiesce under pause (F-MED-6)
--- DESCRIPTION:
--- script_control.pause_all() tears down keymap/LLM/tooltip/gestures/karabiner but
--- never the WPM floating widget or menubar. Their hs.timer (0.2 s / 0.5 s) and the
--- widget's mouse eventtap kept firing under pause, polling keylogger.get_live_stats()
--- and re-rendering the canvas — a « pause = tout éteint » violation plus idle CPU.
---
--- menu_metrics.build() re-syncs widget visibility on every build, and the
--- pause-change listener (ui/menu/init.lua) calls updateMenu() -> build(). So the
--- fix gates the widget START on `not paused` there: a build during pause stops
--- both UIs, a build on resume restarts them per the persisted flags. Pinned at
--- source (build needs the full metrics ctx to drive).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu_metrics: WPM widget/menubar are pause-gated in build (F-MED-6)", function()
	local function read_src()
		local path = helpers.driver_root() .. "ui/menu/menu_metrics.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "cannot open menu_metrics.lua at " .. tostring(path))
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("derives a paused flag from script_control in build", function()
		local src = read_src()
		helpers.assert_true(src:find("script_control.is_paused()", 1, true) ~= nil,
			"build must read the live pause state via script_control.is_paused()")
	end)

	helpers.it("gates the menubar + widget START on `not paused`", function()
		local src = read_src()
		helpers.assert_true(src:find("state.keylogger_menubar_wpm and not paused", 1, true) ~= nil,
			"the menubar WPM start must be gated on `not paused`")
		helpers.assert_true(src:find("state.keylogger_float_wpm and not paused", 1, true) ~= nil,
			"the floating WPM widget start must be gated on `not paused`")
	end)
end)
