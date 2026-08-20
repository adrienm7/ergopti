--- tests/unit/modules/keylogger/test_kc_bridge.lua

--- ==============================================================================
--- MODULE: keylogger.kc_bridge Unit Tests
--- DESCRIPTION:
--- Verifies the pure in-process logic of the Karabiner physical-keycode bridge.
--- The module has two testable pure surfaces: is_ke_managed_output_kc() (a
--- simple set lookup) and refresh_managed_set() / the init-time set builder
--- (which walk tap_hold_config + available_actions to compute the suppression
--- set). All hs.pathwatcher, io.open, and hs.timer calls are covered by the
--- default hs stub so no real file or OS event is touched.
---
--- FEATURES & RATIONALE:
--- 1. Suppression Set Build: refresh_managed_set must populate
---    is_ke_managed_output_kc() correctly from a synthetic tap_hold_config.
--- 2. Guard Enforcement: Calling the module before init must not crash.
--- 3. KE → HS Name Translation: Karabiner modifier names (left_command, etc.)
---    must resolve to the correct hs.keycodes.map numeric values.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================
-- =====================================
-- ======= 1/ Stub Setup ==============
-- =====================================
-- =====================================

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

-- kc_bridge resolves KC_LOG_PATH via ui.menu.menu_paths at module load time.
-- Stub the module so the require does not fail.
package.loaded["infra.config_paths"] = {
	get_config_dir = function() return "/tmp/test_ergopti" end,
}

-- Provide a keycodes.map with enough entries for the tests.
local hs_overrides = {
	keycodes = {
		map = {
			-- Modifier aliases used by ke_name_to_num via KE_TO_HS_KEYCODE_NAME
			cmd       = 55,
			rightcmd  = 54,
			shift     = 56,
			rightshift = 60,
			alt       = 58,
			rightalt  = 61,
			ctrl      = 59,
			rightctrl = 62,
			-- Letter keys
			a = 0, b = 1, c = 8, d = 2, e = 14, f = 3,
			-- delete family
			delete        = 51,
			forwarddelete = 117,
			["return"]    = 36,
			space         = 49,
		},
	},
	-- pathwatcher stub: new() returns a table with start/stop no-ops
	pathwatcher = {
		new = function(_path, _cb)
			local watcher = {}
			watcher.start = function() return watcher end
			watcher.stop = function() end
			return watcher
		end,
	},
	-- timer stub for the fallback poll
	timer = {
		new = function(_interval, _cb)
			local timer = { active = false }
			timer.start = function() timer.active = true; return timer end
			timer.stop = function() timer.active = false; return timer end
			timer.running = function() return timer.active end
			return timer
		end,
		absoluteTime = function() return 0 end,
	},
}

--- Reloads both the bridge and its stateful scheduler under one fresh hs stub.
--- @param overrides table Hammerspoon API overrides.
--- @return table module Fresh bridge module.
local function load_kc_bridge(overrides)
	package.loaded["adapters.timer_scheduler"] = nil
	return helpers.load_with_stubs("modules.keylogger.kc_bridge", overrides)
end

local KC = load_kc_bridge(hs_overrides)




-- ======================================================
-- ======================================================
-- ======= 2/ Module Surface Invariants =================
-- ======================================================
-- ======================================================

helpers.describe("kc_bridge — public surface", function()
	helpers.it("exposes init, start, is_ke_managed_output_kc, refresh/clear managed set, get_stats, stop", function()
		helpers.assert_eq(type(KC.init),                    "function")
		helpers.assert_eq(type(KC.start),                   "function")
		helpers.assert_eq(type(KC.is_ke_managed_output_kc), "function")
		helpers.assert_eq(type(KC.refresh_managed_set),     "function")
		helpers.assert_eq(type(KC.clear_managed_set),       "function")
		helpers.assert_eq(type(KC.get_stats),               "function")
		helpers.assert_eq(type(KC.stop),                    "function")
		helpers.assert_eq(type(KC.set_log_manager),         "function")
	end)
end)




-- ===========================================================
-- ===========================================================
-- ======= 3/ is_ke_managed_output_kc before init ===========
-- ===========================================================
-- ===========================================================

helpers.describe("kc_bridge — pre-init behaviour", function()
	-- Fresh module — _managed_output_kcs starts empty.
	local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_overrides)

	helpers.it("is_ke_managed_output_kc returns false for any kc before init", function()
		helpers.assert_eq(kc.is_ke_managed_output_kc(55), false)
		helpers.assert_eq(kc.is_ke_managed_output_kc(0),  false)
	end)

	-- Called directly, not through pcall: "it did not raise" is not the claim.
	-- The claim is that an uninitialised bridge ANSWERS — a guard that returned
	-- nil here would satisfy the old assertion and crash the caller one line
	-- later, which is where the diagnostic would have been useless.
	helpers.it("get_stats answers a table before init", function()
		local stats = kc.get_stats()
		helpers.assert_eq(type(stats), "table",
			"the stats reader must answer a table even before init — its caller indexes it")
	end)

	helpers.it("stop before init leaves the bridge stopped, not half-torn-down", function()
		kc.stop()
		helpers.assert_eq(type(kc.get_stats()), "table",
			"a stop that never started must leave the module usable; the boot path calls "
				.. "stop() defensively before it calls init()")
	end)
end)




-- ================================================================
-- ================================================================
-- ======= 4/ refresh_managed_set builds suppression set =========
-- ================================================================
-- ================================================================

helpers.describe("kc_bridge — refresh_managed_set", function()
	-- "Rejects X without crashing" asserted survival. What rejection MEANS here is
	-- that the suppression set is not built from the bad input: a refresh that
	-- swallowed nil and left a half-populated set would mark the wrong keycodes
	-- as driver-managed, and the keylogger would then drop the user's real
	-- keystrokes as if the driver had synthesised them.
	helpers.it("a non-table tap_hold_config leaves no keycode marked managed", function()
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_overrides)
		helpers.assert_true(kc.refresh_managed_set(nil, {}) == false)
		helpers.assert_eq(kc.is_ke_managed_output_kc(55), false,
			"a refused refresh must leave the managed set empty, not partially built")
	end)

	helpers.it("a non-table available_actions leaves no keycode marked managed", function()
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_overrides)
		helpers.assert_true(kc.refresh_managed_set({}, nil) == false)
		helpers.assert_eq(kc.is_ke_managed_output_kc(55), false,
			"same on the other argument — half a set is worse than none, because the half "
				.. "that is there looks authoritative")
	end)

	helpers.it("marks output keycodes as managed after refresh", function()
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_overrides)

		-- Simulate a config where key "caps" taps to left_command (kc 55).
		local tap_hold_config = {
			caps = { tap = "action_cmd_tap", hold = "none" },
		}
		local available_actions = {
			{
				id             = "action_cmd_tap",
				karabiner_to   = { { key_code = "left_command" } },
			},
		}

		helpers.assert_true(kc.refresh_managed_set(tap_hold_config, available_actions))

		-- left_command → hs name "cmd" → keycodes.map["cmd"] = 55
		helpers.assert_eq(kc.is_ke_managed_output_kc(55), true)
		-- Unrelated keycode must still be unmanaged.
		helpers.assert_eq(kc.is_ke_managed_output_kc(0),  false)
	end)

	helpers.it("handles hold slot in addition to tap slot", function()
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_overrides)

		local tap_hold_config = {
			esc = { tap = "act_esc", hold = "act_ctrl" },
		}
		local available_actions = {
			{ id = "act_esc",  karabiner_to = { { key_code = "a" } } },    -- kc 0
			{ id = "act_ctrl", karabiner_to = { { key_code = "left_control" } } },  -- kc 59
		}

		kc.refresh_managed_set(tap_hold_config, available_actions)

		helpers.assert_eq(kc.is_ke_managed_output_kc(0),  true)
		helpers.assert_eq(kc.is_ke_managed_output_kc(59), true)
		-- Unrelated kc stays false.
		helpers.assert_eq(kc.is_ke_managed_output_kc(56), false)
	end)

	helpers.it("calling refresh twice replaces the previous set", function()
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_overrides)

		-- First build: marks kc 55 (left_command).
		kc.refresh_managed_set(
			{ k1 = { tap = "act1", hold = "none" } },
			{ { id = "act1", karabiner_to = { { key_code = "left_command" } } } }
		)
		helpers.assert_eq(kc.is_ke_managed_output_kc(55), true)

		-- Second build: only marks kc 56 (left_shift).
		kc.refresh_managed_set(
			{ k2 = { tap = "act2", hold = "none" } },
			{ { id = "act2", karabiner_to = { { key_code = "left_shift" } } } }
		)
		helpers.assert_eq(kc.is_ke_managed_output_kc(56), true)
		-- Previous entry must be gone.
		helpers.assert_eq(kc.is_ke_managed_output_kc(55), false)
	end)

	helpers.it("clear_managed_set releases every output keycode claim", function()
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_overrides)
		kc.refresh_managed_set(
			{ k1 = { tap = "act1", hold = "none" } },
			{ { id = "act1", karabiner_to = { { key_code = "left_command" } } } }
		)
		helpers.assert_eq(kc.is_ke_managed_output_kc(55), true)

		helpers.assert_true(kc.clear_managed_set())

		helpers.assert_eq(kc.is_ke_managed_output_kc(55), false,
			"an inactive Ergopti lease must not suppress the same keycode from personal Karabiner")
	end)

	helpers.it("unknown key_code names are silently skipped", function()
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_overrides)

		kc.refresh_managed_set(
			{ k = { tap = "act_unknown", hold = "none" } },
			{ { id = "act_unknown", karabiner_to = { { key_code = "nonexistent_key_xyz" } } } }
		)
		-- No kc must be added (unknown name yields nil from keycodes.map).
		helpers.assert_eq(kc.is_ke_managed_output_kc(0), false)
	end)

	helpers.it("empty actions list produces an empty managed set", function()
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_overrides)
		kc.refresh_managed_set({}, {})
		helpers.assert_eq(kc.is_ke_managed_output_kc(55), false)
	end)
end)




-- ================================================================
-- ================================================================
-- ======= 5/ M.init() guard and duplicate init ==================
-- ================================================================
-- ================================================================

helpers.describe("kc_bridge — M.init()", function()
	helpers.it("a non-table core_state leaves the module uninitialised", function()
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_overrides)
		kc.init(nil, nil, {}, {}, function() return false end)
		-- Refusal has to be observable, not merely survivable: a module that
		-- swallowed the bad state and initialised anyway passes "does not crash"
		-- and then fails at every later call, far from the argument that caused it.
		kc.start()
		helpers.assert_eq(kc.is_ke_managed_output_kc(55), false,
			"a refused init must leave nothing configured")
	end)

	helpers.it("accepts a valid core_state and becomes usable", function()
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_overrides)
		kc.init(
			{ some_state = true },
			nil,  -- no log_manager needed for this surface test
			{ k = { tap = "none", hold = "none" } },
			{},
			function() return false end
		)
		helpers.assert_eq(type(kc.get_stats()), "table",
			"a successful init must leave the public surface answering — the positive control "
				.. "for the two refusal cases above")
	end)

	helpers.it("ignores duplicate init calls", function()
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_overrides)
		local state = { ok = true }
		local may_persist = function() return false end
		kc.init(state, nil, {}, {}, may_persist)
		local before = kc.get_stats()
		kc.init(state, nil, {}, {}, may_persist)
		helpers.assert_eq(type(kc.get_stats()), type(before),
			"a second init must be ignored, not re-run — re-running rebuilds the managed set "
				.. "while the first init's watchers are still armed against the old one")
	end)
end)





-- =====================================================================
-- =====================================================================
-- ======= 6/ kc_bridge stop/start cycle (e2e-async-lifecycle-1) =======
-- =====================================================================
-- =====================================================================

-- State flags mutated by the tracking stubs below.
local lc_watcher_running = false
local lc_timer_running   = false

-- hs overrides that track watcher/timer running state via closures.
local hs_lifecycle_overrides = {
	keycodes = { map = { cmd = 55, shift = 56 } },
	pathwatcher = {
		new = function(_path, _cb)
			local watcher = {}
			watcher.start = function() lc_watcher_running = true; return watcher end
			watcher.stop  = function() lc_watcher_running = false end
			return watcher
		end,
	},
	timer = {
		new = function(_interval, _cb)
			local timer = {}
			timer.start = function() lc_timer_running = true; return timer end
			timer.stop  = function() lc_timer_running = false; return timer end
			timer.running = function() return lc_timer_running end
			return timer
		end,
		absoluteTime = function() return 0 end,
	},
}

-- The adapter captures its native timer table at require time; rebind it with
-- the lifecycle hs override before this behavior group starts.
package.loaded["adapters.timer_scheduler"] = nil

helpers.describe("kc_bridge — stop/start lifecycle (e2e-async-lifecycle-1)", function()

	helpers.it("watcher and timer are running after init", function()
		lc_watcher_running = false
		lc_timer_running   = false
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_lifecycle_overrides)
		kc.init({ ok = true }, nil, {}, {}, function() return false end)
		helpers.assert_true(lc_watcher_running,
			"path watcher must be running after init")
		helpers.assert_true(lc_timer_running,
			"poll timer must be running after init")
	end)

	helpers.it("stop() halts both watcher and timer", function()
		lc_watcher_running = false
		lc_timer_running   = false
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_lifecycle_overrides)
		kc.init({ ok = true }, nil, {}, {}, function() return false end)
		kc.stop()
		helpers.assert_eq(lc_watcher_running, false,
			"path watcher must be stopped after stop()")
		helpers.assert_eq(lc_timer_running, false,
			"poll timer must be stopped after stop()")
	end)

	helpers.it("start() re-arms watcher and timer after stop (regression)", function()
		-- Pre-fix: no M.start() existed — the bridge stayed dead after stop().
		-- Post-fix: M.start() calls _arm_watchers() which re-creates nil handles.
		lc_watcher_running = false
		lc_timer_running   = false
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_lifecycle_overrides)
		kc.init({ ok = true }, nil, {}, {}, function() return false end)
		kc.stop()
		local saved_open = io.open
		io.open = function(path, mode)
			if mode == "r" then
				return {
					seek = function() return 0 end,
					close = function() return true end,
				}
			end
			return saved_open(path, mode)
		end
		local call_ok, started = pcall(kc.start)
		io.open = saved_open
		helpers.assert_true(call_ok,
			"the restart fixture must release its temporary file override: " .. tostring(started))
		helpers.assert_eq(started, true,
			"restart must commit after the disabled-period EOF is proven")
		helpers.assert_true(lc_watcher_running,
			"path watcher must be re-armed by start() after stop()")
		helpers.assert_true(lc_timer_running,
			"poll timer must be re-armed by start() after stop()")
	end)

	helpers.it("start() before init arms nothing", function()
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_lifecycle_overrides)
		lc_watcher_running = false
		lc_timer_running   = false
		kc.start()
		helpers.assert_eq(lc_watcher_running, false,
			"an uninitialised start must not arm the path watcher — it would poll a log path "
				.. "that has not been resolved yet")
		helpers.assert_eq(lc_timer_running, false, "nor the poll timer")
	end)
end)





-- =====================================================================
-- =====================================================================
-- ======= 7/ require_state guard behavioral coverage (F-LOW-14) =======
-- =====================================================================
-- =====================================================================

-- F-LOW-14: kc_bridge.lua was the sole keylogger sibling module missing the
-- canonical require_state(func_name) guard — every _state-touching function
-- independently hand-rolled its own ad hoc `if not _state then ... end` check.
-- This section pins the behavioral contract: a public function called before
-- M.init() must both (a) not crash and (b) log via Logger.error, exactly like
-- every other keylogger sibling module's require_state helper.
package.loaded["adapters.timer_scheduler"] = nil
helpers.describe("kc_bridge — require_state guard fires Logger.error before init (F-LOW-14)", function()

	--- Loads a fresh kc_bridge with a Logger.error spy installed, so tests can
	--- assert the guard actually logs rather than merely not crashing.
	--- @return table module, table error_calls
	local function load_kc_bridge_with_error_spy()
		local error_calls = {}
		package.loaded["infra.logger"] = {
			debug = function() end, trace = function() end, done = function() end,
			info  = function() end, start = function() end, success = function() end,
			warn  = function() end,
			error = function(_log, fmt, ...) table.insert(error_calls, string.format(fmt, ...)) end,
		}
		local kc = helpers.load_with_stubs("modules.keylogger.kc_bridge", hs_overrides)
		return kc, error_calls
	end

	helpers.it("start() before init logs Logger.error and does not crash", function()
		local kc, error_calls = load_kc_bridge_with_error_spy()
		kc.start()
		helpers.assert_true(#error_calls > 0,
			"M.start() called before M.init() must log via Logger.error (require_state contract)")
	end)

	helpers.it("start() after init does NOT log an error", function()
		local kc, error_calls = load_kc_bridge_with_error_spy()
		kc.init({ ok = true }, nil, {}, {}, function() return false end)
		error_calls = {} -- clear any init-time noise before the call under test
		kc.start()
		helpers.assert_eq(#error_calls, 0,
			"M.start() after a successful M.init() must not trip the require_state guard")
	end)

end)
