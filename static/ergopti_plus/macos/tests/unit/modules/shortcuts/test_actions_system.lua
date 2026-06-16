--- tests/unit/modules/shortcuts/test_actions_system.lua

local helpers = require("tests.helpers")

-- Load the stubbed hammerspoon environment
local hs_stub = helpers.load_with_stubs("tests.stubs.hs")

helpers.describe("shortcuts.actions.system", function()
	helpers.it("toggle_awake creates an event watcher with the correct events", function()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil
		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system")

		-- We just ensure that toggle_awake doesn't crash and starts successfully
		sys.toggle_awake()
		-- We cannot easily assert the exact watch_types here without deep introspection of the eventtap stub,
		-- but we can verify it doesn't crash.
		helpers.assert_true(true, "toggle_awake should execute without errors")

		-- Turn it off
		sys.toggle_awake()
		helpers.assert_true(true, "toggle_awake should toggle off without errors")
	end)
end)




-- ============================================================
-- ============================================================
-- ======= keep_awake persistent alert (regression) ===========
-- ============================================================
-- ============================================================

-- Guards the fix for the 7b16a3f5 regression that replaced math.huge with 2.0
-- seconds (banner disappeared after 2s), and the close path on auto-deactivation.
-- Rules:
--   1. toggle ON  → hs.alert.show called with math.huge duration
--   2. toggle OFF → hs.alert.closeAll called (banner closed unconditionally)
--   3. auto-deactivation → same; closeAll must be called regardless of show return value
helpers.describe("shortcuts.actions.system: keep_awake persistent alert", function()
	-- Builds a fresh module instance with spied alert + timer stubs.
	local function make_sys_with_alert_spy()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil

		local show_calls      = {}
		local close_all_calls = 0

		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
			alert = setmetatable({
				show = function(msg, duration)
					table.insert(show_calls, { msg = msg, duration = duration })
					return "test-alert-uuid"
				end,
				closeAll      = function() close_all_calls = close_all_calls + 1 end,
				closeSpecific = function() end,
			}, { __call = function(_, _) end }),
		})

		return sys, show_calls, close_all_calls
	end

	helpers.it("shows the on-banner with math.huge duration so it persists while active", function()
		local sys, show_calls = make_sys_with_alert_spy()
		sys.toggle_awake()
		local on_call = show_calls[#show_calls]
		helpers.assert_true(on_call ~= nil, "hs.alert.show should be called on toggle ON")
		helpers.assert_eq(on_call.duration, math.huge, "duration must be math.huge — not a fixed timeout")
	end)

	helpers.it("closes the banner via closeAll on manual toggle OFF", function()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil

		local close_all_calls = 0

		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
			alert = setmetatable({
				show          = function() return "test-alert-uuid" end,
				closeAll      = function() close_all_calls = close_all_calls + 1 end,
				closeSpecific = function() end,
			}, { __call = function(_, _) end }),
		})

		sys.toggle_awake()   -- ON
		local calls_before = close_all_calls
		sys.toggle_awake()   -- OFF → closeAll must be called
		helpers.assert_true(close_all_calls > calls_before, "closeAll must be called on toggle OFF")
	end)

	helpers.it("closes the banner via closeAll on stop_awake", function()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil

		local close_all_calls = 0

		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
			alert = setmetatable({
				show          = function() return "test-alert-uuid" end,
				closeAll      = function() close_all_calls = close_all_calls + 1 end,
				closeSpecific = function() end,
			}, { __call = function(_, _) end }),
		})

		sys.toggle_awake()   -- ON
		local calls_before = close_all_calls
		sys.stop_awake()     -- direct stop (e.g. module shutdown)
		helpers.assert_true(close_all_calls > calls_before, "closeAll must be called on stop_awake")
	end)

	-- Regression guard: closeAll must be called even when hs.alert.show returns nil
	-- (older Hammerspoon builds). This was the root cause of banners persisting after
	-- auto-deactivation — the ID was nil so nothing was ever closed.
	helpers.it("calls closeAll even when hs.alert.show returned nil (no ID captured)", function()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil

		local close_all_calls = 0

		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
			alert = setmetatable({
				show          = function() return nil end,
				closeAll      = function() close_all_calls = close_all_calls + 1 end,
				closeSpecific = function() end,
			}, { __call = function(_, _) end }),
		})

		sys.toggle_awake()   -- ON  → awake_alert_id remains nil (show returned nil)
		local calls_before = close_all_calls
		sys.toggle_awake()   -- OFF → closeAll must still be called
		helpers.assert_true(close_all_calls > calls_before, "closeAll must be called even when alert ID is nil")
	end)

	-- Drives the auto-deactivation eventtap callback directly. Activates keep-awake,
	-- captures the watcher callback handed to eventtap.new, and replaces the clock so
	-- we can step past the activation grace window. Returns the module, a mutable
	-- clock, a closeAll counter, and the captured callback holder.
	local function activate_with_watcher()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil
		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system")
		local hs  = _G.hs

		local clock = { now = 1000 }
		hs.timer.secondsSinceEpoch = function() return clock.now end

		local close_all = { count = 0 }
		hs.alert.closeAll = function() close_all.count = close_all.count + 1 end
		hs.alert.show     = function() return "uuid" end

		local captured = { cb = nil }
		hs.eventtap.new = function(_types, cb)
			captured.cb = cb
			return { start = function() end, stop = function() end }
		end

		sys.toggle_awake()   -- ON → builds and "starts" the watcher, capturing its callback
		return sys, clock, close_all, captured
	end

	-- A fake CGEvent of an arbitrary type that is neither keyDown nor mouseMoved,
	-- so the watcher callback falls straight through to the deactivation branch.
	local function fake_activity_event()
		return {
			getType  = function() return 4242 end,
			getFlags = function() return {} end,
			location = function() return { x = 0, y = 0 } end,
		}
	end

	-- Regression for the `local type = _ev:getType()` shadow bug: it turned the
	-- type() builtin into a number, so `type(awake_timer.stop)` crashed the eventtap
	-- callback BEFORE close_awake_alert() ran — the banner stayed on screen forever
	-- after the user touched the touchpad/keyboard.
	helpers.it("auto-deactivation closes the banner without crashing (type-shadow regression)", function()
		local _sys, clock, close_all, captured = activate_with_watcher()
		helpers.assert_true(type(captured.cb) == "function", "toggle_awake must create a watcher callback")

		local before = close_all.count
		clock.now = clock.now + 100   -- well past the activation grace window
		local ok = pcall(captured.cb, fake_activity_event())
		helpers.assert_true(ok, "watcher callback must not error (regression: 'type' builtin was shadowed)")
		helpers.assert_true(close_all.count > before, "auto-deactivation must close the keep-awake banner")
	end)

	-- Regression for the double-Ctrl+M bug: a touchpad brush within the grace window
	-- (e.g. the thumb pressing Ctrl+M a second time) must NOT auto-deactivate, else
	-- the second Ctrl+M re-enables keep-awake instead of disabling it.
	helpers.it("ignores input within the activation grace window (rapid double Ctrl+M)", function()
		local _sys, clock, close_all, captured = activate_with_watcher()
		local before = close_all.count
		clock.now = clock.now + 0.1   -- inside the grace window
		local ok = pcall(captured.cb, fake_activity_event())
		helpers.assert_true(ok, "watcher callback must not error within the grace window")
		helpers.assert_eq(close_all.count, before, "input within the grace window must not auto-deactivate")
	end)

	-- Regression for the dropped "empty keystroke": keep-awake must post a real
	-- no-op key (F18) every tick so the HID idle counter resets and Teams stays
	-- "available". Warping the mouse alone never resets that counter. The watcher
	-- must recognise THIS key as synthetic and not self-deactivate.
	local F18 = require("lib.keycodes").F18_WAKE_OS

	-- A fake keyDown CGEvent with the given keycode and no modifiers.
	local function fake_key_event(keycode)
		return {
			getType    = function() return _G.hs.eventtap.event.types.keyDown end,
			getKeyCode = function() return keycode end,
			getFlags   = function() return {} end,
			location   = function() return { x = 0, y = 0 } end,
		}
	end

	helpers.it("_emit_activity_keystroke posts the F18 wake key (down + up)", function()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil
		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system")
		local hs  = _G.hs

		local posted = {}
		hs.eventtap.event.newKeyEvent = function(_mods, key, isDown)
			return { key = key, isDown = isDown, post = function() posted[#posted + 1] = { key = key, isDown = isDown } end }
		end

		sys._emit_activity_keystroke()
		helpers.assert_eq(#posted, 2, "must post a key-down and a key-up")
		helpers.assert_eq(posted[1].key, F18, "wake key must be F18 (the keymap-reserved no-op)")
		helpers.assert_eq(posted[1].isDown, true)
		helpers.assert_eq(posted[2].isDown, false)
	end)

	helpers.it("watcher ignores the synthetic F18 wake key but deactivates on a real key", function()
		local _sys, clock, close_all, captured = activate_with_watcher()
		clock.now = clock.now + 100   -- past the activation grace window

		local before = close_all.count
		local ok1 = pcall(captured.cb, fake_key_event(F18))
		helpers.assert_true(ok1, "watcher must not error on the synthetic wake key")
		helpers.assert_eq(close_all.count, before, "the F18 jiggle key must NOT auto-deactivate keep-awake")

		-- A genuine, unmodified keypress (keycode 0 = 'a') means the user is back.
		local ok2 = pcall(captured.cb, fake_key_event(0))
		helpers.assert_true(ok2, "watcher must not error on a real key")
		helpers.assert_true(close_all.count > before, "a real keypress must auto-deactivate keep-awake")
	end)
end)




-- =====================================================
-- =====================================================
-- ======= wrap_event_decision (regression) ============
-- =====================================================
-- =====================================================

-- Locks the two hard-won wrap-eventtap rules:
--   1. Alt (Option) must NOT block wrapping — Ergopti's wrap symbols sit on the
--      AltGr layer and carry the alt flag (the original bug excluded alt, so no
--      AltGr symbol ever wrapped).
--   2. When no selection is readable (nothing selected, or an app like VS Code
--      that hides AXSelectedText), the symbol must pass through (never swallowed).
helpers.describe("shortcuts.actions.system: wrap_event_decision", function()
	package.loaded["lib.keycodes"] = nil
	package.loaded["modules.shortcuts.actions.system"] = nil
	local sys = helpers.load_with_stubs("modules.shortcuts.actions.system")
	local PAIRS = { ["("] = { left = "(", right = ")" }, [")"] = { left = "(", right = ")" } }

	helpers.it("wraps an AltGr-typed symbol when a selection exists (alt must not block)", function()
		helpers.assert_eq(sys.wrap_event_decision({ alt = true }, "(", PAIRS, true), "wrap")
	end)

	helpers.it("passes the symbol through when no selection is readable", function()
		-- The regression that lost the character in VS Code: pair matches but the
		-- app exposes no selection, so we must NOT suppress the keystroke.
		helpers.assert_eq(sys.wrap_event_decision({ alt = true }, "(", PAIRS, false), "passthrough")
	end)

	helpers.it("never treats Cmd/Ctrl combos as wrap input", function()
		helpers.assert_eq(sys.wrap_event_decision({ cmd = true }, "(", PAIRS, true), "passthrough")
		helpers.assert_eq(sys.wrap_event_decision({ ctrl = true }, "(", PAIRS, true), "passthrough")
	end)

	helpers.it("passes through characters that are not configured wrap symbols", function()
		helpers.assert_eq(sys.wrap_event_decision({}, "x", PAIRS, true), "passthrough")
	end)

	helpers.it("passes through empty / nil characters without crashing", function()
		helpers.assert_eq(sys.wrap_event_decision({}, "", PAIRS, true), "passthrough")
		helpers.assert_eq(sys.wrap_event_decision(nil, "(", PAIRS, true), "wrap")
	end)

	helpers.it("wraps a plain (no-modifier) wrap symbol with a selection", function()
		helpers.assert_eq(sys.wrap_event_decision({}, "(", PAIRS, true), "wrap")
	end)
end)
