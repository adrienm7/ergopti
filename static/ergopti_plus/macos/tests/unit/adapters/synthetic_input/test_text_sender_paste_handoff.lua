--- tests/unit/adapters/synthetic_input/test_text_sender_paste_handoff.lua

--- ==============================================================================
--- MODULE: Text Sender Paste Handoff
--- DESCRIPTION:
--- Exercises the actual clipboard, timer and synthetic-input adapters while the
--- native broker is held. Queue admission must not start host paste settlement.
--- This controlled Quartz model does not qualify native application consumption.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.synthetic_input_fixture")

local function with_sender(callback)
	helpers.with_stub_scope({
		"adapters.text_sender", "adapters.clipboard", "adapters.synthetic_input",
		"adapters.timer_scheduler", "adapters.event_provenance", "adapters.storage",
		"adapters.json_codec", "infra.logger", "infra.paths", "infra.timings",
	}, function()
		local f = Fixture.make({ deliver_trigger = false, absolute_time = 0 })
		local initial = {
			["public.utf8-plain-text"] = "USER CLIPBOARD",
			["public.html"] = "<b>USER CLIPBOARD</b>",
		}
		local clipboard = initial
		f.restore_calls = 0
		f.hs_overrides.pasteboard = {
			readAllData = function() return clipboard end,
			setContents = function(value)
				clipboard = { ["public.utf8-plain-text"] = value }
				return true
			end,
			writeAllData = function(value)
				f.restore_calls = f.restore_calls + 1
				clipboard = value
				return true
			end,
			clearContents = function() clipboard = {} end,
		}
		local synthetic = f.load()
		f.synthetic = synthetic
		f.producers = {}
		f.complete_calls = 0
		local actual_begin, actual_complete = synthetic.begin, synthetic.on_complete
		synthetic.begin = function(...)
			local tx = actual_begin(...)
			f.producers[#f.producers + 1] = tx
			return tx
		end
		synthetic.on_complete = function(tx, observer)
			return actual_complete(tx, function(...)
				f.complete_calls = f.complete_calls + 1
				return observer(...)
			end)
		end
		f.sender = require("adapters.text_sender")
		f.clipboard = function() return clipboard end
		f.initial = initial
		f.restore_delay = require("infra.timings").sec("debounce", "clipboard_restore_ms")
		f.expire_restore = function()
			local snapshot = {}
			for _, timer in ipairs(f.timers) do snapshot[#snapshot + 1] = timer end
			for _, timer in ipairs(snapshot) do
				if timer.delay == f.restore_delay and not timer.stopped then
					f.options.absolute_time = f.options.absolute_time + math.ceil(timer.delay * 1e9)
					timer.callback()
				end
			end
		end
		f.finish_broker = function()
			f.deliver_trigger = true
			for _ = 1, 32 do
				local selected
				for index, timer in ipairs(f.timers) do
					if not timer.stopped and timer.delay <= synthetic.PERIODIC_OWNER_TICK_SEC then
						selected = table.remove(f.timers, index)
						break
					end
				end
				if not selected then return end
				f.options.absolute_time = f.options.absolute_time + math.floor(selected.delay * 1e9)
				selected.callback()
				if selected.recurring and not selected.stopped then
					f.timers[#f.timers + 1] = selected
				end
			end
			error("text sender native broker did not settle")
		end
		f.handoff_only = function()
			f.deliver_trigger = true
			for index, timer in ipairs(f.timers) do
				if timer.delay == 0 and not timer.stopped then
					table.remove(f.timers, index)
					timer.callback()
					return
				end
			end
			error("no native paste handoff was available")
		end
		callback(f)
	end)
end

helpers.describe("text sender retains paste payload through native handoff", function()
	helpers.it("keeps payload while Cmd+V is queued (text-sender-paste-handoff)", function()
		with_sender(function(f)
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			helpers.assert_eq(#f.pump_deliveries, 0)
			f.expire_restore()
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "PAYLOAD",
				"a held native paste still owns its payload after the nominal restore deadline")
		end)
	end)

	helpers.it("starts restoration grace after actual paste completion (text-sender-paste-handoff)", function()
		with_sender(function(f)
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			f.expire_restore()
			f.finish_broker()
			helpers.assert_eq(#f.pump_deliveries, 1)
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "PAYLOAD",
				"the receiving host still needs its full post-dispatch paste grace")
			f.expire_restore()
			helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial),
				"every user pasteboard type must return after actual native handoff and grace")
			helpers.assert_eq(f.restore_calls, 1)
		end)
	end)

	helpers.it("refuses an overlap before replacing a queued paste payload (text-sender-paste-handoff)", function()
		with_sender(function(f)
			helpers.assert_eq(f.sender.send("FIRST", { mode = "clipboard" }), true)
			local callbacks = 0
			helpers.assert_eq(f.sender.send("SECOND", { mode = "clipboard" }, function()
				callbacks = callbacks + 1
			end), false)
			helpers.assert_eq(callbacks, 1, "refusal preserves the synchronous notification contract")
			helpers.assert_eq(#f.producers, 1, "the refused overlap must never acquire native output")
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "FIRST")
			f.finish_broker()
			helpers.assert_eq(#f.pump_deliveries, 1)
		end)
	end)

	helpers.it("keeps host paste grace exclusive after terminal completion (text-sender-paste-handoff)", function()
		with_sender(function(f)
			helpers.assert_eq(f.sender.send("FIRST", { mode = "clipboard" }), true)
			f.finish_broker()
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.sender.send("SECOND", { mode = "clipboard" }), false)
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "FIRST")
			f.expire_restore()
			helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial))
			helpers.assert_eq(f.sender.send("SECOND", { mode = "clipboard" }), true)
		end)
	end)

	helpers.it("does not shorten grace to the original pre-dispatch deadline (text-sender-paste-handoff)", function()
		with_sender(function(f)
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			local initial_timer
			for _, timer in ipairs(f.timers) do
				if timer.delay == f.restore_delay then initial_timer = timer; break end
			end
			helpers.assert_not_nil(initial_timer)
			f.options.absolute_time = math.floor(f.restore_delay * 0.9 * 1e9)
			f.finish_broker()
			f.options.absolute_time = math.ceil(f.restore_delay * 1e9)
			initial_timer.callback()
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "PAYLOAD")
			f.expire_restore()
			helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial))
		end)
	end)

	helpers.it("restores an undispatched cancellation only after the exact terminal (text-sender-paste-handoff)", function()
		with_sender(function(f)
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			helpers.assert_eq(f.synthetic.cancel(f.producers[1]), true)
			f.finish_broker()
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(#f.pump_deliveries, 0, "cancelled queued paste must never hand off")
			helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial))
			f.finish_broker()
			helpers.assert_eq(f.complete_calls, 1, "late native cleanup must not repeat completion")
			helpers.assert_eq(f.restore_calls, 1, "late native cleanup must not repeat restoration")
		end)
	end)

	helpers.it("retains grace when cancellation follows native handoff (text-sender-paste-handoff)", function()
		with_sender(function(f)
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), true)
			f.handoff_only()
			helpers.assert_eq(#f.pump_deliveries, 1)
			helpers.assert_eq(f.synthetic.cancel(f.producers[1]), true)
			f.finish_broker()
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "PAYLOAD")
			f.expire_restore()
			helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial))
			helpers.assert_eq(f.restore_calls, 1)
		end)
	end)

	helpers.it("joins native work when seal fails and cancellation refuses (text-sender-paste-handoff)", function()
		with_sender(function(f)
			local actual_seal = f.synthetic.seal
			f.synthetic.seal = function(tx)
				actual_seal(tx)
				error("seal reported failure after committing native work")
			end
			f.synthetic.cancel = function() return false end
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), false)
			f.expire_restore()
			helpers.assert_eq(f.complete_calls, 0)
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "PAYLOAD")
			f.finish_broker()
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(#f.pump_deliveries, 1, "uncertain output must never be retried")
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "PAYLOAD")
			f.expire_restore()
			helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial))
		end)
	end)
end)
