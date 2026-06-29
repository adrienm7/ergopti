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

local function read(rel)
	local fh = assert(io.open(helpers.driver_root() .. rel, "r"))
	local s = fh:read("*a"); fh:close()
	return s
end

helpers.describe("dead audit code is removed", function()
	helpers.it("F-I2: peakNFrames is gone from the gestures engine", function()
		helpers.assert_true(read("modules/gestures/engine.lua"):find("peakNFrames", 1, true) == nil,
			"the write-only peakNFrames counter must be removed (live gate is time-based)")
	end)

	helpers.it("F-I4: tooltip set_model_info dead entry is removed", function()
		helpers.assert_true(read("ui/tooltip/tooltip_llm.lua"):find("function M.set_model_info", 1, true) == nil,
			"the never-wired set_model_info must be removed")
		helpers.assert_true(read("adapters/tooltip_renderer.lua"):find("model_info", 1, true) == nil,
			"the dead model_info draw-call mapping must be removed")
	end)
end)
