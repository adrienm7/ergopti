--- tests/unit/adapters/test_hotkey_registrar.lua

--- ==============================================================================
--- MODULE: Hotkey Registrar Adapter Tests (Hammerspoon)
--- DESCRIPTION:
--- Exercises adapters/hotkey_registrar.lua against the HotkeyRegistrar port
--- contract (_shared/core/ports/HotkeyRegistrar.spec.js) using the recording
--- hs.hotkey stub, so every assertion is about what actually reached the OS rather
--- than about the adapter's own return value agreeing with itself.
---
--- COVERAGE:
--- 1. bind() canonicalises before touching the OS — two spellings of one chord
---    must not produce two live bindings that both fire.
--- 2. bind() refuses without reaching the OS when the chord is unparseable, and
---    returns nil rather than raising when the OS itself refuses.
--- 3. unbind() is idempotent and releases the underlying hotkey — a handle that
---    reported success while leaving the hotkey live is a permanent leak the UI
---    cannot show.
--- 4. setEnabled() suspends and resumes delivery without releasing the handle.
--- 5. Tokens are never reused, so a released handle stays unknown instead of
---    silently addressing a later binding.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==========================
-- ==========================
-- ======= 1/ Harness =======
-- ==========================
-- ==========================

--- Loads a pristine adapter together with the hs stub it will bind through.
--- Each case gets its own instance because the adapter holds module-level state
--- (the live-binding table and the token counter) that must not leak between
--- cases — a shared counter would make the "tokens are never reused" case pass
--- for the wrong reason.
--- @return table adapter, table hs_stub
local function fresh()
	local adapter = helpers.load_with_stubs("adapters.hotkey_registrar")
	return adapter, _G.hs
end





-- ==========================
-- ==========================
-- ======= 2/ Binding =======
-- ==========================
-- ==========================

helpers.describe("hotkey_registrar: bind", function()
	helpers.it("registers the chord with Hammerspoon and answers a handle", function()
		local adapter, hs_stub = fresh()
		local handle = adapter.bind("Ctrl+Shift+S", function() end)

		helpers.assert_eq(type(handle), "string", "bind() must answer an opaque handle")
		helpers.assert_eq(#hs_stub.hotkey._bound, 1, "exactly one hotkey must have reached the OS")
		helpers.assert_eq(hs_stub.hotkey._bound[1].key, "s", "the key Hammerspoon received")
		helpers.assert_eq(table.concat(hs_stub.hotkey._bound[1].mods, ","), "ctrl,shift",
			"the modifiers Hammerspoon received, in canonical order")
	end)

	helpers.it("canonicalises before binding, so spelling cannot double-register", function()
		local adapter, hs_stub = fresh()
		adapter.bind("shift+ctrl+s", function() end)

		helpers.assert_eq(table.concat(hs_stub.hotkey._bound[1].mods, ","), "ctrl,shift",
			"the caller's modifier order must not reach the OS")
	end)

	helpers.it("reports the canonical chord a handle holds", function()
		local adapter = fresh()
		local handle = adapter.bind("SHIFT+ctrl+s", function() end)

		helpers.assert_eq(adapter.chord_of(handle), "Ctrl+Shift+S",
			"the menu labels a binding from this, not from the string the caller passed")
	end)

	helpers.it("refuses an unparseable chord without touching the OS", function()
		local adapter, hs_stub = fresh()
		local handle = adapter.bind("Ctrl+Shift", function() end)

		helpers.assert_nil(handle, "a chord that names no key must be refused")
		helpers.assert_eq(#hs_stub.hotkey._bound, 0,
			"and must not reach Hammerspoon — a bind that got there would report success")
	end)

	helpers.it("refuses a non-function callback", function()
		local adapter, hs_stub = fresh()

		helpers.assert_nil(adapter.bind("Ctrl+T", "not a function"),
			"a string callback must be refused, not bound and crashed on first press")
		helpers.assert_eq(#hs_stub.hotkey._bound, 0, "and must not reach Hammerspoon")
	end)

	helpers.it("answers nil rather than raising when the OS refuses", function()
		local adapter, hs_stub = fresh()
		hs_stub.hotkey.bind = function() error("hotkey already claimed") end

		local ok, handle = pcall(adapter.bind, "Ctrl+Alt+Q", function() end)
		helpers.assert_true(ok, "a refused chord is an outcome the menu displays, not an exception")
		helpers.assert_nil(handle, "and must be reported as nil")
	end)

	helpers.it("delivers the press to the caller's callback", function()
		local adapter, hs_stub = fresh()
		local fired = 0
		adapter.bind("Ctrl+T", function() fired = fired + 1 end)

		hs_stub.hotkey._bound[1].pressed_fn()
		helpers.assert_eq(fired, 1, "the registered callback must be the one the OS holds")
	end)
end)





-- ==========================
-- ==========================
-- ======= 3/ Release =======
-- ==========================
-- ==========================

helpers.describe("hotkey_registrar: unbind", function()
	helpers.it("releases the underlying hotkey and reports true", function()
		local adapter, hs_stub = fresh()
		local handle = adapter.bind("Ctrl+T", function() end)
		local hotkey = hs_stub.hotkey._bound[1]

		helpers.assert_eq(adapter.unbind(handle), true, "releasing a live binding must report true")
		helpers.assert_eq(hotkey.deleted, true, "and must actually delete the hs hotkey")
		helpers.assert_eq(adapter.live_count(), 0, "leaving nothing behind in the adapter")
	end)

	helpers.it("is idempotent", function()
		local adapter = fresh()
		local handle = adapter.bind("Ctrl+T", function() end)
		adapter.unbind(handle)

		local ok, second = pcall(adapter.unbind, handle)
		helpers.assert_true(ok, "teardown paths unbind defensively — a second call must not raise")
		helpers.assert_eq(second, false, "and must report that there was nothing to release")
	end)

	helpers.it("retains and disables a handle when delete throws, then retries it", function()
		local adapter, hs_stub = fresh()
		local handle = adapter.bind("Ctrl+T", function() end)
		local hotkey = hs_stub.hotkey._bound[1]
		local original_delete = hotkey.delete
		local attempts = 0
		function hotkey:delete()
			attempts = attempts + 1
			if attempts == 1 then error("synthetic delete failure") end
			return original_delete(self)
		end

		helpers.assert_eq(adapter.unbind(handle), false)
		helpers.assert_eq(adapter.live_count(), 1,
			"a failed OS delete must retain the only retry capability")
		helpers.assert_eq(adapter.chord_of(handle), "Ctrl+T")
		helpers.assert_eq(hotkey.enabled, false,
			"the leaked global capture must be disabled while awaiting retry")

		helpers.assert_eq(adapter.unbind(handle), true)
		helpers.assert_eq(attempts, 2)
		helpers.assert_eq(hotkey.deleted, true)
		helpers.assert_eq(adapter.live_count(), 0)
	end)

	helpers.it("fences callback delivery when both native delete and disable throw", function()
		local adapter, hs_stub = fresh()
		local fired = 0
		local handle = adapter.bind("Ctrl+T", function() fired = fired + 1 end)
		local hotkey = hs_stub.hotkey._bound[1]
		function hotkey:delete() error("synthetic delete failure") end
		function hotkey:disable() error("synthetic disable failure") end

		helpers.assert_eq(adapter.unbind(handle), false,
			"the retained native object still requires a later delete retry")
		hotkey.pressed_fn()
		helpers.assert_eq(fired, 0,
			"a native teardown failure must not deliver a logically revoked action")
		helpers.assert_eq(adapter.live_count(), 1,
			"the opaque handle must remain available for exact cleanup retry")
	end)

	helpers.it("reports false for a handle it never issued", function()
		local adapter = fresh()
		helpers.assert_eq(adapter.unbind("hotkey#999"), false,
			"an unknown handle is not an error, but it is not a release either")
		helpers.assert_eq(adapter.unbind(nil), false, "nor is nil")
	end)

	helpers.it("never reuses a token, so a released handle stays unknown", function()
		local adapter = fresh()
		local first = adapter.bind("Ctrl+T", function() end)
		adapter.unbind(first)
		local second = adapter.bind("Ctrl+Y", function() end)

		helpers.assert_true(first ~= second,
			"reusing a token would let a stale handle silently address a later binding")
		helpers.assert_eq(adapter.chord_of(first), nil, "and the released handle must stay unknown")
	end)
end)





-- ===================================
-- ===================================
-- ======= 4/ Suspend & Resume =======
-- ===================================
-- ===================================

helpers.describe("hotkey_registrar: setEnabled", function()
	helpers.it("suspends without releasing", function()
		local adapter, hs_stub = fresh()
		local handle = adapter.bind("Ctrl+T", function() end)

		helpers.assert_eq(adapter.setEnabled(handle, false), true, "the handle must reach the requested state")
		helpers.assert_eq(hs_stub.hotkey._bound[1].enabled, false, "and the hs hotkey must be disabled")
		helpers.assert_eq(hs_stub.hotkey._bound[1].deleted, false,
			"a suspend that deleted the hotkey could never be resumed")
		helpers.assert_eq(adapter.chord_of(handle), "Ctrl+T", "and the handle must stay known")
	end)

	helpers.it("keeps delivery fenced and retries a failed native disable", function()
		local adapter, hs_stub = fresh()
		local fired = 0
		local handle = adapter.bind("Ctrl+T", function() fired = fired + 1 end)
		local hotkey = hs_stub.hotkey._bound[1]
		local original_disable = hotkey.disable
		local attempts = 0
		function hotkey:disable()
			attempts = attempts + 1
			if attempts == 1 then error("synthetic disable failure") end
			return original_disable(self)
		end

		helpers.assert_eq(adapter.setEnabled(handle, false), false)
		hotkey.pressed_fn()
		helpers.assert_eq(fired, 0,
			"logical suspension must not depend on the native disable succeeding")
		helpers.assert_eq(adapter.setEnabled(handle, false), true,
			"an unsettled native disable must remain retryable")
		helpers.assert_eq(attempts, 2)
	end)

	helpers.it("resumes", function()
		local adapter, hs_stub = fresh()
		local handle = adapter.bind("Ctrl+T", function() end)
		adapter.setEnabled(handle, false)

		helpers.assert_eq(adapter.setEnabled(handle, true), true, "resuming must report success")
		helpers.assert_eq(hs_stub.hotkey._bound[1].enabled, true, "and re-enable the hs hotkey")
	end)

	helpers.it("is a no-op when the handle already holds the requested state", function()
		local adapter, hs_stub = fresh()
		local handle = adapter.bind("Ctrl+T", function() end)

		helpers.assert_eq(adapter.setEnabled(handle, true), true,
			"asking for the state it already holds must succeed")
		helpers.assert_eq(hs_stub.hotkey._bound[1].enabled, true, "and leave it enabled")
	end)

	helpers.it("reports false for a handle it never issued", function()
		local adapter = fresh()
		helpers.assert_eq(adapter.setEnabled("hotkey#999", true), false,
			"an unknown handle must be reported, not silently accepted")
	end)
end)

helpers.describe("hotkey_registrar: delivery guard", function()
	helpers.it("audit pause fence: blocks every owned callback from one live predicate", function()
		local adapter, hs_stub = fresh()
		local paused = true
		local fired = 0
		helpers.assert_eq(adapter.set_delivery_guard(function() return not paused end), true)
		adapter.bind("Ctrl+T", function() fired = fired + 1 end)

		hs_stub.hotkey._bound[1].pressed_fn()
		helpers.assert_eq(fired, 0,
			"a registered native handle must not bypass the live process pause")

		paused = false
		hs_stub.hotkey._bound[1].pressed_fn()
		helpers.assert_eq(fired, 1,
			"the same handle must resume without a fragile native rebind sweep")
	end)

	helpers.it("audit pause fence: a throwing delivery guard fails closed", function()
		local adapter, hs_stub = fresh()
		local fired = 0
		adapter.set_delivery_guard(function() error("guard failure") end)
		adapter.bind("Ctrl+T", function() fired = fired + 1 end)

		-- Call directly: an escaped exception fails the surrounding test harness,
		-- while the fired counter proves the fail-closed behavioral result
		hs_stub.hotkey._bound[1].pressed_fn()
		helpers.assert_eq(fired, 0,
			"an unreadable lifecycle state must deny the action rather than guess active")
	end)
end)
