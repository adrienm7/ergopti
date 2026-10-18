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
		"infra.toml.reader", "json", "toml_codec.basic_string", "toml_codec.bom",
		"toml_codec.key_path", "toml_codec.reader", "toml_codec.record_scanner",
	}, function()
		local f = Fixture.make({ deliver_trigger = false, absolute_time = 0 })
		local initial = {
			["public.utf8-plain-text"] = "USER CLIPBOARD",
			["public.html"] = "<b>USER CLIPBOARD</b>",
		}
		local clipboard = initial
		f.restore_calls = 0
		f.change_count = 0
		f.hs_overrides.pasteboard = {
			changeCount = function()
				f.count_reads = (f.count_reads or 0) + 1
				if f.count_failure_on_read == f.count_reads then return nil end
				if f.count_failure == "throw" then error("pasteboard count unavailable") end
				if f.count_failure == "nil" then return nil end
				return f.change_count
			end,
			readAllData = function() return clipboard end,
			setContents = function(value)
				f.change_count = f.change_count + 1
				clipboard = { ["public.utf8-plain-text"] = value }
				if f.write_refusal == "throw" then error("payload write raised after mutation") end
				if f.write_refusal == "false" then return false end
				return true
			end,
			writeAllData = function(value)
				f.restore_calls = f.restore_calls + 1
				f.change_count = f.change_count + 1
				clipboard = value
				if f.restore_refusal == "false" then return false end
				return true
			end,
			clearContents = function() f.change_count = f.change_count + 1; clipboard = {} end,
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
			return actual_complete(tx, function(finished, status, ...)
				f.complete_calls = f.complete_calls + 1
				f.last_terminal_status = status
				return observer(finished, status, ...)
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

helpers.describe("text sender restores only its exact native pasteboard owner", function()
	for _, value in ipairs({ "NEW USER COPY", "PAYLOAD" }) do
		helpers.it("preserves a user copy during paste grace: " .. value, function()
			with_sender(function(f)
				helpers.assert_true(f.sender.send("PAYLOAD", { mode = "clipboard" }))
				f.finish_broker()
				helpers.assert_true(f.hs_overrides.pasteboard.setContents(value))
				f.expire_restore()
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], value)
				helpers.assert_eq(f.restore_calls, 0, "a new native owner must preserve even identical text")
				helpers.assert_true(f.sender.send("SECOND", { mode = "clipboard" }))
				f.finish_broker(); f.expire_restore()
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], value)
			end)
		end)
	end
	helpers.it("captures the external copy before a second send inherits an expired grace", function()
		with_sender(function(f)
			helpers.assert_true(f.sender.send("FIRST", { mode = "clipboard" }))
			f.finish_broker()
			f.options.absolute_time = f.options.absolute_time + math.ceil(f.restore_delay * 1e9)
			f.hs_overrides.pasteboard.setContents("NEW USER COPY")
			helpers.assert_true(f.sender.send("SECOND", { mode = "clipboard" }))
			f.finish_broker(); f.expire_restore()
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "NEW USER COPY")
			helpers.assert_eq(f.restore_calls, 1, "only the second request may restore its new snapshot")
		end)
	end)
	for _, refusal in ipairs({ "throw", "nil" }) do
		helpers.it("retains clipboard recovery while native count returns " .. refusal, function()
			with_sender(function(f)
				helpers.assert_true(f.sender.send("PAYLOAD", { mode = "clipboard" }))
				f.finish_broker()
				f.count_failure = refusal
				f.expire_restore()
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "PAYLOAD")
				helpers.assert_eq(f.restore_calls, 0)
				helpers.assert_eq(f.sender.send("BLOCKED", { mode = "clipboard" }), false)
				helpers.assert_eq(#f.producers, 1)
				f.count_failure = nil
				f.expire_restore()
				helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial))
				helpers.assert_eq(f.restore_calls, 1)
			end)
		end)
	end
	helpers.it("does not adopt the clipboard written by a reentrant payload diagnostic", function()
		with_sender(function(f)
			local debug = f.logger.debug
			f.logger.debug = function(log, format, ...)
				if format:find("write():", 1, true) then
					f.hs_overrides.pasteboard.setContents("NEW USER COPY")
				end
				return debug(log, format, ...)
			end
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), false)
			f.finish_broker(); f.expire_restore()
			helpers.assert_eq(#f.pump_deliveries, 0)
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "NEW USER COPY")
			helpers.assert_eq(f.restore_calls, 0)
		end)
	end)
	helpers.it("keeps the native write receipt captured before a reentrant refusal diagnostic", function()
		with_sender(function(f)
			local error_log = f.logger.error
			f.logger.error = function(log, format, ...)
				if format:find("write():", 1, true) then
					f.write_refusal = nil
					f.hs_overrides.pasteboard.setContents("NEW USER COPY")
				end
				return error_log(log, format, ...)
			end
			f.write_refusal = "throw"
			local receipt = {}
			local written, returned = require("adapters.clipboard").write("PAYLOAD", receipt)
			helpers.assert_eq(written, false)
			helpers.assert_true(returned == receipt)
			helpers.assert_eq(receipt.count, 1, "capture before Logger can change the board")
			helpers.assert_eq(receipt.count_ok, true)
			helpers.assert_eq(f.change_count, 2)
		end)
	end)
	helpers.it("preserves a user copy made after a refused native restore", function()
		with_sender(function(f)
			helpers.assert_true(f.sender.send("PAYLOAD", { mode = "clipboard" }))
			f.finish_broker()
			f.restore_refusal = "false"
			local error_log = f.logger.error
			f.logger.error = function(log, format, ...)
				if format:find("restore():", 1, true) then f.hs_overrides.pasteboard.setContents("NEW USER COPY") end
				return error_log(log, format, ...)
			end
			f.expire_restore()
			f.restore_refusal = nil
			f.expire_restore()
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "NEW USER COPY")
			helpers.assert_eq(f.restore_calls, 1, "an old retry must not overwrite the diagnostic's new owner")
		end)
	end)
	helpers.it("preserves a user copy when an undispatched paste is cancelled", function()
		with_sender(function(f)
			helpers.assert_true(f.sender.send("PAYLOAD", { mode = "clipboard" }))
			f.hs_overrides.pasteboard.setContents("NEW USER COPY")
			helpers.assert_true(f.synthetic.cancel(f.producers[1]))
			f.finish_broker(); f.expire_restore()
			helpers.assert_eq(#f.pump_deliveries, 0)
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "NEW USER COPY")
			helpers.assert_eq(f.restore_calls, 0)
		end)
	end)
end)

helpers.describe("native clipboard ownership metadata", function()
	helpers.it("retains an unproven post-write owner until another observed clipboard change", function()
		with_sender(function(f)
			f.count_failure_on_read = 4
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), false)
			helpers.assert_eq(#f.producers, 0)
			helpers.assert_eq(f.restore_calls, 0)
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "PAYLOAD")
			helpers.assert_eq(f.sender.send("BLOCKED", { mode = "clipboard" }), false)
			f.hs_overrides.pasteboard.setContents("NEW USER COPY")
			f.expire_restore()
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "NEW USER COPY")
			helpers.assert_true(f.sender.send("SECOND", { mode = "clipboard" }))
			f.finish_broker(); f.expire_restore()
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "NEW USER COPY")
		end)
	end)
	helpers.it("keeps a thrown payload's exact receipt through reentrant diagnostics", function()
		with_sender(function(f)
			f.write_refusal = "throw"
			local error_log = f.logger.error
			f.logger.error = function(log, format, ...)
				if format:find("write():", 1, true) then
					f.write_refusal = nil
					f.hs_overrides.pasteboard.setContents("NEW USER COPY")
				end
				return error_log(log, format, ...)
			end
			helpers.assert_eq(f.sender.send("PAYLOAD", { mode = "clipboard" }), false)
			f.expire_restore()
			helpers.assert_eq(#f.producers, 0)
			helpers.assert_eq(f.restore_calls, 0)
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "NEW USER COPY")
		end)
	end)
	helpers.it("fences reentrant sends while a native restore diagnostic is running", function()
		with_sender(function(f)
			helpers.assert_true(f.sender.send("PAYLOAD", { mode = "clipboard" }))
			f.finish_broker()
			local debug = f.logger.debug
			local nested
			f.logger.debug = function(log, format, ...)
				if format:find("restore():", 1, true) then nested = f.sender.send("REENTRANT", { mode = "clipboard" }) end
				return debug(log, format, ...)
			end
			f.expire_restore()
			helpers.assert_eq(nested, false)
			helpers.assert_eq(#f.producers, 1)
			helpers.assert_eq(f.restore_calls, 1)
			helpers.assert_true(helpers.deep_equal(f.clipboard(), f.initial))
		end)
	end)
end)

helpers.describe("clipboard release keeps its reentrant diagnostics fenced", function()
	for _, entry in ipairs({ "timer", "send" }) do
		helpers.it("fences a Logger.info successor during clipboard reconciliation from " .. entry, function()
			with_sender(function(f)
				helpers.assert_true(f.sender.send("FIRST", { mode = "clipboard" }))
				f.finish_broker()
				f.hs_overrides.pasteboard.setContents("NEW USER COPY")
				local info, nested, attempted = f.logger.info, nil, false
				f.logger.info = function(log, format, ...)
					if not attempted and format:find("Clipboard changed owner", 1, true) then
						attempted = true
						nested = f.sender.send("NESTED", { mode = "clipboard" })
					end
					return info(log, format, ...)
				end
				if entry == "timer" then f.expire_restore()
				else
					f.options.absolute_time = f.options.absolute_time + math.ceil(f.restore_delay * 1e9)
					helpers.assert_true(f.sender.send("OUTER", { mode = "clipboard" }))
				end
				helpers.assert_eq(nested, false, "diagnostics cannot admit a successor before reconciliation returns")
				helpers.assert_eq(#f.producers, entry == "timer" and 1 or 2)
				if entry == "send" then f.finish_broker(); f.expire_restore() end
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "NEW USER COPY")
			end)
		end)
	end
	helpers.it("keeps an external copy when native trigger timeouts retire the queued paste", function()
		with_sender(function(f)
			helpers.assert_true(f.sender.send("PAYLOAD", { mode = "clipboard" }))
			f.hs_overrides.pasteboard.setContents("NEW USER COPY")
			for _ = 1, 12 do
				local selected
				for _, deadline in ipairs({ f.synthetic.PUMP_DELIVERY_TIMEOUT_SEC, f.synthetic.PERIODIC_OWNER_TICK_SEC }) do
					for index, timer in ipairs(f.timers) do
						if not timer.stopped and timer.delay <= deadline then
							if deadline ~= f.synthetic.PUMP_DELIVERY_TIMEOUT_SEC or timer.delay == deadline then
								selected = table.remove(f.timers, index)
								break
							end
						end
					end
					if selected then break end
				end
				if not selected then break end
				f.options.absolute_time = f.options.absolute_time + math.ceil(selected.delay * 1e9)
				selected.callback()
				if selected.recurring and not selected.stopped then f.timers[#f.timers + 1] = selected end
				if f.complete_calls > 0 then break end
			end
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.last_terminal_status, "failed")
			helpers.assert_eq(#f.pump_deliveries, 0)
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "NEW USER COPY")
			helpers.assert_eq(f.restore_calls, 0)
		end)
	end)
end)
