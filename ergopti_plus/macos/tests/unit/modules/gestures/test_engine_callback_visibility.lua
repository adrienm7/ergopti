--- tests/unit/modules/gestures/test_engine_callback_visibility.lua

--- ==============================================================================
--- MODULE: Gesture Engine Callback Visibility Regression Tests
--- DESCRIPTION:
--- Proves that externally supplied touch hooks and guarded gesture commits remain
--- exception-contained while their failures reach the central, deduplicating log.
--- A failed commit must still reset the gesture transaction before the next input.
--- ==============================================================================

local helpers = require("tests.helpers")

local Logger = helpers.load_with_stubs("infra.logger")

local current_time = 0

local function touch(x, y)
	return { absoluteVector = { position = { x = x, y = y } } }
end

local function state_with(gesture_actions)
	return {
		enabled = true,
		ga = gesture_actions or {},
		modes = {},
		sensitivities = {},
	}
end

local function recording_actions()
	local calls = 0
	return {
		module = {
			execute_single = function()
				calls = calls + 1
				return true
			end,
			execute_axis = function() return false end,
			set_gesture_in_progress = function() end,
		},
		calls = function() return calls end,
	}
end

local function fresh_engine()
	package.loaded["infra.logger"] = Logger
	package.loaded["modules.gestures.engine"] = nil
	local engine = helpers.load_with_stubs("modules.gestures.engine")
	_G.hs.timer.secondsSinceEpoch = function() return current_time end
	return engine
end

local function matching_errors(needle_a, needle_b)
	local count = 0
	for _, line in ipairs(Logger.ring_buffer_snapshot()) do
		if line:find("[ERROR]", 1, true)
			and line:find(needle_a, 1, true)
			and line:find(needle_b, 1, true) then
			count = count + 1
		end
	end
	return count
end

local function reset_logger()
	Logger.set_level("WARNING")
	Logger.ring_buffer_clear()
	Logger.reset_dedup()
end

helpers.describe("gestures.engine: callback failure visibility", function()
	helpers.it("logs and centrally throttles repeated any-touch hook failures", function()
		reset_logger()
		local engine = fresh_engine()
		local actions = recording_actions()
		engine.init(state_with(), actions.module)

		local hook_calls = 0
		engine.set_any_touch_hook(function()
			hook_calls = hook_calls + 1
			error("touch hook exploded")
		end)

		for frame = 1, 3 do
			current_time = frame / 100
			engine.process_frame({ touch(100, 100), touch(110, 100) })
		end

		helpers.assert_eq(hook_calls, 3,
			"throttling diagnostics must not disable the live touch hook")
		helpers.assert_eq(matching_errors("Gesture any-touch hook", "touch hook exploded"), 1,
			"the first callback failure must be searchable without a per-frame log storm")
		helpers.assert_eq(Logger.dedup_suppressed_count(), 2,
			"the central logger must suppress identical frame-frequency failures")

		engine.set_any_touch_hook(nil)
		reset_logger()
	end)

	helpers.it("logs a failed commit and resets state before the next gesture", function()
		reset_logger()
		local engine = fresh_engine()
		local actions = recording_actions()
		local state = state_with(setmetatable({}, {
			__index = function() error("commit state exploded") end,
		}))
		engine.init(state, actions.module)

		current_time = 0
		engine.process_frame({ touch(100, 100), touch(110, 100) })
		current_time = 0.1
		engine.process_frame({})

		helpers.assert_eq(matching_errors("Gesture commit", "commit state exploded"), 1,
			"a contained commit failure must reach the central logger with context")

		state.ga = { tap_2 = "mission_control" }
		current_time = 1
		engine.process_frame({ touch(100, 100), touch(110, 100) })
		current_time = 1.1
		engine.process_frame({})
		helpers.assert_eq(actions.calls(), 1,
			"the failed gesture must be reset so the next gesture starts cleanly")

		reset_logger()
	end)
end)
