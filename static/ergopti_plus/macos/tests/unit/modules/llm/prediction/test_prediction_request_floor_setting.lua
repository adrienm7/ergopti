--- tests/unit/modules/llm/prediction/test_prediction_request_floor_setting.lua

--- ==============================================================================
--- MODULE: The Request Floor Is The User's Setting
--- DESCRIPTION:
--- An automatic prediction request waits for the minimum time between two
--- requests the user set in the AI trigger menu (llm.trigger.min_request_interval_ms),
--- one value for every backend; a request the user triggers himself is never
--- held. Drives the real engine through the shared prediction pipeline fixture.
---
--- ROOT CAUSE ENCODED:
--- The floor was a fixed per-backend table in inference.json (300 ms local,
--- 500 ms API) that no menu showed, so the user could neither lengthen it to
--- spare a metered API nor remove it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Pipeline = require("tests.support.prediction_pipeline")

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

helpers.describe("request floor: the interval the user set (request-floor-setting)", function()
	helpers.it("refuses what is not a finite non-negative number of seconds and keeps the value", function()
		local fixture = Pipeline.load({})
		helpers.assert_eq(fixture.engine.set_llm_min_request_interval(1.5), true)
		for _, bad in ipairs({ -1, "x", 0 / 0, math.huge }) do
			helpers.assert_eq(fixture.engine.set_llm_min_request_interval(bad), false)
		end
		local found, value = fixture.engine.get_llm_runtime_setting("llm_min_request_interval")
		helpers.assert_eq(found, true)
		helpers.assert_eq(value, 1.5)
		helpers.assert_eq(fixture.engine.set_llm_min_request_interval("0.25"), true, "a stored string is coerced")
		helpers.assert_eq(select(2, fixture.engine.get_llm_runtime_setting("llm_min_request_interval")), 0.25)
	end)

	helpers.it("holds an automatic request for the whole configured interval, not a backend's fixed one", function()
		local fixture = Pipeline.load({})
		helpers.assert_eq(fixture.engine.set_llm_min_request_interval(2), true)
		fixture.engine.perform_check(true)
		helpers.assert_eq(fixture.fetches, 1, "the first request leaves at once")
		local timers = native_timers()
		local before = #timers
		fixture.state.buffer = "hello world, again"
		fixture.engine.perform_check(false)
		helpers.assert_eq(fixture.fetches, 1, "the next automatic request is inside the interval")
		helpers.assert_true(#timers > before, "it is re-armed for the remainder")
		helpers.assert_true(timers[#timers].delay > 0.5 and timers[#timers].delay <= 2,
			"the remainder comes from the 2 s the user set, not a 300 or 500 ms table")
	end)

	helpers.it("never holds a request the user triggered, whatever the interval", function()
		local fixture = Pipeline.load({})
		helpers.assert_eq(fixture.engine.set_llm_min_request_interval(10), true)
		fixture.engine.perform_check(true)
		fixture.engine.perform_check(true)
		helpers.assert_eq(fixture.fetches, 2, "the second explicit request is not delayed")
	end)

	helpers.it("sends an automatic request at once when the user set no interval", function()
		local fixture = Pipeline.load({})
		helpers.assert_eq(fixture.engine.set_llm_min_request_interval(0), true)
		fixture.engine.perform_check(true)
		fixture.state.buffer = "hello world, again"
		fixture.engine.perform_check(false)
		helpers.assert_eq(fixture.fetches, 2)
	end)
end)
