--- tests/unit/platform/remap/test_set_enabled_async_kill.lua

--- ==============================================================================
--- MODULE: Regression — set_enabled(false) uses async kill, not blocking
--- DESCRIPTION:
--- Guards against the bug where karabiner/init.lua M.set_enabled(false) called
--- hs.execute(KILL_CMD) synchronously. KILL_CMD has `for pass in 1 2 3; do
--- ... /bin/sleep 1; done` — blocking the main run loop for ≥3 s. This is
--- triggered directly from the UI menu and caused a 3 s freeze on every
--- "disable Karabiner" click.
---
--- Fix (2026-06-19): added KeLifecycle.kill_async() which backgrounds KILL_CMD
--- via nohup, then called it from set_enabled() instead of the synchronous path.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =================================================================
-- =================================================================
-- ======= 1/ set_enabled source uses kill_async, not KILL_CMD ====
-- =================================================================
-- =================================================================

helpers.describe("karabiner set_enabled(false): async kill", function()
	helpers.it("set_enabled() calls kill_async(), not hs.execute(KILL_CMD)", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local init_src = base .. "/platform/remap/init.lua"

		local fh = io.open(init_src, "r")
		helpers.assert_true(fh ~= nil, "Cannot open karabiner/init.lua at: " .. init_src)
		local src = fh:read("*a")
		fh:close()

		-- Find set_enabled function body (everything between function M.set_enabled and next function)
		local set_enabled_start = src:find("function M%.set_enabled%(", 1, false)
		helpers.assert_true(set_enabled_start ~= nil, "function M.set_enabled not found")

		-- Extract a region of 500 chars starting from set_enabled (covers the function body)
		local region = src:sub(set_enabled_start, set_enabled_start + 600)

		-- Must call kill_async
		helpers.assert_true(
			region:find("kill_async", 1, true) ~= nil,
			"set_enabled() must call kill_async() instead of synchronous hs.execute(KILL_CMD)"
		)

		-- Must NOT call hs.execute(KILL_CMD) directly inside set_enabled
		helpers.assert_true(
			region:find("hs%.execute.*KILL_CMD", 1, false) == nil,
			"set_enabled() must not call hs.execute(KILL_CMD) synchronously — use kill_async()"
		)
	end)

	helpers.it("ke_lifecycle exports kill_async as a function", function()
		local KeLifecycle = helpers.load_with_stubs("platform.remap.ke_lifecycle")
		helpers.assert_true(
			type(KeLifecycle.kill_async) == "function",
			"ke_lifecycle must export kill_async()"
		)
	end)
end)
