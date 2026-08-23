--- tests/unit/modules/shortcuts/test_surround_with_parens_transaction.lua

--- ==============================================================================
--- MODULE: Parenthesis Surround Dispatch Transaction Regression Tests
--- DESCRIPTION:
--- Models the exact SyntheticInput dispatch-terminal contract around the two
--- parenthesis batches. The closing timer must not exist until on_dispatched
--- proves the opening reached the FIFO, and a proven closing failure must retry
--- autonomously without treating false, nil, throw, late, or duplicate callback
--- shapes as permission to publish a second closing batch.
--- ==============================================================================

local helpers = require("tests.helpers")

local MUTATED = {
	"modules.shortcuts.actions.text", "adapters.synthetic_input",
	"adapters.timer_scheduler", "infra.logger", "infra.paths", "infra.timings",
}


--- Builds a faithful void-callback SyntheticInput double and exact timer owner.
--- @param options table|nil Failure and ordering controls.
--- @return table fixture
local function fresh_fixture(options)
	options = options or {}
	for _, name in ipairs(MUTATED) do package.loaded[name] = nil end
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.paths"] = { shared = function() return nil end }
	package.loaded["infra.timings"] = { sec = function() return 0.01 end }

	local emitted = {}
	local dispatches = {}
	local next_dispatch_mode = 0
	local synthetic = {}

	--- Completes one synthetic transaction exactly once.
	--- @param tx table Synthetic transaction.
	--- @param status string Terminal status.
	local function complete(tx, status)
		if tx.completed == true then return end
		tx.completed = true
		for _, callback in ipairs(tx.complete_callbacks) do callback(tx, status) end
	end

	--- Publishes one native terminal while permitting duplicate observer delivery.
	--- @param batch table Exact batch identity.
	--- @param status string dispatched|failed|cancelled.
	local function notify(batch, status)
		if batch.native_terminal == nil then
			batch.native_terminal = status
			if status == "dispatched" then
				for _, event in ipairs(batch.events) do emitted[#emitted + 1] = event end
			end
		end
		for _, callback in ipairs(batch.tx.dispatch_callbacks) do
			callback(batch.tx, batch, status)
		end
	end

	function synthetic.begin()
		return {
			sealed = false,
			completed = false,
			complete_callbacks = {},
			dispatch_callbacks = {},
			retain = nil,
		}
	end
	function synthetic.retain(tx)
		local token = { active = true, tx = tx }
		tx.retain = token
		return token
	end
	function synthetic.on_complete(tx, callback)
		tx.complete_callbacks[#tx.complete_callbacks + 1] = callback
	end
	function synthetic.on_dispatched(tx, callback)
		if options.observer_mode == "throw" then error("dispatch observer registration exploded") end
		tx.dispatch_callbacks[#tx.dispatch_callbacks + 1] = callback
		-- Production is a void API; nil is the successful return contract.
		return nil
	end
	function synthetic.begin_batch(tx, token)
		if tx.sealed == true then
			assert(token == tx.retain and token.active == true,
				"sealed surround transaction lost its exact retain")
		end
		return { tx = tx, events = {} }
	end
	function synthetic.discard_batch(batch)
		if batch.discarded == true or batch.native_terminal ~= nil then return false end
		batch.discarded = true
		notify(batch, "cancelled")
		return true
	end
	function synthetic.keyStroke(batch, modifiers, key)
		batch.events[#batch.events + 1] = {
			kind = "stroke", modifiers = modifiers, key = key,
		}
		return true
	end
	function synthetic.keyStrokes(batch, value)
		batch.events[#batch.events + 1] = { kind = "text", value = value }
		return true
	end
	function synthetic.dispatch(batch)
		next_dispatch_mode = next_dispatch_mode + 1
		local mode = (options.dispatch_modes or {})[next_dispatch_mode] or "accepted_late"
		dispatches[#dispatches + 1] = batch
		if mode:find("sync_dispatched", 1, true) then notify(batch, "dispatched") end
		if mode:find("sync_failed", 1, true) then notify(batch, "failed") end
		if mode:find("sync_cancelled", 1, true) then notify(batch, "cancelled") end
		if mode:find("throw", 1, true) then error("synthetic dispatch exploded") end
		if mode:find("false", 1, true) then return false end
		if mode:find("nil", 1, true) then return nil end
		return true
	end
	function synthetic.seal(tx)
		tx.sealed = true
		return true
	end
	function synthetic.release(tx, token)
		if token.active ~= true then return false end
		token.active = false
		complete(tx, "complete")
		return true
	end
	function synthetic.cancel(tx)
		if tx.completed == true then return false end
		if tx.retain then tx.retain.active = false end
		complete(tx, "cancelled")
		return true
	end
	package.loaded["adapters.synthetic_input"] = synthetic

	local timer_calls = {}
	local next_timer_mode = 0
	local scheduler = { cancel_refusals = options.cancel_refusals or 0 }

	--- Settles one timer and notifies its exact in-memory observers.
	--- @param handle table Timer handle.
	local function settle_timer(handle)
		handle.timer = nil
		handle.committed = false
		handle.fired = true
		local observers = handle.observers
		handle.observers = {}
		for _, observer in ipairs(observers) do observer() end
	end

	function scheduler.after(delay, callback)
		next_timer_mode = next_timer_mode + 1
		local mode = (options.timer_modes or {})[next_timer_mode] or "committed"
		local handle = {
			timer = {}, committed = false, fired = false, observers = {},
		}
		local call = { delay = delay, callback = callback, handle = handle }
		timer_calls[#timer_calls + 1] = call
		if mode == "settled" then
			settle_timer(handle)
			return handle, false
		end
		if mode == "debt" then
			scheduler.cancel_refusals = math.huge
			return handle, false
		end
		handle.committed = true
		function call.fire()
			if handle.fired == true then return end
			settle_timer(handle)
			callback()
		end
		return handle, true
	end
	function scheduler.onSettled(handle, observer)
		if handle.timer == nil then observer()
		else handle.observers[#handle.observers + 1] = observer end
		return true
	end
	function scheduler.cancel(handle)
		if handle.timer == nil then return true end
		if scheduler.cancel_refusals > 0 then
			scheduler.cancel_refusals = scheduler.cancel_refusals - 1
			return false
		end
		settle_timer(handle)
		return true
	end
	package.loaded["adapters.timer_scheduler"] = scheduler

	return {
		actions = helpers.load_with_stubs("modules.shortcuts.actions.text"),
		emitted = emitted,
		dispatches = dispatches,
		timers = timer_calls,
		notify = notify,
		scheduler = scheduler,
	}
end


helpers.describe("surround_with_parens: opening terminal gate", function()
	helpers.it("does not schedule or emit a close before the exact opening terminal", function()
		local f = fresh_fixture()
		helpers.assert_eq(f.actions.surround_with_parens(), true)
		helpers.assert_eq(#f.dispatches, 1)
		helpers.assert_eq(#f.timers, 0,
			"dispatch acceptance is not proof that the opening reached the FIFO")
		helpers.assert_eq(#f.emitted, 0)

		f.notify(f.dispatches[1], "failed")
		helpers.assert_eq(#f.timers, 0)
		helpers.assert_eq(#f.emitted, 0,
			"a terminally failed opening may never acquire or emit its closing sibling")
		f.notify(f.dispatches[1], "dispatched")
		helpers.assert_eq(#f.timers, 0,
			"a contradictory duplicate terminal must be inert")
	end)

	helpers.it("schedules the closing delay only after opening on_dispatched", function()
		local f = fresh_fixture()
		helpers.assert_eq(f.actions.surround_with_parens(), true)
		local opening = f.dispatches[1]
		f.notify(opening, "dispatched")
		helpers.assert_eq(#f.emitted, 2)
		helpers.assert_eq(f.emitted[1].key, "left")
		helpers.assert_eq(f.emitted[2].value, "(")
		helpers.assert_eq(#f.timers, 1)

		f.timers[1].fire()
		helpers.assert_eq(#f.dispatches, 2)
		helpers.assert_eq(#f.emitted, 2,
			"closing dispatch acceptance is not its terminal proof either")
		f.notify(f.dispatches[2], "dispatched")
		helpers.assert_eq(#f.emitted, 4)
		helpers.assert_eq(f.emitted[3].key, "right")
		helpers.assert_eq(f.emitted[4].value, ")")
		helpers.assert_eq(f.actions.has_pending_text_action(), false)
	end)

	helpers.it("buffers synchronous terminals without running the close before dispatch returns", function()
		local f = fresh_fixture({
			dispatch_modes = { "sync_dispatched", "sync_dispatched" },
		})
		helpers.assert_eq(f.actions.surround_with_parens(), true)
		helpers.assert_eq(#f.timers, 1)
		helpers.assert_eq(#f.emitted, 2)
		f.timers[1].fire()
		helpers.assert_eq(#f.emitted, 4)
		helpers.assert_eq(f.actions.has_pending_text_action(), false)
	end)

	helpers.it("fails before opening when the void observer registration throws", function()
		local f = fresh_fixture({ observer_mode = "throw" })
		helpers.assert_eq(f.actions.surround_with_parens(), false)
		helpers.assert_eq(#f.dispatches, 0)
		helpers.assert_eq(#f.timers, 0)
		helpers.assert_eq(#f.emitted, 0)
		helpers.assert_eq(f.actions.has_pending_text_action(), false)
	end)

	for _, result in ipairs({ "false", "nil", "throw" }) do
		helpers.it("waits for terminal proof after opening dispatch " .. result, function()
			local f = fresh_fixture({ dispatch_modes = { result .. "_late", "accepted_late" } })
			helpers.assert_eq(f.actions.surround_with_parens(), false)
			helpers.assert_eq(#f.timers, 0)
			helpers.assert_eq(#f.emitted, 0)
			f.notify(f.dispatches[1], "dispatched")
			helpers.assert_eq(#f.timers, 1,
				"only late exact proof may authorize the matching close")
			f.timers[1].fire()
			f.notify(f.dispatches[2], "dispatched")
			helpers.assert_eq(#f.emitted, 4,
				"mutate-then-refuse ambiguity may not leave a proven opening orphaned")
		end)
	end
end)


helpers.describe("surround_with_parens: closing retry ownership", function()
	for _, result in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retries autonomously after synchronous close " .. result, function()
			local f = fresh_fixture({
				dispatch_modes = {
					"accepted_late", result .. "_sync_failed", "accepted_late",
				},
			})
			helpers.assert_eq(f.actions.surround_with_parens(), true)
			f.notify(f.dispatches[1], "dispatched")
			f.timers[1].fire()
			helpers.assert_eq(#f.dispatches, 2)
			helpers.assert_eq(#f.timers, 2,
				"a proven failed close must arm an autonomous retry")
			helpers.assert_eq(#f.emitted, 2)
			f.timers[2].fire()
			helpers.assert_eq(#f.dispatches, 3)
			f.notify(f.dispatches[3], "dispatched")
			helpers.assert_eq(#f.emitted, 4)
			helpers.assert_eq(f.actions.has_pending_text_action(), false)
		end)
	end

	helpers.it("waits for a late close failure and ignores its duplicate callback", function()
		local f = fresh_fixture({
			dispatch_modes = { "accepted_late", "false_late", "accepted_late" },
		})
		helpers.assert_eq(f.actions.surround_with_parens(), true)
		f.notify(f.dispatches[1], "dispatched")
		f.timers[1].fire()
		local failed_close = f.dispatches[2]
		helpers.assert_eq(#f.timers, 1,
			"a false return alone may not invent a sibling closing batch")
		f.notify(failed_close, "failed")
		helpers.assert_eq(#f.timers, 2)
		f.notify(failed_close, "failed")
		helpers.assert_eq(#f.timers, 2,
			"duplicate terminal delivery may not arm a second retry")
		f.timers[2].fire()
		f.notify(f.dispatches[3], "dispatched")
		helpers.assert_eq(#f.emitted, 4)
	end)

	helpers.it("closes immediately when the post-opening cosmetic timer refuses", function()
		local f = fresh_fixture({ timer_modes = { "settled" } })
		helpers.assert_eq(f.actions.surround_with_parens(), true)
		f.notify(f.dispatches[1], "dispatched")
		helpers.assert_eq(#f.timers, 1)
		helpers.assert_eq(#f.dispatches, 2,
			"timer refusal after a visible opening must not leave it orphaned")
		f.notify(f.dispatches[2], "dispatched")
		helpers.assert_eq(#f.emitted, 4)
	end)

	helpers.it("closes autonomously when the retry timer refuses cleanly", function()
		local f = fresh_fixture({
			dispatch_modes = { "accepted_late", "sync_failed", "accepted_late" },
			timer_modes = { "committed", "settled" },
		})
		helpers.assert_eq(f.actions.surround_with_parens(), true)
		f.notify(f.dispatches[1], "dispatched")
		f.timers[1].fire()
		helpers.assert_eq(#f.timers, 2)
		helpers.assert_eq(#f.dispatches, 3,
			"a settled retry refusal must fall back to one immediate closing attempt")
		f.notify(f.dispatches[3], "dispatched")
		helpers.assert_eq(#f.emitted, 4)
		helpers.assert_eq(f.actions.has_pending_text_action(), false)
	end)

	helpers.it("retries exactly once after retained retry-timer debt settles", function()
		local f = fresh_fixture({
			dispatch_modes = { "accepted_late", "sync_failed", "accepted_late" },
			timer_modes = { "committed", "debt" },
		})
		helpers.assert_eq(f.actions.surround_with_parens(), true)
		f.notify(f.dispatches[1], "dispatched")
		f.timers[1].fire()
		helpers.assert_eq(#f.dispatches, 2,
			"a live refused timer remains the only retry owner")
		f.scheduler.cancel_refusals = 0
		helpers.assert_eq(f.scheduler.cancel(f.timers[2].handle), true)
		helpers.assert_eq(#f.dispatches, 3,
			"exact timer settlement must autonomously recover the closing")
		f.notify(f.dispatches[3], "dispatched")
		helpers.assert_eq(#f.emitted, 4)
		helpers.assert_eq(f.actions.has_pending_text_action(), false)
	end)

	helpers.it("bounds repeated synchronous failures and retains one recovery intent", function()
		local f = fresh_fixture({
			dispatch_modes = {
				"accepted_late", "sync_failed", "sync_failed", "accepted_late",
			},
			timer_modes = { "committed", "settled", "settled", "committed" },
		})
		helpers.assert_eq(f.actions.surround_with_parens(), true)
		f.notify(f.dispatches[1], "dispatched")
		f.timers[1].fire()
		helpers.assert_eq(#f.dispatches, 3,
			"only one immediate fallback may run in the failing callback stack")
		helpers.assert_eq(#f.timers, 3)
		helpers.assert_eq(f.actions.has_pending_text_action(), true)

		helpers.assert_eq(f.actions.pause_text_actions(), false,
			"lifecycle settlement must retain the proven opening until it closes")
		helpers.assert_eq(#f.timers, 4,
			"the retained close intent must acquire one later recovery owner")
		f.timers[4].fire()
		f.notify(f.dispatches[4], "dispatched")
		helpers.assert_eq(#f.emitted, 4)
		helpers.assert_eq(f.actions.pause_text_actions(), true)
		helpers.assert_eq(f.actions.has_pending_text_action(), false)
	end)

	helpers.it("retains exact timer rollback debt after completing both parentheses", function()
		local f = fresh_fixture({ timer_modes = { "debt" } })
		helpers.assert_eq(f.actions.surround_with_parens(), true)
		f.notify(f.dispatches[1], "dispatched")
		f.notify(f.dispatches[2], "dispatched")
		helpers.assert_eq(#f.emitted, 4)
		helpers.assert_eq(f.actions.pause_text_actions(), false)
		f.scheduler.cancel_refusals = 0
		helpers.assert_eq(f.actions.pause_text_actions(), true)
		helpers.assert_eq(f.actions.resume_text_actions(), true)
		helpers.assert_eq(#f.dispatches, 2,
			"settling delayed timer debt may not replay either parenthesis")
	end)
end)


for _, name in ipairs(MUTATED) do package.loaded[name] = nil end
