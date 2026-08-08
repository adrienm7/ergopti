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
--- @return table eventtap_stub, fire_char function, fire_key function
local function make_eventtap_stub()
	-- Shared state: the handler installed by the MOST RECENT hs.eventtap.new() call
	local _handler   = nil
	local _running   = false

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
		local tap = {}
		function tap:start()  _running = true  ; return self end
		function tap:stop()   _running = false ; return self end
		function tap:isEnabled() return _running end
		return tap
	end

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
