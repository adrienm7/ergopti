--- tests/unit/adapters/synthetic_input/test_guarded_clipboard_pair.lua

--- ==============================================================================
--- MODULE: Guarded Clipboard Native Pair
--- DESCRIPTION:
--- Drives TextSender through the actual FIFO and native-post boundary. Clipboard
--- ownership is checked before Down; any attempted Down owes its exact Up even
--- when posting or cancellation leaves the native side effect uncertain.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_sender = require("tests.support.text_sender_fixture")

local function tick(f)
	for index, timer in ipairs(f.timers) do
		if not timer.stopped and timer.delay <= f.synthetic.PERIODIC_OWNER_TICK_SEC then
			table.remove(f.timers, index)
			f.options.absolute_time = f.options.absolute_time + math.floor(timer.delay * 1e9)
			timer.callback()
			if timer.recurring and not timer.stopped then f.timers[#f.timers + 1] = timer end
			return true
		end
	end
	return false
end

local function emitted(f)
	local count = f.key_posts
	for _, delivery in ipairs(f.pump_deliveries) do count = count + #(delivery.events or {}) end
	return count
end

local function attempts(f, down)
	local count = 0
	for _, event in ipairs(f.key_attempts) do if event.key == "v" and event.isDown == down then count = count + 1 end end
	return count
end

helpers.describe("clipboard pair owns its payload at the native publication boundary", function()
	helpers.it("keeps healthy paste and restoration behavior (guarded-clipboard-pair)", function()
		with_sender(function(f)
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			helpers.assert_eq(emitted(f), 0)
			f.finish_broker()
			helpers.assert_eq(emitted(f), 2)
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.last_terminal_status, "complete")
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "PAYLOAD")
			f.expire_restore()
			helpers.assert_eq(f.clipboard(), f.initial)
			helpers.assert_eq(f.restore_calls, 1)
		end)
	end)

	helpers.it("refuses a foreign copy while the native pair is queued (guarded-clipboard-pair)", function()
		with_sender(function(f)
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			local epoch = f.synthetic.current_action_epoch()
			f.hs_overrides.pasteboard.setContents("EXTERNAL COPY")
			f.finish_broker()
			helpers.assert_eq(emitted(f), 0, "foreign contents must never be pasted by our pair")
			helpers.assert_eq(f.synthetic.current_action_epoch(), epoch, "a reversible refusal has no handoff epoch")
			helpers.assert_eq(f.last_terminal_status, "failed")
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "EXTERNAL COPY")
			helpers.assert_eq(f.restore_calls, 0)
		end)
	end)

	helpers.it("does not return a queued paste through an ambient callback (guarded-clipboard-pair)", function()
		with_sender(function(f)
			f.synthetic.enter_callback()
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			local _, events = f.synthetic.leave_callback(false)
			helpers.assert_eq(events, nil, "the clipboard owner must stay on its outside-callback FIFO timer")
			f.hs_overrides.pasteboard.setContents("EXTERNAL COPY")
			f.finish_broker()
			helpers.assert_eq(emitted(f), 0)
			helpers.assert_eq(f.last_terminal_status, "failed")
		end)
	end)

	helpers.it("fails closed when the final native ownership receipt is unreadable (guarded-clipboard-pair)", function()
		with_sender(function(f)
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			f.count_failure = "throw"
			f.finish_broker()
			helpers.assert_eq(emitted(f), 0)
			helpers.assert_eq(f.last_terminal_status, "failed")
			helpers.assert_eq(f.restore_calls, 0)
			helpers.assert_eq(f.sender.send("SUCCESSOR", { mode = "clipboard" }), false)
			f.count_failure = nil
			f.expire_restore()
			helpers.assert_eq(f.clipboard(), f.initial)
		end)
	end)

	helpers.it("never replays an uncertain Down and preserves paste grace after compensation (guarded-clipboard-pair)", function()
		with_sender(function(f)
			f.key_observer = function(event)
				if event.key == "v" and event.isDown then error("native Down raised after posting") end
			end
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			f.finish_broker()
			helpers.assert_eq(attempts(f, true), 1)
			helpers.assert_eq(attempts(f, false), 1)
			helpers.assert_eq(f.last_terminal_status, "failed")
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.restore_calls, 0, "an uncertain posted paste still owes its receiving host grace")
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "PAYLOAD")
			f.expire_restore()
			helpers.assert_eq(f.clipboard(), f.initial)
			helpers.assert_eq(f.restore_calls, 1)
		end)
	end)

	helpers.it("retains Up beyond the ordinary retry budget and blocks its FIFO sibling (guarded-clipboard-pair)", function()
		with_sender(function(f)
			local refuse_up = true
			f.key_observer = function(event)
				if event.key == "v" and not event.isDown and refuse_up then error("native Up refused") end
			end
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			local sibling = f.synthetic.begin("guarded-pair.sibling", "action")
			helpers.assert_eq(f.synthetic.emit_key_stroke({}, "s", 0, sibling), true)
			f.synthetic.seal(sibling)
			for _ = 1, 40 do tick(f); if attempts(f, false) > f.synthetic.SERIAL_POST_MAX_ATTEMPTS then break end end
			helpers.assert_true(attempts(f, false) > f.synthetic.SERIAL_POST_MAX_ATTEMPTS,
				"release debt must outlive the ordinary bounded-post retry budget")
			helpers.assert_eq(attempts(f, true), 1)
			helpers.assert_eq(f.complete_calls, 0)
			local reported = false
			for _, line in ipairs(f.logs) do
				if line:find("Guarded key-up cleanup remains pending", 1, true) then reported = true end
			end
			helpers.assert_true(reported, "retained native release debt must not fail silently")
			helpers.assert_eq(#f.pump_deliveries, 0, "the sibling cannot overtake unreleased modifiers")
			helpers.assert_eq(f.sender.send("SECOND", { mode = "clipboard" }), false)
			refuse_up = false
			f.finish_broker()
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.last_terminal_status, "failed", "a recovered refusal remains an honest failure")
			helpers.assert_eq(attempts(f, true), 1)
			helpers.assert_eq(#f.pump_deliveries, 1)
		end)
	end)

	helpers.it("cancellation after Down never removes the required Up (guarded-clipboard-pair)", function()
		with_sender(function(f)
			f.key_observer = function(event)
				if event.key == "v" and event.isDown then
					helpers.assert_eq(f.synthetic.cancel(f.producers[1]), false)
					f.hs_overrides.pasteboard.setContents("EXTERNAL COPY")
				end
			end
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			f.finish_broker()
			helpers.assert_eq(attempts(f, true), 1)
			helpers.assert_eq(attempts(f, false), 1)
			helpers.assert_eq(f.last_terminal_status, "cancelled")
			helpers.assert_eq(f.complete_calls, 1)
			f.expire_restore()
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "EXTERNAL COPY")
			helpers.assert_eq(f.restore_calls, 0)
		end)
	end)

	helpers.it("waits for the exact periodic stop acknowledgement before terminal (guarded-clipboard-pair)", function()
		with_sender(function(f)
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			for _, timer in ipairs(f.timers) do
				if timer.recurring and timer.delay == f.synthetic.PERIODIC_OWNER_TICK_SEC then timer.stop_failures = 1 end
			end
			for _ = 1, 40 do
				tick(f)
				if f.synthetic.stats().pending_periodic_cleanup > 0 then break end
			end
			helpers.assert_true(f.synthetic.stats().pending_periodic_cleanup > 0)
			helpers.assert_eq(attempts(f, true), 1)
			helpers.assert_eq(attempts(f, false), 1)
			helpers.assert_eq(f.complete_calls, 0, "stop refusal must retain the native pair's completion")
			f.finish_broker()
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.last_terminal_status, "complete")
			helpers.assert_eq(f.synthetic.stats().pending_periodic_cleanup, 0)
		end)
	end)

	helpers.it("treats an identical external copy as a different payload owner (guarded-clipboard-pair)", function()
		with_sender(function(f)
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			f.hs_overrides.pasteboard.setContents("PAYLOAD")
			f.finish_broker()
			helpers.assert_eq(emitted(f), 0)
			helpers.assert_eq(f.last_terminal_status, "failed")
			helpers.assert_eq(f.restore_calls, 0)
		end)
	end)

	for _, phase in ipairs({ true, false }) do
		helpers.it("ignores a recursive tick before native " .. (phase and "Down" or "Up") .. " effect (guarded-clipboard-pair)", function()
			with_sender(function(f)
				local key_stroke = f.synthetic.keyStroke
				f.synthetic.keyStroke = function(batch, ...)
					local result = key_stroke(batch, ...)
					for _, event in ipairs(batch.events) do
						if event.isDown == phase then
							local post = event.post
							event.post = function(self, ...)
								local before = #f.key_attempts
								tick(f)
								helpers.assert_eq(#f.key_attempts, before, "recursive owner must stay inert until the native frame returns")
								return post(self, ...)
							end
						end
					end
					return result
				end
				helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
				f.finish_broker()
				helpers.assert_eq(attempts(f, true), 1)
				helpers.assert_eq(attempts(f, false), 1)
				helpers.assert_eq(f.key_attempts[1].isDown, true)
				helpers.assert_eq(f.key_attempts[2].isDown, false)
				helpers.assert_eq(f.complete_calls, 1)
			end)
		end)
	end

	helpers.it("keeps Up when the post-attempt epoch probe reenters cancellation (guarded-clipboard-pair)", function()
		with_sender(function(f)
			local reentered = 0
			local options = f.options
			setmetatable(options, { __index = function(_, key)
				if key ~= "absolute_time" then return nil end
				reentered = reentered + 1
				options.absolute_time = 100000000
				helpers.assert_eq(f.synthetic.cancel(f.producers[1]), false)
				tick(f)
				return options.absolute_time
			end })
			f.key_observer = function(event)
				if event.isDown then options.absolute_time = nil end
			end
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			f.finish_broker()
			helpers.assert_eq(reentered, 1)
			helpers.assert_eq(attempts(f, true), 1)
			helpers.assert_eq(attempts(f, false), 1)
			helpers.assert_eq(f.synthetic.stats().action_handoffs, 1)
			helpers.assert_eq(f.last_terminal_status, "cancelled")
			helpers.assert_eq(f.complete_calls, 1)
		end)
	end)

	helpers.it("refuses cancelled admission after native timer start reentry (guarded-clipboard-pair)", function()
		with_sender(function(f)
			local make_timer = f.hs_overrides.timer.new
			local cancelled = false
			f.hs_overrides.timer.new = function(interval, callback)
				local timer = make_timer(interval, callback)
				if interval == f.synthetic.PERIODIC_OWNER_TICK_SEC and not cancelled then
					local start = timer.start
					timer.start = function(self, ...)
						local result = start(self, ...)
						cancelled = true
						helpers.assert_eq(f.synthetic.cancel(f.producers[1]), true)
						return result
					end
				end
				return timer
			end
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), false)
			helpers.assert_true(cancelled)
			f.finish_broker()
			helpers.assert_eq(emitted(f), 0)
			helpers.assert_eq(f.synthetic.stats().pending, 0)
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.sender.send("HEALTHY SUCCESSOR", { mode = "clipboard" }), true)
			f.finish_broker()
			helpers.assert_eq(attempts(f, true), 1)
			helpers.assert_eq(attempts(f, false), 1)
		end)
	end)

	helpers.it("leaves a successor opened by synchronous stop settlement intact (guarded-clipboard-pair)", function()
		with_sender(function(f)
			helpers.assert_eq(f.sender.send("OBSOLETE", { mode = "clipboard" }), true)
			local first = f.producers[1]
			local observed = 0
			f.synthetic.on_complete(first, function()
				observed = observed + 1
				helpers.assert_eq(f.sender.send("HEALTHY SUCCESSOR", { mode = "clipboard" }), true)
			end)
			f.hs_overrides.pasteboard.setContents("EXTERNAL COPY")
			f.finish_broker()
			helpers.assert_eq(observed, 1)
			helpers.assert_eq(#f.producers, 2)
			helpers.assert_eq(f.complete_calls, 3, "two sender terminals and one extra observer each run once")
			helpers.assert_eq(attempts(f, true), 1)
			helpers.assert_eq(attempts(f, false), 1)
			helpers.assert_eq(f.last_terminal_status, "complete")
			helpers.assert_eq(f.synthetic.stats().pending, 0)
			f.expire_restore()
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "EXTERNAL COPY")
		end)
	end)
	helpers.it("discards late construction tags after native cancellation reentry (guarded-clipboard-pair)", function()
		with_sender(function(f)
			local cancelled = false
			setmetatable(f.options, { __index = function(_, key)
				if key == "new_key_event_throw_at" and not cancelled then
					cancelled = true
					helpers.assert_eq(f.synthetic.cancel(f.producers[1]), true)
				end
			end })
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), false)
			f.finish_broker()
			helpers.assert_true(cancelled)
			helpers.assert_eq(emitted(f), 0)
			helpers.assert_eq(f.synthetic.stats().records, 0, "cancelled construction cannot republish orphan tags")
			helpers.assert_eq(f.synthetic.stats().pending, 0)
			helpers.assert_eq(f.synthetic.stats().active_transactions, 0)
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.sender.send("HEALTHY SUCCESSOR", { mode = "clipboard" }), true)
			f.finish_broker()
			helpers.assert_eq(attempts(f, true), 1)
			helpers.assert_eq(attempts(f, false), 1)
		end)
	end)

end)
