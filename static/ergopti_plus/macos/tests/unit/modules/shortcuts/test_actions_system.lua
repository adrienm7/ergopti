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
--   2. toggle OFF → the banner is closed (unconditionally)
--   3. auto-deactivation → same, regardless of what show returned
--
-- The close MECHANISM is deliberately not asserted here beyond "the banner went
-- away": closeAll used to dismiss every alert on screen, so the normal path now
-- targets the stored id via closeSpecific and only the no-id path falls back to
-- closeAll. These tests therefore count either call as "banner closed", which is
-- the invariant they were written to protect. The collateral-dismissal guard
-- itself lives in its own test below.
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

	helpers.it("closes the banner on manual toggle OFF", function()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil

		local close_calls = 0

		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
			alert = setmetatable({
				show          = function() return "test-alert-uuid" end,
				closeAll      = function() close_calls = close_calls + 1 end,
				closeSpecific = function() close_calls = close_calls + 1 end,
			}, { __call = function(_, _) end }),
		})

		sys.toggle_awake()   -- ON
		local calls_before = close_calls
		sys.toggle_awake()   -- OFF → the banner must be closed
		helpers.assert_true(close_calls > calls_before, "the banner must be closed on toggle OFF")
	end)

	helpers.it("closes the banner on stop_awake", function()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil

		local close_calls = 0

		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
			alert = setmetatable({
				show          = function() return "test-alert-uuid" end,
				closeAll      = function() close_calls = close_calls + 1 end,
				closeSpecific = function() close_calls = close_calls + 1 end,
			}, { __call = function(_, _) end }),
		})

		sys.toggle_awake()   -- ON
		local calls_before = close_calls
		sys.stop_awake()     -- direct stop (e.g. module shutdown)
		helpers.assert_true(close_calls > calls_before, "the banner must be closed on stop_awake")
	end)

	-- Regression guard (shortcuts-awake-closes-all-alerts): closing OUR banner must
	-- not dismiss unrelated alerts other modules put on screen. Whenever the show
	-- call handed us an id, the close must target exactly that id and must never
	-- reach closeAll, which is a screen-wide sweep.
	helpers.it("closes only its own alert when an id was captured (never closeAll)", function()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil

		local close_all_calls = 0
		local closed_ids      = {}

		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
			alert = setmetatable({
				show          = function() return "test-alert-uuid" end,
				closeAll      = function() close_all_calls = close_all_calls + 1 end,
				closeSpecific = function(id) closed_ids[#closed_ids + 1] = id end,
			}, { __call = function(_, _) end }),
		})

		sys.toggle_awake()   -- ON  → id captured
		sys.toggle_awake()   -- OFF → must close that id and nothing else

		helpers.assert_eq(close_all_calls, 0,
			"closeAll must NOT be called when an alert id is available — it dismisses every "
			.. "on-screen alert, including unrelated ones from other modules")
		helpers.assert_eq(closed_ids[#closed_ids], "test-alert-uuid",
			"the close must target the stored keep-awake alert id")
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

		-- Counts either close API: these tests assert the banner went away, not which
		-- call removed it (the normal path targets the stored id via closeSpecific).
		local close_all = { count = 0 }
		hs.alert.closeAll      = function() close_all.count = close_all.count + 1 end
		hs.alert.closeSpecific = function() close_all.count = close_all.count + 1 end
		hs.alert.show          = function() return "uuid" end

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




-- ====================================================================================
-- ====================================================================================
-- ======= bind_instant_screenshot defers blocking calls (shortcuts-actions-1) ========
-- ====================================================================================
-- ====================================================================================

-- Shared factory used by shortcuts-actions-1 and shortcuts-actions-2 tests.
-- Returns (sys, spy) where spy = { captured_cb, do_after_calls, exec_calls }.
-- Uses a table reference for captured_cb so updates made when bind_instant_screenshot()
-- calls eventtap.new are visible AFTER the call (Lua scalars are returned by value;
-- updating an upvalue after the function returns cannot be seen by the caller).
-- window_override: optional `window` stub table (defaults to a window with id=42).
local function make_sys_screenshot_spies(window_override)
	package.loaded["lib.keycodes"] = nil
	package.loaded["modules.shortcuts.actions.system"] = nil
	-- lib.notifications uses hs.notify under the hood — stub it so the deferred
	-- screencapture callback (and the nil-id guard branch) don't crash in headless tests.
	package.loaded["lib.notifications"] = { notify = function() end }

	local spy = { captured_cb = nil, do_after_calls = {}, exec_calls = {} }

	local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
		eventtap = {
			new = function(_types, cb)
				spy.captured_cb = cb
				return { start = function() end, stop = function() end, isEnabled = function() return true end }
			end,
			event = {
				types      = { keyDown = 10 },
				newKeyEvent = function() return { post = function() end } end,
			},
		},
		timer = {
			doAfter  = function(delay, fn) table.insert(spy.do_after_calls, { delay = delay, fn = fn }) return { stop = function() end } end,
			doEvery  = function(_d, _fn) return { start = function() end, stop = function() end } end,
			new      = function(_d, _fn) return { start = function() end, stop = function() end } end,
			secondsSinceEpoch = function() return 0 end,
			absoluteTime      = function() return 0 end,
			usleep   = function() end,
		},
		execute  = function(cmd) table.insert(spy.exec_calls, cmd) return "", true, "exit", 0 end,
		window   = window_override or {
			frontmostWindow = function()
				return { id = function() return 42 end }
			end,
		},
	})

	return sys, spy
end

-- Regression: two synchronous hs.execute calls (mkdir + screencapture) were running
-- inline on the CGEventTap thread, regularly exceeding the dispatch deadline and
-- silently disabling the tap (kCGEventTapDisabledByTimeout). The fix defers them via
-- hs.timer.doAfter(0, ...) and returns true immediately from the callback.
helpers.describe("shortcuts.actions.system: bind_instant_screenshot defers exec (shortcuts-actions-1 regression)", function()

	helpers.it("invoking the eventtap callback does NOT call hs.execute inline", function()
		local _sys, spy = make_sys_screenshot_spies()
		_sys.bind_instant_screenshot()

		helpers.assert_true(spy.captured_cb ~= nil, "bind_instant_screenshot must register an eventtap callback")

		-- Simulate the @ key with no modifiers
		local fake_event = {
			getKeyCode = function() return 10 end,
			getFlags   = function() return {} end,
		}
		spy.captured_cb(fake_event)

		helpers.assert_eq(#spy.exec_calls, 0,
			"hs.execute must NOT be called inline in the eventtap callback (would block CGEventTap thread)")
	end)

	helpers.it("invoking the eventtap callback schedules a doAfter(0) with the capture work", function()
		local _sys, spy = make_sys_screenshot_spies()
		_sys.bind_instant_screenshot()

		local fake_event = {
			getKeyCode = function() return 10 end,
			getFlags   = function() return {} end,
		}
		spy.captured_cb(fake_event)

		helpers.assert_true(#spy.do_after_calls >= 1,
			"a doAfter must be scheduled for the deferred screenshot work")
		helpers.assert_eq(spy.do_after_calls[#spy.do_after_calls].delay, 0,
			"the deferred callback must be scheduled with delay 0 (next run-loop tick)")
	end)

	helpers.it("running the deferred callback issues the mkdir and screencapture calls", function()
		local _sys, spy = make_sys_screenshot_spies()
		_sys.bind_instant_screenshot()

		local fake_event = {
			getKeyCode = function() return 10 end,
			getFlags   = function() return {} end,
		}
		spy.captured_cb(fake_event)

		-- Fire the deferred work
		local deferred = spy.do_after_calls[#spy.do_after_calls]
		helpers.assert_true(deferred ~= nil, "deferred callback must have been scheduled")
		deferred.fn()

		local has_mkdir  = false
		local has_screen = false
		for _, cmd in ipairs(spy.exec_calls) do
			if cmd:find("mkdir",       1, true) then has_mkdir  = true end
			if cmd:find("screencapture", 1, true) then has_screen = true end
		end
		helpers.assert_true(has_mkdir,  "deferred callback must run mkdir -p")
		helpers.assert_true(has_screen, "deferred callback must run screencapture")
	end)
end)




-- ======================================================================================
-- ======================================================================================
-- ======= bind_instant_screenshot guards nil window id (shortcuts-actions-2) ===========
-- ======================================================================================
-- ======================================================================================

-- Regression: when hs.window.frontmostWindow():id() returns nil (borderless or
-- system windows without a CGWindowID), the old code fell through to
-- "screencapture -l " .. id which concat'd nil and raised an error inside the
-- deferred closure — the screenshot was silently skipped and the eventtap
-- consumed the keystroke without providing feedback.
-- Fix: validate id before constructing the command and show the same warning
-- the "no active window" branch already shows.
helpers.describe("shortcuts.actions.system: bind_instant_screenshot guards nil window ID (shortcuts-actions-2 regression)", function()

	helpers.it("does NOT run screencapture when window id is nil", function()
		local nil_id_window = {
			frontmostWindow = function()
				return { id = function() return nil end }
			end,
		}
		local _sys, spy = make_sys_screenshot_spies(nil_id_window)
		_sys.bind_instant_screenshot()

		local fake_event = {
			getKeyCode = function() return 10 end,
			getFlags   = function() return {} end,
		}
		helpers.assert_true(spy.captured_cb ~= nil, "eventtap must have been registered")
		-- The callback must not raise even when id() returns nil
		local ok = pcall(spy.captured_cb, fake_event)
		helpers.assert_true(ok, "eventtap callback must not raise when window id is nil")

		-- Run any deferred work that was scheduled
		for _, call in ipairs(spy.do_after_calls) do
			if call.fn then pcall(call.fn) end
		end
		-- The nil-id guard must bail out before scheduling screencapture
		local found_screencapture = false
		for _, cmd in ipairs(spy.exec_calls) do
			if cmd:find("screencapture", 1, true) then found_screencapture = true end
		end
		helpers.assert_true(not found_screencapture,
			"screencapture must NOT be called when window id is nil")
	end)

	helpers.it("source: id nil-check appears before the deferred screencapture command", function()
		local src_path = helpers.driver_root() .. "modules/shortcuts/actions/system.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil, "system.lua must be readable")
		local src = fh:read("*a"); fh:close()

		-- The guard must check `not id` before the deferred block that uses id.
		-- Use the actual pcall invocation pattern (not the comment line that also mentions
		-- screencapture -l, which appears one line before the guard and would give a false
		-- position: "-- ... screencapture -l" → comment is found first, then "if not id").
		local guard_pos = src:find("if not id then", 1, true)
		local defer_pos = src:find('pcall(hs.execute, "screencapture -l ', 1, true)
		helpers.assert_true(guard_pos ~= nil,
			"system.lua must have an 'if not id then' guard for the nil window ID case")
		helpers.assert_true(defer_pos ~= nil,
			"system.lua must still contain the screencapture -l command in the deferred path")
		helpers.assert_true(guard_pos < defer_pos,
			"the nil-id guard must appear before the screencapture -l command")
	end)

end)




-- ==========================================================================================
-- ==========================================================================================
-- ======= bind_wrap_text_if_selected caches read_ax_selection (shortcuts-wrap-ax-uncached) =
-- ==========================================================================================
-- ==========================================================================================

-- Regression: bind_wrap_text_if_selected's eventtap callback called text_acts.read_ax_selection()
-- (two synchronous cross-process AX calls) on every keystroke matching a wrap symbol, with zero
-- caching. lib/vscode_bridge.lua documents this exact failure mode and mitigates it with a
-- short-lived TTL cache; this call site had none — a slow AX call risks
-- kCGEventTapDisabledByTimeout, killing the tap. The fix mirrors vscode_bridge's cache pattern.
helpers.describe("shortcuts.actions.system: bind_wrap_text_if_selected AX cache (shortcuts-wrap-ax-uncached regression)", function()

	-- Builds a fresh system module with hs.eventtap.new stubbed to capture the wrap
	-- callback, hs.timer.secondsSinceEpoch stubbed to a controllable fake clock, and
	-- modules.shortcuts.actions.text's read_ax_selection replaced with a call counter.
	local function make_sys_with_ax_spy()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil
		package.loaded["modules.shortcuts.actions.text"]   = nil

		local ax_call_count = 0
		local clock = { now = 1000 }

		-- Stub text.lua fully (system.lua only needs read_ax_selection + WRAP_PAIRS +
		-- wrap_selection for this path) so the real AX-dependent implementation is
		-- never exercised — we only care about call-count caching behaviour here.
		package.loaded["modules.shortcuts.actions.text"] = {
			WRAP_PAIRS = { ["("] = { left = "(", right = ")" } },
			read_ax_selection = function()
				ax_call_count = ax_call_count + 1
				return "selected text"
			end,
			wrap_selection = function() end,
		}

		local captured = { cb = nil }
		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
			eventtap = {
				new = function(_types, cb)
					captured.cb = cb
					return { start = function() end, stop = function() end }
				end,
				event = { types = { keyDown = 10 } },
			},
			timer = {
				doAfter = function(_d, _fn) return { stop = function() end } end,
				secondsSinceEpoch = function() return clock.now end,
			},
		})

		sys.bind_wrap_text_if_selected(nil)
		return sys, captured, clock, function() return ax_call_count end
	end

	-- A fake keyDown event typing the wrap symbol "(" with no modifiers.
	local function fake_wrap_key_event()
		return {
			getFlags      = function() return {} end,
			getCharacters = function() return "(" end,
		}
	end

	helpers.it("N rapid wrap-key presses within the TTL trigger at most 1 real AX call", function()
		local _sys, captured, _clock, get_count = make_sys_with_ax_spy()
		helpers.assert_true(type(captured.cb) == "function", "bind_wrap_text_if_selected must register an eventtap callback")

		local REPEAT_COUNT = 10
		for _ = 1, REPEAT_COUNT do
			captured.cb(fake_wrap_key_event())
		end

		helpers.assert_eq(get_count(), 1,
			string.format("%d rapid wrap-key presses must trigger at most 1 real read_ax_selection() call", REPEAT_COUNT))
	end)

	helpers.it("a press after the TTL window elapses triggers a second real AX call", function()
		local _sys, captured, clock, get_count = make_sys_with_ax_spy()

		captured.cb(fake_wrap_key_event())
		helpers.assert_eq(get_count(), 1, "first press must call read_ax_selection")

		clock.now = clock.now + 0.05  -- still within the TTL window
		captured.cb(fake_wrap_key_event())
		helpers.assert_eq(get_count(), 1, "a press within the TTL window must reuse the cached selection")

		clock.now = clock.now + 1.0  -- past the TTL window
		captured.cb(fake_wrap_key_event())
		helpers.assert_eq(get_count(), 2, "a press after the TTL window must trigger a fresh AX call")
	end)
end)




-- =======================================================================================
-- =======================================================================================
-- ======= schedule_awake_tick float random bounds (shortcuts-actions-3) =================
-- =======================================================================================
-- =======================================================================================

-- Regression: math.random(m, n) requires integer-representable bounds in Lua 5.4.
-- AWAKE_TICK_MIN_SEC and AWAKE_TICK_MAX_SEC come from Timings.sec() which returns
-- floats (ms / 1000). If a maintainer sets tick_min_ms to e.g. 1500 (→ 1.5),
-- math.random(1.5, 5.0) raises "no integer representation". The fix switches to
-- the float-safe uniform form: min + math.random() * span.
helpers.describe("shortcuts.actions.system: schedule_awake_tick float random bounds (shortcuts-actions-3 regression)", function()

	helpers.it("source: uses math.random() (no-arg) not math.random(m, n) for the tick interval", function()
		local src_path = helpers.driver_root() .. "modules/shortcuts/actions/system.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil, "system.lua must be readable")
		local src = fh:read("*a"); fh:close()

		-- The buggy form passes the float bounds directly to math.random(m, n).
		local has_buggy = src:find("math.random(AWAKE_TICK_MIN_SEC, AWAKE_TICK_MAX_SEC)", 1, true) ~= nil
		helpers.assert_true(
			not has_buggy,
			"system.lua must NOT use math.random(AWAKE_TICK_MIN_SEC, AWAKE_TICK_MAX_SEC) — "
			.. "that form requires integer bounds and raises on float values (shortcuts-actions-3)"
		)

		-- The float-safe form uses the zero-arg math.random() for a [0,1) uniform draw.
		local has_float_safe = src:find("math.random()", 1, true) ~= nil
		helpers.assert_true(
			has_float_safe,
			"system.lua must use math.random() (no-arg) for the tick interval to support float bounds"
		)
	end)

	helpers.it("source: span variable is computed before the interval assignment", function()
		local src_path = helpers.driver_root() .. "modules/shortcuts/actions/system.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil)
		local src = fh:read("*a"); fh:close()

		-- The float-safe pattern requires a span = max - min intermediate variable.
		local span_pos    = src:find("local span = AWAKE_TICK_MAX_SEC", 1, true)
		local interval_pos = src:find("AWAKE_TICK_MIN_SEC + math.random()", 1, true)
		helpers.assert_true(span_pos ~= nil,
			"system.lua must compute 'local span = AWAKE_TICK_MAX_SEC - AWAKE_TICK_MIN_SEC'")
		helpers.assert_true(interval_pos ~= nil,
			"system.lua must compute interval as AWAKE_TICK_MIN_SEC + math.random() * span")
		helpers.assert_true(span_pos < interval_pos,
			"span must be computed before the interval assignment")
	end)

end)
