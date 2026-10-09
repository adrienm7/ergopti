--- tests/unit/modules/keymap/test_escape_invalidates_hotstring_buffer.lua

--- ==============================================================================
--- REGRESSION: Escape dismissal invalidates the authoritative hotstring context
--- ==============================================================================

local helpers = require("tests.helpers")

local Fixture = require("tests.support.escape_context_fixture")

local function escape_event()
	return {
		getKeyCode = function() return 53 end,
		getProperty = function() return 0 end,
	}
end


helpers.describe("Escape invalidates hotstring context", function()
	helpers.it("Escape invalidates hotstring context in runtime and hotstring-only modes", function()
		for _, case in ipairs({
			{ visible = true, expected_resets = 1 },
			{ quarantined = true, hotstring_visible = true, expected_hides = 1 },
		}) do
			Fixture.with_fixture(case, function(Bridge, state, trap, deferred, get_resets, get_hides)
				local consumed = trap(escape_event())
				helpers.assert_eq(consumed, true)
				helpers.assert_eq(state.buffer, "",
					"a consumed Escape must synchronously revoke magic-key eligibility")
				helpers.assert_eq(state.start_is_word_boundary, false)
				helpers.assert_eq(#deferred, 1)
				deferred[1]()
				helpers.assert_eq(get_resets(), case.expected_resets or 0)
				helpers.assert_eq(get_hides(), case.expected_hides or 0)

				state.buffer = "agé"
				state.start_is_word_boundary = true
				helpers.assert_true(Bridge.check_escape_reset())
				helpers.assert_eq(state.buffer, "")
				helpers.assert_eq(state.start_is_word_boundary, false)
			end)
		end
	end)

	helpers.it("Escape invalidates hotstring context only after deferral commits", function()
		for _, refusal in ipairs({ "false", "throw" }) do
			Fixture.with_fixture({
				visible = true,
				defer_refuses = refusal == "false",
				defer_throws = refusal == "throw",
			}, function(Bridge, state, trap, deferred)
				local consumed = trap(escape_event())
				helpers.assert_eq(consumed, false,
					"Escape must pass through when deferred ownership is refused")
				helpers.assert_eq(state.buffer, "agé",
					"a pass-through Escape must retain the exact prior buffer")
				helpers.assert_eq(state.start_is_word_boundary, true)
				helpers.assert_eq(#deferred, 0)
			end)
		end
	end)
end)

return true
