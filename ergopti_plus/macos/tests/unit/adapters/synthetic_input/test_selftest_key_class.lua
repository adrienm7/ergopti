--- tests/unit/adapters/synthetic_input/test_selftest_key_class.lua

--- ==============================================================================
--- MODULE: Synthetic Input Selftest Key Class Tests
--- DESCRIPTION:
--- The field run's selftest keys are a ledger record field, never a tag bit:
--- 1. a live selftest pair is posted globally (the keymap tap must see it),
---    carries selftest in both phases, is a replacement and advances no action
---    epoch that would reset the keymap's buffer between two typed keys;
--- 2. once its record is evicted, the tag decodes as ordinary synthetic output,
---    so the class fails safe instead of becoming physical typing;
--- 3. it is not loopback-pinned, so ledger churn can evict it;
--- 4. it is refused inside an eventtap callback, where a return table would
---    bypass the keymap tap that has to see it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.synthetic_input_fixture")
local USER_DATA = Fixture.USER_DATA

helpers.describe("synthetic input: field-run selftest key class", function()
	helpers.it("posts a live selftest pair globally with the class in both phases", function()
		local fixture = Fixture.make()
		local synthetic, provenance = fixture.load()
		local epoch_before = synthetic.current_action_epoch()
		local observed = {}
		fixture.key_observer = function(event)
			observed[#observed + 1] = provenance.classify(event, event.isDown and "keymap" or "keymap.loopback_keyup")
		end
		helpers.assert_true(synthetic.emit_selftest_key_stroke({}, "w"))
		helpers.assert_eq(fixture.key_posts, 0, "the pair waits for the owner tick, outside the caller")
		fixture.fire_next_timer()
		helpers.assert_eq(fixture.key_posts, 2)
		helpers.assert_eq(fixture.global_key_posts, 2, "a selftest pair must re-enter every tap globally")
		for phase = 1, 2 do
			helpers.assert_true(observed[phase].owned)
			helpers.assert_true(observed[phase].selftest, "phase " .. phase .. " must carry the selftest class")
			helpers.assert_eq(observed[phase].effect, "replacement")
			helpers.assert_true(not observed[phase].loopback, "a selftest key is not a loopback control")
			helpers.assert_eq(observed[phase].owner, synthetic.SELFTEST_OWNER)
		end
		helpers.assert_true(synthetic.current_action_epoch() == epoch_before,
			"a selftest key must not reset the keymap context between two typed keys")
	end)

	helpers.it("ordinary output never carries the selftest class", function()
		local fixture = Fixture.make()
		local synthetic, provenance = fixture.load()
		local tx = synthetic.begin("unit.ordinary", "replacement")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "w")
		local tag = batch.events[1]:getProperty(USER_DATA)
		local claimed = provenance.classify(batch.events[1], "keymap")
		helpers.assert_true(claimed.owned)
		helpers.assert_true(claimed.selftest == false, "a live ordinary record reads selftest false")
		helpers.assert_true(synthetic.lookup_tag(tag).selftest == false)
		synthetic.cancel(tx)
	end)

	helpers.it("degrades to ordinary synthetic output once its record is evicted", function()
		local fixture = Fixture.make()
		local synthetic, provenance = fixture.load()
		synthetic.RECORD_LIMIT = 4
		helpers.assert_true(synthetic.emit_selftest_key_stroke({}, "w"))
		local churn_tx = synthetic.begin("unit.selftest-churn", "replacement")
		local churn_batch = synthetic.begin_callback(churn_tx)
		-- Two newer pairs evict both selftest phases: they are not pinned.
		synthetic.keyStroke(churn_batch, {}, "x")
		synthetic.keyStroke(churn_batch, {}, "y")
		local observed = {}
		fixture.key_observer = function(event)
			observed[#observed + 1] = provenance.classify(event, event.isDown and "keymap" or "keymap.loopback_keyup")
		end
		fixture.fire_next_timer()
		helpers.assert_eq(fixture.key_posts, 2)
		for phase = 1, 2 do
			helpers.assert_true(observed[phase].owned, "an evicted selftest key stays owned, never physical")
			helpers.assert_true(not observed[phase].enriched)
			helpers.assert_true(observed[phase].selftest == false,
				"an evicted selftest key must lose the class instead of keeping it")
			helpers.assert_true(not observed[phase].loopback)
		end
		synthetic.cancel(churn_tx)
	end)

	helpers.it("refuses a selftest key inside an eventtap callback", function()
		local fixture = Fixture.make()
		local synthetic = fixture.load()
		synthetic.enter_callback()
		helpers.assert_throws(function() synthetic.emit_selftest_key_stroke({}, "w") end)
		synthetic.leave_callback(false)
		helpers.assert_eq(synthetic.stats().records, 0)
		helpers.assert_eq(synthetic.stats().active_transactions, 0)
	end)
end)
