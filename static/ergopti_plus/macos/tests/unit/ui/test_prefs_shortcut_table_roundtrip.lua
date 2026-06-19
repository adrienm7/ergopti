--- tests/unit/ui/test_prefs_shortcut_table_roundtrip.lua

--- ==============================================================================
--- MODULE: Regression — preferences flatten_from_disk restores table-valued scalars
--- DESCRIPTION:
--- Guards against the bug where metrics_shortcut and apps_time_shortcut were
--- silently dropped on every reload. These flat keys map to top-level section
--- entries (KEY_MAP entry with sec+key, no path), but their on-disk TOML value
--- is a structured table {mods={...}, key="..."}. flatten_from_disk entered the
--- type(disk_val)=="table" branch and fell through to the sub-path handler which
--- iterated {mods, key} as inner keys and found nothing in _reverse_scalar.
---
--- Fix (2026-06-19): in the table branch, check _reverse_scalar[sec:disk_key]
--- first (top_scalar_fk). If found, store the whole table value and skip the
--- sub-path walk.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==========================================================================
-- ==========================================================================
-- ======= 1/ flatten_from_disk has top_scalar_fk check for table values ===
-- ==========================================================================
-- ==========================================================================

helpers.describe("preferences flatten_from_disk: table-valued scalar keys", function()
	helpers.it("source checks _reverse_scalar for table disk_val before sub-path walk", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/ui/menu/preferences.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open ui/menu/preferences.lua at: " .. src_file)
		local src = fh:read("*a")
		fh:close()

		-- The fix must check _reverse_scalar in the type=="table" branch using
		-- a top-level sec:disk_key lookup
		helpers.assert_true(
			src:find("top_scalar_fk", 1, true) ~= nil,
			"flatten_from_disk must check top_scalar_fk before sub-path walk"
		)

		-- Verify that the check comes INSIDE the type(disk_val)=="table" branch
		local table_branch_pos = src:find('type(disk_val) == "table"', 1, true)
		local top_scalar_pos   = src:find("top_scalar_fk", 1, true)
		helpers.assert_true(
			table_branch_pos ~= nil and top_scalar_pos ~= nil,
			"both type(disk_val)==table branch and top_scalar_fk must exist"
		)
		helpers.assert_true(
			top_scalar_pos > table_branch_pos,
			"top_scalar_fk check must appear after the type(disk_val)==table branch start"
		)
	end)

	helpers.it("metrics_shortcut and apps_time_shortcut are in KEY_MAP as scalars", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/ui/menu/preferences.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open ui/menu/preferences.lua")
		local src = fh:read("*a")
		fh:close()

		-- Both entries must be present in KEY_MAP
		helpers.assert_true(
			src:find("metrics_shortcut", 1, true) ~= nil,
			"metrics_shortcut must be defined in KEY_MAP"
		)
		helpers.assert_true(
			src:find("apps_time_shortcut", 1, true) ~= nil,
			"apps_time_shortcut must be defined in KEY_MAP"
		)
	end)
end)
