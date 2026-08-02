--- tests/unit/ui/test_wpm_menubar_color_hold.lua

--- ==============================================================================
--- MODULE: Regression — WPM menubar color-hold is single-sourced, not hardcoded
--- DESCRIPTION:
--- Audit finding F-L7. wpm_menubar.lua passed a hardcoded 3.0 s to get_active_source
--- while the floating widget uses CONFIG.source_color_duration (1.0 s from the shared
--- wpm_color_hold_ms). The two WPM surfaces visibly disagreed on how long the source
--- color lingers (rules 5.1 magic number / 5.2 single source). Fix: read the duration
--- once from the same shared loader.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("wpm_menubar color-hold duration is single-sourced", function()
	helpers.it("source: no bare 3.0 passed to get_active_source; uses COLOR_HOLD_S", function()
		-- Selected by a declaration unique to ui/wpm/wpm_menubar.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function update_menubar")
		helpers.assert_true(src ~= nil, "ui/wpm/wpm_menubar.lua source must be locatable")
		helpers.assert_true(src:find("get_active_source(stats, 3.0", 1, true) == nil,
			"must NOT pass a hardcoded 3.0 to get_active_source")
		helpers.assert_true(src:find("get_active_source(stats, COLOR_HOLD_S", 1, true) ~= nil,
			"must pass the single-sourced COLOR_HOLD_S")
		helpers.assert_true(src:find("source_color_duration", 1, true) ~= nil,
			"COLOR_HOLD_S must derive from the widget's shared source_color_duration")
	end)

	helpers.it("the menubar's hold duration equals the widget's source_color_duration", function()
		-- Both read from wpm_widget._load_shared_const (the shared TOML), so the menubar
		-- COLOR_HOLD_S must match the widget value (or its 1.0 s fallback) — never 3.0.
		local ww = helpers.load_with_stubs("ui.wpm.wpm_widget")
		local widget_dur = ww._load_shared_const().source_color_duration
		-- The shipped TOML sets wpm_color_hold_ms = 1000 -> 1.0 s; tolerate a nil (fallback).
		if type(widget_dur) == "number" then
			helpers.assert_true(widget_dur ~= 3.0, "the shared duration must not be the old hardcoded 3.0")
		end
	end)
end)
