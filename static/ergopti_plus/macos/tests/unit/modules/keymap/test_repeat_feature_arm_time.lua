--- tests/unit/modules/keymap/test_repeat_feature_arm_time.lua

--- ==============================================================================
--- MODULE: Repeat Feature Synthetic Transaction Regression Tests
--- DESCRIPTION:
--- Exercises try_repeat_feature through the production expander, TextSender, and
--- SyntheticInput adapter. Deleting the magic key and emitting the repeated
--- character must form one tagged replacement transaction, and consecutive
--- repeats must receive distinct immutable generations even in the same tick.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Loads a fresh expander wired to the real synthetic-input adapter.
--- @return table fixture
local function load_fixture()
	package.loaded["modules.keylogger"] = {
		notify_synthetic = function() end,
	}
	package.loaded["modules.keymap.expander"] = nil
	package.loaded["modules.keymap.terminator_replay"] = nil

	local expander = helpers.load_with_stubs("modules.keymap.expander")
	local synthetic = require("adapters.synthetic_input")
	local state = {
		buffer = "ab★",
		magic_key = "★",
		is_repeat_feature_enabled = function() return true end,
		suppress_rescan = function() end,
	}
	expander.init(state, {}, {
		get_llm_enabled = function() return false end,
		is_runtime_available = function() return true end,
		start_timer = function() end,
	})
	return {
		expander = expander,
		synthetic = synthetic,
		state = state,
		hs = require("hs"),
		cleanup = function()
			package.loaded["modules.keylogger"] = nil
			package.loaded["modules.keymap.expander"] = nil
			package.loaded["modules.keymap.terminator_replay"] = nil
		end,
	}
end


--- Fires one ignored-window repeat inside a real callback collector.
--- @param fixture table
--- @return table events
local function fire_repeat(fixture)
	fixture.synthetic.enter_callback()
	local fired = fixture.expander.try_repeat_feature("★", true)
	local consume, events = fixture.synthetic.leave_callback(fired)
	helpers.assert_true(fired, "the repeat feature must fire for ab★")
	helpers.assert_true(consume)
	helpers.assert_not_nil(events)
	return events
end


helpers.describe("keymap expander: repeat uses an explicit replacement transaction", function()
	helpers.it("tags the delete and repeated character with one generation", function()
		local fixture = load_fixture()
		local events = fire_repeat(fixture)
		helpers.assert_eq(#events, 4,
			"ignored-window repeat must return Backspace down/up and text down/up")
		helpers.assert_eq(fixture.state.buffer, "abb")

		local property = fixture.hs.eventtap.event.properties.eventSourceUserData
		local first = fixture.synthetic.lookup_tag(events[1]:getProperty(property))
		local last = fixture.synthetic.lookup_tag(events[4]:getProperty(property))
		helpers.assert_true(first and first.owned and last and last.owned)
		helpers.assert_eq(first.owner, "repeat_key")
		helpers.assert_eq(first.effect, "replacement")
		helpers.assert_eq(first.generation, last.generation,
			"delete and insertion must be indivisible members of one replacement")
		helpers.assert_eq(first.ordinal, 1)
		helpers.assert_eq(last.ordinal, 2)
		fixture.cleanup()
	end)

	helpers.it("allocates a new generation for an immediate consecutive repeat", function()
		local fixture = load_fixture()
		local first_events = fire_repeat(fixture)
		fixture.state.buffer = fixture.state.buffer .. "★"
		local second_events = fire_repeat(fixture)

		local property = fixture.hs.eventtap.event.properties.eventSourceUserData
		local first = fixture.synthetic.lookup_tag(first_events[1]:getProperty(property))
		local second = fixture.synthetic.lookup_tag(second_events[1]:getProperty(property))
		helpers.assert_true(first and second)
		helpers.assert_true(first.generation ~= second.generation,
			"transaction identity must not collapse two producers that run in the same tick")
		helpers.assert_eq(fixture.state.buffer, "abbb")
		fixture.cleanup()
	end)
end)
