--- tests/unit/platform/remap/test_regenerate_pause_guard.lua

--- ==============================================================================
--- MODULE: Regression — M.regenerate() must not redeploy the full config mid-pause
--- DESCRIPTION:
--- « pause = tout éteint ». M.pause() deploys a reduced karabiner.json that keeps
--- only the script-control rules, so the keyboard stops being remapped. Deploying
--- the FULL Ergopti config afterwards hands every one of those remaps straight
--- back — the keyboard silently un-pauses while the UI still says "paused".
---
--- ROOT CAUSE ENCODED — the invariant was enforced per call site:
--- The layout-change watcher guards its own call and its comment states the rule
--- in general terms: "Redeploying the full remapping … would silently undo the
--- pause (« pause = tout éteint »)". That reasoning is true of EVERY caller, but
--- the guard sat at that one site while every menu path that regenerates — the
--- tap/hold and sticky delay editors, layout changes, action edits — reached
--- M.regenerate() unguarded. This is `project-ahk-invariant-incomplete-application`
--- verbatim: the rule was written down, then applied once.
---
--- The guard now lives in the function that performs the deploy, so a new caller
--- inherits it instead of having to remember it.
---
--- RESUME MUST STILL WORK: script_control clears _is_paused BEFORE calling
--- resume_all(), so M.resume() -> M.regenerate() passes the guard and a setting
--- changed during the pause lands on the resume rebuild rather than being lost.
--- Both directions are asserted below.
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

	local deploys = { count = 0 }
	-- The counter sits on build_karabiner_json: it is the first thing regenerate()
	-- does after the guard, so a non-zero count means the paused deploy went ahead.
	package.loaded["platform.remap.generator"] = {
		build_karabiner_json      = function()
			deploys.count = deploys.count + 1
			return {}
		end,
		merge_into_existing_config = function(built, _dst) return built end,
		deploy_string              = function() return true, "ok" end,
		KE_PHYSICAL_KC_LOG         = nil,
	}

	package.loaded["platform.remap"] = nil
	-- The layout watcher too. platform/remap/watchers.lua:28 does `local hs = hs`,
	-- so it keeps whatever stub was global when it was FIRST required — and
	-- load_with_stubs clears only the module it is given, by design (clearing the
	-- subtree throws away stubs other tests deliberately place there).
	--
	-- Left cached, it reaches start_input_source_watcher holding an `hs` whose
	-- keycodes table has no inputSourceChanged, and the two cases below fail with
	-- "attempt to call a nil value". That happened in CI and not locally, because
	-- test discovery uses lfs when installed and `find` when not, the two orders
	-- differ, and the failure needs something else to have loaded watchers first.
	package.loaded["platform.remap.watchers"] = nil
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

		K.regenerate()

		helpers.assert_eq(deploys.count, 0,
			"regenerate() must not rebuild the full config while paused — deploying it hands "
			.. "KE back every remap the pause removed, silently un-pausing the keyboard while "
			.. "the UI still reports paused")
	end)

	helpers.it("builds and deploys normally when not paused", function()
		-- The opposite failure: a guard that always blocked would break every menu
		-- edit and the resume rebuild itself.
		local K, deploys = load_karabiner(false)

		K.regenerate()

		helpers.assert_true(deploys.count >= 1,
			"regenerate() must still work when the script is not paused — script_control "
			.. "clears the paused flag before resume_all(), so the resume rebuild depends on it")
	end)
end)
