--- tests/unit/adapters/synthetic_input/test_provenance.lua

--- ==============================================================================
--- MODULE: Synthetic Input provenance Tests
--- DESCRIPTION:
--- Preserves the native behavioral scenarios from the original provenance suite.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.synthetic_input_fixture")
local make_fixture = Fixture.make
local USER_DATA = Fixture.USER_DATA
local SOURCE_PID = Fixture.SOURCE_PID
local MOUSE_BUTTON = Fixture.MOUSE_BUTTON
local KEY_DOWN = Fixture.KEY_DOWN
local KEY_UP = Fixture.KEY_UP
local FLAGS_CHANGED = Fixture.FLAGS_CHANGED
local LEFT_MOUSE_DOWN = Fixture.LEFT_MOUSE_DOWN
local LEFT_MOUSE_UP = Fixture.LEFT_MOUSE_UP
local RIGHT_MOUSE_DOWN = Fixture.RIGHT_MOUSE_DOWN
local RIGHT_MOUSE_UP = Fixture.RIGHT_MOUSE_UP
local MOUSE_MOVED = Fixture.MOUSE_MOVED
local LEFT_MOUSE_DRAGGED = Fixture.LEFT_MOUSE_DRAGGED
local OTHER_MOUSE_UP = Fixture.OTHER_MOUSE_UP
local RIGHT_MOUSE_DRAGGED = Fixture.RIGHT_MOUSE_DRAGGED
local OTHER_MOUSE_DRAGGED = Fixture.OTHER_MOUSE_DRAGGED
local CURRENT_PID = Fixture.CURRENT_PID

helpers.describe("synthetic input: explicit per-event provenance", function()
	helpers.it("loads production adapters and claims reordered events once per consumer", function()
		local fixture = make_fixture()
		local synthetic, provenance = fixture.load()
		local epoch_before = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.action", "action")
		local batch = synthetic.begin_callback(tx)
		helpers.assert_true(synthetic.keyStrokes(batch, "ab"))
		local completed = false
		synthetic.on_complete(tx, function(_, status)
			completed = status == "complete"
		end)
		local consume, events = synthetic.finish_callback(batch, true)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(consume)
		helpers.assert_eq(#events, 4)
		helpers.assert_eq(fixture.post_count, 0,
			"originating callback path must never call event:post()")
		helpers.assert_true(not completed,
			"completion must wait until timer zero after callback return")
		helpers.assert_true(synthetic.current_action_epoch() ~= epoch_before,
			"a successful nonempty action handoff must replace the epoch token")
		helpers.assert_eq(synthetic.stats().action_handoffs, 1)

		local tags = {}
		for _, event in ipairs(events) do
			local tag = event:getProperty(USER_DATA)
			helpers.assert_nil(tags[tag], "every phase needs a unique user-data tag")
			tags[tag] = true
		end

		-- Ordinal 2 arrives before ordinal 1: immutable metadata follows the event,
		-- while only a repeated delivery of that exact tag is a duplicate.
		local second = provenance.classify(events[3], "keymap")
		helpers.assert_eq(second.ordinal, 2)
		helpers.assert_eq(second.phase, "down")
		helpers.assert_true(not second.duplicate)
		helpers.assert_eq(second.effect, "action")

		local first_late = provenance.classify(events[1], "keymap")
		helpers.assert_eq(first_late.ordinal, 1)
		local duplicate = provenance.classify(events[3], "keymap")
		helpers.assert_true(duplicate.duplicate)

		local other_consumer = provenance.classify(events[3], "keylogger")
		helpers.assert_true(not other_consumer.duplicate)
		helpers.assert_true(synthetic.current_action_epoch() == synthetic.current_action_epoch(),
			"epoch reads must return the same allocation until another handoff")

		-- Metadata is a copy: callers cannot corrupt the ledger seen by a sibling.
		other_consumer.owner = "mutated"
		local copied = provenance.classify(events[4], "third-consumer")
		helpers.assert_eq(copied.owner, "unit.action")

		fixture.fire_next_timer() -- post-return confirmation reaches terminal state
		helpers.assert_true(not completed,
			"terminal lifecycle callbacks must never run inline with confirmation")
		fixture.fire_next_timer() -- retained lifecycle dispatcher
		helpers.assert_true(completed)
	end)

	helpers.it("rejects same-PID untagged input and keeps PID secondary", function()
		local fixture = make_fixture()
		local synthetic, provenance = fixture.load()
		local pid_reads_before = fixture.pid_reads
		helpers.assert_nil(provenance.classify(
			fixture.external_event(nil, CURRENT_PID), "keymap"))
		helpers.assert_eq(fixture.pid_reads, pid_reads_before,
			"unknown tags must not pay the PID diagnostic read")

		local tx = synthetic.begin("unit.pid", "replacement")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "x")
		local _, events = synthetic.finish_callback(batch, true)
		events[1].source_pid = 9999
		local metadata = provenance.classify(events[1], "keymap")
		helpers.assert_true(metadata.owned,
			"known tag stays authoritative across a PID mismatch")
		helpers.assert_true(metadata.pid_matches == false)
	end)

	helpers.it("keeps evicted and pre-reload tags fail-closed with decoded effect", function()
		local fixture = make_fixture()
		local synthetic, provenance = fixture.load()
		local tx = synthetic.begin("unit.large", "replacement")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "a")
		local first_event = batch.events[1]
		local first_tag = first_event:getProperty(USER_DATA)
		helpers.assert_throws(function() synthetic.claim_tag(first_tag, {}) end,
			"live tags must reject an invalid consumer ID")
		-- 2,050 pairs exceed the real 4,096-record bound inside one batch.
		for _ = 2, 2050 do synthetic.keyStroke(batch, {}, "a") end
		local evicted = provenance.classify(first_event, "keymap")
		helpers.assert_true(evicted.owned)
		helpers.assert_true(not evicted.enriched)
		helpers.assert_true(evicted.stale)
		helpers.assert_eq(evicted.effect, "replacement")
		helpers.assert_eq(synthetic.stats().action_handoffs, 0,
			"current-session replacement eviction must not publish a false boundary")
		helpers.assert_eq(synthetic.stats().stale_context_tags, 0)
		helpers.assert_true(synthetic.decode_tag(first_tag).owned)
		helpers.assert_throws(function() synthetic.claim_tag(first_tag, {}) end,
			"stale tags must enforce the same fail-fast consumer contract")

		local reservation_before = fixture.settings_store[
			"ergopti.synthetic_input.next_tag_sequence_v2"]
		local stale_loop_tx = synthetic.begin("unit.stale-loop", "action")
		local stale_loop_batch = synthetic.begin_callback(stale_loop_tx)
		synthetic.loopbackKeyStroke(stale_loop_batch, {}, "f16")
		local stale_loop_event = stale_loop_batch.events[1]
		synthetic.finish_callback(stale_loop_batch, true)
		synthetic.seal(stale_loop_tx)

		fixture.timers = {}
		local reloaded, provenance_after_reload = fixture.load()
		local reservation_after = fixture.settings_store[
			"ergopti.synthetic_input.next_tag_sequence_v2"]
		helpers.assert_true(reservation_after > reservation_before,
			"each load must reserve a disjoint persisted sequence block")
		local old_epoch = reloaded.current_action_epoch()
		helpers.assert_true(provenance_after_reload.is_owned(first_event))
		helpers.assert_true(reloaded.current_action_epoch() == old_epoch,
			"is_owned must remain a read-only ownership probe")
		helpers.assert_eq(reloaded.stats().stale_context_tags, 0)
		local old = provenance_after_reload.classify(first_event, "keymap")
		helpers.assert_true(old.owned)
		helpers.assert_eq(old.effect, "replacement")
		helpers.assert_true(not old.enriched)
		helpers.assert_true(reloaded.current_action_epoch() ~= old_epoch,
			"a pre-reload replacement must invalidate the new logical context")
		helpers.assert_eq(reloaded.stats().stale_context_tags, 1)

		local new_tx = reloaded.begin("unit.reload", "action")
		local new_batch = reloaded.begin_callback(new_tx)
		reloaded.keyStroke(new_batch, {}, "b")
		helpers.assert_true(new_batch.events[1]:getProperty(USER_DATA) ~= first_tag,
			"reload must not reuse an old Quartz tag")

		local epoch_before_stale_loop = reloaded.current_action_epoch()
		local stale_loop = provenance_after_reload.classify(stale_loop_event, "keymap")
		helpers.assert_true(stale_loop.owned)
		helpers.assert_true(not stale_loop.loopback)
		helpers.assert_true(stale_loop.stale_loopback,
			"an old F16 must never be routed into a new prediction")
		helpers.assert_true(reloaded.current_action_epoch() == epoch_before_stale_loop,
			"an old internal loopback is not an observable user action")
		helpers.assert_eq(reloaded.stats().stale_context_tags, 1,
			"the stale loopback must not enter non-loopback context dedupe")
	end)

	helpers.it("advances one bounded conservative epoch per stale non-loopback tag", function()
		local fixture = make_fixture()
		local prior = fixture.load()

		local function prior_action_events(key)
			local tx = prior.begin("unit.prior-action", "action")
			local batch = prior.begin_callback(tx)
			prior.keyStroke(batch, {}, key)
			local down, up = batch.events[1], batch.events[2]
			prior.finish_callback(batch, true)
			prior.seal(tx)
			return down, up
		end

		local first_down, first_up = prior_action_events("a")
		local second_down = prior_action_events("b")
		fixture.timers = {}
		local synthetic, provenance = fixture.load() -- old events lose live enrichment
		synthetic.STALE_CONTEXT_DEDUPE_LIMIT = 2
		local initial_epoch = synthetic.current_action_epoch()

		helpers.assert_true(provenance.is_owned(first_down))
		helpers.assert_true(synthetic.current_action_epoch() == initial_epoch,
			"a nil-consumer ownership probe must not mutate the epoch")
		helpers.assert_eq(synthetic.stats().stale_context_tags, 0)

		local first = provenance.classify(first_down, "keymap")
		local first_epoch = synthetic.current_action_epoch()
		helpers.assert_true(first.stale and first.effect == "action")
		helpers.assert_true(first_epoch ~= initial_epoch,
			"the first consumer of a stale action tag must invalidate current context")
		helpers.assert_eq(synthetic.stats().action_handoffs, 1)

		local sibling = provenance.classify(first_down, "keylogger")
		helpers.assert_true(sibling.stale and sibling.effect == "action")
		helpers.assert_true(synthetic.current_action_epoch() == first_epoch,
			"a sibling consumer must not publish the same stale tag twice")
		helpers.assert_eq(synthetic.stats().action_handoffs, 1)

		provenance.classify(first_up, "keylogger")
		helpers.assert_eq(synthetic.stats().action_handoffs, 2,
			"a distinct stale phase tag must publish its own conservative boundary")
		provenance.classify(second_down, "keymap")
		helpers.assert_eq(synthetic.stats().action_handoffs, 3)
		helpers.assert_eq(synthetic.stats().stale_context_tags, 2,
			"stale-context dedupe memory must stay at its configured bound")

		local before_revisit = synthetic.current_action_epoch()
		provenance.classify(first_down, "third-consumer")
		helpers.assert_true(synthetic.current_action_epoch() ~= before_revisit,
			"an evicted dedupe entry must fail safe if its tag appears again")
		helpers.assert_eq(synthetic.stats().stale_context_tags, 2)
	end)

	helpers.it("wraps the persisted sequence ring without bricking a reload", function()
		local sequence_limit = 1 << 38
		local reservation_key = "ergopti.synthetic_input.next_tag_sequence_v2"
		local fixture = make_fixture({
			settings_store = { [reservation_key] = sequence_limit - 2 },
		})
		local synthetic, provenance = fixture.load()
		synthetic.RECORD_LIMIT = 2
		local initial_epoch = synthetic.current_action_epoch()
		local tx = synthetic.begin("unit.wrap", "action")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStrokes(batch, "ab") -- four tags cross limit - 1 -> 0
		local _, events = synthetic.finish_callback(batch, true)
		helpers.assert_eq(synthetic.decode_tag(events[1]:getProperty(USER_DATA)).sequence,
			sequence_limit - 2)
		helpers.assert_eq(synthetic.decode_tag(events[3]:getProperty(USER_DATA)).sequence, 0)
		helpers.assert_true(synthetic.current_action_epoch() ~= initial_epoch)
		helpers.assert_eq(synthetic.stats().action_handoffs, 1)
		local wrapped_stale = provenance.classify(events[1], "keymap")
		helpers.assert_true(wrapped_stale.stale)
		helpers.assert_eq(synthetic.stats().action_handoffs, 1,
			"a wrapped current-session block must not look like pre-reload output")
		helpers.assert_eq(synthetic.stats().stale_context_tags, 0)

		fixture.timers = {}
		local reloaded = fixture.load()
		local reloaded_tx = reloaded.begin("unit.wrap-reload", "replacement")
		local reloaded_batch = reloaded.begin_callback(reloaded_tx)
		reloaded.keyStroke(reloaded_batch, {}, "c")
		helpers.assert_eq(reloaded.decode_tag(
			reloaded_batch.events[1]:getProperty(USER_DATA)).sequence,
			(1 << 20) - 2,
			"reload must continue from the persisted modular reservation")
	end)
end)
