--- tests/unit/modules/shortcuts/system_actions/test_keystats_pause_wiring.lua

--- ==============================================================================
--- MODULE: keystats pause-wiring source-invariant regression tests
--- DESCRIPTION:
--- Verifies at the source level that the keystats silencing mechanism is wired
--- via the real poll path (keystats.handle_key checks _script_control.is_paused)
--- rather than the dead push path (_keystats.pause/resume in script_control).
---
--- FEATURES & RATIONALE:
--- 1. Source Invariant (a): script_control.lua must NOT reference _keystats.pause
---    AND keystats/init.lua must reference _script_control.is_paused — the only
---    combination that actually silences logging in production.
--- 2. Timer/Watcher Guards: keystats/init.lua timer and watcher callbacks must
---    call _is_paused() so hardware events do not write to the log during pause.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==================================================================================
-- ==================================================================================
-- ======= 1/ Source-level invariant — no dead push branch, real poll present =======
-- ==================================================================================
-- ==================================================================================

helpers.describe("keystats pause wiring — source-level invariant (e2e-pause-suspend-2 regression)", function()

	helpers.it("script_control.lua does NOT reference _keystats.pause or _keystats.resume", function()
		-- Selected by a declaration unique to modules/shortcuts/script_control.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function log_shortcut_if_available")
		helpers.assert_true(src ~= nil, "modules/shortcuts/script_control.lua source must be locatable")
		-- The dead push branch (_keystats.pause / _keystats.resume) was never
		-- reachable in production because the 5th arg was never passed. Removing it
		-- avoids false confidence that the keystats is silenced via push.
		helpers.assert_true(src:find("_keystats%.pause", 1, false) == nil,
			"script_control.lua must NOT reference _keystats.pause (dead push branch)")
		helpers.assert_true(src:find("_keystats%.resume", 1, false) == nil,
			"script_control.lua must NOT reference _keystats.resume (dead push branch)")
	end)

	helpers.it("keystats/init.lua handle_key checks _script_control.is_paused (real mechanism)", function()
		-- Selected by a declaration unique to modules/keystats/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function ensure_browser_window_watchers")
		helpers.assert_true(src ~= nil, "modules/keystats/init.lua source must be locatable")
		helpers.assert_true(src:find("_script_control.is_paused", 1, true) ~= nil,
			"keystats/init.lua must poll _script_control.is_paused — the real silence mechanism")
	end)

end)





-- ====================================================================================
-- ====================================================================================
-- ======= 2/ Timer/watcher callbacks respect pause guard (e2e-pause-suspend-1) =======
-- ====================================================================================
-- ====================================================================================

helpers.describe("keystats pause wiring — timer/watcher callbacks guarded (e2e-pause-suspend-1 regression)", function()

	helpers.it("each keystats timer/watcher gate checks the injected pause predicate", function()
		-- The sensor callbacks (check_idle, perform_maintenance, caffeinate_cb,
		-- wifi/battery/spaces/audio watcher lambdas) were extracted into the
		-- self-contained watchers.lua, which receives _is_paused as an injected
		-- predicate and keeps the exact _is_paused() guard at every call site.
		-- Read both files so the guard count survives that move (move-resilient).
		-- Takes a selector unique to one production file rather than that file's
		-- path, so moving or splitting a module cannot turn these invariants into
		-- path errors.
		local function read_src(selector)
			local s = helpers.read_driver_source(selector)
			return s
		end
		local init_src = read_src("local function ensure_browser_window_watchers") -- modules/keystats/init.lua
		helpers.assert_true(init_src ~= nil, "keystats/init.lua must be readable")
		local watchers_src = read_src("local function poll_mouse_distance")
		helpers.assert_true(watchers_src ~= nil, "keystats/watchers.lua must be readable")

		-- Count floors silently became stale when callbacks were consolidated behind
		-- hardware_callback_allowed(). Name every persistence-capable boundary and
		-- require its own direct or shared pause gate instead.
		local boundaries = {
			"function M.check_idle()",
			"function M.perform_maintenance()",
			"local function hardware_callback_allowed",
			"local function schedule_context_refresh",
			"function M.caffeinate_cb(event)",
		}
		for _, boundary in ipairs(boundaries) do
			local start_at = watchers_src:find(boundary, 1, true)
			-- These top-level functions close at column zero under the convention
			-- gate; sibling declaration order must not determine the scanned body
			local finish_at = start_at and watchers_src:find("\nend", start_at + #boundary, true)
			helpers.assert_true(start_at ~= nil and finish_at ~= nil,
				"pause-guard boundary must remain locatable: " .. boundary)
			local body = watchers_src:sub(start_at, finish_at - 1)
			helpers.assert_true(body:find("_is_paused()", 1, true) ~= nil,
				"persistence-capable boundary must consult pause directly or through its gate: "
					.. boundary)
		end
	end)

end)
