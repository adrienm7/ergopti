--- tests/unit/ui/test_wpm_widget_bad_pos.lua

--- ==============================================================================
--- MODULE: Regression — WPM widget persisted position is type-coerced (F-LOW-5)
--- DESCRIPTION:
--- The floating WPM widget reads its saved position from hs.settings at module
--- load. A corrupt / hand-edited plist can return a STRING (e.g. "100") there. The
--- only downstream guard is `if not _pos_x`, which a non-empty string passes, so
--- the string reaches `_pos_x + compact_w - canvas_width` (string+number arithmetic
--- → raises) and hs.canvas geometry. The error fires in the timer/layout callback
--- and is swallowed to the HS Console, so the widget silently never appears.
---
--- Fix: coerce with tonumber at the read — a non-numeric value becomes nil, so the
--- existing default-recompute (`if not _pos_x`) correctly fires.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("wpm_widget: persisted position coerced with tonumber (F-LOW-5)", function()
	helpers.it("reads pos_x and pos_y through tonumber", function()
		-- Selected by a declaration unique to ui/wpm/wpm_widget.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function resolve_shared_constants_path")
		helpers.assert_true(src ~= nil, "ui/wpm/wpm_widget.lua source must be locatable")

		helpers.assert_true(src:find("tonumber(Storage.get(_SETTINGS_X))", 1, true) ~= nil,
			"pos_x must be read via tonumber(Storage.get(_SETTINGS_X)) so a string plist value defaults")
		helpers.assert_true(src:find("tonumber(Storage.get(_SETTINGS_Y))", 1, true) ~= nil,
			"pos_y must be read via tonumber(Storage.get(_SETTINGS_Y))")
		-- The old raw read must be gone (it let a string flow into arithmetic/canvas).
		helpers.assert_true(src:find("local _pos_x      = hs.settings.get(_SETTINGS_X)", 1, true) == nil,
			"the raw (un-coerced) pos_x read must be replaced")
	end)
end)
