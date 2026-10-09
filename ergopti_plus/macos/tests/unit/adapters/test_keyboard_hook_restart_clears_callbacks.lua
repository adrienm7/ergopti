--- tests/unit/adapters/test_keyboard_hook_restart_clears_callbacks.lua

--- ==============================================================================
--- MODULE: KeyboardHook Restart Clears Callbacks — Regression Test
--- DESCRIPTION:
--- Regression test for audit fix M-12: M.start() must clear ALL callbacks from
--- the previous lifecycle before reading the new opts. If a caller restarts the
--- hook without providing onKey, the old onKey handler must be silently dropped —
--- not carried over from the previous call.
---
--- RATIONALE:
--- Before the M-12 fix, _on_char and _on_key were only set when the new opts
--- provided them; absent keys left the previous function references alive,
--- causing ghost callbacks that fired for events the new caller never opted
--- into. This test encodes that failure mode so the regression can never silently
--- return.
---
--- APPROACH:
--- 1. Build a controlled eventtap stub that captures the handler closure each
---    time hs.eventtap.new() is called, and exposes fire_key() / fire_char()
---    helpers to invoke that handler synchronously.
--- 2. First start: { onChar = fn_a, onKey = fn_b }.
--- 3. Second start: { onChar = fn_c } — onKey intentionally omitted.
--- 4. Fire a non-printable key event via the second tap's handler.
--- 5. Assert fn_b (old onKey) is NOT called.
--- 6. Assert fn_c (new onChar) IS called for a printable character event.
--- ==============================================================================

local helpers = require("tests.helpers")


-- =======================================================
-- =======================================================
-- ======= 1/ Eventtap Stub with Handler Capture =========
-- =======================================================
-- =======================================================

--- Builds an hs.eventtap override whose .new() records the handler closure
--- and exposes fire_char() and fire_key() helpers for synchronous invocation.
--- The stub also satisfies isEnabled() so keyboard_hook.isRunning() works.
--- @param options table|nil Failure controls.
--- @return table eventtap_stub, fire_char function, fire_key function
local function make_eventtap_stub(options)
	options = options or {}
	-- Shared state: the handler installed by the MOST RECENT hs.eventtap.new() call
	local _handler   = nil
	local _running   = false
	local _taps = {}

	local stub = {}

	stub.keyStroke  = function() end
	stub.keyStrokes = function() end
	stub.checkKeyboardModifiers = function() return {} end
	stub.__keystrokes = {}
	stub.__reset = function() end
	stub.event = {
		types = { keyDown = 10, keyUp = 11, flagsChanged = 12 },
		newKeyEvent = function() return { post = function() end } end,
	}

	stub.new = function(_types, fn)
		-- Capture the new handler; previous tap's handler is discarded
		_handler = fn
		local tap = {
			handler = fn,
			start_failures = (#_taps == 0 and options.start_failures) or 0,
			stop_failures = (#_taps == 0 and options.stop_failures) or 0,
			start_calls = 0,
			stop_calls = 0,
		}
		function tap:start()
			self.start_calls = self.start_calls + 1
			_running = true
			if self.start_failures > 0 then
				self.start_failures = self.start_failures - 1
				error("native start exploded")
			end
			return self
		end
		function tap:stop()
			self.stop_calls = self.stop_calls + 1
			if self.stop_failures > 0 then
				self.stop_failures = self.stop_failures - 1
				error("native stop exploded")
			end
			_running = false
			return self
		end
		function tap:isEnabled()
			if options.is_enabled_error then error("native state query exploded") end
			return _running
		end
		_taps[#_taps + 1] = tap
		return tap
	end
	stub.__taps = _taps

	--- Fires the current handler with a synthetic printable-character event.
	--- @param char string Single printable character to deliver.
	local function fire_char(char)
		if not _handler then return end
		-- Build a minimal event object that satisfies the handler's pcall paths
		local event = {
			getCharacters = function() return char end,
			getKeyCode    = function() return 0 end,
		}
		return _handler(event)
	end

	--- Fires the current handler with a synthetic non-printable key event.
	--- @param keycode number Raw key code to deliver (default 53 = Escape).
	local function fire_key(keycode)
		if not _handler then return end
		-- getCharacters() returns "" so utf8.len yields 0, routing to the onKey path
		local event = {
			getCharacters = function() return "" end,
			getKeyCode    = function() return keycode or 53 end,
		}
		return _handler(event)
	end

	return stub, fire_char, fire_key
end


-- ============================================
-- ============================================
-- ======= 2/ Regression Tests ================
-- ============================================
-- ============================================

helpers.describe("KeyboardHook restart — old onKey cleared when omitted on second start()", function()

	helpers.it("fn_b (old onKey) is NOT called after restart without onKey", function()
		local eventtap_stub, _fire_char, fire_key = make_eventtap_stub()
		local M = helpers.load_with_stubs("adapters.keyboard_hook", {
			eventtap = eventtap_stub,
		})

		local fn_b_called = false
		local fn_a_called = false

		-- First start: register both callbacks
		M.start({
			onChar = function(_) fn_a_called = true end,
			onKey  = function(_) fn_b_called = true end,
		})

		-- Second start: only onChar provided; onKey intentionally omitted
		local fn_c_called = false
		M.start({
			onChar = function(_) fn_c_called = true end,
		})

		-- Fire a non-printable key event — only the second tap's handler is active
		fire_key(53)

		-- fn_b must not have been invoked: the old onKey was cleared by restart
		helpers.assert_true(
			not fn_b_called,
			"old onKey (fn_b) must NOT be called after restart without onKey"
		)
	end)


	helpers.it("fn_c (new onChar) IS called after restart", function()
		local eventtap_stub, fire_char, _fire_key = make_eventtap_stub()
		local M = helpers.load_with_stubs("adapters.keyboard_hook", {
			eventtap = eventtap_stub,
		})

		-- First start with fn_a
		M.start({
			onChar = function(_) end,
			onKey  = function(_) end,
		})

		-- Second start: new onChar = fn_c
		local fn_c_called = false
		M.start({
			onChar = function(_) fn_c_called = true end,
		})

		-- Fire a printable character event
		fire_char("a")

		helpers.assert_true(
			fn_c_called,
			"new onChar (fn_c) must be called for printable char events after restart"
		)
	end)


	helpers.it("fn_a (old onChar) is NOT called after restart replaces it with fn_c", function()
		local eventtap_stub, fire_char, _fire_key = make_eventtap_stub()
		local M = helpers.load_with_stubs("adapters.keyboard_hook", {
			eventtap = eventtap_stub,
		})

		local fn_a_called = false
		M.start({
			onChar = function(_) fn_a_called = true end,
		})

		-- Replace onChar with fn_c on second start
		M.start({
			onChar = function(_) end,
		})

		-- Fire a char event — fn_a must not be invoked
		fire_char("b")

		helpers.assert_true(
			not fn_a_called,
			"old onChar (fn_a) must NOT be called after it was replaced by restart"
		)
	end)


	helpers.it("no callbacks at all after restart with empty opts", function()
		local eventtap_stub, fire_char, fire_key = make_eventtap_stub()
		local M = helpers.load_with_stubs("adapters.keyboard_hook", {
			eventtap = eventtap_stub,
		})

		local fn_a_called = false
		local fn_b_called = false
		M.start({
			onChar = function(_) fn_a_called = true end,
			onKey  = function(_) fn_b_called = true end,
		})

		-- Restart with no opts — all callbacks must be cleared
		M.start({})

		fire_char("x")
		fire_key(48)

		helpers.assert_true(
			not fn_a_called,
			"old onChar must NOT fire after restart with empty opts"
		)
		helpers.assert_true(
			not fn_b_called,
			"old onKey must NOT fire after restart with empty opts"
		)
	end)

end)

helpers.describe("KeyboardHook native state query", function()
	helpers.it("fails closed when eventtap:isEnabled() throws", function()
		local eventtap_stub = make_eventtap_stub({ is_enabled_error = true })
		local M = helpers.load_with_stubs("adapters.keyboard_hook", {
			eventtap = eventtap_stub,
		})

		M.start({})
		local ok, running = pcall(M.isRunning)
		helpers.assert_true(ok,
			"a native eventtap state error must not escape into its caller")
		helpers.assert_eq(false, running,
			"an uncertain native eventtap state must fail closed")
	end)
end)

helpers.describe("KeyboardHook exact native ownership", function()
	helpers.it("retains a failed-stop tap, makes it inert and refuses replacement", function()
		local eventtap_stub, fire_char = make_eventtap_stub({ stop_failures = 1 })
		local M = helpers.load_with_stubs("adapters.keyboard_hook", {
			eventtap = eventtap_stub,
		})
		local calls = 0

		helpers.assert_eq(true, M.start({ onChar = function() calls = calls + 1 end }))
		helpers.assert_eq(false, M.stop(),
			"failed native stop must retain cleanup debt")
		fire_char("a")
		helpers.assert_eq(0, calls,
			"a retained cleanup-debt callback must be generation-inert")
		helpers.assert_eq(true, M.start({}),
			"a later start must first retry the exact retained cleanup")
		helpers.assert_eq(2, eventtap_stub.__taps[1].stop_calls)
		helpers.assert_eq(2, #eventtap_stub.__taps,
			"a successor may exist only after exact cleanup commits")
		helpers.assert_eq(true, M.stop())
	end)

	helpers.it("rolls back a partially enabled tap whose start throws", function()
		local eventtap_stub, fire_char = make_eventtap_stub({ start_failures = 1 })
		local M = helpers.load_with_stubs("adapters.keyboard_hook", {
			eventtap = eventtap_stub,
		})
		local calls = 0

		helpers.assert_eq(false, M.start({ onChar = function() calls = calls + 1 end }),
			"partial native activation must reject the adapter start")
		fire_char("a")
		helpers.assert_eq(0, calls,
			"the rejected candidate callback must be inert")
		helpers.assert_eq(1, eventtap_stub.__taps[1].stop_calls,
			"start failure must roll back the exact candidate")
		helpers.assert_eq(false, M.isRunning())
	end)
end)

helpers.describe("KeyboardHook raw event mode", function()
	helpers.it("preserves an advanced handler's event types and consume decision", function()
		local eventtap_stub, _fire_char, fire_key = make_eventtap_stub()
		local M = helpers.load_with_stubs("adapters.keyboard_hook", {
			eventtap = eventtap_stub,
		})

		local received = nil
		local returned_events = { { tag = "older-action" } }
		M.start({
			eventTypes = { 42 },
			onEvent = function(event)
				received = event
				return false, returned_events
			end,
		})

		local consumed, events = fire_key(42)
		helpers.assert_true(received ~= nil, "raw callback must receive the native event")
		helpers.assert_true(consumed == false, "raw callback must retain its consume decision")
		helpers.assert_true(events == returned_events,
			"raw callback must preserve the ordered event table returned to Hammerspoon")
	end)
end)

helpers.describe("KeyboardHook callback visibility", function()
	helpers.it("contains and file-logs throws from every eventtap callback kind", function()
		local eventtap_stub, fire_char, fire_key = make_eventtap_stub()
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.pcall = function(module_name, callback, ...)
			local results = table.pack(pcall(callback, ...))
			if not results[1] then
				errors[#errors + 1] = {
					module_name = module_name,
					error = tostring(results[2]),
				}
			end
			return table.unpack(results, 1, results.n)
		end
		package.loaded["infra.logger"] = logger
		local M = helpers.load_with_stubs("adapters.keyboard_hook", {
			eventtap = eventtap_stub,
		})

		helpers.assert_eq(true, M.start({
			onEvent = function() error("raw callback exploded") end,
		}))
		local raw_ok, raw_consumed = pcall(fire_key, 42)
		helpers.assert_eq(true, raw_ok,
			"a raw callback throw must not escape and disable the native tap")
		helpers.assert_eq(false, raw_consumed)

		helpers.assert_eq(true, M.start({
			onChar = function() error("character callback exploded") end,
		}))
		helpers.assert_eq(true, pcall(fire_char, "a"))

		helpers.assert_eq(true, M.start({
			onKey = function() error("key callback exploded") end,
		}))
		helpers.assert_eq(true, pcall(fire_key, 53))

		helpers.assert_eq(3, #errors,
			"every contained callback failure must reach the file logger boundary")
		for _, item in ipairs(errors) do
			helpers.assert_eq("adapters.keyboard_hook", item.module_name)
			helpers.assert_true(item.error:find("callback exploded", 1, true) ~= nil)
		end
	end)
end)
