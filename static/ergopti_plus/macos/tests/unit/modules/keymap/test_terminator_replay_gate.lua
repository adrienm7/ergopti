--- tests/unit/modules/keymap/test_terminator_replay_gate.lua

--- ==============================================================================
--- MODULE: Terminator replay transaction gate
--- DESCRIPTION:
--- Exercises the real SyntheticInput transaction lifecycle used to order a held
--- Enter/Tab/text terminator after its replacement. The failure cases assert the
--- user key stays pending until a complete retry can be constructed; no mutable
--- expected_synthetic_* ledger participates in the proof.
--- ==============================================================================

local helpers = require("tests.helpers")


local function load_gate()
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	for _, name in ipairs({
		"adapters.synthetic_input", "adapters.event_provenance",
		"modules.keymap.terminator_replay",
	}) do
		package.loaded[name] = nil
	end

	local SyntheticInput = require("adapters.synthetic_input")
	local sent = {}
	local timers = {}
	local fail_send = false
	package.loaded["adapters.text_sender"] = {
		pressKey = function(key, _mods, delay)
			if fail_send then return false end
			sent[#sent + 1] = { kind = "key", key = key, delay = delay }
			return true
		end,
		send = function(value, opts)
			if fail_send then return false end
			sent[#sent + 1] = { kind = "text", text = value, mode = opts and opts.mode }
			return true
		end,
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay, callback)
			local handle = {
				delay = delay,
				callback = callback,
				cancelled = false,
				timer = {},
			}
			timers[#timers + 1] = handle
			return handle
		end,
		cancel = function(handle)
			if type(handle) == "table" then
				handle.cancelled = true
				handle.timer = nil
			end
			return true
		end,
	}

	local Replay = require("modules.keymap.terminator_replay")
	Replay.init({})
	return {
		replay = Replay,
		synthetic = SyntheticInput,
		hs = hs_stub,
		sent = sent,
		timers = timers,
		set_send_failure = function(value) fail_send = value == true end,
	}
end


local function fire_timer(fixture, delay)
	local initial_count = #fixture.timers
	for index = 1, initial_count do
		local timer = fixture.timers[index]
		if not timer.cancelled and (delay == nil or timer.delay == delay) then
			timer.cancelled = true
			timer.timer = nil
			timer.callback()
			return true
		end
	end
	return false
end


--- Drains post-eventtap confirmation and lifecycle dispatch in run-loop order.
--- A confirmation can arm the retained lifecycle timer after the stub's first
--- pass has already visited it, so two turns are the minimum faithful model.
local function fire_hs_lifecycle(fixture)
	fixture.hs.timer.__fire_all()
	fixture.hs.timer.__fire_all()
end


local function new_transaction(fixture)
	return fixture.synthetic.begin("replacement-under-test", "replacement")
end


helpers.describe("terminator replay: real transaction ordering", function()
	helpers.it("waits until the replacement callback batch is handed to Quartz", function()
		local fixture = load_gate()
		fixture.synthetic.enter_callback()
		local tx = new_transaction(fixture)
		fixture.synthetic.with_transaction(tx, function()
			fixture.synthetic.emit_key_strokes("UI")
		end)
		fixture.synthetic.seal(tx)

		helpers.assert_true(fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = tx,
		}))
		helpers.assert_eq(#fixture.sent, 0,
			"sealing is not dispatch; Enter must still be held")

		local consume, events = fixture.synthetic.leave_callback(true)
		helpers.assert_true(consume)
		helpers.assert_eq(#events, 4)
		helpers.assert_eq(#fixture.sent, 0,
			"the post-return confirmation fence has not fired yet")
		fire_hs_lifecycle(fixture)

		helpers.assert_eq(#fixture.sent, 1)
		helpers.assert_eq(fixture.sent[1].key, "return")
		helpers.assert_true(not fixture.replay.is_pending())
	end)

	helpers.it("replays exactly once after an already-complete transaction", function()
		local fixture = load_gate()
		local tx = new_transaction(fixture)
		fixture.synthetic.seal(tx)

		helpers.assert_true(fixture.replay.arm({
			kind = "key", key = "tab", chars = "\t", transaction = tx,
		}))
		fire_hs_lifecycle(fixture)
		fixture.replay.flush_if_delivered()
		fixture.replay.flush_if_delivered()

		helpers.assert_eq(#fixture.sent, 1)
		helpers.assert_eq(fixture.sent[1].key, "tab")
	end)

	helpers.it("sends a printable terminator through the direct text path", function()
		local fixture = load_gate()
		local tx = new_transaction(fixture)
		fixture.synthetic.seal(tx)

		fixture.replay.arm({
			kind = "text", chars = " ", transaction = tx,
		})
		fire_hs_lifecycle(fixture)

		helpers.assert_eq(#fixture.sent, 1)
		helpers.assert_eq(fixture.sent[1].kind, "text")
		helpers.assert_eq(fixture.sent[1].text, " ")
		helpers.assert_eq(fixture.sent[1].mode, "direct")
	end)

	helpers.it("waits for both transaction completion and the paste settle fence", function()
		local fixture = load_gate()
		local tx = new_transaction(fixture)
		fixture.synthetic.seal(tx)

		fixture.replay.arm({
			kind = "key", key = "return", chars = "\r",
			transaction = tx, min_delay = 0.08,
		})
		helpers.assert_eq(#fixture.sent, 0)
		fire_hs_lifecycle(fixture)
		helpers.assert_true(fire_timer(fixture, 0.08))
		helpers.assert_eq(#fixture.sent, 1)
		helpers.assert_eq(fixture.sent[1].key, "return")
	end)

	helpers.it("watchdog releases a terminator when replacement completion is lost", function()
		local fixture = load_gate()
		local tx = new_transaction(fixture)
		fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = tx,
		})

		helpers.assert_eq(#fixture.sent, 0)
		helpers.assert_true(fire_timer(fixture, 0.25))
		helpers.assert_eq(#fixture.sent, 1)
		helpers.assert_true(not fixture.replay.is_pending())
		fixture.synthetic.cancel(tx)
	end)

	helpers.it("discard makes queued watchdog, fence, and completion callbacks inert", function()
		local fixture = load_gate()
		local tx = new_transaction(fixture)
		fixture.replay.arm({
			kind = "key", key = "return", chars = "\r",
			transaction = tx, min_delay = 0.08,
		})

		local watchdog = fixture.timers[1]
		local fence = fixture.timers[2]
		helpers.assert_not_nil(watchdog, "arm must retain the watchdog callback")
		helpers.assert_not_nil(fence, "a delayed replay must retain the settle-fence callback")
		helpers.assert_true(fixture.replay.is_pending())

		fixture.replay.discard_pending("window context changed")
		helpers.assert_true(not fixture.replay.is_pending(),
			"discard must relinquish the consumed terminator immediately")

		-- Model callbacks that were already queued by the native run loop before
		-- cancellation settled. They must reject the discarded pending identity even
		-- when invoked directly, rather than relying only on timer:stop().
		watchdog.callback()
		fence.callback()
		fixture.synthetic.seal(tx)
		fire_hs_lifecycle(fixture)

		helpers.assert_eq(#fixture.sent, 0,
			"no stale watchdog, fence, or completion may replay a discarded key")
		helpers.assert_true(not fixture.replay.is_pending(),
			"stale callbacks must not resurrect discarded ownership")
	end)
end)


helpers.describe("terminator replay: construction failures never drop the key", function()
	helpers.it("keeps Enter pending and retries after TextSender recovers", function()
		local fixture = load_gate()
		local tx = new_transaction(fixture)
		fixture.synthetic.seal(tx)
		fixture.set_send_failure(true)

		helpers.assert_true(fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = tx,
		}))
		fire_hs_lifecycle(fixture)
		helpers.assert_eq(#fixture.sent, 0)
		helpers.assert_true(fixture.replay.is_pending(),
			"failed construction must retain ownership of the consumed physical key")
		helpers.assert_eq(fixture.synthetic.stats().active_transactions, 0,
			"the failed replay transaction must be cancelled, not leaked")

		fixture.set_send_failure(false)
		helpers.assert_true(fire_timer(fixture, 0.05))
		helpers.assert_eq(#fixture.sent, 1)
		helpers.assert_eq(fixture.sent[1].key, "return")
		helpers.assert_true(not fixture.replay.is_pending())
	end)

	helpers.it("does not overwrite an older terminator that still cannot be emitted", function()
		local fixture = load_gate()
		local first_tx = new_transaction(fixture)
		local second_tx = new_transaction(fixture)
		fixture.set_send_failure(true)
		fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = first_tx,
		})

		helpers.assert_true(not fixture.replay.arm({
			kind = "text", chars = " ", transaction = second_tx,
		}))
		helpers.assert_true(fixture.replay.is_pending())
		helpers.assert_eq(#fixture.sent, 0)
		fixture.synthetic.cancel(first_tx)
		fixture.synthetic.cancel(second_tx)
	end)

	helpers.it("flush_now reports failure while preserving a retryable pending key", function()
		local fixture = load_gate()
		local tx = new_transaction(fixture)
		fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = tx,
		})
		fixture.set_send_failure(true)

		helpers.assert_true(not fixture.replay.flush_now("teardown"))
		helpers.assert_true(fixture.replay.is_pending())
		helpers.assert_eq(#fixture.sent, 0)
		fixture.synthetic.cancel(tx)
	end)
end)


helpers.describe("terminator replay: malformed requests fail closed", function()
	helpers.it("rejects missing characters, key names and unknown kinds", function()
		local fixture = load_gate()
		helpers.assert_true(not fixture.replay.arm({ kind = "key", key = "return", chars = "" }))
		helpers.assert_true(not fixture.replay.arm({ kind = "key", chars = "\r" }))
		helpers.assert_true(not fixture.replay.arm({ kind = "chord", chars = "\r" }))
		helpers.assert_true(not fixture.replay.is_pending())
	end)

	helpers.it("replays immediately but reports a missing replacement transaction", function()
		local fixture = load_gate()
		helpers.assert_true(not fixture.replay.arm({
			kind = "key", key = "return", chars = "\r",
		}))
		helpers.assert_eq(#fixture.sent, 1,
			"caller misuse must not cost the user their Enter")
		helpers.assert_true(not fixture.replay.is_pending())
	end)
end)


package.loaded["adapters.text_sender"] = nil
package.loaded["adapters.timer_scheduler"] = nil
package.loaded["adapters.synthetic_input"] = nil
package.loaded["adapters.event_provenance"] = nil
package.loaded["modules.keymap.terminator_replay"] = nil
