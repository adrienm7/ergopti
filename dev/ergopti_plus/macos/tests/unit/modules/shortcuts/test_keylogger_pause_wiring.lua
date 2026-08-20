--- tests/unit/modules/shortcuts/test_keylogger_pause_wiring.lua

--- ==============================================================================
--- MODULE: keylogger pause-wiring source-invariant regression tests
--- DESCRIPTION:
--- Verifies at the source level that the keylogger silencing mechanism is wired
--- via the real poll path (keylogger.handle_key checks _script_control.is_paused)
--- rather than the dead push path (_keylogger.pause/resume in script_control).
---
--- FEATURES & RATIONALE:
--- 1. Source Invariant (a): script_control.lua must NOT reference _keylogger.pause
---    AND keylogger/init.lua must reference _script_control.is_paused — the only
---    combination that actually silences logging in production.
--- 2. Timer/Watcher Guards: keylogger/init.lua timer and watcher callbacks must
---    call _is_paused() so hardware events do not write to the log during pause.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==================================================================================
-- ==================================================================================
-- ======= 1/ Source-level invariant — no dead push branch, real poll present =======
-- ==================================================================================
-- ==================================================================================

helpers.describe("keylogger pause wiring — source-level invariant (e2e-pause-suspend-2 regression)", function()

	helpers.it("script_control.lua does NOT reference _keylogger.pause or _keylogger.resume", function()
		-- Selected by a declaration unique to modules/shortcuts/script_control.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function log_shortcut_if_available")
		helpers.assert_true(src ~= nil, "modules/shortcuts/script_control.lua source must be locatable")
		-- The dead push branch (_keylogger.pause / _keylogger.resume) was never
		-- reachable in production because the 5th arg was never passed. Removing it
		-- avoids false confidence that the keylogger is silenced via push.
		helpers.assert_true(src:find("_keylogger%.pause", 1, false) == nil,
			"script_control.lua must NOT reference _keylogger.pause (dead push branch)")
		helpers.assert_true(src:find("_keylogger%.resume", 1, false) == nil,
			"script_control.lua must NOT reference _keylogger.resume (dead push branch)")
	end)

	helpers.it("keylogger/init.lua handle_key checks _script_control.is_paused (real mechanism)", function()
		-- Selected by a declaration unique to modules/keylogger/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function ensure_browser_window_filter")
		helpers.assert_true(src ~= nil, "modules/keylogger/init.lua source must be locatable")
		helpers.assert_true(src:find("_script_control.is_paused", 1, true) ~= nil,
			"keylogger/init.lua must poll _script_control.is_paused — the real silence mechanism")
	end)

end)





-- ====================================================================================
-- ====================================================================================
-- ======= 2/ Timer/watcher callbacks respect pause guard (e2e-pause-suspend-1) =======
-- ====================================================================================
-- ====================================================================================

helpers.describe("keylogger pause wiring — timer/watcher callbacks guarded (e2e-pause-suspend-1 regression)", function()

	helpers.it("each keylogger timer/watcher gate checks the injected pause predicate", function()
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
		local init_src = read_src("local function ensure_browser_window_filter") -- modules/keylogger/init.lua
		helpers.assert_true(init_src ~= nil, "keylogger/init.lua must be readable")
		local watchers_src = read_src("local function poll_mouse_distance")
		helpers.assert_true(watchers_src ~= nil, "keylogger/watchers.lua must be readable")

		-- Count floors silently became stale when callbacks were consolidated behind
		-- hardware_callback_allowed(). Name every persistence-capable boundary and
		-- require its own direct or shared pause gate instead.
		local boundaries = {
			{ start = "function M.check_idle()", finish = "function M.perform_maintenance()" },
			{ start = "function M.perform_maintenance()", finish = "local function hardware_callback_allowed" },
			{ start = "local function hardware_callback_allowed", finish = "local function run_hardware_callback" },
			{ start = "local function schedule_context_refresh", finish = "local function stop_object_watcher" },
			{ start = "function M.caffeinate_cb(event)", finish = "function M.init_hardware_watchers()" },
		}
		for _, boundary in ipairs(boundaries) do
			local start_at = watchers_src:find(boundary.start, 1, true)
			local finish_at = start_at and watchers_src:find(boundary.finish,
				start_at + #boundary.start, true)
			helpers.assert_true(start_at ~= nil and finish_at ~= nil,
				"pause-guard boundary must remain locatable: " .. boundary.start)
			local body = watchers_src:sub(start_at, finish_at - 1)
			helpers.assert_true(body:find("_is_paused()", 1, true) ~= nil,
				"persistence-capable boundary must consult pause directly or through its gate: "
					.. boundary.start)
		end
	end)

end)
