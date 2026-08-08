--- tests/unit/modules/shortcuts/test_actions_system.lua

local helpers = require("tests.helpers")

-- Load the stubbed hammerspoon environment
local hs_stub = helpers.load_with_stubs("tests.stubs.hs")

helpers.describe("shortcuts.actions.system", function()
	helpers.it("toggle_awake creates an event watcher with the correct events", function()
		package.loaded["infra.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil
		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system")
		-- load_with_stubs builds a FRESH stub table per call, so the one captured
		-- at the top of this file is not the one the module just bound. Read the
		-- live global instead — the same trap the KEYSTROKES comment in
		-- tests/stubs/hs.lua documents for keystroke assertions.
		local hs_live = _G.hs
		hs_live.eventtap.__reset()

		sys.toggle_awake()

		-- This case used to say it "cannot easily assert the exact watch_types
		-- without deep introspection of the eventtap stub" and assert true twice.
		-- The stub was the problem, not the assertion: hs.eventtap.new discarded
		-- both its arguments. It records them now, so the claim in the case name
		-- is the claim being checked.
		local taps = hs_live.eventtap.__taps
		helpers.assert_eq(#taps, 1, "keep-awake must install exactly one input watcher")

		local watched = {}
		for _, t in ipairs(taps[1].types or {}) do watched[t] = true end
		local ev = hs_live.eventtap.event.types
		-- The point of the watcher is to stop the jiggler the moment the user is
		-- back. A list missing keyDown means typing does not count as being back,
		-- and the cursor keeps moving under their hands.
		helpers.assert_true(watched[ev.keyDown], "a key press must count as user activity")
		helpers.assert_true(watched[ev.leftMouseUp] or watched[ev.leftMouseDown],
			"so must a click")
		helpers.assert_true(taps[1].started >= 1, "the watcher must actually be started")

		sys.toggle_awake()
		helpers.assert_true(taps[1].stopped >= 1,
			"toggling keep-awake off must stop the watcher — an eventtap left running "
				.. "keeps consuming every event the user generates for the rest of the session")
	end)
end)


-- =======================================================================================
-- =======================================================================================
-- ======= CapsLock uses the HID state API (system-capslock-hid regression) ===============
-- =======================================================================================
-- =======================================================================================

local function load_capslock_fixture(toggle_impl)
	package.loaded["modules.shortcuts.actions.system"] = nil
	package.loaded["adapters.synthetic_input"] = nil
	package.loaded["adapters.key_state"] = {
		toggle_capslock = toggle_impl,
	}
	package.loaded["infra.keycodes"] = nil

	local logs = { debug = {}, error = {} }
	local logger = helpers.make_logger_stub()
	logger.debug = function(_, format, ...)
		local message = string.format(format, ...)
		if message:find("CapsLock", 1, true) then
			logs.debug[#logs.debug + 1] = message
		end
	end
	logger.error = function(_, format, ...)
		logs.error[#logs.error + 1] = string.format(format, ...)
	end
	package.loaded["infra.logger"] = logger

	local raw_key_attempts = 0
	package.loaded["adapters.synthetic_input"] = {
		emit_key_stroke = function()
			raw_key_attempts = raw_key_attempts + 1
			return true
		end,
	}
	local system = helpers.load_with_stubs("modules.shortcuts.actions.system")
	local function cleanup()
		package.loaded["modules.shortcuts.actions.system"] = nil
		package.loaded["adapters.synthetic_input"] = nil
		package.loaded["adapters.key_state"] = nil
		package.loaded["infra.logger"] = nil
	end
	return system, logs, function() return raw_key_attempts end, cleanup
end


helpers.describe("shortcuts.actions.system: CapsLock HID toggle (system-capslock-hid)", function()
	helpers.it("uses hs.hid.capslock.toggle and logs the returned ON/OFF state (system-capslock-hid)", function()
		local hid_calls = 0
		local enabled = false
		local system, logs, raw_key_attempts, cleanup = load_capslock_fixture(function()
			hid_calls = hid_calls + 1
			enabled = not enabled
			return enabled
		end)

		helpers.assert_eq(system.toggle_capslock(), true)
		helpers.assert_eq(system.toggle_capslock(), false,
			"false is a successful toggle-to-OFF result, not an API failure")
		helpers.assert_eq(hid_calls, 2)
		helpers.assert_eq(raw_key_attempts(), 0,
			"CapsLock is a flagsChanged HID state; a synthetic key pair silently no-ops on macOS")
		helpers.assert_eq(#logs.error, 0)
		helpers.assert_true(logs.debug[1] and logs.debug[1]:find("ON", 1, true) ~= nil)
		helpers.assert_true(logs.debug[2] and logs.debug[2]:find("OFF", 1, true) ~= nil)
		cleanup()
	end)

	helpers.it("logs an adapter failure and never reports a false success (system-capslock-hid)", function()
		local system, logs, raw_key_attempts, cleanup = load_capslock_fixture(function()
			return nil, "HID permission denied"
		end)

		local call_ok, result = pcall(system.toggle_capslock)
		helpers.assert_true(call_ok,
			"a user action must report the HID failure without escaping its callback")
		helpers.assert_nil(result)
		helpers.assert_eq(raw_key_attempts(), 0,
			"failure must not fall back to the known-silent newKeyEvent path")
		helpers.assert_eq(#logs.debug, 0,
			"the failure path must not emit the old unconditional success log")
		helpers.assert_eq(#logs.error, 1)
		helpers.assert_true(logs.error[1]:find("HID permission denied", 1, true) ~= nil)
		cleanup()
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
		package.loaded["infra.keycodes"] = nil
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
		package.loaded["infra.keycodes"] = nil
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
		package.loaded["infra.keycodes"] = nil
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
		package.loaded["infra.keycodes"] = nil
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
		package.loaded["infra.keycodes"] = nil
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
		package.loaded["infra.keycodes"] = nil
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
		-- Called directly: the regression this guards (the 'type' builtin shadowed
		-- inside the callback) raised, and a raise here now fails with that error
		-- rather than with a boolean. The assertion is the callback's EFFECT.
		captured.cb(fake_activity_event())
		helpers.assert_true(close_all.count > before, "auto-deactivation must close the keep-awake banner")
	end)

	-- Regression for the double-Ctrl+M bug: a touchpad brush within the grace window
	-- (e.g. the thumb pressing Ctrl+M a second time) must NOT auto-deactivate, else
	-- the second Ctrl+M re-enables keep-awake instead of disabling it.
	helpers.it("ignores input within the activation grace window (rapid double Ctrl+M)", function()
		local _sys, clock, close_all, captured = activate_with_watcher()
		local before = close_all.count
		clock.now = clock.now + 0.1   -- inside the grace window
		captured.cb(fake_activity_event())
		helpers.assert_eq(close_all.count, before, "input within the grace window must not auto-deactivate")
	end)

	-- Regression for the dropped "empty keystroke": keep-awake must post a real
	-- no-op key (F18) every tick so the HID idle counter resets and Teams stays
	-- "available". Warping the mouse alone never resets that counter. The watcher
	-- must recognise THIS key as synthetic and not self-deactivate.
	local F18 = require("infra.keycodes").F18_WAKE_OS

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
		package.loaded["infra.keycodes"] = nil
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
		captured.cb(fake_key_event(F18))
		helpers.assert_eq(close_all.count, before, "the F18 jiggle key must NOT auto-deactivate keep-awake")

		-- A genuine, unmodified keypress (keycode 0 = 'a') means the user is back.
		captured.cb(fake_key_event(0))
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
	package.loaded["infra.keycodes"] = nil
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
	package.loaded["infra.keycodes"] = nil
	package.loaded["modules.shortcuts.actions.system"] = nil
	-- lib.notifications uses hs.notify under the hood — stub it so the deferred
	-- screencapture callback (and the nil-id guard branch) don't crash in headless tests.
	package.loaded["infra.notifications"] = { notify = function() end }
	-- The capture goes through adapters.shell_runner, which captures `local hs = hs`
	-- at require-time. Cached from an earlier test file it stays bound to THAT file's
	-- hs stub, so the module under test spawns correctly while the assertions below
	-- read a different stub's records and see nothing. Cleared here rather than in
	-- load_with_stubs: several tests install their own adapter doubles into
	-- package.loaded before calling it, and a blanket adapter sweep wipes those.
	package.loaded["adapters.shell_runner"] = nil

	local spy = { captured_cb = nil, do_after_calls = {}, exec_calls = {}, tasks = {} }

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
		-- hs.task is stubbed rather than the ShellRunner module: the capture now
		-- goes through the real adapter, so stubbing at the OS boundary exercises
		-- that wiring instead of asserting against a hand-written double. It also
		-- keeps package.loaded clean — a leaked adapter stub would make every later
		-- test observe a driver that spawns nothing, silently.
		--
		-- The arity is the real one: hs.task.new(path, on_done, args) in the
		-- 3-argument form, and start() RETURNS a boolean (a stub returning nil
		-- would let a refused launch pass as success).
		task = {
			new = function(path, on_done, args)
				local rec = { path = path, on_done = on_done, args = args, started = false }
				table.insert(spy.tasks, rec)
				return {
					start     = function() rec.started = true return true end,
					terminate = function() end,
				}
			end,
		},
		window   = window_override or {
			frontmostWindow = function()
				return { id = function() return 42 end }
			end,
		},
	})

	return sys, spy
end

--- Returns the first recorded spawn whose binary basename matches, or nil.
--- @param spy table The spy table from make_sys_screenshot_spies.
--- @param basename string e.g. "mkdir", "screencapture".
--- @return table|nil
local function spawn_of(spy, basename)
	for _, rec in ipairs(spy.tasks) do
		if type(rec.path) == "string" and rec.path:find(basename, 1, true) then return rec end
	end
	return nil
end


--- Flattens a spawn's argv into one searchable string.
--- @param rec table|nil A recorded spawn.
--- @return string
local function argv_of(rec)
	if not rec or type(rec.args) ~= "table" then return "" end
	local parts = {}
	for _, a in ipairs(rec.args) do table.insert(parts, tostring(a)) end
	return table.concat(parts, " ")
end


-- Regression: two synchronous hs.execute calls (mkdir + screencapture) were running
-- inline on the CGEventTap thread, regularly exceeding the dispatch deadline and
-- silently disabling the tap (kCGEventTapDisabledByTimeout).
--
-- The first fix deferred them with hs.timer.doAfter(0, ...). That protected the tap
-- deadline but NOT the driver: the timer body runs on the same single runloop, so
-- the freeze simply moved one tick later, and every keystroke during mkdir +
-- screencapture was still lost. They are now real asynchronous subprocesses, and
-- these cases assert that — a doAfter would no longer satisfy them.
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

	helpers.it("invoking the eventtap callback launches the capture work as a subprocess", function()
		local _sys, spy = make_sys_screenshot_spies()
		_sys.bind_instant_screenshot()

		local fake_event = {
			getKeyCode = function() return 10 end,
			getFlags   = function() return {} end,
		}
		spy.captured_cb(fake_event)

		-- This is the half of the invariant the "no inline hs.execute" case cannot
		-- carry: silently doing NOTHING also calls no blocking API.
		helpers.assert_true(#spy.tasks >= 1,
			"the capture work must actually be launched, off the tap callback — a fix that "
			.. "merely stops calling hs.execute inline and drops the screenshot would pass "
			.. "the inline assertion above")
		local first = spy.tasks[1]
		helpers.assert_true(first.path:sub(1, 1) == "/",
			"the binary must be an absolute path: the Hammerspoon process does not inherit "
			.. "the login shell's PATH, so a bare name is not reliably resolvable")
		helpers.assert_true(first.started,
			"an hs.task that is created but never started is a subprocess that never runs, "
			.. "and start() is where a refused launch is reported")
	end)

	helpers.it("the capture runs only after the directory has been created", function()
		local _sys, spy = make_sys_screenshot_spies()
		_sys.bind_instant_screenshot()

		local fake_event = {
			getKeyCode = function() return 10 end,
			getFlags   = function() return {} end,
		}
		spy.captured_cb(fake_event)

		local mkdir = spawn_of(spy, "mkdir")
		helpers.assert_true(mkdir ~= nil, "the screenshots directory must still be created")
		helpers.assert_true(argv_of(mkdir):find("-p", 1, true) ~= nil,
			"mkdir needs -p: the parent Pictures/screenshots path may not exist either")

		-- The ordering assertion the old mechanism could not express. Both calls used
		-- to be issued back to back inside one deferred block, so nothing verified
		-- that the directory existed before screencapture tried to write into it.
		helpers.assert_nil(spawn_of(spy, "screencapture"),
			"the capture must NOT be launched before mkdir reports completion — a capture "
			.. "into a missing directory writes no file, and the old code notified success "
			.. "regardless")

		mkdir.on_done(0, "", "")

		local capture = spawn_of(spy, "screencapture")
		helpers.assert_true(capture ~= nil,
			"once the directory exists the capture must be launched")
		local argv = argv_of(capture)
		helpers.assert_true(argv:find("-l", 1, true) ~= nil,
			"the capture must still target the recorded window id with -l")
		helpers.assert_true(argv:find("42", 1, true) ~= nil,
			"and that id must be the one read from the frontmost window, not a placeholder")
		helpers.assert_eq(#spy.exec_calls, 0,
			"and none of this may go through the blocking shell at any point")
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
		-- Called directly: the regression is a raise, so a raise must fail this case
		-- with its own error rather than with a boolean.
		spy.captured_cb(fake_event)

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

	helpers.it("a nil window id launches no subprocess at all", function()
		-- Replaces a source grep for the old shell command string. Asserting the
		-- ORDER of two substrings in the file could only ever prove the guard is
		-- written above the call; this proves it actually stops it, and it keeps
		-- holding through any rewrite of the capture mechanism.
		local _sys, spy = make_sys_screenshot_spies({
			frontmostWindow = function() return { id = function() return nil end } end,
		})
		_sys.bind_instant_screenshot()

		spy.captured_cb({
			getKeyCode = function() return 10 end,
			getFlags   = function() return {} end,
		})

		helpers.assert_eq(#spy.tasks, 0,
			"a borderless or system window returns nil from :id(), and screencapture -l "
			.. "needs a valid CGWindowID — concatenating nil into the argv would raise "
			.. "inside the callback, where the throw is invisible")
		helpers.assert_eq(#spy.exec_calls, 0, "and nothing may reach the blocking shell either")
	end)

end)




-- ==========================================================================================
-- ==========================================================================================
-- ======= bind_wrap_text_if_selected caches read_ax_selection (shortcuts-wrap-ax-uncached) =
-- ==========================================================================================
-- ==========================================================================================

-- Regression: bind_wrap_text_if_selected's eventtap callback called text_acts.read_ax_selection()
-- (two synchronous cross-process AX calls) on every keystroke matching a wrap symbol, with zero
-- caching. infra/vscode_bridge.lua documents this exact failure mode and mitigates it with a
-- short-lived TTL cache; this call site had none — a slow AX call risks
-- kCGEventTapDisabledByTimeout, killing the tap. The fix mirrors vscode_bridge's cache pattern.
helpers.describe("shortcuts.actions.system: bind_wrap_text_if_selected AX cache (shortcuts-wrap-ax-uncached regression)", function()

	-- Builds a fresh system module with hs.eventtap.new stubbed to capture the wrap
	-- callback, hs.timer.secondsSinceEpoch stubbed to a controllable fake clock, and
	-- modules.shortcuts.actions.text's read_ax_selection replaced with a call counter.
	-- @param selection string|nil What read_ax_selection returns. nil is the COMMON
	--   real-world result (nothing selected, or an app hiding AXSelectedText such as
	--   VS Code/Electron) and was the case the original spy could not express.
	local function make_sys_with_ax_spy(selection)
		if selection == nil then selection = "selected text" end
		if selection == "" then selection = nil end
		package.loaded["infra.keycodes"] = nil
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
				return selection
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

	-- Regression: freshness was keyed on the cached VALUE
	-- (`_wrap_ax_selection_cache ~= nil`), so a nil selection was never cached and
	-- every wrap-key press re-paid both synchronous cross-process AX calls inline on
	-- the CGEventTap thread. nil is the COMMON result — nothing selected, or an app
	-- that hides AXSelectedText — so the cache was effectively inert exactly when it
	-- mattered. Same defect and same fix as infra/vscode_bridge.lua (3e403b254), whose
	-- sibling site this is. The spy above could not express it: it hardcoded a
	-- positive selection.
	helpers.it("N rapid presses with NO selection also trigger at most 1 real AX call", function()
		local _sys, captured, _clock, get_count = make_sys_with_ax_spy("")

		local REPEAT_COUNT = 10
		for _ = 1, REPEAT_COUNT do
			captured.cb(fake_wrap_key_event())
		end

		helpers.assert_eq(get_count(), 1,
			string.format("%d rapid wrap-key presses with nothing selected must still trigger at "
				.. "most 1 real read_ax_selection() call — a negative result must be cached like "
				.. "any other, or the cache is inert in the most common case", REPEAT_COUNT))
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
		-- Selected by a declaration unique to modules/shortcuts/actions/system.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function read_wrap_ax_selection_cached")
		helpers.assert_true(src ~= nil, "modules/shortcuts/actions/system.lua source must be locatable")
		if not src then return end

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
		-- Selected by a declaration unique to modules/shortcuts/actions/system.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function read_wrap_ax_selection_cached")
		helpers.assert_true(src ~= nil, "modules/shortcuts/actions/system.lua source must be locatable")
		if not src then return end

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
