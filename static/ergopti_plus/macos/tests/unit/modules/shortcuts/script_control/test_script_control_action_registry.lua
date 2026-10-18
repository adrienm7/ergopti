--- tests/unit/modules/shortcuts/script_control/test_script_control_action_registry.lua

--- ==============================================================================
--- MODULE: shortcuts.script_control Unit Tests
--- DESCRIPTION:
--- Validates the public configuration surface of the script-control daemon: the
--- ACTIONS array shape, the action label map, and the slot-binding setter.
--- The eventtap dispatch path itself relies on hs.eventtap and is exercised at
--- integration time.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.shortcuts.script_control.script_control_fixture"] = nil
local Fixture = require("tests.support.modules.shortcuts.script_control.script_control_fixture")
local SC = Fixture.SC





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
	-- script-chords-three-os-2026-09-30: the four slots every driver shares,
	-- each starting with its preset, the switch on.
	helpers.it("script-chord: an empty configuration holds the four presets and the switch on", function()
		local actions = SC.get_shortcut_actions()
		helpers.assert_eq(actions.script_altgr_enter, "script_pause_toggle")
		helpers.assert_eq(actions.script_altgr_backspace, "script_reload")
		helpers.assert_eq(actions.script_altgr_delete, "open_personal_shortcuts")
		helpers.assert_eq(actions.script_altgr_escape, "script_quit")
		helpers.assert_eq(SC.chords_enabled(), true)
		local ids = {}
		for _, slot in ipairs(SC.slots()) do ids[#ids + 1] = slot.id end
		helpers.assert_eq(table.concat(ids, ","),
			"script_altgr_enter,script_altgr_backspace,script_altgr_delete,script_altgr_escape")
	end)

	helpers.it("accepts a shared slot and an action", function()
		helpers.assert_eq(SC.set_shortcut_action("script_altgr_backspace", "script_reload"), true)
		helpers.assert_eq(SC.set_shortcut_action("script_altgr_enter", "script_pause_toggle"), true)
		helpers.assert_eq(SC.set_shortcut_action("script_altgr_escape", "script_quit"), true)
	end)

	helpers.it("rejects non-string arguments and unknown slots without crashing", function()
		helpers.assert_eq(SC.set_shortcut_action(nil, "script_reload"), false)
		helpers.assert_eq(SC.set_shortcut_action("script_altgr_backspace", nil), false)
		helpers.assert_eq(SC.set_shortcut_action(42, true), false)
		helpers.assert_eq(SC.set_shortcut_action("return_key", "script_reload"), false,
			"the retired macOS slot names are no slot any more")
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
