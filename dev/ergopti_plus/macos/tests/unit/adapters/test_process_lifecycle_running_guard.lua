--- tests/unit/adapters/test_process_lifecycle_running_guard.lua

--- ==============================================================================
--- MODULE: Regression — process_lifecycle _running only set when watchers created
--- DESCRIPTION:
--- Guards against the bug where process_lifecycle.start() set _running = true
--- unconditionally at the end, even if both pcall() calls (for hs.application.watcher
--- and hs.window.filter) had failed. If accessibility permissions were denied,
--- no watchers were created but _running=true, so the next start() would return
--- immediately — permanently disabling app-launch/quit/focus events for the session.
---
--- Fix (2026-06-19): _running = true is only set when _app_watcher ~= nil or
--- _window_filter ~= nil (at least one watcher was successfully created).
--- ==============================================================================

local helpers = require("tests.helpers")




-- =========================================================================
-- =========================================================================
-- ======= 1/ _running only set when watchers are created ==================
-- =========================================================================
-- =========================================================================

helpers.describe("process_lifecycle: _running gate", function()
	helpers.it("source sets _running = true only when watchers were created", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/adapters/process_lifecycle.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open process_lifecycle.lua at: " .. src_file)
		local src = fh:read("*a")
		fh:close()

		-- The old bug: _running = true appears immediately after the second pcall
		-- without any nil check on the watchers. The fix wraps it in a conditional.
		-- Check that the nil-guard pattern exists before _running = true.
		helpers.assert_true(
			src:find("_app_watcher ~= nil or _window_filter ~= nil", 1, true) ~= nil,
			"process_lifecycle must gate _running=true on watcher existence"
		)

		-- The guarded assignment must appear in the source
		local guard_pos  = src:find("_app_watcher ~= nil or _window_filter ~= nil", 1, true)
		local running_pos = src:find("\t\t_running = true", 1, true)
		helpers.assert_true(
			guard_pos ~= nil and running_pos ~= nil,
			"both the guard and _running=true must exist"
		)
		helpers.assert_true(
			running_pos > guard_pos,
			"_running = true must appear after the watcher nil-check guard"
		)
	end)
end)
