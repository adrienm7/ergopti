--- tests/unit/modules/hotstrings/test_injector_fast_channel.lua

--- ==============================================================================
--- MODULE: Injector Non-Forking Emit Channel
--- DESCRIPTION:
--- `emit_key` must not spawn a subprocess when the uinput channel is open.
---
--- WHY THIS IS THE ASSERTION:
--- The Linux daemon cannot take EVIOCGRAB — which is the root cause of the
--- `abcd` → `acd` corruption, because without a grab every physical keystroke
--- reaches the application in real time and interleaves with the ~90 ms
--- erase-then-type window of an expansion. The measured blocker is that
--- re-emitting a consumed event shells out `ydotool key <code>:<value>` ONCE PER
--- EVENT: a fork per physical keystroke, on the input path.
---
--- So the property that unblocks the grab is not "emit_key works" — it always
--- worked — it is "emit_key does not fork". That cannot be observed from a
--- return value: os.execute reports the same thing whether it was called once or
--- not at all, and io.popen does not raise on anything. The only way to assert it
--- is to make the spawn observable and require that it does not happen.
---
--- WHY NOT BATCHING:
--- `ydotool key` accepts several `code:value` pairs per call, so collapsing a
--- pump batch into one fork looks like the obvious fix. It is wrong: `_pump_one`
--- re-emits an event and THEN dispatches it, so an injection triggered by event
--- N would run before the re-emit of N itself — reintroducing exactly the
--- interleaving the grab exists to remove. The channel has to be non-forking,
--- which is what these tests pin.
--- ==============================================================================

local helpers = require("tests.helpers")


--- A stand-in for the uinput channel that records what it was asked to emit.
--- @param open boolean Whether the channel reports itself as open.
local function fake_channel(open)
	local ch = { emitted = {} }
	ch.is_open = function() return open end
	ch.emit = function(code, value)
		ch.emitted[#ch.emitted + 1] = { code = code, value = value }
		return true
	end
	return ch
end





-- ==============================================================
-- ==============================================================
-- ======= 1/ With the channel open, nothing is spawned =========
-- ==============================================================
-- ==============================================================

helpers.describe("injector: emit_key does not fork when the uinput channel is open", function()

	helpers.it("routes the event to the channel and never runs a shell command", function()
		local injector = helpers.load_module("modules.hotstrings.injector")
		local ch = fake_channel(true)
		injector._set_uinput(ch)

		-- Both spawn paths, made observable. shell_run() goes through os.execute;
		-- the test runner seam is deliberately NOT used here, because a test that
		-- asserts on the seam would pass on an implementation that bypasses it.
		local real_execute, real_popen = os.execute, io.popen
		local spawned = {}
		os.execute = function(cmd) spawned[#spawned + 1] = tostring(cmd) ; return true end
		io.popen = function(cmd) spawned[#spawned + 1] = tostring(cmd) ; return nil end

		local ok, err = pcall(function()
			injector.emit_key(30, 1)
			injector.emit_key(30, 0)
		end)

		os.execute, io.popen = real_execute, real_popen
		injector._set_uinput(nil)

		if not ok then error(err, 0) end

		helpers.assert_eq(#spawned, 0,
			"emit_key spawned " .. #spawned .. " subprocess(es) (" .. table.concat(spawned, " | ")
			.. ") with the non-forking channel open. Under EVIOCGRAB that is a fork per physical "
			.. "keystroke on the input path, which is the measured reason the daemon cannot grab")

		helpers.assert_eq(#ch.emitted, 2, "both events must reach the channel")
		helpers.assert_eq(ch.emitted[1].code, 30, "the keycode must be passed through unchanged")
		helpers.assert_eq(ch.emitted[1].value, 1, "the press must be passed through unchanged")
		helpers.assert_eq(ch.emitted[2].value, 0, "the release must be passed through unchanged")
	end)

	helpers.it("passes autorepeat to the channel without collapsing it", function()
		local injector = helpers.load_module("modules.hotstrings.injector")
		local ch = fake_channel(true)
		injector._set_uinput(ch)

		injector.emit_key(30, 2)
		injector._set_uinput(nil)

		helpers.assert_eq(#ch.emitted, 1, "the autorepeat must reach the channel")
		helpers.assert_eq(ch.emitted[1].value, 2,
			"emit_key must hand the channel the value it was given. The ydotool path collapses 2 "
			.. "into 1 because its wire format cannot express a repeat; routing that collapse "
			.. "through a channel that CAN express it would discard information for no reason")
	end)

end)





-- ==============================================================
-- ==============================================================
-- ======= 2/ Without a channel it refuses, it does not fork ====
-- ==============================================================
-- ==============================================================

helpers.describe("injector: emit_key has one channel and no fallback", function()

	helpers.it("refuses rather than spawning a subprocess when no channel is open", function()
		local injector = helpers.load_module("modules.hotstrings.injector")
		injector._set_uinput(nil)

		-- The seam is deliberately NOT used to observe this: a test that watches
		-- the seam would pass on an implementation that bypasses it. os.execute
		-- and io.popen are the two ways a process can be spawned at all.
		local real_execute, real_popen = os.execute, io.popen
		local spawned = {}
		os.execute = function(cmd) spawned[#spawned + 1] = tostring(cmd) ; return true end
		io.popen = function(cmd) spawned[#spawned + 1] = tostring(cmd) ; return nil end

		local ok, result = pcall(injector.emit_key, 30, 1)

		os.execute, io.popen = real_execute, real_popen
		if not ok then error(result, 0) end

		helpers.assert_eq(#spawned, 0,
			"a subprocess per event is the cost that made the grab impossible; falling "
				.. "back to it silently reintroduces the defect on exactly the machines "
				.. "where uinput is unavailable. Spawned: " .. table.concat(spawned, " | "))
		helpers.assert_eq(result, false,
			"and it must SAY it failed, so the daemon can refuse to grab rather than "
				.. "grabbing a keyboard it cannot give back")
	end)

	helpers.it("treats a channel that reports itself closed as no channel", function()
		local injector = helpers.load_module("modules.hotstrings.injector")
		-- is_open() is the contract: a channel that failed to open reports false
		-- rather than raising, and half-open must not read as open.
		injector._set_uinput(fake_channel(false))
		local result = injector.emit_key(30, 1)
		injector._set_uinput(nil)

		helpers.assert_eq(result, false,
			"a closed channel cannot carry the event, and reporting success for an "
				.. "event the application never received is the worst of the options")
	end)

end)





-- ==============================================================
-- ==============================================================
-- ======= 3/ Opening the channel fails closed ==================
-- ==============================================================
-- ==============================================================

helpers.describe("injector: open_fast_channel", function()

	helpers.it("returns false rather than raising when no uinput exists here", function()
		-- This machine has neither LuaJIT FFI nor /dev/uinput, which is exactly
		-- the case the daemon must survive: it keeps the subprocess path and does
		-- not take the grab.
		local injector = helpers.load_module("modules.hotstrings.injector")
		local ok, result = pcall(injector.open_fast_channel)
		helpers.assert_true(ok, "open_fast_channel must not raise: " .. tostring(result))
		helpers.assert_eq(type(result), "boolean",
			"it must answer with a boolean so the daemon can decide whether grabbing is safe")
	end)

end)
