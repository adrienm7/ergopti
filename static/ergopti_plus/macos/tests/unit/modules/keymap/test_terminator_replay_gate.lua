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


local function load_gate(options)
	options = options or {}
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	for _, name in ipairs({
		"adapters.timer_scheduler", "adapters.synthetic_input", "adapters.event_provenance",
		"modules.keymap.terminator_replay",
	}) do
		package.loaded[name] = nil
	end

	local sent = {}
	local post_attempts = 0
	local posted_trigger = nil
	local native_new_key_event = hs_stub.eventtap.event.newKeyEvent
	hs_stub.eventtap.event.newKeyEvent = function(modifiers, key, is_down)
		local event = native_new_key_event(modifiers, key, is_down)
		local native_post = event.post
		event.post = function(self, app)
			post_attempts = post_attempts + 1
			if options.key_post_always_throws then error("reserved post exploded") end
			if self.isDown then
				if self.unicode and self.unicode ~= "" then
					sent[#sent + 1] = { kind = "text", text = self.unicode, mode = "direct", app = app }
				else
					sent[#sent + 1] = { kind = "key", key = self.key, delay = 0, app = app }
				end
			end
			return native_post(self, app)
		end
		return event
	end
	local native_new_mouse_event = hs_stub.eventtap.event.newMouseEvent
	hs_stub.eventtap.event.newMouseEvent = function(event_type, position, modifiers)
		local event = native_new_mouse_event(event_type, position, modifiers)
		local native_post = event.post
		event.post = function(self, app)
			posted_trigger = self
			return native_post(self, app)
		end
		return event
	end
	local SyntheticInput = require("adapters.synthetic_input")
	local timers = {}
	local timer_calls = 0
	local fail_send = false
	package.loaded["adapters.text_sender"] = {
		pressKey = function(key, _mods, delay)
			if fail_send then return false end
			return SyntheticInput.emit_key_stroke({}, key, delay or 0)
		end,
		send = function(value, opts)
			if fail_send then return false end
			return SyntheticInput.emit_key_strokes(value)
		end,
	}
	local function schedule_timer(delay, callback, recurring)
		timer_calls = timer_calls + 1
		local call_index = timer_calls
		local handle = {
			delay = delay,
			callback = callback,
			cancelled = false,
			recurring = recurring == true,
			timer = {},
		}
		timers[#timers + 1] = handle
		if options.reject_timer_at == call_index then
			handle.timer = nil
			handle.cancelled = true
			return handle, false
		end
		return handle, true
	end
	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay, callback)
			return schedule_timer(delay, callback, false)
		end,
		every = function(delay, callback)
			return schedule_timer(delay, callback, true)
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
		post_attempts = function() return post_attempts end,
		drain_deferred = function()
			local broker = hs_stub.timer.__timers[#hs_stub.timer.__timers]
			assert(broker and broker.running,
				"terminator fallback did not schedule its deferred broker")
			broker:fire()
			assert(posted_trigger ~= nil,
				"terminator fallback broker did not post its tagged trigger")
			local pump = nil
			for _, tap in ipairs(hs_stub.eventtap.__taps) do
				if tap.types and tap.types[1] == hs_stub.eventtap.event.types.otherMouseUp then
					pump = tap
					break
				end
			end
			assert(pump ~= nil, "terminator fallback synthetic pump was not created")
			local consume, events = pump.fn(posted_trigger)
			posted_trigger = nil
			hs_stub.timer.__fire_all()
			return consume, events
		end,
	}
end


local function fire_timer(fixture, delay)
	local initial_count = #fixture.timers
	for index = 1, initial_count do
		local timer = fixture.timers[index]
		if not timer.cancelled and (delay == nil or timer.delay == delay) then
			if not timer.recurring then
				timer.cancelled = true
				timer.timer = nil
			end
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
	-- One turn can settle the predecessor and open the reserved successor, a
	-- second posts it, and a third settles its transaction. Keep one extra turn
	-- to prove every recurring owner has become inert after exact completion.
	for _ = 1, 4 do fixture.hs.timer.__fire_all() end
end


local function new_transaction(fixture)
	return fixture.synthetic.begin("replacement-under-test", "replacement")
end


local function capture_replay_errors(callback)
	local Logger = require("infra.logger")
	local original_error = Logger.error
	local errors = {}
	Logger.error = function(log, format_string, ...)
		if log == "keymap.terminator_replay" then
			errors[#errors + 1] = string.format(format_string, ...)
		end
	end
	local outcome = table.pack(xpcall(function() callback(errors) end, debug.traceback))
	Logger.error = original_error
	if not outcome[1] then error(outcome[2], 0) end
	return errors
end


local function count_failed_terminator_errors(errors)
	local count = 0
	for _, message in ipairs(errors) do
		if message:find("Held terminator", 1, true)
			and message:find("failed", 1, true) then
			count = count + 1
		end
	end
	return count
end


--- Replaces one named module upvalue for an otherwise unreachable hardening path.
--- @param fn function Closure that owns the upvalue.
--- @param target string Upvalue name.
--- @param value any Replacement value.
local function set_upvalue(fn, target, value)
	for index = 1, math.huge do
		local name = debug.getupvalue(fn, index)
		if name == nil then break end
		if name == target then
			debug.setupvalue(fn, index, value)
			return true
		end
	end
	return false
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

	helpers.it("reports a held terminator dropped after replacement failure", function()
		local fixture = load_gate()
		local errors = capture_replay_errors(function()
			local tx = new_transaction(fixture)
			local producer = fixture.synthetic.retain(tx)
			helpers.assert_true(fixture.synthetic.seal(tx))
			helpers.assert_true(fixture.replay.arm({
				kind = "key", key = "return", chars = "\r", transaction = tx,
			}), "the physical Enter must be owned before the replacement fails")

			helpers.assert_true(fixture.synthetic.fail(tx, "paced target refused output"))
			helpers.assert_true(fixture.synthetic.release(tx, producer))
			fire_hs_lifecycle(fixture)

			helpers.assert_eq(tx.completion_status, "failed")
			helpers.assert_true(not fixture.replay.is_pending(),
				"an unsafe replay must release its reservation after the failed replacement")
			helpers.assert_eq(#fixture.sent, 0,
				"submitting a partially replaced line would be more destructive than dropping Enter")
		end)
		helpers.assert_eq(count_failed_terminator_errors(errors), 1,
			"the consumed Enter loss must have one terminator-specific ERROR")
	end)

	helpers.it("reports the same loss when the replacement completion callback is lost", function()
		local fixture = load_gate()
		local errors = capture_replay_errors(function()
			local tx = new_transaction(fixture)
			local producer = fixture.synthetic.retain(tx)
			helpers.assert_true(fixture.synthetic.seal(tx))
			helpers.assert_true(fixture.replay.arm({
				kind = "key", key = "return", chars = "\r", transaction = tx,
			}))

			-- Model complete loss of the adapter's deferred completion delivery. The
			-- recurring watchdog must still surface the consumed key loss from the
			-- transaction's immutable terminal fields.
			tx.complete_callbacks = {}
			helpers.assert_true(fixture.synthetic.fail(tx, "paced target refused output"))
			helpers.assert_true(fixture.synthetic.release(tx, producer))
			helpers.assert_eq(tx.completion_status, "failed")
			helpers.assert_true(fixture.replay.is_pending())
			helpers.assert_true(fire_timer(fixture, 0.25))

			helpers.assert_true(not fixture.replay.is_pending())
			helpers.assert_eq(#fixture.sent, 0)
		end)
		helpers.assert_eq(count_failed_terminator_errors(errors), 1,
			"the watchdog must emit the same terminator-specific ERROR exactly once")
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
		fire_hs_lifecycle(fixture)
		helpers.assert_eq(#fixture.sent, 1)
		helpers.assert_eq(fixture.sent[1].key, "return")
	end)

	helpers.it("starts a Terminal paste settle window after its paced dispatch plan", function()
		local fixture = load_gate()
		local tx = new_transaction(fixture)
		fixture.synthetic.seal(tx)

		helpers.assert_true(fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = tx,
			min_delay = 0.08, dispatch_budget = 0.44,
		}))
		fire_hs_lifecycle(fixture)
		helpers.assert_eq(#fixture.sent, 0)
		helpers.assert_true(not fire_timer(fixture, 0.08),
			"the paste settle window must not run concurrently with paced deletes")
		helpers.assert_true(fire_timer(fixture, 0.52))
		fire_hs_lifecycle(fixture)
		helpers.assert_eq(#fixture.sent, 1)
		helpers.assert_eq(fixture.sent[1].key, "return")
	end)

	helpers.it("watchdog repairs a lost callback only after transaction completion", function()
		local fixture = load_gate()
		local tx = new_transaction(fixture)
		fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = tx,
		})

		helpers.assert_eq(#fixture.sent, 0)
		fixture.synthetic.seal(tx)
		helpers.assert_true(fire_timer(fixture, 0.25))
		fire_hs_lifecycle(fixture)
		helpers.assert_eq(#fixture.sent, 1)
		helpers.assert_true(not fixture.replay.is_pending())
	end)

	helpers.it("never lets a planned watchdog overtake an unfinished paced transaction", function()
		local fixture = load_gate()
		local tx = new_transaction(fixture)
		helpers.assert_true(fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = tx,
			dispatch_budget = 0.44,
		}))
		local watchdog_delay = fixture.timers[1].delay
		helpers.assert_true(math.abs(watchdog_delay - 0.69) < 0.000001,
			"the canonical 250ms margin must start after the immutable paced plan")
		helpers.assert_true(fire_timer(fixture, watchdog_delay))
		helpers.assert_eq(#fixture.sent, 0,
			"a timer cannot authorize Enter while replacement output is non-terminal")
		helpers.assert_true(fixture.replay.is_pending(),
			"the consumed physical terminator remains owned until exact settlement")
		fixture.synthetic.cancel(tx)
		fire_hs_lifecycle(fixture)
		helpers.assert_true(not fixture.replay.is_pending())
	end)

	helpers.it("keeps the same watchdog autonomous after an early tick and lost completion wake", function()
		local fixture = load_gate()
		local tx = new_transaction(fixture)
		local retain = fixture.synthetic.retain(tx)
		helpers.assert_true(fixture.synthetic.seal(tx))
		helpers.assert_true(fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = tx,
		}))
		local watchdog = fixture.timers[1]
		helpers.assert_true(watchdog.recurring,
			"liveness must belong to one recurring native owner")
		helpers.assert_true(fire_timer(fixture, 0.25))
		helpers.assert_eq(#fixture.sent, 0)
		helpers.assert_true(not watchdog.cancelled,
			"an early watchdog tick must retain its autonomous owner")

		-- Model total loss of the predecessor's post-eventtap completion callback.
		-- Transaction terminal fields are still the adapter's exact source of truth.
		tx.complete_callbacks = {}
		helpers.assert_true(fixture.synthetic.release(tx, retain))
		helpers.assert_eq(tx.completion_status, "complete")
		helpers.assert_true(fire_timer(fixture, 0.25),
			"the original recurring owner must observe terminal truth without rearm")
		fire_hs_lifecycle(fixture)
		helpers.assert_eq(#fixture.sent, 1)
		helpers.assert_eq(fixture.sent[1].key, "return")
		helpers.assert_true(watchdog.cancelled,
			"exact replay must retire the original watchdog owner")
		helpers.assert_true(not fixture.replay.is_pending())
	end)

	helpers.it("passes the physical terminator when watchdog acquisition is refused", function()
		local fixture = load_gate({ reject_timer_at = 1 })
		local tx = new_transaction(fixture)
		fixture.synthetic.seal(tx)

		helpers.assert_true(not fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = tx,
		}), "without a watchdog the module must not claim ownership of Enter")
		helpers.assert_true(not fixture.replay.is_pending())
		helpers.assert_eq(#fixture.sent, 0,
			"failure before commit must not synthesize a second terminator")
	end)

	helpers.it("rolls back the watchdog when the paste settle fence is refused", function()
		local fixture = load_gate({ reject_timer_at = 2 })
		local tx = new_transaction(fixture)
		fixture.synthetic.seal(tx)

		helpers.assert_true(not fixture.replay.arm({
			kind = "key", key = "return", chars = "\r",
			transaction = tx, min_delay = 0.08,
		}), "both timers must commit before the physical key is owned")
		helpers.assert_true(not fixture.replay.is_pending())
		helpers.assert_true(fixture.timers[1].cancelled,
			"fence refusal must cancel the exact watchdog candidate")
		fixture.timers[1].callback()
		helpers.assert_eq(#fixture.sent, 0,
			"a queued callback from rolled-back acquisition must remain identity-fenced")
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

	helpers.it("fails a permanently refused reserved Enter and releases the drain", function()
		local fixture = load_gate({ key_post_always_throws = true })
		local tx = new_transaction(fixture)
		fixture.synthetic.seal(tx)
		helpers.assert_true(fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = tx,
		}))
		local drained = 0
		helpers.assert_true(fixture.synthetic.when_idle(function() drained = drained + 1 end))

		for _ = 1, 20 do fixture.hs.timer.__fire_all() end
		helpers.assert_eq(fixture.post_attempts(), fixture.synthetic.SERIAL_POST_MAX_ATTEMPTS,
			"the exact Enter ordinal must have a finite native retry budget")
		helpers.assert_eq(#fixture.sent, 0)
		helpers.assert_true(not fixture.replay.is_pending(),
			"terminal failure must not strand an invisible replay owner")
		helpers.assert_eq(fixture.synthetic.stats().active_transactions, 0)
		helpers.assert_eq(drained, 1,
			"pause/reload/quit must receive one terminal drain callback")
	end)
end)


helpers.describe("terminator replay: construction refusal never consumes the key", function()
	local seal_refusals = {
		{ name = "false", refuse = function() return false end },
		{ name = "nil", refuse = function() return nil end },
		{ name = "truthy non-contract value", refuse = function() return "sealed" end },
		{ name = "throw", refuse = function() error("seal exploded") end },
	}

	for _, refusal in ipairs(seal_refusals) do
		helpers.it("keeps the fallback owner private when seal returns " .. refusal.name, function()
			local fixture = load_gate()
			local original_seal = fixture.synthetic.seal
			local original_cancel = fixture.synthetic.cancel
			local original_reserve = fixture.synthetic.prepare_reserved_successor
			local seal_attempts = 0
			local cancellations = 0
			local reservations = 0
			local refusing = true
			fixture.synthetic.seal = function(tx)
				seal_attempts = seal_attempts + 1
				if refusing then return refusal.refuse() end
				return original_seal(tx)
			end
			fixture.synthetic.cancel = function(tx)
				cancellations = cancellations + 1
				return original_cancel(tx)
			end
			fixture.synthetic.prepare_reserved_successor = function(...)
				reservations = reservations + 1
				return original_reserve(...)
			end

			local outcome = table.pack(xpcall(function()
				-- Stock prepare() always returns a reserved successor. Injecting the
				-- unreserved fallback owner keeps this non-reachable hardening contract
				-- executable without inventing a production-facing test seam.
				helpers.assert_true(set_upvalue(fixture.replay.is_pending, "_pending", {
					kind = "key", key = "return", chars = "\r",
				}), "the fixture must reach the module's exact pending owner")

				helpers.assert_true(not fixture.replay.flush_now("seal refusal"),
					"only literal true may publish a constructed replay")
				helpers.assert_true(fixture.replay.is_pending(),
					"a refused seal must retain the same logical terminator for retry")
				helpers.assert_eq(seal_attempts, 1)
				helpers.assert_eq(cancellations, 1,
					"the refused private transaction must be cancelled exactly once")
				helpers.assert_eq(reservations, 0,
					"the fallback must not create or publish a reserved successor")
				helpers.assert_eq(fixture.post_attempts(), 0,
					"no native event may escape after seal refusal")
				helpers.assert_eq(fixture.synthetic.stats().pending, 0,
					"the refused synthetic batch must leave no FIFO publication")
				helpers.assert_eq(#fixture.timers, 1,
					"one refusal must acquire exactly one bounded retry")
				helpers.assert_true(math.abs(fixture.timers[1].delay - 0.05) < 0.000001)

				refusing = false
				helpers.assert_true(fire_timer(fixture, 0.05))
				helpers.assert_true(not fixture.replay.is_pending(),
					"one exact-true retry must commit the retained terminator")
				local consume, events = fixture.drain_deferred()
				helpers.assert_true(consume,
					"the synthetic pump must consume its private broker trigger")
				helpers.assert_eq(#events, 2,
					"recovery must return exactly one terminator key pair to Quartz")
				helpers.assert_eq(events[1].key, "return")
				helpers.assert_true(events[1].isDown)
				helpers.assert_true(not events[2].isDown)
				helpers.assert_eq(seal_attempts, 2)
				helpers.assert_eq(cancellations, 1)
				helpers.assert_eq(reservations, 0)
				helpers.assert_eq(fixture.synthetic.stats().pending, 0,
					"the callback-returned key pair must release FIFO ownership")
				helpers.assert_eq(fixture.synthetic.stats().active_transactions, 0,
					"the successful retry must reach exact terminal completion")
			end, debug.traceback))

			fixture.synthetic.seal = original_seal
			fixture.synthetic.cancel = original_cancel
			fixture.synthetic.prepare_reserved_successor = original_reserve
			if not outcome[1] then error(outcome[2], 0) end
		end)
	end

	helpers.it("rolls the reserved owner back when predecessor registration throws", function()
		local fixture = load_gate()
		local tx = new_transaction(fixture)
		fixture.synthetic.seal(tx)
		local original_on_complete = fixture.synthetic.on_complete
		local registrations = 0
		fixture.synthetic.on_complete = function(...)
			registrations = registrations + 1
			if registrations == 2 then error("predecessor registration exploded") end
			return original_on_complete(...)
		end

		local armed = fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = tx,
		})
		fixture.synthetic.on_complete = original_on_complete
		helpers.assert_true(not armed,
			"the physical Enter must pass through when full ownership cannot commit")
		helpers.assert_true(not fixture.replay.is_pending())
		helpers.assert_eq(fixture.synthetic.stats().active_transactions, 0,
			"the private reservation transaction and periodic owner must roll back")
		helpers.assert_eq(#fixture.sent, 0)
	end)

	helpers.it("refuses Enter ownership before commit and accepts a fresh retry", function()
		local fixture = load_gate()
		local tx = new_transaction(fixture)
		fixture.synthetic.seal(tx)
		fixture.set_send_failure(true)

		helpers.assert_true(not fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = tx,
		}), "a key whose replay cannot be pre-built must remain physical")
		fire_hs_lifecycle(fixture)
		helpers.assert_eq(#fixture.sent, 0)
		helpers.assert_true(not fixture.replay.is_pending(),
			"failed construction must not claim ownership of the physical key")
		helpers.assert_eq(fixture.synthetic.stats().active_transactions, 0,
			"the refused reservation and completed predecessor must not leak")

		fixture.set_send_failure(false)
		helpers.assert_true(fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = tx,
		}), "a fresh physical event may be claimed once construction recovers")
		fire_hs_lifecycle(fixture)
		helpers.assert_eq(#fixture.sent, 1)
		helpers.assert_eq(fixture.sent[1].key, "return")
		helpers.assert_true(not fixture.replay.is_pending())
	end)

	helpers.it("a refused first reservation leaves no owner to overwrite", function()
		local fixture = load_gate()
		local first_tx = new_transaction(fixture)
		local second_tx = new_transaction(fixture)
		fixture.set_send_failure(true)
		helpers.assert_true(not fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = first_tx,
		}))

		fixture.set_send_failure(false)
		helpers.assert_true(fixture.replay.arm({
			kind = "text", chars = " ", transaction = second_tx,
		}))
		helpers.assert_true(fixture.replay.is_pending())
		helpers.assert_eq(#fixture.sent, 0)
		fixture.synthetic.cancel(first_tx)
		fixture.synthetic.cancel(second_tx)
	end)

	helpers.it("flush_now cannot observe an owner after pre-build refusal", function()
		local fixture = load_gate()
		local tx = new_transaction(fixture)
		fixture.set_send_failure(true)
		helpers.assert_true(not fixture.replay.arm({
			kind = "key", key = "return", chars = "\r", transaction = tx,
		}))

		helpers.assert_true(not fixture.replay.flush_now("teardown"))
		helpers.assert_true(not fixture.replay.is_pending())
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

	helpers.it("refuses ownership when the replacement transaction is missing", function()
		local fixture = load_gate()
		helpers.assert_true(not fixture.replay.arm({
			kind = "key", key = "return", chars = "\r",
		}))
		fire_hs_lifecycle(fixture)
		helpers.assert_eq(#fixture.sent, 0,
			"false means physical Enter passes through; synthesis would duplicate it")
		helpers.assert_true(not fixture.replay.is_pending())
	end)
end)


package.loaded["adapters.text_sender"] = nil
package.loaded["adapters.timer_scheduler"] = nil
package.loaded["adapters.synthetic_input"] = nil
package.loaded["adapters.event_provenance"] = nil
package.loaded["modules.keymap.terminator_replay"] = nil
