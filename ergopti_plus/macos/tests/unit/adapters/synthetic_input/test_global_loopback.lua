--- tests/unit/adapters/synthetic_input/test_global_loopback.lua

--- ==============================================================================
--- MODULE: Synthetic Input global loopback Tests
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

helpers.describe("synthetic input: ambient transactions and loopback", function()
	helpers.it("globally posts loopback after the origin callback so keymap receives it", function()
		local fixture = make_fixture({ gc_cancels_unretained_timers = true })
		local synthetic, provenance = fixture.load()
		local epoch_before = synthetic.current_action_epoch()
		local received
		local order = {}
		fixture.key_observer = function(event)
			if event.isDown then
				received = provenance.classify(event, "keymap")
				order[#order + 1] = "keymap"
			end
		end

		synthetic.enter_callback() -- simulate the originating keymap callback
		local tx = synthetic.begin("unit.llm-loopback", "action")
		synthetic.on_complete(tx, function(_, status)
			if status == "complete" then order[#order + 1] = "complete" end
		end)
		synthetic.with_transaction(tx, function()
			synthetic.emit_loopback_key_stroke({}, "f16", 0)
		end)
		synthetic.seal(tx)
		local _, returned = synthetic.leave_callback(false)
		helpers.assert_nil(returned,
			"loopback cannot use a return table that bypasses its originating tap")
		helpers.assert_nil(received)
		helpers.assert_eq(fixture.post_count, 0)

		collectgarbage("collect")
		fixture.fire_next_timer()
		helpers.assert_eq(fixture.key_posts, 2)
		helpers.assert_not_nil(received,
			"global Quartz post must re-enter the simulated keymap callback")
		helpers.assert_true(received.owned)
		helpers.assert_true(received.loopback)
		helpers.assert_eq(received.effect, "action")
		helpers.assert_true(synthetic.current_action_epoch() == epoch_before,
			"loopback control alone must not invalidate action context")
		helpers.assert_eq(order[1], "keymap")
		helpers.assert_nil(order[2],
			"completion must be isolated from the global post callback")
		fixture.fire_next_timer()
		helpers.assert_eq(order[2], "complete",
			"transaction completion must follow both global posts")
	end)

	helpers.it("pins live loopback provenance until both keymap phases claim it", function()
		local fixture = make_fixture()
		local synthetic, provenance = fixture.load()
		synthetic.RECORD_LIMIT = 4
		helpers.assert_true(synthetic.emit_loopback_key_stroke({}, "f16", 0))

		local churn_tx = synthetic.begin("unit.loopback-ledger-churn", "replacement")
		local churn_batch = synthetic.begin_callback(churn_tx)
		for _ = 1, 3 do synthetic.keyStroke(churn_batch, {}, "x") end
		helpers.assert_eq(synthetic.stats().records, synthetic.RECORD_LIMIT)

		local observed = {}
		local posted = {}
		fixture.key_observer = function(event)
			posted[#posted + 1] = event
			local consumer = event.isDown and "keymap" or "keymap.loopback_keyup"
			observed[#observed + 1] = provenance.classify(event, consumer)
		end
		fixture.fire_next_timer()

		helpers.assert_eq(fixture.key_posts, 2)
		for phase = 1, 2 do
			helpers.assert_true(observed[phase].enriched,
				"live loopback phase " .. phase .. " must survive unrelated ledger churn")
			helpers.assert_true(observed[phase].loopback)
			helpers.assert_true(not observed[phase].stale_loopback)
		end

		-- Both authoritative consumers have now claimed their phases. One newer pair
		-- must be able to evict those pins while preserving the configured bound.
		synthetic.keyStroke(churn_batch, {}, "y")
		helpers.assert_eq(synthetic.stats().records, synthetic.RECORD_LIMIT)
		for phase = 1, 2 do
			local tag = posted[phase]:getProperty(USER_DATA)
			local retired = synthetic.lookup_tag(tag)
			helpers.assert_true(retired.stale_loopback,
				"claimed loopback phase " .. phase .. " must become eviction-eligible")
			helpers.assert_true(not retired.loopback)
		end
		synthetic.cancel(churn_tx)
	end)

	helpers.it("rolls back every loopback phase when construction throws", function()
		local fixture = make_fixture({ new_key_event_throw_at = 2 })
		local synthetic = fixture.load()
		helpers.assert_throws(function()
			synthetic.emit_loopback_key_stroke({}, "f16", 0)
		end)
		local stats = synthetic.stats()
		helpers.assert_eq(stats.records, 0,
			"the successfully built down phase must not survive a key-up constructor failure")
		helpers.assert_eq(stats.pending_loopbacks, 0)
		helpers.assert_eq(stats.active_transactions, 0)
		helpers.assert_eq(fixture.key_posts, 0)
	end)

	helpers.it("cancels a pending global loopback at the physical ordering fence", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		helpers.assert_true(synthetic.emit_loopback_key_stroke({}, "f16", 0))
		helpers.assert_eq(synthetic.stats().pending_loopbacks, 1)
		local fence = synthetic.claim_physical_fence()
		helpers.assert_not_nil(fence)
		helpers.assert_nil(fence.events)
		helpers.assert_eq(fence.cancelled_loopbacks, 1)
		helpers.assert_eq(synthetic.stats().pending_loopbacks, 0)
		while #fixture.timers > 0 do fixture.fire_next_timer() end
		helpers.assert_eq(fixture.key_posts, 0,
			"a delayed control signal must never overtake the physical event")
		helpers.assert_eq(synthetic.stats().records, 0)
	end)
end)
