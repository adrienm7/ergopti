--- tests/unit/adapters/test_text_sender_clipboard_serial.lua

--- ==============================================================================
--- MODULE: Regression — text_sender clipboard path serializes save/restore
--- DESCRIPTION:
--- Audit finding F-L8. The clipboard path called Clipboard.save() fresh on every
--- send with no cross-call state. Two clipboard sends within CLIPBOARD_RESTORE_DELAY_S
--- meant call #2's save() captured call #1's still-injected payload as "the user's
--- clipboard", and both restores then clobbered the real original. Fix: serialise —
--- on an overlapping send cancel the pending restore but KEEP the first-captured
--- original (mirrors keymap/utils.lua).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("text_sender clipboard path serializes save/restore", function()
	helpers.it("an overlapping second send does NOT re-save, and the original survives", function()
		local saves = 0
		local restores = {}
		local timers = {}
		package.loaded["adapters.clipboard"] = {
			save    = function() saves = saves + 1; return "ORIGINAL", true end,
			write   = function(_) return true end,
			restore = function(v) restores[#restores + 1] = v; return true end,
		}
		package.loaded["adapters.synthetic_input"] = {
			emit_key_stroke = function() return true end,
		}
		package.loaded["adapters.timer_scheduler"] = {
			after = function(_delay, callback)
				local handle = { timer = {}, callback = callback }
				timers[#timers + 1] = handle
				return handle, true
			end,
			cancel = function(handle)
				if handle then handle.timer = nil end
				return true
			end,
		}

		local TS = helpers.load_with_stubs("adapters.text_sender", {
			eventtap = { keyStroke = function() end, keyStrokes = function() end },
		})

		TS.send(("a"):rep(50), { mode = "clipboard" })  -- call #1: saves ORIGINAL, arms restore
		TS.send(("b"):rep(50), { mode = "clipboard" })  -- call #2: overlaps (restore #1 not fired)

		-- Root cause: the second save must NOT run while a restore is pending —
		-- otherwise it would capture call #1's injected "a..." as the user clipboard.
		helpers.assert_eq(saves, 1)

		-- Fire the surviving (last) restore; the clipboard must be the user's ORIGINAL.
		pcall(timers[#timers].callback)
		helpers.assert_true(#restores >= 1, "a restore must fire")
		helpers.assert_eq(restores[#restores], "ORIGINAL")

		package.loaded["adapters.clipboard"]   = nil
		package.loaded["adapters.synthetic_input"] = nil
		package.loaded["adapters.timer_scheduler"] = nil
		package.loaded["adapters.text_sender"] = nil
	end)
end)


local function load_failure_fixture(options)
	options = options or {}
	for _, name in ipairs({
		"adapters.text_sender", "adapters.clipboard", "adapters.synthetic_input",
		"adapters.timer_scheduler",
		"infra.logger", "infra.timings",
	}) do package.loaded[name] = nil end
	local original = { ["public.utf8-plain-text"] = "ORIGINAL" }
	local current = original
	local timers = {}
	local writes = 0
	local restores = 0
	local emits = 0
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.timings"] = { sec = function() return 0.15 end }
	package.loaded["adapters.clipboard"] = {
		save = function() return original, true end,
		write = function(text)
			writes = writes + 1
			current = text
			local outcome = options.write_outcomes and options.write_outcomes[writes]
			if outcome == "throw" then error("injected write failure") end
			if outcome == "false" then return false end
			return true
		end,
		restore = function(saved)
			restores = restores + 1
			local outcome = options.restore_outcomes and options.restore_outcomes[restores]
			if outcome == "throw" then error("injected restore failure") end
			if outcome == "false" then return false end
			current = saved
			return true
		end,
	}
	package.loaded["adapters.synthetic_input"] = {
		emit_key_stroke = function()
			emits = emits + 1
			return true
		end,
		defer_after_callback = function(_label, callback)
			if options.defer_synchronously then
				callback()
				return true
			end
			return false
		end,
	}
	local timer_calls = 0
	local cancel_calls = 0
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_delay, callback)
			timer_calls = timer_calls + 1
			local outcome = options.timer_outcomes and options.timer_outcomes[timer_calls]
			if outcome == "throw" then error("injected timer failure") end
			local handle = { callback = callback, stopped = false, timer = {} }
			timers[#timers + 1] = handle
			if outcome == "nil" then
				handle.timer = nil
				return handle, false
			end
			if options.timer_synchronously then
				callback()
				return handle, false
			end
			return handle, outcome ~= "uncommitted"
		end,
		cancel = function(handle)
			cancel_calls = cancel_calls + 1
			local cancel_outcome = options.cancel_results and options.cancel_results[cancel_calls]
			if options.cancel_returns_false or cancel_outcome == false then return false end
			if handle then
				handle.stopped = true
				handle.timer = nil
			end
			return true
		end,
	}
	local sender = helpers.load_with_stubs("adapters.text_sender", {})
	return {
		sender = sender,
		original = original,
		current = function() return current end,
		timers = timers,
		restores = function() return restores end,
		emits = function() return emits end,
		cancel_calls = function() return cancel_calls end,
	}
end


helpers.describe("text_sender clipboard path fails closed at native boundaries", function()
	helpers.it("mutate-then-false write restores and emits no Cmd+V", function()
		local f = load_failure_fixture({ write_outcomes = { "false" } })
		helpers.assert_eq(f.sender.send(("x"):rep(60), { mode = "clipboard" }), false)
		helpers.assert_eq(f.emits(), 0)
		helpers.assert_true(f.current() == f.original)
	end)

	helpers.it("restore refusal retains ownership and autonomously retries", function()
		local f = load_failure_fixture({ restore_outcomes = { "false", "success" } })
		helpers.assert_eq(f.sender.send(("y"):rep(60), { mode = "clipboard" }), true)
		helpers.assert_eq(f.emits(), 1)
		f.timers[1].callback()
		helpers.assert_eq(f.restores(), 1)
		helpers.assert_eq(#f.timers, 2)
		f.timers[2].callback()
		helpers.assert_eq(f.restores(), 2)
		helpers.assert_true(f.current() == f.original)
	end)

	helpers.it("timer refusal rolls back before publishing Cmd+V", function()
		local f = load_failure_fixture({ timer_outcomes = { "nil" } })
		helpers.assert_eq(f.sender.send(("z"):rep(60), { mode = "clipboard" }), false)
		helpers.assert_eq(f.emits(), 0)
		helpers.assert_true(f.current() == f.original)
	end)

	helpers.it("retains an uncommitted timer whose exact rollback is refused", function()
		local f = load_failure_fixture({
			timer_outcomes = { "uncommitted" },
			cancel_results = { false, false, true },
		})
		helpers.assert_eq(f.sender.send(("u"):rep(60), { mode = "clipboard" }), false)
		helpers.assert_eq(f.emits(), 0)
		helpers.assert_true(f.current() == f.original)
		helpers.assert_eq(f.cancel_calls(), 2,
			"failed acquisition and synchronous clipboard rollback both retry the exact timer")

		helpers.assert_eq(f.sender.send(("v"):rep(60), { mode = "clipboard" }), true,
			"the next send must retry retained cleanup before arming its own restore")
		helpers.assert_eq(f.cancel_calls(), 3)
		helpers.assert_eq(f.emits(), 1)
	end)

	helpers.it("bounds synchronous timer and fallback callbacks instead of recursing", function()
		local f = load_failure_fixture({
			restore_outcomes = { "false" },
			timer_synchronously = true,
			defer_synchronously = true,
		})
		-- Keep every restore attempt refused, including any accidental recursive one.
		package.loaded["adapters.clipboard"].restore = function()
			return false
		end
		helpers.assert_eq(f.sender.send(("q"):rep(60), { mode = "clipboard" }), false)
		helpers.assert_eq(f.emits(), 0,
			"Cmd+V must not publish before a stable restore callback exists")
		helpers.assert_eq(#f.timers, 2,
			"one initial arm and one retry are bounded; synchronous recursion is forbidden")
	end)
end)
