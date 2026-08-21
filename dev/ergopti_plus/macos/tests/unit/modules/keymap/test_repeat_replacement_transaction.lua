--- tests/unit/modules/keymap/test_repeat_replacement_transaction.lua

--- ==============================================================================
--- REGRESSION: repeat-key must use the common replacement transaction (HS-005)
--- ==============================================================================

local helpers = require("tests.helpers")
local SyntheticStack = require("tests.support.synthetic_input_stack")

local function make_state(buffer)
	local state = {
		buffer = buffer,
		magic_key = "★",
	}
	function state.is_repeat_feature_enabled() return true end
	function state.suppress_rescan(_) end
	return state
end

local function make_registry()
	return {
		is_terminator = function() return false end,
		terminator_is_consumed = function() return false end,
	}
end

local function make_llm()
	local bridge = { previews = {}, timer_starts = 0 }
	function bridge.update_preview(buffer)
		bridge.previews[#bridge.previews + 1] = buffer
	end
	function bridge.is_runtime_available() return true end
	function bridge.get_llm_enabled() return false end
	function bridge.start_timer() bridge.timer_starts = bridge.timer_starts + 1 end
	return bridge
end

local function load_subject(keylogger)
	package.loaded["modules.keylogger"] = keylogger
	local subject, synthetic = SyntheticStack.load("modules.keymap.expander")
	return subject, synthetic
end

local function cleanup()
	package.loaded["modules.keylogger"] = nil
	package.loaded["modules.keymap.expander"] = nil
end

helpers.describe("repeat replacement transaction", function()
	helpers.it("repeat replacement transaction publishes telemetry, keylogger buffer, and preview", function()
		local notifications = {}
		local buffers = {}
		local keylogger = {
			notify_synthetic = function(...)
				notifications[#notifications + 1] = { ... }
			end,
			set_buffer = function(buffer)
				buffers[#buffers + 1] = buffer
			end,
		}
		local Expander, SyntheticInput = load_subject(keylogger)
		local state = make_state("ab★")
		local llm = make_llm()
		Expander.init(state, make_registry(), llm)

		SyntheticInput.enter_callback()
		local fired = Expander.try_repeat_feature("★", false)
		local consume, events = SyntheticInput.leave_callback(fired)
		if hs.timer and hs.timer.__fire_all then
			hs.timer.__fire_all()
			hs.timer.__fire_all()
		end

		cleanup()
		helpers.assert_true(fired)
		helpers.assert_true(consume)
		helpers.assert_eq(#events, 2, "one repeated codepoint must produce one key pair")
		helpers.assert_eq(state.buffer, "abb")
		helpers.assert_eq(#notifications, 1)
		helpers.assert_eq(notifications[1][1], "b")
		helpers.assert_eq(notifications[1][2], "hotstring")
		helpers.assert_eq(notifications[1][3], 0)
		helpers.assert_eq(notifications[1][4], "repeat_key")
		helpers.assert_eq(#buffers, 1)
		helpers.assert_eq(buffers[1], "abb")
		helpers.assert_eq(#llm.previews, 1,
			"transaction completion must refresh the now-fireable buffer")
		helpers.assert_eq(llm.previews[1], "abb")
	end)

	helpers.it("repeat replacement transaction refuses output without ghost telemetry", function()
		local notify_count = 0
		local set_buffer_count = 0
		local keylogger = {
			notify_synthetic = function() notify_count = notify_count + 1 end,
			set_buffer = function() set_buffer_count = set_buffer_count + 1 end,
		}
		local Expander, SyntheticInput = load_subject(keylogger)
		local state = make_state("ab★")
		local llm = make_llm()
		Expander.init(state, make_registry(), llm)

		local original_emit = SyntheticInput.emit_key_strokes
		SyntheticInput.emit_key_strokes = function() return false end
		SyntheticInput.enter_callback()
		local fired = Expander.try_repeat_feature("★", false)
		local consume, events = SyntheticInput.leave_callback(fired)
		SyntheticInput.emit_key_strokes = original_emit
		if hs.timer and hs.timer.__fire_all then hs.timer.__fire_all() end

		cleanup()
		helpers.assert_eq(fired, false)
		helpers.assert_eq(consume, false)
		helpers.assert_eq(events and #events or 0, 0,
			"a refused transaction must publish no prefix")
		helpers.assert_eq(state.buffer, "ab★")
		helpers.assert_eq(notify_count, 0,
			"telemetry must follow successful output construction")
		helpers.assert_eq(set_buffer_count, 0)
		helpers.assert_eq(#llm.previews, 0)
	end)
end)
