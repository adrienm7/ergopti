--- tests/unit/ui/test_menu_llm_probe_no_loop.lua

--- ==============================================================================
--- MODULE: Regression — menu_llm probe callback does not unconditionally rebuild
--- DESCRIPTION:
--- Guards against the build_item → probe_llm_health → update_menu → build_item
--- loop that fired at ~10-20 rebuilds/second with live HTTP requests.
---
--- Root cause (2026-06-19): build_item() called probe_llm_health(..., update_menu)
--- passing the bare update_menu function as refresh_fn. The probe's HTTP callback
--- called update_menu() unconditionally, which triggered another build, another
--- probe, and so on.
---
--- Fix: pass a guarded closure that only calls update_menu when _llm_health_status
--- actually changes value from its snapshot at probe-fire time.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =========================================================================
-- =========================================================================
-- ======= 1/ build_item uses a guarded probe callback =====================
-- =========================================================================
-- =========================================================================

helpers.describe("menu_llm build_item: probe callback is guarded", function()
	helpers.it("source does not pass bare update_menu to probe_llm_health", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/ui/menu/menu_llm/init.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open menu_llm/init.lua at: " .. src_file)
		local src = fh:read("*a")
		fh:close()

		-- The old bug: probe_llm_health(backend, update_menu) directly
		helpers.assert_true(
			src:find("probe_llm_health(state.llm_backend", 1, true) ~= nil,
			"probe_llm_health call must still exist in build_item"
		)
		-- The bare pattern must NOT appear (it was the bug)
		helpers.assert_true(
			src:find("probe_llm_health(state.llm_backend or \"mlx\", update_menu)", 1, true) == nil,
			"probe_llm_health must NOT receive bare update_menu — use a guarded closure"
		)
	end)

	helpers.it("probe callback guards on _llm_health_status change", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/ui/menu/menu_llm/init.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open menu_llm/init.lua")
		local src = fh:read("*a")
		fh:close()

		-- The guard must compare against a snapshot captured before the probe
		helpers.assert_true(
			src:find("probe_snapshot", 1, true) ~= nil,
			"probe callback must use probe_snapshot to guard against unnecessary rebuilds"
		)
		helpers.assert_true(
			src:find("_llm_health_status ~= probe_snapshot", 1, true) ~= nil,
			"probe callback must only call update_menu when _llm_health_status changes"
		)
	end)
end)
