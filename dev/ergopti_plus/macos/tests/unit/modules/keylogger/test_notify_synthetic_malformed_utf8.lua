--- tests/unit/modules/keylogger/test_notify_synthetic_malformed_utf8.lua

--- Regression: malformed UTF-8 from an asynchronous completion must not abort
--- logical telemetry. The real keylogger stores one opaque fallback event while
--- physical echo ownership continues to come exclusively from exact event tags.

local helpers = require("tests.helpers")
local fixture_module = require("tests.support.keylogger_provenance_fixture")

local MALFORMED = string.char(0xF0, 0x28)

helpers.describe("keylogger: malformed UTF-8 synthetic telemetry", function()
	helpers.it("records one opaque fallback without raising", function()
		local fixture = fixture_module.load_keylogger()
		fixture.state.is_enabled = true
		local tagged = fixture_module.tagged_key(
			fixture.synthetic_input, "test.malformed-utf8", "replacement", "x")

		-- An escaped UTF-8 error fails the test directly; the assertions below
		-- additionally prove that the malformed sequence is handled atomically.
		fixture.keylogger.notify_synthetic(
			MALFORMED, "llm", 0, "stream", MALFORMED, false)
		helpers.assert_eq(#fixture.flushes, 1)
		helpers.assert_eq(#fixture.flushes[1].events, 1,
			"invalid input is one opaque logical event, not a partial character prefix")
		helpers.assert_eq(fixture.flushes[1].events[1][1], MALFORMED)
		helpers.assert_eq(fixture.flushes[1].events[1][3].st, "llm")
		helpers.assert_eq(#fixture.state.recent_typing_eff, 1)
		helpers.assert_eq(fixture.keylogger.get_live_stats().source, "llm")
		local metadata = fixture.provenance.classify(tagged, "test.malformed-utf8")
		helpers.assert_not_nil(metadata,
			"logical UTF-8 fallback must not disturb the physical ownership adapter")
		helpers.assert_eq(metadata.owner, "test.malformed-utf8")
	end)

	helpers.it("still splits valid multibyte text by Unicode codepoint", function()
		local fixture = fixture_module.load_keylogger()
		fixture.state.is_enabled = true
		local text = "caf" .. utf8.char(0xE9)

		fixture.keylogger.notify_synthetic(text, "hotstring", 0, "case", text, false)

		local events = fixture.flushes[1].events
		helpers.assert_eq(#events, 4)
		helpers.assert_eq(events[1][1], "c")
		helpers.assert_eq(events[2][1], "a")
		helpers.assert_eq(events[3][1], "f")
		helpers.assert_eq(events[4][1], utf8.char(0xE9))
		helpers.assert_eq(#fixture.state.recent_typing_eff, 4)
	end)

	helpers.it("proves the malformed sequence would raise if iterated directly", function()
		local ok = pcall(function()
			for _ in utf8.codes(MALFORMED) do end
		end)
		helpers.assert_true(not ok,
			"the scenario must remain capable of detecting removal of the validation branch")
	end)
end)
