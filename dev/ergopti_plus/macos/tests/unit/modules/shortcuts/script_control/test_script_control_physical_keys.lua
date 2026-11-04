--- tests/unit/modules/shortcuts/script_control/test_script_control_physical_keys.lua

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
		local enabled = false
		return {
			start = function() enabled = true end,
			stop = function() enabled = false end,
			isEnabled = function() return enabled end,
		}
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

	-- A chord the tap saw after the main thread held it (stale-physical-event)
	-- is not acted on late: pause, reload or quit 1.2 s after the press is a
	-- surprise, and macOS may already have delivered the key without the tap.
	helpers.it("a genuine sentinel that waited behind the main thread passes untouched (stale-physical-event)", function()
		local EventClock = require("adapters.event_clock")
		local Health = require("infra.key_event_health")
		EventClock.reset()
		Health.reset()
		local host_ns = 3600 * 1e9
		local saved = _G.hs.timer.absoluteTime
		_G.hs.timer.absoluteTime = function() return host_ns end
		local ok, err = pcall(function()
			local function stamped(ms_ago)
				local event = make_event(ESCAPE_SENTINEL)
				local stamp = math.floor(host_ns - ms_ago * 1e6)
				event.timestamp = function() return stamp end
				return event
			end
			dispatched = nil
			live_mods = { _raw = 0x40 }
			helpers.assert_eq(handler(stamped(1)), true, "a fresh genuine sentinel is consumed")
			_G.hs.timer.__fire_all()
			helpers.assert_eq(dispatched, "script_quit")
			dispatched = nil
			helpers.assert_eq(handler(stamped(1200)), false, "a late sentinel is not consumed")
			_G.hs.timer.__fire_all()
			helpers.assert_eq(dispatched, nil, "and runs nothing")
			helpers.assert_eq(Health.counts().stale_passed, 1)
		end)
		_G.hs.timer.absoluteTime = saved
		if not ok then error(err, 0) end
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
		-- tests/meta/runloop/test_pause_path_defers_blocking_work.lua. The stub records timers
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




--- Runs before the extras describe below on purpose: its load_with_stubs
--- installs a fresh global hs stub, which this file's ScriptControl, holding
--- the stub it was loaded with, would never read an eventtap from.
helpers.describe("ScriptControl — the shared script chords (script-chords-three-os-2026-09-30)", function()
	local handler
	local regenerations = 0
	local karabiner = { regenerate = function(done)
		regenerations = regenerations + 1
		if type(done) == "function" then done(true) end
		return true
	end }
	local orig_new = _G.hs.eventtap.new
	_G.hs.eventtap.new = function(_, fn)
		handler = fn
		local enabled = false
		return {
			start = function() enabled = true end,
			stop = function() enabled = false end,
			isEnabled = function() return enabled end,
		}
	end
	_G.hs.eventtap.event.rawFlagMasks = {
		deviceRightCommand = 0x10, deviceRightAlternate = 0x40,
		deviceLeftCommand = 0x08, deviceLeftAlternate = 0x20,
	}
	SC.stop()
	SC.start({}, {}, {}, karabiner)
	_G.hs.eventtap.new = orig_new
	helpers.assert_true(type(handler) == "function", "script-control tap handler must be captured")

	--- A physical right Command + key, the path Karabiner paused leaves. The
	--- fallback reads only a real event, which is userdata: a file handle wears
	--- the event's methods for this block and gets its own metatable back at the end.
	local pressed = { code = 0 }
	local event_backing = {
		getProperty = function() return 0 end,
		getKeyCode = function() return pressed.code end,
		getFlags = function() return { cmd = true } end,
		rawFlags = function() return 0x10 end,
	}
	local event_userdata = assert(io.tmpfile())
	local event_userdata_metatable = debug.getmetatable(event_userdata)
	debug.setmetatable(event_userdata, { __index = event_backing })
	local function right_command(code)
		pressed.code = code
		return event_userdata
	end
	local ESCAPE, RETURN, FORWARD_DELETE = 0x35, 0x24, 0x75

	helpers.it("script-chord: an unassigned slot leaves its chord to the system", function()
		helpers.assert_true(SC.set_shortcut_action("script_altgr_escape", "none"))
		helpers.assert_eq(SC.slot_runs("script_altgr_escape"), false)
		helpers.assert_eq((handler(right_command(ESCAPE))), false, "right Command + Escape reaches the application")
		helpers.assert_eq(SC.karabiner_chords().normal.script_altgr_escape, nil,
			"Karabiner keeps no sentinel rule for an unassigned slot")
		helpers.assert_true(SC.set_shortcut_action("script_altgr_escape", "script_quit"))
		helpers.assert_eq((handler(right_command(ESCAPE))), true)
		helpers.assert_eq((handler(right_command(FORWARD_DELETE))), true, "the Delete slot is a chord too")
		_G.hs.timer.__fire_all()
	end)

	helpers.it("script-chord: the switch off leaves every chord to the system and keeps the actions", function()
		helpers.assert_true(SC.set_chords_enabled(false))
		for _, code in ipairs({ ESCAPE, RETURN, FORWARD_DELETE }) do
			helpers.assert_eq((handler(right_command(code))), false)
		end
		local plan = SC.karabiner_chords()
		helpers.assert_eq(next(plan.normal), nil)
		helpers.assert_eq(next(plan.paused), nil)
		helpers.assert_eq(SC.get_shortcut_actions().script_altgr_escape, "script_quit")
		helpers.assert_true(SC.set_chords_enabled(true))
		-- Escape, not Enter: the pause toggle would pause the rest of this file.
		helpers.assert_eq((handler(right_command(ESCAPE))), true)
		_G.hs.timer.__fire_all()
	end)

	helpers.it("script-chord: paused, only a script-management action keeps its chord", function()
		helpers.assert_true(SC.set_shortcut_action("script_altgr_delete", "other_action"))
		helpers.assert_eq(SC.slot_runs("script_altgr_delete", true), false)
		helpers.assert_eq(SC.slot_runs("script_altgr_enter", true), true)
		helpers.assert_eq(SC.slot_runs("script_altgr_delete", false), true)
		local plan = SC.karabiner_chords()
		helpers.assert_eq(plan.normal.script_altgr_delete, true)
		helpers.assert_eq(plan.paused.script_altgr_delete, nil, "no paused sentinel for another action")
		helpers.assert_eq(plan.paused.script_altgr_enter, true)
		helpers.assert_true(SC.set_shortcut_action("script_altgr_delete", "open_personal_shortcuts"))
		helpers.assert_eq(SC.karabiner_chords().paused.script_altgr_delete, true,
			"opening the personal shortcuts is a script-management action")
	end)

	helpers.it("script-chord: a new plan asks Karabiner once for its rules", function()
		SC.karabiner_chords()
		_G.hs.timer.__fire_all()
		regenerations = 0
		helpers.assert_true(SC.set_shortcut_action("script_altgr_enter", "none"))
		helpers.assert_true(SC.set_shortcut_action("script_altgr_backspace", "none"))
		_G.hs.timer.__fire_all()
		helpers.assert_eq(regenerations, 1, "one regeneration for the two changes of one turn")
		SC.karabiner_chords()
		helpers.assert_true(SC.set_shortcut_action("script_altgr_enter", "none"))
		_G.hs.timer.__fire_all()
		helpers.assert_eq(regenerations, 1, "a plan Karabiner already read asks for nothing")
		helpers.assert_true(SC.set_shortcut_action("script_altgr_enter", "script_pause_toggle"))
		helpers.assert_true(SC.set_shortcut_action("script_altgr_backspace", "script_reload"))
		_G.hs.timer.__fire_all()
		helpers.assert_eq(regenerations, 2)
		SC.karabiner_chords()
	end)

	SC.stop()
	debug.setmetatable(event_userdata, event_userdata_metatable)
	io.close(event_userdata)
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
