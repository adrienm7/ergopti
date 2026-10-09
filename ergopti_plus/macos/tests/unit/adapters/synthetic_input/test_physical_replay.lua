--- tests/unit/adapters/synthetic_input/test_physical_replay.lua

--- ==============================================================================
--- MODULE: Synthetic Input physical replay Tests
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
	helpers.it("preflights physical replay before adopting any queued prefix", function()
		local cases = {
			{ name = "copy throw", options = { physical_copy_throw = true } },
			{ name = "copy nil", options = { physical_copy_nil = true } },
			{ name = "tagging throw", options = { physical_set_property_throw = true } },
			{ name = "periodic owner refusal", options = {}, refuse_owner = true },
			{ name = "periodic owner false", options = { false_on_timer_new_call = 2 } },
			{ name = "periodic owner throw", options = { throw_on_timer_new_call = 2 } },
		}
		for _, case in ipairs(cases) do
			local fixture = make_fixture(case.options)
			local synthetic = fixture.load()
			local older = synthetic.begin("unit.physical-preflight-prefix", "replacement")
			local older_batch = synthetic.begin_batch(older)
			synthetic.keyStroke(older_batch, {}, "a")
			helpers.assert_true(synthetic.dispatch(older_batch))
			helpers.assert_true(synthetic.seal(older))

			synthetic.enter_paced_collection()
			local paced = synthetic.begin("unit.physical-preflight-paced", "replacement")
			synthetic.with_transaction(paced, function()
				synthetic.emit_key_stroke({}, "delete", 0)
				synthetic.emit_key_strokes("X")
			end)
			local target = { id = "terminal-app" }
			local paced_owner = synthetic.prepare_collected_paced(paced, 1, 12000, target)
			helpers.assert_not_nil(paced_owner)
			helpers.assert_true(synthetic.seal(paced))
			helpers.assert_true(synthetic.authorize_collected_paced(paced_owner))
			helpers.assert_true(synthetic.commit_collected_paced(paced_owner))
			helpers.assert_true(synthetic.leave_paced_collection())
			helpers.assert_eq(synthetic.stats().pending, 2)

			if case.refuse_owner then fixture.fail_next_timer_new = true end
			local fence = synthetic.claim_physical_fence(fixture.external_event(nil, 42))
			helpers.assert_nil(fence, case.name .. " must pass the untouched original through")
			helpers.assert_eq(synthetic.stats().pending, 2,
				case.name .. " must not detach or acknowledge the older prefix")

			local guard = 0
			while #fixture.pump_deliveries == 0 and #fixture.timers > 0 do
				fixture.fire_next_timer()
				guard = guard + 1
				helpers.assert_true(guard < 30, case.name .. " stranded the older prefix")
			end
			helpers.assert_eq(#fixture.pump_deliveries, 1,
				case.name .. " must leave the exact older batch deliverable")
			helpers.assert_eq(fixture.pump_deliveries[1].events[1].key, "a")
		end
	end)

	helpers.it("fences a physical key behind paced output without collapsing cadence or target", function()
		local terminal_target = { id = "terminal-app" }
		local physical_target = { id = "editor-app" }
		local later_target = { id = "browser-app" }
		local fixture = make_fixture({ frontmost_app = terminal_target })
		local synthetic, provenance = fixture.load()
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal.physical-fence", "replacement")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 2, 12000, terminal_target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned)

		-- The timer-zero wake may post only the first complete delete pair. A human
		-- key arriving now is consumed and copied behind the still-paced suffix.
		while fixture.key_posts < 2 do fixture.fire_next_timer() end
		fixture.frontmost_app = physical_target
		local physical = fixture.external_event(nil, 42)
		physical.key = "tab"
		physical.modifiers = { "cmd" }
		local fence = synthetic.claim_physical_fence(physical)
		helpers.assert_not_nil(fence)
		helpers.assert_true(fence.consume_original,
			"the physical event must be owned before its original can be consumed")
		helpers.assert_nil(fence.events,
			"paced output must never be flattened into an immediate callback return")
		fixture.frontmost_app = later_target

		local replay_seen = 0
		local physical_replay = nil
		fixture.global_key_observer = function(event)
			local tag = event:getProperty(USER_DATA)
			local metadata = synthetic.lookup_tag(tag)
			if metadata and metadata.physical_replay then
				physical_replay = event
				replay_seen = replay_seen + 1
				for _, consumer in ipairs({ "keymap", "keylogger", "shortcuts" }) do
					local owned, status, replay_fence = provenance.classify_with_fence(event, consumer)
					helpers.assert_nil(owned)
					helpers.assert_eq(status, provenance.STATUS_FOREIGN)
					helpers.assert_nil(replay_fence,
						"a tagged physical replay must not recursively fence itself")
				end
			end
		end
		local periodic_pace_turns = 0
		local guard = 0
		while fixture.key_posts < 7 and #fixture.timers > 0 do
			local delay = fixture.fire_next_timer()
			if delay == 0.012 then periodic_pace_turns = periodic_pace_turns + 1 end
			guard = guard + 1
			helpers.assert_true(guard < 80, "paced physical fence must terminate")
		end
		helpers.assert_eq(fixture.key_posts, 7)
		helpers.assert_eq(periodic_pace_turns, 3,
			"the remaining delete pair, suffix, and lifecycle settlement need distinct paced turns")
		helpers.assert_eq(replay_seen, 1,
			"every tap may observe the replay, but Quartz must post it exactly once")
		for index = 1, 6 do
			helpers.assert_true(fixture.posted_targets[index] == terminal_target,
				"the complete replacement must retain its original terminal target")
		end
		helpers.assert_nil(fixture.posted_targets[7],
			"the delayed physical key must use global Quartz routing")
		helpers.assert_not_nil(physical_replay)
		helpers.assert_true(physical_replay ~= physical,
			"the consumed native event must be replayed from its owned copy")
		helpers.assert_eq(physical_replay.key, "tab")
		helpers.assert_eq(physical_replay.source_pid, 42)
		helpers.assert_eq(physical_replay.modifiers[1], "cmd",
			"Cmd-Tab modifier fidelity is required for global shortcut semantics")
	end)

	helpers.it("preserves Cmd-Space modifier flags on the global physical route", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.cmd-space-fidelity", "replacement")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local target = { id = "terminal-app" }
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		synthetic.leave_callback(true)

		local physical = fixture.external_event(nil, 42)
		physical.key = "space"
		physical.modifiers = { "cmd", "shift" }
		local fence = synthetic.claim_physical_fence(physical)
		helpers.assert_not_nil(fence)
		helpers.assert_true(fence.consume_original)
		local guard = 0
		while fixture.key_posts < 5 and #fixture.timers > 0 do
			fixture.fire_next_timer()
			guard = guard + 1
			helpers.assert_true(guard < 60, "Cmd-Space replay did not settle")
		end

		local replay = nil
		local replay_index = nil
		for index, event in ipairs(fixture.key_attempts) do
			local metadata = synthetic.lookup_tag(event:getProperty(USER_DATA))
			if metadata and metadata.physical_replay then
				replay = event
				replay_index = index
			end
		end
		helpers.assert_eq(fixture.key_posts, 5,
			"the global physical replay must settle after the four target events")
		helpers.assert_not_nil(replay)
		helpers.assert_eq(replay_index, #fixture.key_attempts,
			"Cmd-Space must not overtake any paced target suffix")
		helpers.assert_eq(replay.key, "space")
		helpers.assert_eq(replay.modifiers[1], "cmd")
		helpers.assert_eq(replay.modifiers[2], "shift")
		helpers.assert_nil(replay.posted_app,
			"Cmd-Space must re-enter Quartz globally, never through post(app)")
	end)

	helpers.it("retains physical replay timer debt until its exact stop succeeds", function()
		local fixture = make_fixture({ timer_stop_failures_by_call = { [2] = 1 } })
		local synthetic = fixture.load()
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.physical-stop-debt", "replacement")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 20000,
			{ id = "terminal-app" })
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		synthetic.leave_callback(true)
		local fence = synthetic.claim_physical_fence(fixture.external_event(nil, 42))
		helpers.assert_true(fence.consume_original)
		local drained = 0
		helpers.assert_true(synthetic.when_idle(function() drained = drained + 1 end))

		for _ = 1, 3 do fixture.fire_timer_matching(0.02) end
		local physical = fixture.fire_timer_matching(synthetic.PERIODIC_OWNER_TICK_SEC)
		helpers.assert_not_nil(physical)
		helpers.assert_eq(fixture.global_key_posts, 1)
		fixture.fire_timer_matching(synthetic.PERIODIC_OWNER_TICK_SEC)
		helpers.assert_eq(physical.stop_calls, 1)
		helpers.assert_true(not physical.stopped)
		helpers.assert_eq(drained, 0,
			"global idle must retain a physical replay handle after stop refusal")
		fixture.fire_timer_matching(synthetic.PERIODIC_OWNER_TICK_SEC)
		helpers.assert_eq(physical.stop_calls, 2)
		helpers.assert_true(physical.stopped)
		local guard = 0
		while drained == 0 and #fixture.timers > 0 do
			fixture.fire_next_timer()
			guard = guard + 1
			helpers.assert_true(guard < 20, "physical cleanup debt stranded global idle")
		end
		helpers.assert_eq(drained, 1)
	end)

	helpers.it("fails a paced transaction when its exact target process is gone", function()
		local fixture = make_fixture()
		local target = { id = "terminal-app" }
		function target:pid() return 8801 end
		fixture.live_applications = { [8801] = target }
		local synthetic = fixture.load()
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.dead-terminal-target", "replacement")
		local completion = nil
		synthetic.on_complete(tx, function(_, status) completion = status end)
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		synthetic.leave_callback(true)

		while fixture.key_posts < 2 do fixture.fire_next_timer() end
		fixture.live_applications[8801] = nil
		local guard = 0
		while completion == nil and #fixture.timers > 0 do
			fixture.fire_next_timer()
			guard = guard + 1
			helpers.assert_true(guard < 30, "dead target left the serializer non-terminal")
		end
		helpers.assert_eq(completion, "failed",
			"a non-delivery proof may never be published as complete")
		helpers.assert_eq(fixture.key_posts, 2,
			"the remaining suffix must not be redirected to another application")
	end)

	helpers.it("bounds permanent paced post refusal and releases the global drain", function()
		local fixture = make_fixture({ key_post_always_throws = true })
		local synthetic = fixture.load()
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.permanent-paced-refusal", "replacement")
		local completion = nil
		synthetic.on_complete(tx, function(_, status) completion = status end)
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, { id = "terminal-app" })
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		synthetic.leave_callback(true)
		local drained = 0
		helpers.assert_true(synthetic.when_idle(function() drained = drained + 1 end))

		for _ = 1, 12 do
			if completion ~= nil or #fixture.timers == 0 then break end
			fixture.fire_next_timer()
		end
		helpers.assert_eq(completion, "failed",
			"permanent refusal needs one observable terminal result")
		helpers.assert_true(#fixture.key_attempts <= 8,
			"native post retries must have a finite budget")
		local post_logs = 0
		for _, line in ipairs(fixture.logs) do
			if line:find("Paced terminal post", 1, true) then post_logs = post_logs + 1 end
		end
		helpers.assert_true(post_logs <= 3,
			"a permanent refusal must not create an unbounded error stream")
		for _ = 1, 8 do
			if drained == 1 or #fixture.timers == 0 then break end
			fixture.fire_next_timer()
		end
		helpers.assert_eq(synthetic.stats().active_transactions, 0)
		helpers.assert_eq(drained, 1,
			"terminal failure must open the process-wide drain exactly once")
	end)

	helpers.it("fences a physical mouse event globally and replays it once to provenance consumers", function()
		local fixture = make_fixture()
		local synthetic, provenance = fixture.load()
		local target = { id = "terminal-app" }
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal.mouse-fence", "replacement")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned)

		local fence = synthetic.claim_physical_fence(fixture.mouse_event(LEFT_MOUSE_DOWN))
		helpers.assert_true(fence.consume_original)
		local replay_seen = 0
		fixture.key_observer = function(event)
			local metadata = synthetic.lookup_tag(event:getProperty(USER_DATA))
			if metadata and metadata.physical_replay then
				replay_seen = replay_seen + 1
				for _, consumer in ipairs({ "tooltip.mouse", "keylogger.nonkeyboard" }) do
					local owned, status, replay_fence = provenance.classify_with_fence(event, consumer)
					helpers.assert_nil(owned)
					helpers.assert_eq(status, provenance.STATUS_FOREIGN)
					helpers.assert_nil(replay_fence)
				end
			end
		end
		local guard = 0
		while fixture.key_posts < 5 and #fixture.timers > 0 do
			fixture.fire_next_timer()
			guard = guard + 1
			helpers.assert_true(guard < 80, "mouse fence must terminate")
		end
		helpers.assert_eq(replay_seen, 1)
		helpers.assert_nil(fixture.posted_targets[5],
			"a mouse replay must remain global instead of inheriting a later app")
	end)
end)
