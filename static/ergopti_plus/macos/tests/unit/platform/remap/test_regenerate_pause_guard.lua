--- tests/unit/platform/remap/test_regenerate_pause_guard.lua

--- ==============================================================================
--- MODULE: Regression — M.regenerate() must not redeploy the full config mid-pause
--- DESCRIPTION:
--- « pause = tout éteint ». The exact lease controller flips a pause variable
--- without replacing the generated config. M.regenerate() must nevertheless stay
--- quiescent while paused: settings edits are deferred until resume instead of
--- performing config I/O and restarting a lease generation behind a paused UI.
---
--- ROOT CAUSE ENCODED — the invariant was enforced per call site:
--- The layout-change watcher guards its own call and its comment states the rule
--- in general terms: "Redeploying the full remapping … would silently undo the
--- pause (« pause = tout éteint »)". The generator now also gates normal rules on
--- the pause variable, but the no-work-under-pause invariant is still transitive:
--- the guard sat at that one site while every menu path that regenerates — the
--- tap/hold and sticky delay editors, layout changes, action edits — reached
--- M.regenerate() unguarded. This is `project-ahk-invariant-incomplete-application`
--- verbatim: the rule was written down, then applied once.
---
--- The guard now lives in the function that performs the deploy, so a new caller
--- inherits it instead of having to remember it.
---
--- RESUME MUST STILL WORK: the public path holds a private capability that may
--- regenerate after RESUMED while script_control deliberately remains paused.
--- It commits _is_paused=false only after publication, READY and lease-bound
--- input startup succeed. The ordinary paused and unpaused cases are asserted
--- below; the private transactional exception is behavioral coverage in
--- test_set_enabled_lease_transaction.lua.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===============================================
-- ===============================================
-- ======= 1/ Karabiner Over A Paused Stub =======
-- ===============================================
-- ===============================================

--- Loads the karabiner module with a shortcuts double reporting `paused`, and a
--- generator double that records whether a deploy was attempted.
--- @param paused boolean What shortcuts.is_paused() reports.
--- @return table karabiner, table deploys
local function load_karabiner(paused)
	package.loaded["modules.shortcuts"] = { is_paused = function() return paused end }
	package.loaded["platform.remap.config"] = {
		load_available_actions = function() return { { id = "none" } } end,
		load_tap_hold_keys = function() return { { id = "left_shift" } } end,
		load_mod_combos = function() return { { id = "left_shift+right_shift" } } end,
		compute_non_canonical_combos = function() return {} end,
		load_user_config = function()
			return {
				enabled = true,
				tap_hold_config = {},
				mod_combos_config = {},
				tap_hold_timeout_ms = 200,
				sticky_timeout_ms = 1000,
				simultaneous_threshold_ms = 50,
				combo_symmetric = false,
			}
		end,
		save_user_config = function() return true end,
		resolve_layout_actions = function() return 0 end,
	}

	local deploys = { count = 0, phase = "active" }
	-- The counter sits on build_karabiner_json: it is the first thing regenerate()
	-- does after the guard, so a non-zero count means the paused deploy went ahead.
	package.loaded["platform.remap.generator"] = {
		build_karabiner_json      = function()
			deploys.count = deploys.count + 1
			return {}, nil, { "legacy-ergopti-rule" }
		end,
		merge_and_deploy_config = function(_built, _dst, legacy_rules)
			deploys.merge_legacy_rules = legacy_rules
			return true, "ok"
		end,
		KE_PHYSICAL_KC_LOG         = nil,
	}
	package.loaded["platform.remap.lease_controller"] = {
		init = function(listener)
			deploys.phase_listener = listener
			return true
		end,
		token = function() return "0123456789abcdef0123456789abcdef" end,
		start_paused = function(callback)
			if callback then callback(true, "ready") end
			return true
		end,
		stop = function() return true end,
		stop_exact = function() return true end,
		pause = function(callback)
			deploys.phase = "paused"
			if deploys.phase_listener then deploys.phase_listener("paused") end
			if callback then callback(true, "paused") end
			return true
		end,
		resume = function(callback)
			deploys.phase = "active"
			if deploys.phase_listener then deploys.phase_listener("active") end
			if callback then callback(true, "resumed") end
			return true
		end,
		status = function()
			return deploys.phase, {
				phase = deploys.phase,
				token = "0123456789abcdef0123456789abcdef",
				activation_blocked = false,
			}
		end,
	}
	package.loaded["platform.remap.ke_lifecycle"] = {
		open_gui = function() return true end,
		stop = function() return true end,
		notify_ready = function() end,
	}
	package.loaded["platform.remap.watchers"] = {
		start_gesture_watcher = function() return { id = "gesture" } end,
		stop_gesture_watcher = function() return true end,
		start_cycle_windows_hotkey = function() return "cycle" end,
		start_alt_tab_windows_hotkey = function() return "windows" end,
		start_alt_tab_monitor_hotkey = function() return "monitor" end,
		start_alt_tab_apps_hotkey = function() return "apps" end,
		stop_alt_tab_apps_tracker = function() return true end,
		start_input_source_watcher = function() return true end,
		stop_input_source_watcher = function() return true end,
	}
	package.loaded["adapters.hotkey_registrar"] = { unbind = function() return true end }
	package.loaded["modules.keylogger.kc_bridge"] = {
		clear_managed_set = function() return true end,
		refresh_managed_set = function() return true end,
	}
	package.loaded["modules.gestures.engine"] = {}

	package.loaded["platform.remap"] = nil
	-- load_with_stubs replaces hs.keycodes wholesale, so the override must carry its
	-- own .map: the layout watcher resolves a key name at load time via
	-- Keycodes.to_name(), which iterates hs.keycodes.map.
	local K = helpers.load_with_stubs("platform.remap", {
		keycodes = {
			inputSourceChanged = function() end,
			currentLayout      = function() return "ABC" end,
			map                = { f17 = 64 },
		},
		-- The timer override replaces hs.timer wholesale, so every member the module
		-- touches must be present — absoluteTime included.
		timer = {
			doEvery           = function(_i, _fn) return { stop = function() end } end,
			doAfter           = function(_d, _fn) return { stop = function() end } end,
			secondsSinceEpoch = function() return 1000 end,
			absoluteTime      = function() return 0 end,
			usleep            = function() end,
		},
		execute = function() return "", true end,
	})
	K.init({ expand_path = function(p) return p end })
	return K, deploys
end





-- ==============================================
-- ==============================================
-- ======= 2/ Paused Blocks, Resume Does Not ====
-- ==============================================
-- ==============================================

helpers.describe("karabiner.regenerate honours the pause invariant", function()
	helpers.it("does not build or deploy while the script is paused", function()
		local K, deploys = load_karabiner(true)

		-- Reach the pause guard instead of passing on the earlier disabled guard.
		K.regenerate()

		helpers.assert_eq(deploys.count, 0,
			"regenerate() must not rebuild the config while paused — edits remain deferred "
			.. "until resume, with no config I/O or lease restart behind the paused UI")
	end)

	helpers.it("builds and deploys normally when enabled and not paused", function()
		-- The opposite failure: a guard that always blocked would break every menu
		-- edit and the resume rebuild itself.
		local K, deploys = load_karabiner(false)

		K.regenerate()

		helpers.assert_true(deploys.count >= 1,
			"regenerate() must still work for ordinary menu edits when the script is not paused")
		helpers.assert_eq(deploys.merge_legacy_rules[1], "legacy-ergopti-rule",
			"regenerate() must forward the generator's legacy-rule inventory to merge — "
			.. "otherwise the first lease upgrade leaves old ungated Ergopti rules active")
	end)
end)
