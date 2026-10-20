--- tests/unit/modules/shortcuts/text_actions/clipboard/test_plain_paste_publication.lua

--- ==============================================================================
--- MODULE: Plain Paste Native Publication
--- DESCRIPTION:
--- Actual Text/SyntheticInput/TimerScheduler owners retain a queued clipboard
--- pair through native generation validation, uncertain post and exact stop ACK.
--- Generation changes are causal copy models; post/stop failures are defensive
--- fault controls, not evidence that Cocoa physically delivered a key.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_sender = require("tests.support.text_sender_fixture")
require("logger")

local function tick(f, delay)
	for index, timer in ipairs(f.timers) do
		if not timer.stopped and timer.delay <= delay then
			table.remove(f.timers, index)
			f.options.absolute_time = f.options.absolute_time + math.ceil(timer.delay * 1e9)
			timer.callback()
			if timer.recurring and not timer.stopped then f.timers[#f.timers + 1] = timer end
			return true
		end
	end
	return false
end

local function emitted(f)
	local total = f.key_posts
	for _, delivery in ipairs(f.pump_deliveries) do total = total + #(delivery.events or {}) end
	return total
end

local function attempts(f, down)
	local total = 0
	for _, event in ipairs(f.key_attempts) do
		if event.key == "v" and event.isDown == down then total = total + 1 end
	end
	return total
end

local function with_plain(callback)
	helpers.with_stub_scope({
		"modules.shortcuts.actions.text", "modules.shortcuts.actions.text_continuation",
		"modules.shortcuts.actions.text_dispatch", "modules.shortcuts.actions.text_transform_grace",
	}, function()
		with_sender(function(f)
			local board = f.hs_overrides.pasteboard
			board.getContents = function() return f.clipboard()["public.utf8-plain-text"] end
			hs.pasteboard.getContents = board.getContents
			package.loaded["infra.paths"] = { shared = function() return nil end }
			package.loaded["infra.timings"] = { sec = function() return 0.01 end }
			f.text = require("modules.shortcuts.actions.text")
			function f.queue()
				helpers.assert_true(f.text.paste_as_plain_text())
				helpers.assert_true(tick(f, 0.01))
				helpers.assert_eq(emitted(f), 0, "the true broker must still own the native pair")
			end
			function f.expire()
				helpers.assert_true(tick(f, 0.01 + 1e-9), "an exact completion or retry timer must exist")
			end
			callback(f, board)
		end)
	end)
end

helpers.describe("plain paste validates ownership immediately before native Down", function()
	helpers.it("keeps healthy native pair and all-type restoration", function()
		with_plain(function(f)
			f.queue(); f.finish_broker()
			helpers.assert_eq(emitted(f), 2)
			helpers.assert_eq(f.restore_calls, 0)
			f.expire()
			helpers.assert_eq(f.clipboard(), f.initial)
			helpers.assert_eq(f.text.has_pending_text_action(), false)
		end)
	end)

	for _, same in ipairs({ false, true }) do
		helpers.it("refuses a queued foreign generation, identical text=" .. tostring(same), function()
			with_plain(function(f, board)
				f.queue()
				local epoch = f.synthetic.current_action_epoch()
				helpers.assert_true(board.setContents(same and "USER CLIPBOARD" or "FOREIGN BEFORE DOWN"))
				local foreign, count = f.clipboard(), f.change_count
				f.finish_broker()
				helpers.assert_eq(emitted(f), 0)
				helpers.assert_true(rawequal(f.synthetic.current_action_epoch(), epoch))
				helpers.assert_eq(f.last_terminal_status, "failed")
				helpers.assert_eq(f.complete_calls, 1)
				helpers.assert_eq(f.clipboard(), foreign)
				helpers.assert_eq(f.change_count, count)
				helpers.assert_eq(f.restore_calls, 0)
				helpers.assert_eq(f.text.has_pending_text_action(), false)
			end)
		end)
	end

	helpers.it("rejects a copy after any native trigger was posted but before its HID delivery", function()
		with_plain(function(f, board)
			f.queue()
			-- If the producer uses a CG trigger, let the real outside-tap owner post
			-- it while withholding its actual delivery. Direct native pairs stay queued.
			for _ = 1, 4 do if not tick(f, 0) then break end end
			helpers.assert_eq(emitted(f), 0)
			helpers.assert_true(board.setContents("COPY AFTER TRIGGER"))
			if f.last_trigger then f.deliver_posted_trigger(f.last_trigger) end
			f.finish_broker()
			helpers.assert_eq(emitted(f), 0, "cached HID admission cannot establish native clipboard ownership")
			helpers.assert_eq(f.clipboard()["public.utf8-plain-text"], "COPY AFTER TRIGGER")
			helpers.assert_eq(f.restore_calls, 0)
			helpers.assert_eq(f.text.has_pending_text_action(), false)
		end)
	end)

	helpers.it("starts restoration grace after a long real FIFO wait", function()
		with_plain(function(f)
			f.queue()
			f.options.absolute_time = f.options.absolute_time + 1000000000
			-- Deliver only long timers: the native broker remains deliberately held.
			local due = {}
			for _, timer in ipairs(f.timers) do
				if not timer.stopped and timer.delay == 0.01 then due[#due + 1] = timer end
			end
			for _, timer in ipairs(due) do timer.callback() end
			helpers.assert_eq(f.restore_calls, 0)
			helpers.assert_eq(f.clipboard()["public.html"], nil)
			f.finish_broker()
			helpers.assert_eq(emitted(f), 2)
			helpers.assert_eq(f.restore_calls, 0)
			f.expire()
			helpers.assert_eq(f.clipboard(), f.initial)
		end)
	end)

	helpers.it("keeps the pair outside an ambient callback collector", function()
		with_plain(function(f)
			f.synthetic.enter_callback()
			helpers.assert_true(f.text.paste_as_plain_text())
			local _, events = f.synthetic.leave_callback(false)
			helpers.assert_eq(events, nil)
			-- The real action timer runs only after its originating callback exits.
			helpers.assert_true(tick(f, 0.01))
			f.finish_broker()
			helpers.assert_eq(emitted(f), 2)
			f.expire()
			helpers.assert_eq(f.clipboard(), f.initial)
		end)
	end)

	helpers.it("fails closed on unavailable generation before Down and settles exact debt later", function()
		with_plain(function(f)
			f.queue(); f.count_failure = "throw"; f.finish_broker()
			helpers.assert_eq(emitted(f), 0)
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.last_terminal_status, "failed")
			helpers.assert_eq(f.restore_calls, 0)
			helpers.assert_true(f.text.has_pending_text_action())
			helpers.assert_eq(f.text.paste_as_plain_text(), false)
			f.count_failure = nil; f.expire()
			helpers.assert_eq(f.clipboard(), f.initial)
			helpers.assert_eq(f.text.has_pending_text_action(), false)
		end)
	end)

	helpers.it("cancels before Down without handing off events or restoring over pending native work", function()
		with_plain(function(f)
			f.queue()
			helpers.assert_eq(f.text.pause_text_actions(), false)
			helpers.assert_eq(f.restore_calls, 0)
			f.finish_broker()
			helpers.assert_eq(emitted(f), 0)
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.clipboard(), f.initial)
			helpers.assert_true(f.text.resume_text_actions())
		end)
	end)

	helpers.it("keeps grace after an uncertain Down, never replaying it", function()
		with_plain(function(f)
			f.key_observer = function(event)
				if event.key == "v" and event.isDown then error("controlled post-mutating Down exception") end
			end
			f.queue(); f.finish_broker()
			helpers.assert_eq(attempts(f, true), 1)
			helpers.assert_eq(attempts(f, false), 1)
			helpers.assert_eq(f.last_terminal_status, "failed")
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.restore_calls, 0)
			helpers.assert_true(f.text.has_pending_text_action())
			f.expire()
			helpers.assert_eq(f.clipboard(), f.initial)
			helpers.assert_eq(f.restore_calls, 1)
		end)
	end)

	helpers.it("retains mandatory Up and exact clipboard owner beyond ordinary retries", function()
		with_plain(function(f)
			local refuse = true
			f.key_observer = function(event)
				if event.key == "v" and not event.isDown and refuse then error("controlled uncertain Up") end
			end
			f.queue()
			for _ = 1, 12 do helpers.assert_true(tick(f, f.synthetic.PERIODIC_OWNER_TICK_SEC)) end
			helpers.assert_eq(attempts(f, true), 1)
			helpers.assert_true(attempts(f, false) > f.synthetic.SERIAL_POST_MAX_ATTEMPTS)
			helpers.assert_eq(f.complete_calls, 0)
			helpers.assert_eq(f.restore_calls, 0)
			helpers.assert_eq(f.text.pause_text_actions(), false)
			helpers.assert_eq(f.text.resume_text_actions(), false)
			refuse = false; f.finish_broker()
			helpers.assert_eq(attempts(f, true), 1)
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.restore_calls, 0)
			f.expire()
			helpers.assert_eq(f.clipboard(), f.initial)
			helpers.assert_true(f.text.resume_text_actions())
		end)
	end)

	helpers.it("retains native stop debt after Up until exact ACK and subsequent grace", function()
		with_plain(function(f)
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
			helpers.assert_eq(f.complete_calls, 0)
			helpers.assert_eq(f.restore_calls, 0)
			helpers.assert_eq(f.text.pause_text_actions(), false)
			owner.stop_failures = 0; f.finish_broker()
			helpers.assert_eq(f.complete_calls, 1)
			helpers.assert_eq(f.restore_calls, 0)
			f.expire()
			helpers.assert_eq(f.clipboard(), f.initial)
			helpers.assert_true(f.text.resume_text_actions())
		end)
	end)
end)
