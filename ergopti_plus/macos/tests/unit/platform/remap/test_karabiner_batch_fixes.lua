--- tests/unit/platform/remap/test_karabiner_batch_fixes.lua

--- ==============================================================================
--- MODULE: Regressions — a racing probe and a per-layout-change rebuild
--- DESCRIPTION:
--- 1. The CapsWord probe had no generation guard. A terminated or timed-out
---    probe's callback still fires, and it cleared _capsword_check_pending and
---    cancelled the watchdog unconditionally — by then the SUCCESSOR probe's. The
---    sibling layout read in the same module was generation-gated for exactly
---    this reason; this one was not, so a slow probe unlocked a fresh one and
---    left two racing.
--- 2. load_available_actions re-read and re-decoded the shared modifier-chord
---    catalogue on every layout change, rebuilding the same 673 action tables and
---    writing one DEBUG line per resolved action — 548 log writes at the driver's
---    default level, for a fact the total already conveys.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("karabiner: a superseded CapsWord probe releases nothing", function()

	helpers.it("the probe callback checks its own generation first", function()
		local src = helpers.read_driver_source("_capsword_check_pending")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the watchers source must be readable or this asserts nothing")
		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("_capsword_gen", 1, true) ~= nil,
			"a terminated probe's late callback must not clear the flag or cancel the "
			.. "watchdog belonging to the probe that replaced it")

		-- The guard must precede the release, not merely coexist with it.
		local guard   = code:find("my_capsword_gen ~= _capsword_gen")
		local release = code:find("_capsword_check_pending = false", guard or 1, true)
		helpers.assert_not_nil(guard, "the callback must compare generations")
		helpers.assert_true(release == nil or release > guard,
			"the generation check has to come before the state it protects is cleared")
	end)

end)

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
