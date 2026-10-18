--- tests/support/text_sender_fixture.lua

--- ==============================================================================
--- MODULE: Native Text Sender Fixture
--- DESCRIPTION:
--- Composes the real clipboard, scheduler and synthetic-input adapters with
--- controllable Quartz and pasteboard primitives for handoff ownership tests.
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
			for index, timer in ipairs(f.timers) do
				if timer.delay == synthetic.PERIODIC_OWNER_TICK_SEC and not timer.stopped then
					table.remove(f.timers, index)
					f.options.absolute_time = f.options.absolute_time + math.floor(timer.delay * 1e9)
					timer.callback()
					if timer.recurring and not timer.stopped then f.timers[#f.timers + 1] = timer end
					return
				end
			end
			error("no guarded native paste handoff was available")
		end

		callback(f)
	end)
end

return with_sender
