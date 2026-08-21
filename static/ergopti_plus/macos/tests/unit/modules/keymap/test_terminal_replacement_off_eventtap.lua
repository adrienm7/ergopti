--- tests/unit/modules/keymap/test_terminal_replacement_off_eventtap.lua

--- ==============================================================================
--- MODULE: Terminal Replacement Commit Boundary Tests
--- DESCRIPTION:
--- Proves that terminal pacing owns and authorizes every fallible resource while
--- output is reversible, then publishes buffer and guaranteed serializer state.
--- Fallible telemetry runs only after that irreversible in-memory boundary and
--- cannot roll back output the engine already accepted.
--- A refused seal must leave every later side effect and serializer untouched.
--- ==============================================================================

local helpers = require("tests.helpers")
local SyntheticStack = require("tests.support.synthetic_input_stack")
local ApplyPredictionFixture = require("tests.support.apply_prediction_fixture")


local function make_state()
	local state = {
		buffer = "xgboost",
		magic_key = "star",
		repeat_enabled = true,
	}
	function state.is_repeat_feature_enabled() return state.repeat_enabled end
	function state.suppress_rescan() end
	return state
end


local function make_llm()
	return {
		update_preview = function() end,
		get_llm_enabled = function() return false end,
		start_timer = function() end,
	}
end


--- Loads the real expander and synthetic builder around controllable commit seams.
--- @param seal_result boolean Exact result returned by SyntheticInput.seal().
--- @param body function function(fixture).
local function with_fixture(seal_result, body)
	local trace = {}
	local previous_keylogger = package.loaded["modules.keylogger"]
	local previous_timings = package.loaded["infra.timings"]
	package.loaded["modules.keylogger"] = {
		notify_synthetic = function()
			trace[#trace + 1] = "telemetry"
		end,
		set_buffer = function()
			trace[#trace + 1] = "keylogger-buffer"
		end,
	}
	package.loaded["infra.timings"] = {
		ms = function() return 12 end,
	}

	local loaded_ok, expander_or_err, synthetic = pcall(function()
		local expander, adapter = SyntheticStack.load("modules.keymap.expander")
		return expander, adapter
	end)
	package.loaded["modules.keylogger"] = previous_keylogger
	package.loaded["infra.timings"] = previous_timings
	if not loaded_ok then error(expander_or_err, 0) end
	local expander = expander_or_err
	local text_sender = require("adapters.text_sender")
	local target = { id = "terminal-app" }

	local originals = {
		prepare = synthetic.prepare_collected_paced,
		budget = synthetic.paced_settlement_budget,
		authorize = synthetic.authorize_collected_paced,
		commit = synthetic.commit_collected_paced,
		deliver = synthetic.deliver_collected_paced,
		seal = synthetic.seal,
		cancel = synthetic.cancel,
		target = text_sender.terminalInputTarget,
	}
	local owner = { id = "prepared-terminal-owner" }
	local cancelled = 0
	synthetic.prepare_collected_paced = function()
		trace[#trace + 1] = "prepare"
		return owner
	end
	synthetic.paced_settlement_budget = function(received)
		helpers.assert_true(received == owner)
		return 0.12
	end
	synthetic.authorize_collected_paced = function(received)
		helpers.assert_true(received == owner)
		trace[#trace + 1] = "authorize"
		return true
	end
	synthetic.commit_collected_paced = function(received)
		helpers.assert_true(received == owner)
		trace[#trace + 1] = "commit"
		return true
	end
	-- The pre-fix one-phase API is retained only in this red fixture so the test
	-- fails on ordering, not because a future API does not exist yet.
	synthetic.deliver_collected_paced = function()
		trace[#trace + 1] = "commit"
		return true
	end
	synthetic.seal = function(tx)
		trace[#trace + 1] = "seal"
		if seal_result ~= true then return seal_result end
		return originals.seal(tx)
	end
	synthetic.cancel = function(tx)
		cancelled = cancelled + 1
		return originals.cancel(tx)
	end
	text_sender.terminalInputTarget = function() return target end

	local outcome = table.pack(xpcall(function()
		local state = make_state()
		helpers.assert_true(expander.init(state, {}, make_llm()))
		synthetic.enter_callback()
		local replaced, tx = expander.perform_text_replacement(
			8,
			function()
				synthetic.emit_key_strokes("XGBoost")
				return 7, "XGBoost"
			end,
			function()
				trace[#trace + 1] = "buffer"
				state.buffer = "XGBoost"
			end,
			false, false, "hotstring", "terminal-order"
		)
		body({
			trace = trace,
			replaced = replaced,
			transaction = tx,
			cancelled = function() return cancelled end,
		})
		if synthetic.abort_callback then synthetic.abort_callback() end
	end, debug.traceback))

	synthetic.prepare_collected_paced = originals.prepare
	synthetic.paced_settlement_budget = originals.budget
	synthetic.authorize_collected_paced = originals.authorize
	synthetic.commit_collected_paced = originals.commit
	synthetic.deliver_collected_paced = originals.deliver
	synthetic.seal = originals.seal
	synthetic.cancel = originals.cancel
	text_sender.terminalInputTarget = originals.target
	if not outcome[1] then error(outcome[2], 0) end
end


helpers.describe("keymap.expander: terminal replacement commit boundary", function()
	helpers.it("commits pacing after exact seal and buffer but before fallible telemetry", function()
		with_fixture(true, function(fixture)
			helpers.assert_true(fixture.replaced)
			helpers.assert_eq(table.concat(fixture.trace, ","),
				"prepare,seal,authorize,buffer,commit,telemetry,keylogger-buffer",
				"the guaranteed serializer commit must precede fallible telemetry")
			helpers.assert_eq(fixture.cancelled(), 0)
		end)
	end)

	helpers.it("treats a false seal result as a refused transaction", function()
		with_fixture(false, function(fixture)
			helpers.assert_true(not fixture.replaced)
			helpers.assert_eq(table.concat(fixture.trace, ","), "prepare,seal",
				"a refused seal must precede and veto buffer, telemetry, and delivery")
			helpers.assert_eq(fixture.cancelled(), 1)
		end)
	end)

	helpers.it("acquires terminator replay before committing a paced terminal replacement", function()
		local expander, synthetic = SyntheticStack.load("modules.keymap.expander")
		local text_sender = require("adapters.text_sender")
		local timer_scheduler = require("adapters.timer_scheduler")
		local terminator_replay = require("modules.keymap.terminator_replay")
		local target = { id = "terminal-app" }
		local original_target = text_sender.terminalInputTarget
		local original_after = timer_scheduler.after
		local original_commit = synthetic.commit_collected_paced
		local paced_commits = 0
		text_sender.terminalInputTarget = function() return target end
		timer_scheduler.after = function() return nil, false end
		synthetic.commit_collected_paced = function(owner)
			paced_commits = paced_commits + 1
			return original_commit(owner)
		end

		local ok_body, body_error = xpcall(function()
			local state = make_state()
			helpers.assert_true(terminator_replay.init(state))
			helpers.assert_true(expander.init(state, {}, make_llm()))
			synthetic.enter_callback()
			local replaced = expander.perform_text_replacement(
				8,
				function()
					synthetic.emit_key_strokes("XGBoost")
					return 7, "XGBoost", "XGBoost", 0.02
				end,
				function() state.buffer = "XGBoost" end,
				false, false, "hotstring", "terminal-terminator-refusal", false,
				{ kind = "key", key = "return", chars = "\r", modifiers = {} }
			)
			local consume, events = synthetic.leave_callback(replaced)
			helpers.assert_true(not replaced,
				"the physical terminator must pass through when replay ownership is refused")
			helpers.assert_true(not consume)
			helpers.assert_nil(events,
				"no delete/paste prefix may escape without the terminator owner")
			helpers.assert_eq(state.buffer, "xgboost")
			helpers.assert_eq(paced_commits, 0,
				"paced ownership must remain reversible until replay timers commit")
			helpers.assert_eq(synthetic.stats().pending, 0)
		end, debug.traceback)

		text_sender.terminalInputTarget = original_target
		timer_scheduler.after = original_after
		synthetic.commit_collected_paced = original_commit
		if not ok_body then error(body_error, 0) end
	end)

	helpers.it("orders deferred tooltip paste and F16 behind all paced terminal deletes", function()
		local completion = ("p"):rep(60)
		local result = ApplyPredictionFixture.run({
			text = completion,
			buffer = "abcdefgh",
			deletes = 8,
			terminal = true,
			invoke_tooltip = true,
			settle = false,
			pace_ms = 20,
		})
		helpers.assert_true(result.call_ok and result.applied,
			"the real tooltip callback must accept without an ambient eventtap collector")
		helpers.assert_nil(result.events,
			"deferred tooltip output is globally serialized, never callback-returned")
		helpers.assert_eq(#result.posted_events, 0,
			"no irreversible native post may occur inside tooltip acceptance")
		helpers.assert_eq(result.arm_chain_before_completion, 0)

		local previous_posts = 0
		local guard = 0
		while #result.posted_events < 16 do
			local delay = result.fire_next_timer()
			helpers.assert_not_nil(delay, "paced replacement lost its pre-acquired wake")
			local delta = #result.posted_events - previous_posts
			helpers.assert_true(delta <= 2,
				"one run-loop turn may post at most one terminal delete pair")
			if delta > 0 then
				helpers.assert_eq(delta, 2)
				helpers.assert_eq(result.posted_events[previous_posts + 1].key, "delete")
				helpers.assert_eq(result.posted_events[previous_posts + 2].key, "delete")
			end
			previous_posts = #result.posted_events
			guard = guard + 1
			helpers.assert_true(guard < 80, "terminal deletes did not settle")
		end
		helpers.assert_eq(result.arm_chain_count_now(), 0,
			"F16 must remain unarmed while any replacement suffix is pending")

		while #result.posted_events < 18 do
			helpers.assert_not_nil(result.fire_next_timer())
			guard = guard + 1
			helpers.assert_true(guard < 100, "Cmd+V did not settle")
		end
		for index = 1, 18 do
			helpers.assert_true(result.posted_events[index].app == result.terminal_target)
		end
		helpers.assert_eq(result.posted_events[17].key, "v")
		helpers.assert_eq(result.posted_events[18].key, "v")
		helpers.assert_eq(result.posted_events[17].clipboard, completion,
			"the replacement clipboard must remain owned at the actual Cmd+V handoff")
		helpers.assert_eq(result.posted_events[17].restores, 0,
			"eight paced delete turns must not let the wall clock restore early")

		while #result.posted_events < 20 do
			helpers.assert_not_nil(result.fire_next_timer())
			guard = guard + 1
			helpers.assert_true(guard < 140, "F16 chain signal did not settle")
		end
		helpers.assert_eq(result.posted_events[19].key, "f16")
		helpers.assert_eq(result.posted_events[20].key, "f16")
		helpers.assert_eq(result.arm_chain_count_now(), 1)
		helpers.assert_true(result.posted_events[19].app == nil,
			"the post-completion loopback remains global")

		while result.clipboard_restores() == 0 do
			helpers.assert_not_nil(result.fire_next_timer())
			guard = guard + 1
			helpers.assert_true(guard < 180, "clipboard restore did not settle")
		end
		helpers.assert_eq(result.clipboard_value(), "original")
	end)

	helpers.it("keeps Enter behind a paced plan longer than the base watchdog margin", function()
		local previous_keylogger = package.loaded["modules.keylogger"]
		package.loaded["modules.keylogger"] = {
			notify_synthetic = function() end,
			set_buffer = function() end,
		}
		-- Install a faithful post observer before SyntheticInput captures the native
		-- constructor. The double distinguishes target post(app) from global post().
		package.loaded["tests.stubs.hs"] = nil
		local event_hs = require("tests.stubs.hs")
		event_hs.__reset()
		local posted = {}
		local native_new_key_event = event_hs.eventtap.event.newKeyEvent
		event_hs.eventtap.event.newKeyEvent = function(modifiers, key, is_down)
			local event = native_new_key_event(modifiers, key, is_down)
			local native_post = event.post
			event.post = function(self, app)
				if self.isDown then
					posted[#posted + 1] = { key = self.key, text = self.unicode, app = app }
				end
				return native_post(self, app)
			end
			return event
		end
		local expander, synthetic = SyntheticStack.load("modules.keymap.expander", {
			eventtap = event_hs.eventtap,
		})
		package.loaded["modules.keylogger"] = previous_keylogger
		local text_sender = require("adapters.text_sender")
		local replay = require("modules.keymap.terminator_replay")
		local original_target = text_sender.terminalInputTarget
		local original_prepare = synthetic.prepare_collected_paced
		local terminal_target = { id = "long-terminal-app" }
		local paced_owner = nil
		text_sender.terminalInputTarget = function() return terminal_target end
		synthetic.prepare_collected_paced = function(...)
			paced_owner = original_prepare(...)
			return paced_owner
		end

		local outcome = table.pack(xpcall(function()
			local state = make_state()
			helpers.assert_true(replay.init(state))
			helpers.assert_true(expander.init(state, {}, make_llm()))
			synthetic.enter_callback()
			local deletes = 20
			local replaced, transaction = expander.perform_text_replacement(
				deletes,
				function()
					synthetic.emit_key_strokes("done")
					return 4, "done", "done", 0
				end,
				function() state.buffer = "done" end,
				false, false, "hotstring", "terminal-long-watchdog", false,
				{ kind = "key", key = "return", chars = "\r", modifiers = {} }
			)
			local consume, events = synthetic.leave_callback(replaced)
			helpers.assert_true(replaced and consume)
			helpers.assert_nil(events,
				"a paced terminal batch must remain globally owned after callback return")
			local drained = 0
			helpers.assert_true(synthetic.when_idle(function() drained = drained + 1 end))
			helpers.assert_eq(drained, 0,
				"pause/reload/quit must wait for replacement and reserved Enter")
			helpers.assert_not_nil(paced_owner)
			local expected_budget = (deletes + synthetic.PACED_TRAILING_TICKS)
				* paced_owner.delay_sec
			helpers.assert_true(math.abs(
				synthetic.paced_settlement_budget(paced_owner) - expected_budget) < 0.000001)

			local watchdog = nil
			for _, timer in ipairs(hs.timer.__timers) do
				if timer.running and timer.delay > expected_budget then watchdog = timer break end
			end
			helpers.assert_not_nil(watchdog,
				"terminator ownership must include a watchdog beyond the paced plan")
			helpers.assert_true(math.abs(watchdog.delay - (expected_budget + 0.25)) < 0.000001,
				"the canonical watchdog margin starts after the immutable paced budget")

			for _ = 1, 13 do paced_owner.timer:fire() end
			helpers.assert_true(not transaction.completed)
			helpers.assert_true(replay.is_pending(),
				"the physical Enter must remain owned after the old 250ms deadline")
			helpers.assert_eq(synthetic.stats().pending, 2,
				"replacement and its already-reserved terminator are both drain-visible")

			local physical_x = hs.eventtap.event.newKeyEvent({}, "x", true)
			physical_x.copy = function(self)
				return hs.eventtap.event.newKeyEvent(self.mods, self.key, self.isDown)
			end
			local physical_fence = synthetic.claim_physical_fence(physical_x)
			helpers.assert_not_nil(physical_fence)
			helpers.assert_true(physical_fence.consume_original,
				"x typed during pacing must be retained behind the reserved Enter")
			helpers.assert_eq(synthetic.stats().pending, 3)

			for _ = 14, deletes + synthetic.PACED_TRAILING_TICKS do
				paced_owner.timer:fire()
			end
			helpers.assert_true(transaction.completed,
				"the transaction becomes terminal only after the serializer settlement tick")
			helpers.assert_eq(drained, 0,
				"replacement completion alone cannot bypass Enter or retained physical input")
			helpers.assert_true(replay.is_pending(),
				"completion opens the reserved slot but posting stays off the callback stack")
			helpers.assert_eq(synthetic.stats().pending, 2)
			for _ = 1, 6 do hs.timer.__fire_all() end
			helpers.assert_true(not replay.is_pending())
			helpers.assert_eq(synthetic.stats().pending, 0)
			helpers.assert_eq(drained, 1,
				"the global drain opens once after Enter and the physical suffix settle")
			helpers.assert_true(#posted >= 2)
			helpers.assert_eq(posted[#posted - 1].key, "return")
			helpers.assert_true(posted[#posted - 1].app == terminal_target,
				"the reserved Enter keeps the exact terminal target")
			helpers.assert_eq(posted[#posted].key, "x",
				"replacement -> Enter -> physical x is the immutable FIFO order")
			helpers.assert_true(posted[#posted].app == nil,
				"physical replay must be global so every tap observes it")
		end, debug.traceback))

		synthetic.prepare_collected_paced = original_prepare
		text_sender.terminalInputTarget = original_target
		if not outcome[1] then error(outcome[2], 0) end
	end)
end)
