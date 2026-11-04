--- tests/unit/modules/llm/prediction/test_prediction_debounce_is_configured.lua

--- ==============================================================================
--- MODULE: The Prediction Debounce Is The Configured One
--- DESCRIPTION:
--- The automatic trigger waits the debounce the menu shows, whatever the typing
--- speed, as the Windows and Linux engines do. Drives the real engine through
--- the shared prediction pipeline fixture and reads the delay of the native
--- timer it arms.
---
--- ROOT CAUSE ENCODED:
--- macOS alone scaled the debounce with the live WPM: 1.5x (at most 600 ms)
--- above 55 WPM and 0.5x (at least 50 ms) below 20 WPM. A user who set 500 ms
--- waited 600 ms while typing fast and 250 ms while typing slowly, and no menu
--- reason stated the difference.
--- ==============================================================================

local helpers = require("tests.helpers")
local Pipeline = require("tests.support.prediction_pipeline")

local CONFIGURED_SEC = 0.5

--- Returns the native timer list of the stub the scheduler captured.
--- @return table timers
local function native_timers()
	local scheduler_after = require("adapters.timer_scheduler").after
	for index = 1, 60 do
		local name, value = debug.getupvalue(scheduler_after, index)
		if not name then break end
		if name == "hs" then return value.timer.__timers end
	end
	error("the timer scheduler's native stub must be reachable")
end

--- Arms the automatic trigger at a typing speed and returns the armed delay.
--- @param wpm number The live physical WPM the keystats report.
--- @return number delay Seconds.
local function armed_delay_at(wpm)
	local fixture = Pipeline.load({})
	package.loaded["modules.keystats"].get_live_stats = function() return { wpm_physical = wpm } end
	helpers.assert_eq(fixture.engine.set_llm_debounce(CONFIGURED_SEC), true)
	local timers = native_timers()
	local before = #timers
	helpers.assert_eq(fixture.engine.start_timer(), true, "the automatic trigger arms")
	helpers.assert_true(#timers > before, "a native timer was armed")
	local delay = timers[#timers].delay
	helpers.assert_eq(fixture.engine.stop_timer(), true)
	return delay
end

helpers.describe("prediction debounce: the configured one at every typing speed", function()
	helpers.it("waits the configured debounce while typing fast", function()
		helpers.assert_eq(armed_delay_at(80), CONFIGURED_SEC, "no 1.5x stretch above 55 WPM")
	end)

	helpers.it("waits the configured debounce while typing slowly", function()
		helpers.assert_eq(armed_delay_at(10), CONFIGURED_SEC, "no 0.5x shrink below 20 WPM")
	end)

	helpers.it("waits the configured debounce when idle", function()
		helpers.assert_eq(armed_delay_at(0), CONFIGURED_SEC)
	end)
end)
