--- tests/unit/platform/remap/lifecycle/test_karabiner_batch_fixes.lua

--- ==============================================================================
--- MODULE: Regression — a per-layout-change rebuild
--- DESCRIPTION:
--- load_available_actions re-read and re-decoded the shared modifier-chord
--- catalogue on every layout change, rebuilding the same 673 action tables and
--- writing one DEBUG line per resolved action — 548 log writes at the driver's
--- default level, for a fact the total already conveys.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("karabiner: the shared chord catalogue is decoded once", function()

	helpers.it("caches the decoded catalogue across calls", function()
		local src = helpers.read_driver_source("append_shared_modifier_chords")
		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("_chord_catalogue", 1, true) ~= nil,
			"this runs on every layout change and the catalogue is a file that does not "
			.. "change while the driver runs")
	end)

	helpers.it("does not log one line per resolved action", function()
		local src = helpers.read_driver_source("logical-char action")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the config source must be readable or this asserts nothing")
		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("Action '%%s': logical") == nil,
			"DEBUG is this driver's default level and this loop re-runs on every layout "
			.. "change, so a per-action line is hundreds of writes for what the total says")
	end)

end)
