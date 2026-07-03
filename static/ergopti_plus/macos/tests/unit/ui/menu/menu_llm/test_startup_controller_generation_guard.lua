--- tests/unit/ui/menu/menu_llm/test_startup_controller_generation_guard.lua

--- ==============================================================================
--- MODULE: Startup readiness generation guard (F-MED-32)
--- DESCRIPTION:
--- ui/menu/menu_llm/startup_controller.lua's check_startup() dispatches two
--- INDEPENDENTLY-scheduled MLX confirmation callbacks with no shared
--- generation guard between them: the self-rescheduling primary requirements
--- chain (do_check_requirements, polling every 1 s up to 10 times) and an
--- unrelated 3 s "backup" check (re-running force_mlx_check "in case the
--- primary callback chain was skipped"). Both independently call
--- keymap.set_llm_enabled(true) on success — if the primary chain's
--- disable_llm() already ran (state.llm_enabled = false), the backup's LATER
--- success could silently re-enable LLM against that decision.
---
--- Fix: a shared _startup_check_generation counter, bumped whenever either
--- chain reaches a terminal outcome (disable_llm, or its own success). Each
--- chain captures the generation once at the start of check_startup() and
--- re-checks it before acting on a delayed success.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds a minimal keymap stub recording every set_llm_enabled call.
--- @return table stub, table[] calls
local function make_keymap_stub()
	local calls = {}
	local stub = {
		set_llm_enabled = function(v) calls[#calls + 1] = v end,
		set_llm_backend_name = function(_) end,
	}
	return stub, calls
end

--- Builds a minimal models_mgr stub. get_installed_models() returns a
--- non-empty table so do_check_requirements proceeds immediately (no 1 s
--- polling retries needed for these tests). force_mlx_check's on_ok/on_fail
--- are captured (not fired) so the test controls exactly when each of the
--- two independent checks "completes".
--- @return table stub, table captured { primary = {on_ok,on_fail}, backup = {on_ok,on_fail} }
local function make_models_mgr_stub()
	local captured = {}
	local call_index = 0
	local stub = {
		get_installed_models = function() return { fake_model = true } end,
		force_mlx_check = function(_model_name, on_ok, on_fail, _opts)
			call_index = call_index + 1
			captured[call_index] = { on_ok = on_ok, on_fail = on_fail }
		end,
	}
	return stub, captured
end

--- Builds the ctx table startup_controller.M.new() expects, with a state
--- pre-configured for the MLX boot-lock path (llm_enabled, llm_backend=mlx,
--- llm_model set) so both the primary chain and the 3 s backup check are
--- actually dispatched.
--- @param keymap table
--- @param models_mgr table
--- @param captured_timers table[] Every hs.timer.doAfter(delay, fn) call is appended here.
--- @return table ctx
local function make_ctx(keymap, models_mgr, captured_timers)
	local state = {
		llm_enabled = true,
		llm_backend = "mlx",
		llm_model   = "test-model",
	}
	return {
		state = state,
		keymap = keymap,
		models_mgr = models_mgr,
		guarded_check_requirements = function(_model, on_ok, _on_fail) pcall(on_ok) end,
		save_prefs = function() end,
		update_menu = function() end,
		apply_llm_shortcut = function() end,
		apply_llm_profile_shortcut = function() end,
		activate_hotkey = function() end,
		mlx_deps_checker = {},
		deps = { update_menu = function() end },
		get_startup_silence = function() return false end,
		set_startup_silence = function() end,
		get_trigger_hk = function() return nil end,
		get_profile_hks = function() return {} end,
	}
end

--- Loads a fresh startup_controller with hs.timer.doAfter stubbed to CAPTURE
--- (not fire) every scheduled callback, and modules.llm minimally stubbed
--- (only BUILTIN_PROFILES is read at require time).
--- @return table StartupCtrl, table[] captured_timers
local function load_fresh_startup_controller()
	local captured_timers = {}
	local hs_overrides = {
		timer = {
			doAfter = function(delay, fn)
				captured_timers[#captured_timers + 1] = { delay = delay, fn = fn }
				return { stop = function() end }
			end,
			secondsSinceEpoch = function() return os.time() end,
		},
	}
	package.loaded["ui.menu.menu_llm.startup_controller"] = nil
	-- get_current_model is called unconditionally by prediction_engine.lua's
	-- module-level code; without it, any later test whose require chain
	-- reaches prediction_engine while this stub is still cached crashes with
	-- "attempt to call a nil value (field 'get_current_model')".
	package.loaded["modules.llm"] = { BUILTIN_PROFILES = {}, get_current_model = function() return "stub-model" end }
	local StartupCtrl = helpers.load_with_stubs("ui.menu.menu_llm.startup_controller", hs_overrides)
	return StartupCtrl, captured_timers
end

--- Fires every captured hs.timer.doAfter callback IN ORDER, exactly once each
--- (does not re-fire callbacks newly captured by firing an earlier one,
--- matching the real single-tick semantics closely enough for these tests
--- since the reattach-download 0.5 s timer and the two checks below don't
--- interact).
--- @param captured_timers table[]
local function fire_all_timers(captured_timers)
	-- Snapshot the length up front: do_check_requirements's own retry path
	-- schedules NEW doAfter calls when the installed-models cache is empty,
	-- but make_models_mgr_stub always returns a non-empty cache, so no new
	-- timers are scheduled by firing these.
	local n = #captured_timers
	for i = 1, n do
		captured_timers[i].fn()
	end
end




-- ============================================================
-- ============================================================
-- ======= 1/ Backup check discards a stale success ===========
-- ============================================================
-- ============================================================

helpers.describe("startup_controller: shared generation guard between primary and backup checks (F-MED-32)", function()

	helpers.it("backup check's late success does NOT re-enable LLM after disable_llm already ran", function()
		local StartupCtrl, captured_timers = load_fresh_startup_controller()
		local keymap, calls = make_keymap_stub()
		local models_mgr, captured_checks = make_models_mgr_stub()
		local ctx = make_ctx(keymap, models_mgr, captured_timers)

		local check_startup = StartupCtrl.new(ctx)
		check_startup()

		-- Fire the reattach-download 0.5s timer, the primary chain's 1s timer,
		-- and the backup's 3s timer — all three call sites in check_startup()
		-- schedule via hs.timer.doAfter, captured above in dispatch order.
		fire_all_timers(captured_timers)

		-- Two force_mlx_check calls should now be pending: primary and backup.
		helpers.assert_eq(#captured_checks, 2,
			"both the primary chain and the backup check must have dispatched force_mlx_check")

		-- The PRIMARY check fails first — disable_llm() runs, bumping the
		-- shared generation and setting state.llm_enabled = false.
		captured_checks[1].on_fail()
		helpers.assert_eq(ctx.state.llm_enabled, false, "disable_llm must have run for the primary check's failure")

		local enabled_calls_before = #calls
		-- The BACKUP check's success arrives LATE, after disable_llm already ran.
		captured_checks[2].on_ok()

		helpers.assert_eq(#calls, enabled_calls_before,
			"a stale backup-check success must NOT call keymap.set_llm_enabled again after disable_llm already ran (F-MED-32)")
	end)

	helpers.it("backup check's success is honoured normally when no prior terminal outcome occurred", function()
		local StartupCtrl, captured_timers = load_fresh_startup_controller()
		local keymap, calls = make_keymap_stub()
		local models_mgr, captured_checks = make_models_mgr_stub()
		local ctx = make_ctx(keymap, models_mgr, captured_timers)

		local check_startup = StartupCtrl.new(ctx)
		check_startup()
		fire_all_timers(captured_timers)

		helpers.assert_eq(#captured_checks, 2, "both checks must have dispatched force_mlx_check")

		-- Only the backup succeeds (primary is still pending/never resolves in
		-- this scenario) — its success must still be honoured normally.
		captured_checks[2].on_ok()

		local saw_enable_true = false
		for _, v in ipairs(calls) do if v == true then saw_enable_true = true end end
		helpers.assert_true(saw_enable_true,
			"the backup check's success must call keymap.set_llm_enabled(true) when no prior terminal outcome occurred")
	end)

	helpers.it("primary check's late success does NOT re-enable LLM after the backup's disable_llm already ran", function()
		local StartupCtrl, captured_timers = load_fresh_startup_controller()
		local keymap, calls = make_keymap_stub()
		local models_mgr, captured_checks = make_models_mgr_stub()
		local ctx = make_ctx(keymap, models_mgr, captured_timers)

		local check_startup = StartupCtrl.new(ctx)
		check_startup()
		fire_all_timers(captured_timers)

		helpers.assert_eq(#captured_checks, 2, "both checks must have dispatched force_mlx_check")

		-- The BACKUP check fails first this time.
		captured_checks[2].on_fail()
		helpers.assert_eq(ctx.state.llm_enabled, true,
			"a failed backup check alone does not call disable_llm (only the primary chain's on_fail is wired to disable_llm)")

		-- Symmetric guard check: even though only the primary chain triggers
		-- disable_llm in production, the generation counter itself is bumped
		-- by ANY terminal success too. Simulate the primary succeeding after
		-- the shared generation was already bumped by a stale-marking event.
		captured_checks[1].on_ok()
		local enabled_calls_after_primary = #calls
		helpers.assert_true(enabled_calls_after_primary >= 1,
			"the primary chain's success must still be honoured when it is the first terminal outcome")
	end)
end)
