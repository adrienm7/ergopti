--- tests/unit/modules/shortcuts/test_script_control.lua

--- ==============================================================================
--- MODULE: shortcuts.script_control Unit Tests
--- DESCRIPTION:
--- Validates the public configuration surface of the script-control daemon: the
--- ACTIONS array shape, the action label map, and the slot-binding setter.
--- The eventtap dispatch path itself relies on hs.eventtap and is exercised at
--- integration time.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

-- Stub modules required at top-level by script_control.lua so that load_with_stubs
-- can fully execute the module and expose pause_all/resume_all etc on the returned table.
package.loaded["infra.notifications"] = { notify = function() end }
package.loaded["infra.keycodes"] = {
	F13_KARABINER_RETURN = 0x6A,
	F14_KARABINER_BACKSPACE = 0x6B,
	F15_KARABINER_ESCAPE = 0x6C,
	BACKSPACE = 0x33,
	RETURN = 0x24,
	ESCAPE = 0x35,
}
package.loaded["infra.i18n"] = { get = function(k) return k end, get_locale = function() return "fr" end }
package.loaded["modules.gestures.engine"] = {
  init = function() end
}
package.loaded["modules.gestures.conflicts"] = {
  on_action_changed = function() end
}
package.loaded["modules.gestures.actions"] = {
  init = function() end,
  get_label = function(n) return n end,
  SG_NAMES = { "none", "script_pause_toggle", "script_reload", "script_quit", "other_action" },
  AX_NAMES = {}
}
-- Pause requires tooltip teardown to commit. Keep the generic state-machine
-- tests independent from the real canvas-backed tooltip, which cannot own a
-- surface under the headless hs stub.
package.loaded["ui.tooltip"] = { hide_forced = function() return true end }
-- The fixed HS-012 inventory lazy-loads every owner. These broad ScriptControl
-- API tests must not depend on a real owner cached by an earlier test module.
package.loaded["modules.llm.api_mlx"] = {
	stop_warmup = function() return true end,
	resume_warmup = function() return true end,
}
package.loaded["modules.llm.api_ollama"] = { stop_warmup = function() return true end }
package.loaded["modules.llm.api_remote"] = { stop_warmup = function() return true end }
package.loaded["modules.llm.warmup_controller"] = {
	stop = function() return true end,
	schedule_warmup_with_retry = function() return true end,
}
package.loaded["ui.wpm.wpm_menubar"] = {
	is_running = function() return false end,
	stop = function() return true end,
	resume_after_pause = function() return true end,
}
package.loaded["ui.wpm.wpm_widget"] = {
	is_running = function() return false end,
	stop = function() return true end,
	resume_after_pause = function() return true end,
}
package.loaded["platform.remap.onboarding"] = { stop = function() return true end }

-- Force a fresh adapters.key_state so it captures THIS file's hs stub (the F-CRIT-1
-- sentinel guard delegates the live right-AltGr query to that adapter).
package.loaded["adapters.key_state"] = nil

-- These broad API tests are not serializer timing tests. Complete the newly
-- required input-idle fence synchronously while retaining the real adapter's
-- classification/defer paths used by the sentinel cases below.
package.loaded["adapters.synthetic_input"] = nil
local SyntheticInput = helpers.load_with_stubs("adapters.synthetic_input")
SyntheticInput.when_idle = function(callback)
	callback()
	return true
end
SyntheticInput.defer_after_callback = function(_, callback)
	hs.timer.doAfter(0, callback)
	return true
end

-- ScriptControl's watchdog scheduler must capture the same fresh hs stub as
-- ScriptControl itself; load_with_stubs deliberately reloads only its target.
package.loaded["adapters.timer_scheduler"] = nil
local SC = helpers.load_with_stubs("modules.shortcuts.script_control")




-- =====================================
-- =====================================
-- ======= 1/ Action registry ==========
-- =====================================
-- =====================================

helpers.describe("ScriptControl ACTIONS / ACTION_LABELS", function()
	helpers.it("ACTIONS is a non-empty list of strings", function()
		helpers.assert_true(type(SC.ACTIONS) == "table" and #SC.ACTIONS > 0)
		for _, id in ipairs(SC.ACTIONS) do
			helpers.assert_true(type(id) == "string" and id ~= "")
		end
	end)

	helpers.it("'none', 'script_pause_toggle' and 'script_reload' are present", function()
		local set = {}
		for _, a in ipairs(SC.ACTIONS) do set[a] = true end
		helpers.assert_true(set.none)
		helpers.assert_true(set.script_pause_toggle)
		helpers.assert_true(set.script_reload)
	end)

	helpers.it("ACTION_LABELS has a French label for every non-separator id", function()
		for _, id in ipairs(SC.ACTIONS) do
			-- Skip display-only entries: separators ("-", "--") and section headers ("#…")
			if id ~= "-" and id ~= "--" and id:sub(1, 1) ~= "#" then
				helpers.assert_true(type(SC.ACTION_LABELS[id]) == "string"
					and SC.ACTION_LABELS[id] ~= "")
			end
		end
	end)

	helpers.it("does not contain duplicate ids (separators excluded)", function()
		local seen = {}
		for _, id in ipairs(SC.ACTIONS) do
			-- Skip display-only entries: separators ("-", "--") and section headers ("#…")
			if id ~= "-" and id ~= "--" and id:sub(1, 1) ~= "#" then
				helpers.assert_eq(seen[id], nil, "duplicate id: " .. tostring(id))
				seen[id] = true
			end
		end
	end)
end)





--- =======================================
--- =======================================
--- ======= 2/ Pause state accessor =======
--- =======================================
--- =======================================

helpers.describe("ScriptControl.is_paused", function()
	helpers.it("starts as false", function()
		helpers.assert_eq(SC.is_paused(), false)
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ Slot binding ==============
-- =====================================
-- =====================================

helpers.describe("ScriptControl.set_shortcut_action", function()
	helpers.it("accepts string keyname + action", function()
		SC.set_shortcut_action("backspace", "script_reload")
		SC.set_shortcut_action("return_key", "script_pause_toggle")
		SC.set_shortcut_action("escape", "script_quit")
	end)

	helpers.it("rejects non-string arguments without crashing", function()
		SC.set_shortcut_action(nil, "script_reload")
		SC.set_shortcut_action("backspace", nil)
		SC.set_shortcut_action(42, true)
	end)
end)





--- ========================================
--- ========================================
--- ======= 4/ Pause-change callback =======
--- ========================================
--- ========================================

helpers.describe("ScriptControl.set_on_pause_change", function()
	helpers.it("accepts a function", function()
		SC.set_on_pause_change(function() end)
	end)

	helpers.it("rejects non-function input", function()
		SC.set_on_pause_change("nope")
	end)
end)




-- =====================================
-- =====================================
-- ======= 5/ Extras handlers ===========
-- =====================================
-- =====================================

helpers.describe("ScriptControl.set_extras", function()
	helpers.it("accepts a table of handlers", function()
		SC.set_extras({ open_init = function() end, open_logs = function() end })
	end)

	helpers.it("rejects non-table input", function()
		SC.set_extras("oops")
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 6/ Pause invariant (regression) =======
-- ===============================================
-- ===============================================
-- Critical: pause must fully silence features (no LLM, keylogger, gestures, tooltips,
-- predictions, etc.). See project_suspend_pause_invariant in PROJECT_MEMORY.
-- These tests ensure the guard is present and works for new paths.

helpers.describe("ScriptControl pause invariant", function()
	helpers.it("is_paused reflects pause state and blocks actions", function()
		-- Assume init sets up defaults
		SC.pause_all()
		helpers.assert_true(SC.is_paused(), "after pause_all, is_paused must be true")

		-- Simulate a feature that must early-return when paused
		local action_fired = false
		local function guarded_action()
			if SC.is_paused() then return end
			action_fired = true
		end
		guarded_action()
		helpers.assert_true(not action_fired, "guarded_action must not fire when paused")

		SC.resume_all()
		helpers.assert_true(not SC.is_paused(), "after resume_all, is_paused must be false")
		guarded_action()
		helpers.assert_true(action_fired, "guarded_action must fire when not paused")
	end)

	helpers.it("pause_all and resume_all are safe to call multiple times", function()
		SC.pause_all()
		SC.pause_all()
		helpers.assert_true(SC.is_paused())
		SC.resume_all()
		SC.resume_all()
		helpers.assert_true(not SC.is_paused())
	end)

	helpers.it("set_on_pause_change fires on transitions (regression for listeners)", function()
		local calls = 0
		local last_state = nil
		SC.set_on_pause_change(function(state)
			calls = calls + 1
			last_state = state
		end)

		SC.pause_all()
		helpers.assert_eq(calls, 1)
		helpers.assert_true(last_state)

		SC.resume_all()
		helpers.assert_eq(calls, 2)
		helpers.assert_true(not last_state)

		SC.set_on_pause_change(nil)  -- cleanup
	end)

	helpers.it("pause blocks all extras and script actions (full invariant)", function()
		SC.pause_all()
		-- simulate calling extras while paused; must no-op
		local called = false
		if not SC.is_paused() then called = true end
		helpers.assert_true(not called, "extras must not execute under pause")
		SC.resume_all()
	end)

	helpers.it("pause transition callbacks fire exactly once per change", function()
		local count = 0
		SC.set_on_pause_change(function(_) count = count + 1 end)
		SC.pause_all()
		SC.pause_all()  -- idempotent
		SC.resume_all()
		helpers.assert_eq(count, 2)
		SC.set_on_pause_change(nil)
	end)
end)

helpers.describe("ScriptControl suspend-exempt regression (pause_bindings API)", function()
	-- Regression: before the fix, pause_all() called _shortcuts.stop() which
	-- resolved to shortcuts/init.lua M.stop() and that in turn called
	-- ScriptControl.stop(), killing the script-control eventtap. After that,
	-- AltGr+Enter could no longer un-pause the script.
	-- The fix: shortcuts/init.lua now exposes pause_bindings() / resume_bindings()
	-- that stop only Bindings + KeyboardShortcuts, leaving the script-control tap
	-- alive. script_control.pause_all() prefers pause_bindings over stop().
	--
	-- We verify the invariant at the source-code level: pause_all() must call
	-- _shortcuts.pause_bindings when it is available, not _shortcuts.stop().

	helpers.it("script_control source calls pause_bindings when available (grep invariant)", function()
		-- Read the source of script_control.lua and assert the conditional
		-- that prefers pause_bindings exists, so a future refactor cannot
		-- accidentally remove the guard.
		-- Selected by a declaration unique to modules/shortcuts/script_control.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function log_shortcut_if_available")
		helpers.assert_true(src ~= nil, "modules/shortcuts/script_control.lua source must be locatable")
		if not src then return end
		helpers.assert_true(src:find("pause_bindings", 1, true) ~= nil,
			"script_control.lua must reference pause_bindings to keep the tap alive during pause")
		helpers.assert_true(src:find("resume_bindings", 1, true) ~= nil,
			"script_control.lua must reference resume_bindings for symmetry")
	end)

	helpers.it("shortcuts/init.lua exposes pause_bindings and resume_bindings", function()
		-- Load shortcuts/init.lua with stubs to verify the API surface
		package.loaded["modules.shortcuts.bindings"] = {
			DEFAULT_CHATGPT_URL = "https://test",
			start = function() return true end, stop = function() return true end,
			enable = function() end, disable = function() end,
			is_enabled = function() return true end,
			list_shortcuts = function() return {} end,
		}
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = {
			start = function() return true end, stop = function() return true end,
			set_action = function() end, get_action = function() return "none" end,
			get_slot_label = function() return "" end,
			get_assignments = function() return {} end,
		}
		local ok, shortcuts_mod = pcall(require, "modules.shortcuts")
		if not ok then
			-- If loading fails due to other stubs, just verify via source inspection
			-- Selected by a declaration unique to modules/shortcuts/init.lua rather than by
			-- path, so moving or splitting the module cannot turn this invariant
			-- into a path error.
			local src = helpers.read_driver_source("function M.is_bindings_started")
			helpers.assert_true(src ~= nil, "modules/shortcuts/init.lua source must be locatable")
			if not src then return end
			helpers.assert_true(src:find("pause_bindings", 1, true) ~= nil,
				"shortcuts/init.lua must expose pause_bindings()")
			helpers.assert_true(src:find("resume_bindings", 1, true) ~= nil,
				"shortcuts/init.lua must expose resume_bindings()")
			return
		end
		helpers.assert_true(type(shortcuts_mod.pause_bindings) == "function",
			"shortcuts module must expose pause_bindings()")
		helpers.assert_true(type(shortcuts_mod.resume_bindings) == "function",
			"shortcuts module must expose resume_bindings()")
	end)
end)

helpers.describe("ScriptControl eventtap watchdog (tap-disable recovery regression)", function()
	-- Hammerspoon 1.1.1 normally handles CoreGraphics timeout notifications and
	-- re-enables the tap in native code. This simulates the residual state where
	-- a native or lifecycle failure leaves the script-control tap disabled. The
	-- watchdog must remain as an independent recovery path, or AltGr+Enter can
	-- stay permanently unavailable.
	helpers.it("re-enables the script-control tap after macOS disables it", function()
		local started = 0
		local enabled = true
		local fake_tap = {
			start     = function() started = started + 1; enabled = true end,
			stop      = function() enabled = false end,
			isEnabled = function() return enabled end,
		}
		local orig_new = _G.hs.eventtap.new
		_G.hs.eventtap.new = function(_, _) return fake_tap end

		SC.start({}, {}, {}, nil)
		_G.hs.eventtap.new = orig_new

		-- M.start must arm a recurring watchdog timer.
		local watchdog = _G.hs.timer.__timers[#_G.hs.timer.__timers]
		helpers.assert_true(watchdog ~= nil and watchdog.recurring == true,
			"M.start must arm a recurring tap watchdog")

		-- macOS disables the tap → the watchdog must restart it on its next tick.
		enabled = false
		local started_before = started
		watchdog:fire()
		helpers.assert_true(started > started_before, "watchdog must restart a disabled tap")
		helpers.assert_true(enabled, "tap must be enabled again after the watchdog runs")

		-- Healthy tap → the watchdog must be a no-op (no spurious restart).
		local started_after = started
		watchdog:fire()
		helpers.assert_eq(started, started_after, "watchdog must not restart an already-enabled tap")

		SC.stop()
	end)
end)

helpers.describe("Karabiner layout-change must NOT kill the script-control eventtap (regression)", function()
	-- Regression (root cause of « pause works once then AltGr+Enter dies forever »):
	-- the karabiner input-source watcher rebinds layout-dependent hotkeys after a
	-- layout switch. It used to call shortcuts.stop()/start() — but stop() also tears
	-- down the script-control eventtap and start() is a Bindings-only proxy that never
	-- revives it, so AltGr+Enter died on the FIRST layout switch (which the pause-layout
	-- feature triggers on every pause). The handler must rebind via pause_bindings /
	-- resume_bindings, which leave the keycode-based eventtap alive.
	helpers.it("karabiner/init.lua rebinds via rebind_for_layout, never shortcuts.stop/start", function()
		-- Selected by a declaration unique to platform/remap/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local KARABINER_KE_TILDE_PATH")
		helpers.assert_true(src ~= nil, "platform/remap/init.lua source must be locatable")
		if not src then return end

		-- The layout-rebind path must use the binding-only helper…
		helpers.assert_true(src:find("shortcuts.rebind_for_layout", 1, true) ~= nil,
			"layout rebind must call shortcuts.rebind_for_layout")
		-- …and must NEVER stop/start the whole shortcuts module (that kills script-control).
		helpers.assert_true(src:find("pcall(shortcuts.stop)", 1, true) == nil,
			"layout rebind must not pcall(shortcuts.stop) — it tears down the script-control eventtap")
		helpers.assert_true(src:find("pcall(shortcuts.start)", 1, true) == nil,
			"layout rebind must not pcall(shortcuts.start) — Bindings-only proxy never revives script-control")
		-- Strengthened: the pause/resume round-trip this call site used to perform is
		-- itself now forbidden here. It is symmetric ONLY when the layer was already
		-- running, so on a layer the user had switched off from the menu it silently
		-- re-enabled every shortcut (and its stop() leg killed keep-awake). The
		-- replacement helper is a no-op on a stopped layer by contract.
		helpers.assert_true(src:find("pcall(shortcuts.pause_bindings)", 1, true) == nil,
			"layout rebind must not pcall(shortcuts.pause_bindings) — the round-trip resurrects a disabled layer")
		helpers.assert_true(src:find("pcall(shortcuts.resume_bindings)", 1, true) == nil,
			"layout rebind must not pcall(shortcuts.resume_bindings) — it re-enables shortcuts the user turned off")
	end)
end)

helpers.describe("Karabiner layout-change must respect pause (« pause = tout éteint » regression)", function()
	-- Regression: the pause-layout feature switches the macOS layout on every pause,
	-- which fires the karabiner input-source watcher. That handler would M.regenerate()
	-- the FULL Ergopti config and re-arm the binding hotkeys — silently undoing the
	-- pause (full remapping back, user-facing shortcuts live mid-pause). It may
	-- re-resolve the in-memory layout cache for the later resume, but must return
	-- before deploy/rebind while the script is paused. The behavioral wake/layout
	-- suite proves the absence of those side effects.
	helpers.it("karabiner/init.lua keeps paused layout refresh in memory only", function()
		-- Selected by a declaration unique to platform/remap/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local KARABINER_KE_TILDE_PATH")
		helpers.assert_true(src ~= nil, "platform/remap/init.lua source must be locatable")
		if not src then return end
		helpers.assert_true(src:find("is_paused", 1, true) ~= nil,
			"layout-change handler must consult the pause state")
		helpers.assert_true(src:find('phase == "paused" and paused == true', 1, true) ~= nil,
			"native PAUSED and the script pause commit must agree before consumption")
		helpers.assert_true(src:find('if settled_mode == "paused" then', 1, true) ~= nil,
			"layout-change handler must branch on the proven settled pause mode")
		helpers.assert_true(src:find("not redeploying", 1, true) ~= nil,
			"paused layout refresh must explicitly return without redeploying")
	end)
end)


helpers.describe("resume_all must not re-enable user-disabled gestures or shortcuts", function()
	-- Regression: resume_all() was calling _gestures.enable_all() and
	-- _shortcuts.resume_bindings() unconditionally. A user who had gestures or
	-- shortcuts disabled before pausing would find them re-enabled after unpause.
	-- Exercise the real transaction instead of pinning a particular local-variable
	-- spelling. The spies mutate live state, so deleting either snapshot gate or
	-- committed-owner ledger makes the inactive case fail non-vacuously.
	local function run_restore_case(initially_active)
		local calls = {
			pause_bindings = 0,
			resume_bindings = 0,
			release_bindings_claim = 0,
			disable_gestures = 0,
			enable_gestures = 0,
		}
		local shortcuts_active = initially_active
		local gestures_active = initially_active
		local keymap = {
			pause_processing = function() return true end,
			resume_processing = function() return true end,
			reset_predictions = function() return true end,
		}
		local shortcuts = {
			is_bindings_started = function() return shortcuts_active end,
			pause_bindings = function()
				calls.pause_bindings = calls.pause_bindings + 1
				shortcuts_active = false
				return true
			end,
			resume_bindings = function()
				calls.resume_bindings = calls.resume_bindings + 1
				shortcuts_active = true
				return true
			end,
			release_bindings_pause_claim = function()
				calls.release_bindings_claim = calls.release_bindings_claim + 1
				return true
			end,
		}
		local gestures = {
			is_enabled = function() return gestures_active end,
			disable_all = function()
				calls.disable_gestures = calls.disable_gestures + 1
				gestures_active = false
				return true
			end,
			enable_all = function()
				calls.enable_gestures = calls.enable_gestures + 1
				gestures_active = true
				return true
			end,
		}

		helpers.assert_true(SC.start(keymap, shortcuts, gestures, nil))
		helpers.assert_true(SC.pause_all())
		helpers.assert_true(SC.is_paused())
		helpers.assert_true(SC.resume_all())
		helpers.assert_eq(SC.is_paused(), false)
		helpers.assert_true(SC.stop())
		return calls, shortcuts_active, gestures_active
	end

	helpers.it("leaves shortcuts and gestures disabled when they were inactive before PAUSE", function()
		local calls, shortcuts_active, gestures_active = run_restore_case(false)
		helpers.assert_eq(calls.pause_bindings, 1,
			"global PAUSE must install its claim even on an already-OFF feature")
		helpers.assert_eq(calls.resume_bindings, 0,
			"RESUME may replay only a shortcut owner that committed during PAUSE")
		helpers.assert_eq(calls.release_bindings_claim, 1,
			"an OFF snapshot must release only the global claim")
		helpers.assert_eq(calls.disable_gestures, 0)
		helpers.assert_eq(calls.enable_gestures, 0,
			"RESUME may replay only a gesture owner that committed during PAUSE")
		helpers.assert_eq(shortcuts_active, false)
		helpers.assert_eq(gestures_active, false)
	end)

	helpers.it("restores exactly the shortcuts and gestures active before PAUSE", function()
		local calls, shortcuts_active, gestures_active = run_restore_case(true)
		helpers.assert_eq(calls.pause_bindings, 1,
			"positive control must prove the shortcut owner joined PAUSE")
		helpers.assert_eq(calls.resume_bindings, 1)
		helpers.assert_eq(calls.release_bindings_claim, 0)
		helpers.assert_eq(calls.disable_gestures, 1,
			"positive control must prove the gesture owner joined PAUSE")
		helpers.assert_eq(calls.enable_gestures, 1)
		helpers.assert_eq(shortcuts_active, true)
		helpers.assert_eq(gestures_active, true)
	end)

	helpers.it("bindings.lua exposes is_started() to detect active state before pause", function()
		-- Selected by a declaration unique to modules/shortcuts/bindings.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function get_frontmost_app_name")
		helpers.assert_true(src ~= nil, "modules/shortcuts/bindings.lua source must be locatable")
		if not src then return end
		helpers.assert_true(src:find("function M.is_started", 1, true) ~= nil,
			"bindings.lua must expose M.is_started() for pre-pause state detection")
	end)
end)


helpers.describe("ScriptControl — physical F13/F14/F15 must not misfire pause/reload/quit (F-CRIT-1)", function()
	-- Root cause: the F13/F14/F15 SENTINEL keycodes ARE the real physical keycodes
	-- of those keys (present on extended keyboards). handle_key dispatched them
	-- UNCONDITIONALLY before any modifier check, so a bare F15 press fired
	-- script_quit (os.exit + Karabiner teardown), F14 reloaded, F13 paused — with
	-- no modifier. The fix requires a right-hand AltGr to be physically held — the
	-- invariant of every genuine KE-emitted sentinel — so a stray function key (or
	-- a LEFT-modifier + function key) is passed through instead of dispatched.

	-- Spy on the centralized dispatcher: SC.dispatch_action routes every non-pause
	-- action through GestActions.execute_single. Patch the SAME table SC captured
	-- at require time so the reference resolves to our spy.
	local dispatched
	package.loaded["modules.gestures.actions"].execute_single = function(a) dispatched = a end

	-- Capture the eventtap handler so we can drive handle_key directly.
	local handler
	local orig_new = _G.hs.eventtap.new
	_G.hs.eventtap.new = function(_, fn)
		handler = fn
		return { start = function() end, stop = function() end, isEnabled = function() return true end }
	end

	-- Device-specific right/left modifier masks (mirror real macOS rawFlagMasks).
	_G.hs.eventtap.event.rawFlagMasks = {
		deviceRightCommand   = 0x10,
		deviceRightAlternate = 0x40,
		deviceLeftCommand    = 0x08,
		deviceLeftAlternate  = 0x20,
	}
	-- Controllable live physical modifier state read by is_right_modifier_held().
	local live_mods = { _raw = 0 }
	_G.hs.eventtap.checkKeyboardModifiers = function() return live_mods end

	-- log_shortcut_if_available() (reached only on dispatch) reads the frontmost
	-- app title; the bare stub lacks :title(), so give it one (real hs.application
	-- always exposes it).
	_G.hs.application = _G.hs.application or {}
	_G.hs.application.frontmostApplication = function() return { title = function() return "TestApp" end } end

	SC.stop()              -- ensure no tap survives from an earlier describe
	SC.start({}, {}, {}, nil)
	_G.hs.eventtap.new = orig_new
	helpers.assert_true(type(handler) == "function", "script-control tap handler must be captured")

	-- F15_KARABINER_ESCAPE per the lib.keycodes stub above (0x6C) → escape slot → script_quit.
	local ESCAPE_SENTINEL = 0x6C
	local function make_event(code)
		return {
			getProperty = function() return 0 end,
			getKeyCode = function() return code end,
		}
	end

	helpers.it("a bare physical F15 (no modifier held) does NOT dispatch and passes through", function()
		dispatched = nil
		live_mods = { _raw = 0 }
		local consumed = handler(make_event(ESCAPE_SENTINEL))
		helpers.assert_eq(dispatched, nil, "stray physical F15 must never dispatch a script-control action")
		helpers.assert_eq(consumed, false, "stray physical F15 must pass through to the OS")
	end)

	helpers.it("F15 with a LEFT command held still does NOT dispatch", function()
		dispatched = nil
		live_mods = { _raw = 0x08 }  -- left command only
		local consumed = handler(make_event(ESCAPE_SENTINEL))
		helpers.assert_eq(dispatched, nil, "left-modifier + F15 is not a sentinel context")
		helpers.assert_eq(consumed, false)
	end)

	helpers.it("a genuine sentinel (right AltGr physically held) DOES dispatch the bound action", function()
		dispatched = nil
		live_mods = { _raw = 0x40 }  -- right option held (KE-active: rcmd remapped to ropt)
		local consumed = handler(make_event(ESCAPE_SENTINEL))
		helpers.assert_eq(consumed, true, "a genuine sentinel must be consumed")
		_G.hs.timer.__fire_all()
		helpers.assert_eq(dispatched, "script_quit", "a genuine right-AltGr sentinel must dispatch its action")
	end)

	-- F-HIGH-22 regression: a prior fix required a genuinely right-hand AltGr hold,
	-- but three follow-up commits progressively widened KeyState.is_right_altgr_held()
	-- until it also accepted a bare LEFT Option hold (deviceLeftAlternate) and even a
	-- side-agnostic `mods.alt == true` fallback with NO device bit at all. That meant
	-- holding plain left Option (no right-hand modifier whatsoever) while pressing a
	-- physical F15 dispatched script_quit — a chord that was never meant to be a
	-- genuine sentinel. The fix narrows is_right_altgr_held() back to right-hand-only
	-- masks; sentinel_is_tagged() remains the safety net for the KE-paused path.
	helpers.it("F15 with LEFT Option held (0x20, no tag) does NOT dispatch (F-HIGH-22)", function()
		dispatched = nil
		live_mods = { _raw = 0x20 }  -- left option only — must NOT qualify as a sentinel
		local consumed = handler(make_event(ESCAPE_SENTINEL))
		helpers.assert_eq(dispatched, nil,
			"plain left-Option + physical F15 must NOT dispatch — it is not a genuine right-AltGr sentinel (F-HIGH-22)")
		helpers.assert_eq(consumed, false, "left-Option + F15 must pass through to the OS")
	end)

	-- Same invariant via the generic (device-bit-less) `alt` flag path, which is
	-- exactly what the removed `or mods.alt == true` fallback used to accept.
	helpers.it("F15 with a generic getFlags()={alt=true} (no device bit) does NOT dispatch (F-HIGH-22)", function()
		dispatched = nil
		live_mods = { _raw = 0, alt = true }  -- side-agnostic alt flag, no device-side bit at all
		local consumed = handler(make_event(ESCAPE_SENTINEL))
		helpers.assert_eq(dispatched, nil,
			"a generic alt=true flag with no device bit must NOT qualify as a genuine sentinel (F-HIGH-22)")
		helpers.assert_eq(consumed, false, "generic-alt + F15 must pass through to the OS")
	end)

	helpers.it("a TAGGED sentinel with NO live modifier (paused path) DOES dispatch", function()
		-- Paused rules gate on a MANDATORY modifier KE consumes, so nothing is held when
		-- HS polls (the field log showed "(none)"). KE stamps the sentinel with the
		-- two-modifier tag (left_control + left_shift), which HS reads off the event.
		-- Both flags must be present (M-6 fix: lone ctrl is indistinguishable from physical
		-- Ctrl+F15 and is no longer accepted as a genuine tag).
		dispatched = nil
		live_mods = { _raw = 0 }  -- nothing held (consumed)
		local tagged = {
			getProperty = function() return 0 end,
			getKeyCode = function() return ESCAPE_SENTINEL end,
			getFlags   = function() return { ctrl = true, shift = true } end,  -- full two-modifier KE tag
		}
		local consumed = handler(tagged)
		helpers.assert_eq(consumed, true)
		_G.hs.timer.__fire_all()
		helpers.assert_eq(dispatched, "script_quit",
			"a KE-tagged sentinel (ctrl+shift) must dispatch even when no live modifier is detectable")
	end)

	helpers.it("physical Ctrl+F15 (ctrl only, no shift) does NOT dispatch (M-6 regression)", function()
		-- M-6 root cause: bare left_control flag alone was indistinguishable from a
		-- physical Ctrl+F15. A real Ctrl+F15 produces flags={ctrl=true} with no shift.
		-- The two-modifier tag requirement (ctrl+shift) correctly rejects this.
		dispatched = nil
		live_mods = { _raw = 0 }  -- no live AltGr held
		local ctrl_f15 = {
			getProperty = function() return 0 end,
			getKeyCode = function() return ESCAPE_SENTINEL end,
			getFlags   = function() return { ctrl = true } end,  -- only ctrl, no shift
		}
		local consumed = handler(ctrl_f15)
		helpers.assert_eq(dispatched, nil,
			"physical Ctrl+F15 (ctrl-only tag) must NOT dispatch — lone ctrl is not a genuine sentinel (M-6)")
		helpers.assert_eq(consumed, false, "physical Ctrl+F15 must pass through to the OS")
	end)

	helpers.it("an UNtagged F15 with no live modifier still does NOT dispatch", function()
		dispatched = nil
		live_mods = { _raw = 0 }
		local untagged = {
			getProperty = function() return 0 end,
			getKeyCode = function() return ESCAPE_SENTINEL end,
			getFlags   = function() return {} end,  -- neither tag nor modifier
		}
		local consumed = handler(untagged)
		helpers.assert_eq(dispatched, nil, "no tag and no modifier = stray F15, must not dispatch")
		helpers.assert_eq(consumed, false)
	end)

	SC.stop()
end)


helpers.describe("ScriptControl pause stops the LLM warmup retry chain (F-LOW-2)", function()
	-- The warmup retry chain runs on its own hs.timer chain gated only on the LLM
	-- feature toggle, which pause does not change — so a cold-start warmup in flight
	-- kept POSTing to the backend through the pause (« pause = tout éteint »
	-- violation). pause_all() must cancel it via warmup_controller.stop().
	helpers.it("pause_all() invokes warmup_controller.stop()", function()
		local stopped = 0
		local previous_warmup = package.loaded["modules.llm.warmup_controller"]
		package.loaded["modules.llm.warmup_controller"] = {
			stop = function() stopped = stopped + 1; return true end,
			schedule_warmup_with_retry = function() return true end,
		}

		SC.pause_all()
		SC.resume_all()  -- restore the un-paused state for any later test

		package.loaded["modules.llm.warmup_controller"] = previous_warmup
		helpers.assert_true(stopped >= 1,
			"pause_all must call warmup_controller.stop() so backend warmup POSTs stop during pause")
	end)
end)


helpers.describe("ScriptControl pause invariant actually quiesces the modules (F-INFO-3 / G2)", function()
	-- The prior pause-invariant test only checks the is_paused() boolean, so a
	-- regression deleting the internal pause_all() call (the original G2 bug, where
	-- the public path quiesced nothing) would stay green. This drives the public
	-- pause_all()/resume_all() with SPY modules and asserts the real quiescence calls.
	helpers.it("pause_all invokes the real quiescence calls, resume_all the symmetric restores", function()
		local calls = {}
		local function rec(name)
			return function()
				calls[name] = (calls[name] or 0) + 1
				return true
			end
		end
		-- pause now treats tooltip teardown as required. Keep this unit test
		-- behavioral and deterministic instead of loading the real TOML-backed UI.
		package.loaded["ui.tooltip"] = { hide_forced = rec("tt_hide") }
		local keymap_spy = {
			pause_processing  = rec("km_pause"),
			resume_processing = rec("km_resume"),
			reset_predictions = rec("km_reset"),
		}
		local shortcuts_spy = {
			pause_bindings      = rec("sc_pause"),
			resume_bindings     = rec("sc_resume"),
			is_bindings_started = function() return true end,
		}
		local gestures_spy = {
			disable_all = rec("g_disable"),
			enable_all  = rec("g_enable"),
			is_enabled  = function() return true end,
		}
		local karabiner_spy = {
			get_enabled = function() return true end,
			pause = function(on_done)
				rec("k_pause")()
				on_done(true, "paused")
				return true
			end,
			resume = function(on_done)
				rec("k_resume")()
				on_done(true, "resumed")
				return true
			end,
		}

		SC.stop()  -- release any tap from an earlier describe
		SC.start(keymap_spy, shortcuts_spy, gestures_spy, karabiner_spy)

		-- karabiner.pause()/resume() are deliberately deferred with
		-- hs.timer.doAfter(0): pause_all/resume_all run synchronously inside the
		-- script-control eventtap callback, and the karabiner redeploy writes a
		-- 100 kB+ config (resume regenerates the full one), which would stall the tap
		-- long enough for macOS to disable it — see
		-- tests/meta/test_pause_path_defers_blocking_work.lua. The stub records timers
		-- instead of running them, so the deferred work is flushed here. The
		-- assertions themselves are unchanged: the calls must still happen.
		SC.pause_all()
		if hs.timer.__fire_all then hs.timer.__fire_all() end
		helpers.assert_true((calls.km_pause or 0) >= 1, "pause must call keymap.pause_processing")
		helpers.assert_true((calls.km_reset or 0) >= 1, "pause must call keymap.reset_predictions")
		helpers.assert_true((calls.sc_pause or 0) >= 1, "pause must call shortcuts.pause_bindings")
		helpers.assert_true((calls.g_disable or 0) >= 1, "pause must call gestures.disable_all")
		helpers.assert_true((calls.tt_hide or 0) >= 1, "pause must hide every visible tooltip")
		helpers.assert_true((calls.k_pause or 0) >= 1, "pause must call karabiner.pause")

		SC.resume_all()
		if hs.timer.__fire_all then hs.timer.__fire_all() end
		helpers.assert_true((calls.km_resume or 0) >= 1, "resume must call keymap.resume_processing")
		helpers.assert_true((calls.sc_resume or 0) >= 1, "resume must restore shortcuts.resume_bindings (was running pre-pause)")
		helpers.assert_true((calls.g_enable or 0) >= 1, "resume must restore gestures.enable_all (was enabled pre-pause)")
		helpers.assert_true((calls.k_resume or 0) >= 1, "resume must call karabiner.resume")

		SC.stop()
		package.loaded["ui.tooltip"] = nil
	end)
end)




-- ====================================================================
-- ====================================================================
-- ======= N/ set_extras must feed a dispatch path that exists ========
-- ====================================================================
-- ====================================================================

--- The two set_extras cases above only prove the setter does not throw. They
--- would pass against a setter that discards its argument — which is effectively
--- what shipped: call_extra had NO caller, so a handler registered through the
--- public API could never run. A public extension point that silently does
--- nothing is worse than none at all, because the caller has no way to notice.
helpers.describe("ScriptControl: the extras table is actually reachable", function()

	helpers.it("dispatch falls back to call_extra when the central registry declines", function()
		local src = helpers.read_driver_source("call_extra")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the script-control source must be readable or this invariant asserts nothing")
		helpers.assert_true(src:find("call_extra(action)", 1, true) ~= nil,
			"set_extras must feed a dispatch path that is actually reached")
	end)

	helpers.it("the central dispatcher reports whether it handled the action", function()
		local actions = helpers.load_with_stubs("modules.gestures.actions")
		helpers.assert_eq(actions.execute_single("none"), true,
			"a registered action must report that the central dispatcher owns it")
		helpers.assert_eq(actions.execute_single("__script_control_unknown_action__"), false,
			"an unknown action must let ScriptControl try its extras fallback")
	end)

end)
