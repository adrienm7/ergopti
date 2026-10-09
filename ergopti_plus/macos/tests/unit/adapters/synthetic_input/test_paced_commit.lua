--- tests/unit/adapters/synthetic_input/test_paced_commit.lua

--- ==============================================================================
--- MODULE: Synthetic Input paced commit Tests
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
	helpers.it("refuses cancellation after paced ownership commits", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local target = { id = "terminal-app" }
		local completion
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal.cancel-fence", "replacement")
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
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned)
		helpers.assert_true(not synthetic.cancel(tx),
			"pause/reload cancellation must not revoke an already-consumed user action")

		local guard = 0
		while (#fixture.timers > 0 or completion == nil) and guard < 40 do
			if #fixture.timers > 0 then fixture.fire_next_timer() end
			guard = guard + 1
		end
		helpers.assert_eq(fixture.key_posts, 4)
		helpers.assert_eq(completion, "complete")
	end)

	helpers.it("makes callback abort report committed paced ownership", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local target = { id = "terminal-app" }
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal.abort-fence", "replacement")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))

		local removed, consume_original = synthetic.abort_callback()
		helpers.assert_true(removed)
		helpers.assert_true(consume_original,
			"an enclosing callback failure cannot pass through the already-owned magic key")
		helpers.assert_eq(synthetic.stats().pending, 1,
			"abort must preserve the committed output batch for post-return delivery")
	end)

	helpers.it("keeps callback output reversible until periodic construction commits", function()
		local cases = {
			{ name = "constructor false", options = { false_on_timer_new_call = 1 }, starts = 0 },
			{ name = "constructor nil", options = { fail_on_timer_new_call = 1 }, starts = 0 },
			{ name = "constructor throw", options = { throw_on_timer_new_call = 1 }, starts = 0 },
			{ name = "start false", options = { timer_start_mode = "false" }, starts = 1 },
			{ name = "start nil", options = { timer_start_mode = "nil" }, starts = 1 },
			{ name = "start throw", options = { timer_start_mode = "throw" }, starts = 1 },
			{ name = "start state mismatch", options = { timer_start_mode = "stopped" }, starts = 1 },
			{ name = "start callback reentry", options = { timer_start_inline = true }, starts = 1 },
			{
				name = "start callback rollback debt",
				options = {
					timer_start_inline = true,
					timer_stop_failures_by_call = { [1] = 2 },
				},
				starts = 1,
				cleanup = 1,
			},
		}
		for _, case in ipairs(cases) do
			local fixture = make_fixture(case.options)
			local synthetic = fixture.load()
			local target = { id = "terminal-app" }
			synthetic.enter_callback()
			local tx = synthetic.begin("unit.terminal.wake-" .. case.name, "replacement")
			synthetic.with_transaction(tx, function()
				synthetic.emit_key_stroke({}, "delete", 0)
				synthetic.emit_key_strokes("X")
			end)
			local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
			helpers.assert_nil(owner,
				case.name .. " must refuse periodic ownership during reversible preparation")
			helpers.assert_true(synthetic.seal(tx))
			local consume, returned = synthetic.leave_callback(true)
			helpers.assert_true(consume)
			helpers.assert_eq(#returned, 4,
				case.name .. " must fall back to the complete callback batch")
			helpers.assert_eq(fixture.key_posts, 0)
			helpers.assert_eq(synthetic.stats().pending, 0)
			local expected_cleanup = case.cleanup or 0
			helpers.assert_eq(synthetic.stats().pending_periodic_cleanup, expected_cleanup)
			helpers.assert_eq(fixture.timer_new_calls, 1,
				case.name .. " must not construct a hidden successor")
			helpers.assert_eq(fixture.timer_start_calls, case.starts)
			helpers.assert_eq(fixture.raw_do_every_calls, 0)
			if expected_cleanup > 0 then
				local periodic = fixture.fire_timer_matching(0.012)
				helpers.assert_not_nil(periodic)
				helpers.assert_eq(periodic.stop_calls, 3,
					"queued reentry must settle the twice-refused acquisition")
				helpers.assert_true(periodic.stopped)
				helpers.assert_eq(fixture.timer_new_calls, 1)
				helpers.assert_eq(fixture.key_posts, 0)
				helpers.assert_eq(synthetic.stats().pending_periodic_cleanup, 0)
			end
		end
	end)

	helpers.it("uses only its pre-acquired owner after paced commit, across wake and post refusals", function()
		local fixture = make_fixture({ key_post_throw_at = 3 })
		local synthetic = fixture.load()
		local target = { id = "terminal-app" }
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal.infallible-commit", "replacement")
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
		helpers.assert_not_nil(owner)
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		local do_after_before = fixture.do_after_calls
		local timer_new_before = fixture.timer_new_calls
		synthetic.defer_after_callback = function()
			error("late dispatcher acquisition")
		end

		local commit_ok, committed = pcall(synthetic.commit_collected_paced, owner)
		helpers.assert_true(commit_ok,
			"commit after engine-state mutation must invoke no fallible scheduler")
		helpers.assert_true(committed)
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned)
		fixture.fail_next_do_after = true
		fixture.fail_next_timer_new = true
		fixture.fire_next_timer() -- first pair succeeds through the prepared wake
		fixture.fire_next_timer() -- suffix post is refused; this turn must stop
		helpers.assert_eq(#fixture.key_attempts, 3)
		fixture.fire_next_timer() -- recurring owner retries without reacquisition
		local guard = 0
		while #fixture.timers > 0 and fixture.key_posts < 4 and guard < 40 do
			fixture.fire_next_timer()
			guard = guard + 1
		end
		helpers.assert_eq(fixture.key_posts, 4)
		helpers.assert_eq(fixture.do_after_calls, do_after_before,
			"post-commit recovery must never acquire a one-shot dispatcher")
		helpers.assert_eq(fixture.timer_new_calls, timer_new_before,
			"post-commit recovery must never acquire another periodic owner")
	end)

	helpers.it("finishes with no next input when immediate wake and first post are both refused", function()
		local fixture = make_fixture({ do_after_failures = 1, key_post_throw_at = 1 })
		local synthetic = fixture.load()
		local target = { id = "terminal-app" }
		local completion
		synthetic.enter_callback()
		local tx = synthetic.begin("unit.terminal.double-refusal", "replacement")
		synthetic.on_complete(tx, function(_, status) completion = status end)
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("X")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
		helpers.assert_not_nil(owner,
			"the recurring owner must survive refusal of the optional immediate wake")
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned)

		fixture.fire_next_timer() -- periodic owner: first post refused
		helpers.assert_eq(#fixture.key_attempts, 1)
		helpers.assert_nil(completion)
		local guard = 0
		while (#fixture.timers > 0 or completion == nil) and guard < 40 do
			if #fixture.timers > 0 then fixture.fire_next_timer() end
			guard = guard + 1
		end
		helpers.assert_eq(fixture.key_posts, 4,
			"pre-acquired recurring ownership must finish without another physical event")
		helpers.assert_eq(completion, "complete")
	end)

	helpers.it("serializes overlapping terminal replacements through one FIFO owner", function()
		local fixture = make_fixture()
		local synthetic = fixture.load()
		local target = { id = "terminal-app" }
		synthetic.enter_callback()
		local function queue(owner, text)
			local tx = synthetic.begin(owner, "replacement")
			synthetic.with_transaction(tx, function()
				synthetic.emit_key_stroke({}, "delete", 0)
				synthetic.emit_key_strokes(text)
			end)
			local paced_owner = synthetic.prepare_collected_paced(tx, 1, 12000, target)
			helpers.assert_not_nil(paced_owner)
			helpers.assert_true(synthetic.seal(tx))
			helpers.assert_true(synthetic.authorize_collected_paced(paced_owner))
			helpers.assert_true(synthetic.commit_collected_paced(paced_owner))
		end

		queue("unit.terminal.first", "A")
		queue("unit.terminal.second", "B")
		local consume, returned = synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_nil(returned)
		local observed_owners = {}
		fixture.key_observer = function(event)
			local property = fixture.eventtap.event.properties.eventSourceUserData
			local metadata = synthetic.lookup_tag(event:getProperty(property))
			observed_owners[#observed_owners + 1] = metadata.owner
		end
		local guard = 0
		while #fixture.timers > 0 and guard < 80 do
			fixture.fire_next_timer()
			guard = guard + 1
		end
		helpers.assert_eq(#observed_owners, 8)
		for index = 1, 4 do helpers.assert_eq(observed_owners[index], "unit.terminal.first") end
		for index = 5, 8 do helpers.assert_eq(observed_owners[index], "unit.terminal.second") end
	end)
end)
