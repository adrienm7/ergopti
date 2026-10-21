--- tests/unit/modules/shortcuts/text_actions/clipboard/test_payload_generation_ownership.lua

--- ==============================================================================
--- MODULE: Wrapped and Transformed Clipboard Payload Ownership
--- DESCRIPTION:
--- Real Text, SyntheticInput and TimerScheduler owners must retain their exact
--- payload generation until native paste and conditional all-type restoration.
--- Native post/stop failures below are defensive controls, not Cocoa evidence.
--- The earlier asynchronous Cmd+C result is not attributed to a writer here.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_sender = require("tests.support.text_sender_fixture")
require("logger")

local function emitted(f)
	local total = f.key_posts
	for _, delivery in ipairs(f.pump_deliveries) do total = total + #(delivery.events or {}) end
	return total
end

local function tick(f, maximum)
	for index, timer in ipairs(f.timers) do
		if not timer.stopped and timer.delay <= maximum then
			table.remove(f.timers, index)
			f.options.absolute_time = f.options.absolute_time + math.ceil(timer.delay * 1e9)
			timer.callback()
			if timer.recurring and not timer.stopped then f.timers[#f.timers + 1] = timer end
			return true
		end
	end
	return false
end

local function attempts(f, down)
	local total = 0
	for _, event in ipairs(f.key_attempts) do
		if event.key == "v" and event.isDown == down then total = total + 1 end
	end
	return total
end

local function with_text(kind, callback)
	helpers.with_stub_scope({
		"modules.shortcuts.actions.text", "modules.shortcuts.actions.text_continuation",
		"modules.shortcuts.actions.text_dispatch", "modules.shortcuts.actions.text_transform_grace",
		"unicode_case", "unicode_case.data",
	}, function()
		with_sender(function(f)
			local board = f.hs_overrides.pasteboard
			board.getContents = function() return f.clipboard()["public.utf8-plain-text"] end
			hs.pasteboard.getContents = board.getContents
			package.loaded["infra.paths"] = { shared = function() return nil end }
			package.loaded["infra.timings"] = { sec = function() return 0.01 end }
			f.text = require("modules.shortcuts.actions.text")
			f.payload = kind == "wrap" and "(hello)" or "HELLO"
			function f.stage()
				for index, timer in ipairs(f.timers) do
					if not timer.stopped and timer.delay > f.synthetic.PERIODIC_OWNER_TICK_SEC
						and timer.delay <= 0.01 + 1e-9 then
						table.remove(f.timers, index)
						f.options.absolute_time = f.options.absolute_time + math.ceil(timer.delay * 1e9)
						timer.callback()
						return true
					end
				end
				return false
			end
			function f.queue()
				if kind == "wrap" then helpers.assert_true(f.text.wrap_selection("hello", "(", ")"))
				else
					helpers.assert_true(f.text.toggle_uppercase())
					f.finish_broker() -- True Cmd+C transaction before the target publishes a result.
					helpers.assert_true(board.setContents("hello"))
					helpers.assert_true(f.stage()) -- capture and own transformed payload
					f.previous_trigger = f.last_trigger
					helpers.assert_true(f.stage()) -- enqueue the paste transaction
				end
				-- The copied selection may already have delivered an earlier trigger.
				-- Hold the paste trigger separately so its HID delivery remains observable.
				f.deliver_trigger = false
				f.before_paste_events, f.before_paste_terminals = emitted(f), f.complete_calls
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], f.payload)
			end
			function f.retire()
				if kind == "transform" then helpers.assert_true(f.stage()); f.finish_broker() end
				helpers.assert_true(f.stage(), "the exact restore/retry owner must remain scheduled")
			end
			function f.copy(value) helpers.assert_true(board.setContents(value)) end
			callback(f, board)
		end)
	end)
end

helpers.describe("payload owners preserve the native clipboard generation", function()
	for _, kind in ipairs({ "wrap", "transform" }) do
		helpers.it(kind .. " keeps healthy paste, selection stages and all original types", function()
			with_text(kind, function(f)
				f.queue(); f.finish_broker()
				helpers.assert_eq(emitted(f) - f.before_paste_events, 2)
				helpers.assert_eq(f.restore_calls, 0)
				f.retire()
				helpers.assert_eq(f.clipboard(), f.initial)
				helpers.assert_eq(f.restore_calls, 1)
				helpers.assert_eq(f.text.has_pending_text_action(), false)
			end)
		end)

		for _, same in ipairs({ false, true }) do
			helpers.it(kind .. " preserves a post-handoff copy, identical=" .. tostring(same), function()
				with_text(kind, function(f)
					f.queue(); f.finish_broker(); f.copy(same and f.payload or "POST-PASTE COPY")
					local foreign, count = f.clipboard(), f.change_count
					f.retire()
					helpers.assert_eq(f.clipboard(), foreign)
					helpers.assert_eq(f.change_count, count)
					helpers.assert_eq(f.restore_calls, 0)
					helpers.assert_eq(f.text.has_pending_text_action(), false)
				end)
			end)

			helpers.it(kind .. " refuses a queued foreign copy, identical=" .. tostring(same), function()
				with_text(kind, function(f)
					f.queue(); f.copy(same and f.payload or "QUEUED COPY")
					local foreign, count = f.clipboard(), f.change_count
					f.finish_broker()
					helpers.assert_eq(emitted(f), f.before_paste_events)
					helpers.assert_eq(f.complete_calls, f.before_paste_terminals + 1)
					helpers.assert_eq(f.last_terminal_status, "failed")
					helpers.assert_eq(f.clipboard(), foreign)
					helpers.assert_eq(f.change_count, count)
					helpers.assert_eq(f.restore_calls, 0)
					helpers.assert_eq(f.text.has_pending_text_action(), false)
				end)
			end)
		end

		helpers.it(kind .. " refuses a copy after trigger posting and before HID delivery", function()
			with_text(kind, function(f)
				f.queue()
				for _ = 1, 4 do if not tick(f, 0) then break end end
				helpers.assert_eq(emitted(f), f.before_paste_events)
				f.copy("AFTER TRIGGER")
				if f.last_trigger and f.last_trigger ~= f.previous_trigger then f.deliver_posted_trigger(f.last_trigger) end
				f.finish_broker()
				helpers.assert_eq(emitted(f), f.before_paste_events)
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "AFTER TRIGGER")
				helpers.assert_eq(f.restore_calls, 0)
			end)
		end)

		helpers.it(kind .. " keeps the payload throughout a long real queue wait", function()
			with_text(kind, function(f)
				f.queue(); f.options.absolute_time = f.options.absolute_time + 1000000000
				f.stage() -- Wrap may deliver its prearmed timer while the native pair is held.
				helpers.assert_eq(f.restore_calls, 0)
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], f.payload)
				f.finish_broker(); f.retire()
				helpers.assert_eq(f.clipboard(), f.initial)
			end)
		end)

		helpers.it(kind .. " holds failed native-count cleanup until its exact receipt is readable", function()
			with_text(kind, function(f)
				f.queue(); f.count_failure = "throw"; f.finish_broker()
				helpers.assert_eq(emitted(f), f.before_paste_events)
				helpers.assert_eq(f.restore_calls, 0)
				helpers.assert_true(f.text.has_pending_text_action())
				f.count_failure = nil
				helpers.assert_true(f.stage())
				helpers.assert_eq(f.clipboard(), f.initial)
				helpers.assert_eq(f.text.has_pending_text_action(), false)
			end)
		end)

		helpers.it(kind .. " cancels before Down only after native timer retirement", function()
			with_text(kind, function(f)
				f.queue(); helpers.assert_eq(f.text.pause_text_actions(), false)
				helpers.assert_eq(f.restore_calls, 0)
				f.finish_broker()
				helpers.assert_eq(emitted(f), f.before_paste_events)
				helpers.assert_eq(f.clipboard(), f.initial)
				helpers.assert_true(f.text.resume_text_actions())
			end)
		end)

		helpers.it(kind .. " keeps conservative grace after uncertain native Down", function()
			with_text(kind, function(f)
				f.key_observer = function(event)
					if event.key == "v" and event.isDown then error("controlled post-mutating Down") end
				end
				f.queue(); f.finish_broker()
				helpers.assert_eq(attempts(f, true), 1)
				helpers.assert_eq(attempts(f, false), 1)
				helpers.assert_eq(f.last_terminal_status, "failed")
				helpers.assert_eq(f.restore_calls, 0)
				helpers.assert_true(f.stage())
				helpers.assert_eq(f.clipboard(), f.initial)
			end)
		end)

		helpers.it(kind .. " keeps mandatory Up and stop debt independent of cancellation", function()
			with_text(kind, function(f)
				local refuse = true
				f.key_observer = function(event)
					if event.key == "v" and not event.isDown and refuse then error("controlled Up debt") end
				end
				f.queue()
				for _ = 1, 12 do helpers.assert_true(tick(f, f.synthetic.PERIODIC_OWNER_TICK_SEC)) end
				helpers.assert_eq(attempts(f, true), 1)
				helpers.assert_true(attempts(f, false) > f.synthetic.SERIAL_POST_MAX_ATTEMPTS)
				helpers.assert_eq(f.complete_calls, f.before_paste_terminals)
				helpers.assert_eq(f.text.pause_text_actions(), false)
				refuse = false; f.finish_broker()
				helpers.assert_eq(f.restore_calls, 0)
				helpers.assert_true(f.stage())
				helpers.assert_eq(f.clipboard(), f.initial)
				helpers.assert_true(f.text.resume_text_actions())
			end)
		end)

		helpers.it(kind .. " retains exact native stop debt after Up", function()
			with_text(kind, function(f)
				f.queue()
				local owner
				for _, timer in ipairs(f.timers) do
					if timer.delay == f.synthetic.PERIODIC_OWNER_TICK_SEC and not timer.stopped then owner = timer end
				end
				helpers.assert_true(owner ~= nil)
				owner.stop_failures = 50
				for _ = 1, 4 do helpers.assert_true(tick(f, f.synthetic.PERIODIC_OWNER_TICK_SEC)) end
				helpers.assert_eq(attempts(f, true), 1)
				helpers.assert_eq(attempts(f, false), 1)
				helpers.assert_eq(f.complete_calls, f.before_paste_terminals)
				helpers.assert_eq(f.restore_calls, 0)
				helpers.assert_eq(f.text.pause_text_actions(), false)
				owner.stop_failures = 0; f.finish_broker()
				helpers.assert_eq(f.complete_calls, f.before_paste_terminals + 1)
				helpers.assert_eq(f.restore_calls, 0)
				helpers.assert_true(f.stage())
				helpers.assert_eq(f.clipboard(), f.initial)
				helpers.assert_true(f.text.resume_text_actions())
			end)
		end)

		helpers.it(kind .. " never adopts a missing payload generation later", function()
			with_text(kind, function(f, board)
				local native_write = board.setContents
				board.setContents = function(value)
					local result = native_write(value)
					if value == f.payload then f.count_failure = "nil" end
					return result
				end
				hs.pasteboard.setContents = board.setContents
				if kind == "wrap" then helpers.assert_eq(f.text.wrap_selection("hello", "(", ")"), false)
				else
					helpers.assert_true(f.text.toggle_uppercase()); f.finish_broker()
					f.copy("hello"); helpers.assert_true(f.stage())
				end
				f.count_failure = nil
				helpers.assert_true(f.text.has_pending_text_action())
				helpers.assert_true(f.stage()); f.finish_broker()
				helpers.assert_eq(f.restore_calls, 0)
				helpers.assert_eq(attempts(f, true), 0)
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], f.payload)
				helpers.assert_eq(f.text.pause_text_actions(), false)
			end)
		end)

		helpers.it(kind .. " preserves an originally empty all-type snapshot", function()
			with_text(kind, function(f, board)
				board.clearContents()
				f.queue(); f.finish_broker(); f.retire()
				helpers.assert_eq(f.clipboard(), {})
				helpers.assert_eq(f.restore_calls, 0)
				helpers.assert_eq(f.text.has_pending_text_action(), false)
			end)
		end)

		helpers.it(kind .. " retries a throwing partial restore with its exact generation", function()
			with_text(kind, function(f, board)
				f.queue(); f.finish_broker()
				if kind == "transform" then helpers.assert_true(f.stage()); f.finish_broker() end
				local native_restore, first = board.writeAllData, true
				board.writeAllData = function(snapshot)
					if first then first = false; native_restore({ ["public.utf8-plain-text"] = "THROWN PARTIAL" }); error("controlled post-mutation restore") end
					return native_restore(snapshot)
				end
				hs.pasteboard.writeAllData = board.writeAllData
				helpers.assert_true(f.stage())
				helpers.assert_true(f.text.has_pending_text_action())
				helpers.assert_eq(f.restore_calls, 1)
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "THROWN PARTIAL")
				helpers.assert_true(f.stage())
				helpers.assert_eq(f.restore_calls, 2)
				helpers.assert_eq(f.clipboard(), f.initial)
			end)
		end)

		helpers.it(kind .. " preserves a new copy after handoff and cancellation", function()
			with_text(kind, function(f)
				f.queue(); f.finish_broker(); f.copy("COPY BEFORE PAUSE")
				local count = f.change_count
				helpers.assert_eq(f.text.pause_text_actions(), false)
				helpers.assert_eq(f.restore_calls, 0)
				helpers.assert_true(f.stage())
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "COPY BEFORE PAUSE")
				helpers.assert_eq(f.change_count, count)
				helpers.assert_eq(f.restore_calls, 0)
				helpers.assert_true(f.text.resume_text_actions())
			end)
		end)

		helpers.it(kind .. " rolls a throwing payload mutation back with its immediate receipt", function()
			with_text(kind, function(f)
				if kind == "wrap" then
					f.write_refusal = "throw"
					helpers.assert_eq(f.text.wrap_selection("hello", "(", ")"), false)
				else
					helpers.assert_true(f.text.toggle_uppercase()); f.finish_broker(); f.copy("hello")
					f.write_refusal = "throw"; helpers.assert_true(f.stage())
				end
				helpers.assert_eq(attempts(f, true), 0)
				helpers.assert_eq(f.clipboard(), f.initial)
				helpers.assert_eq(f.restore_calls, 1)
				helpers.assert_eq(f.text.has_pending_text_action(), false)
			end)
		end)

		helpers.it(kind .. " retries partial restore without discarding its post-mutation count", function()
			with_text(kind, function(f, board)
				f.queue(); f.finish_broker()
				if kind == "transform" then helpers.assert_true(f.stage()); f.finish_broker() end
				local native_restore, first = board.writeAllData, true
				board.writeAllData = function(snapshot)
					if first then first = false; native_restore({ ["public.utf8-plain-text"] = "PARTIAL" }); return false end
					return native_restore(snapshot)
				end
				hs.pasteboard.writeAllData = board.writeAllData
				helpers.assert_true(f.stage())
				helpers.assert_true(f.text.has_pending_text_action())
				helpers.assert_eq(f.restore_calls, 1)
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "PARTIAL")
				helpers.assert_true(f.stage())
				helpers.assert_eq(f.restore_calls, 2)
				helpers.assert_eq(f.clipboard(), f.initial)
			end)
		end)

		helpers.it(kind .. " preserves a new copy during refused restoration recovery", function()
			with_text(kind, function(f)
				f.queue(); f.finish_broker()
				if kind == "transform" then helpers.assert_true(f.stage()); f.finish_broker() end
				f.restore_refusal = "false"; helpers.assert_true(f.stage())
				helpers.assert_eq(f.restore_calls, 1)
				f.copy("RECOVERY COPY"); f.restore_refusal = nil
				local count = f.change_count
				helpers.assert_true(f.stage())
				helpers.assert_eq(f.restore_calls, 1)
				helpers.assert_eq(f.change_count, count)
				helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "RECOVERY COPY")
				helpers.assert_eq(f.text.has_pending_text_action(), false)
			end)
		end)
	end
end)
