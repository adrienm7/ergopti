--- tests/unit/modules/keylogger/test_notify_synthetic_disabled_guard.lua

--- Regression: an opt-in keylogger that is off must not accumulate logical
--- expansion telemetry. Physical echo ownership is a separate event-tag concern:
--- an old tagged echo can never make a later, identical untagged key synthetic.

local helpers = require("tests.helpers")
local fixture_module = require("tests.support.keylogger_provenance_fixture")

helpers.describe("keylogger: disabled synthetic telemetry and exact ownership", function()
	helpers.it("records no logical text, WPM sample, source, or flush while disabled", function()
		local fixture = fixture_module.load_keylogger()
		local stats_before = fixture.synthetic_input.stats()

		fixture.keylogger.notify_synthetic("disabled expansion", "hotstring", 2,
			"personal", "disabled expansion", false)

		helpers.assert_eq(#fixture.state.buffer_events, 0)
		helpers.assert_eq(#fixture.state.rich_chunks, 0)
		helpers.assert_eq(#fixture.state.recent_typing_eff, 0)
		helpers.assert_eq(#fixture.flushes, 0)
		helpers.assert_eq(fixture.keylogger.get_live_stats().source, "none")
		local stats_after = fixture.synthetic_input.stats()
		helpers.assert_eq(stats_after.records, stats_before.records,
			"logical telemetry must not fabricate physical ownership records")
	end)

	helpers.it("an earlier tagged echo cannot claim the first physical key after enable", function()
		local fixture = fixture_module.load_keylogger()
		local tagged = fixture_module.tagged_key(
			fixture.synthetic_input, "test.disabled-expansion", "replacement", "x")

		fixture.keylogger.notify_synthetic("x", "hotstring", 0, nil, "x", false)
		fixture.state.is_enabled = true

		local physical = fixture_module.physical_key(fixture.hs, "x")
		helpers.assert_nil(fixture.provenance.classify(
			physical, "test.disabled-expansion.physical"),
			"ownership must be read from this event, never inferred from older output")
		local metadata = fixture.provenance.classify(
			tagged, "test.disabled-expansion.tagged")
		helpers.assert_not_nil(metadata)
		helpers.assert_eq(metadata.owner, "test.disabled-expansion")
		helpers.assert_eq(metadata.effect, "replacement")
	end)
end)
