--- tests/unit/meta/test_dead_code_removed.lua

--- ==============================================================================
--- MODULE: Regression — audit info-finding dead code is removed
--- DESCRIPTION:
--- F-I2: gs.peakNFrames was incremented in several places but never read (the live
---       peak-confirm gate is time-based via PEAK_FINGERS_CONFIRM_MS). Removed.
--- F-I4: tooltip M.set_model_info / the model_info draw-call mapping were never
---       wired into the facade or any caller (the model header is folded into the
---       info line, ELEM_INFO). Removed the dead public entry + adapter mapping so
---       the reserved canvas zone can never be filled frameless.
--- (F-I3 is covered behaviorally in test_clipboard_save_type_count.lua.)
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read(selector)
	local s = helpers.read_driver_source(selector)
	return s
end

helpers.describe("dead audit code is removed", function()
	helpers.it("F-I2: peakNFrames is gone from the gestures engine", function()
		helpers.assert_true(read("local function triggerLiveAxisIfNeeded"):find("peakNFrames", 1, true) == nil,
			"the write-only peakNFrames counter must be removed (live gate is time-based)")
	end)

	helpers.it("F-I4: tooltip set_model_info dead entry is removed", function()
		helpers.assert_true(read("local function refresh_chain_timing"):find("function M.set_model_info", 1, true) == nil,
			"the never-wired set_model_info must be removed")
		helpers.assert_true(read("local function _ensure_deps"):find("model_info", 1, true) == nil,
			"the dead model_info draw-call mapping must be removed")
	end)
end)
