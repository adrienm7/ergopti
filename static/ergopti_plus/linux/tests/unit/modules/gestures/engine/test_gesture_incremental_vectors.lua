--- tests/unit/modules/gestures/engine/test_gesture_incremental_vectors.lua

--- ==============================================================================
--- MODULE: Incremental Step Vectors (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/gestures/incremental_steps.json, which the
--- macOS and Windows suites replay too, through _shared/lua/gestures/incremental,
--- the step rule modules/gestures/incremental_tracker.lua counts with.
---
--- ROOT CAUSE ENCODED:
--- The step rule was pinned only by macOS literals, so a third driver porting
--- it had no shared vectors to prove the port against.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

require("test.incremental_steps_contract")(helpers, json, helpers.driver_root() .. "/../_shared")

helpers.describe("incremental swipes: the Linux reversal floor", function()
	helpers.it("is the corpus floor (incremental-step-vectors)", function()
		local file = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/gestures/incremental_steps.json", "rb"))
		local corpus = json.decode(file:read("*a"))
		file:close()
		local Tracker = helpers.load_module("modules.gestures.incremental_tracker")
		helpers.assert_eq(Tracker.REVERSE_FLOOR_MM, corpus.reverse_floor_mm)
	end)
end)
