--- tests/unit/ui/menu/test_menu_bad_shortcut_mods.lua

--- ==============================================================================
--- MODULE: Regression — string-typed shortcut.mods no longer crashes menus (M-13)
--- DESCRIPTION:
--- Shortcuts persisted to disk before the coerce_mods fix stored .mods as a plain
--- string (e.g. mods="ctrl") instead of a table. ipairs and table.concat both
--- raise on non-table values, which crashed the hotstrings and metrics submenu
--- builders silently (pcall in the menu tick).
---
--- Fix: coerce_mods() wraps both callsites in menu_hotstrings.lua and
--- menu_metrics.lua — { mods="ctrl" } is treated as { mods={"ctrl"} }.
---
--- PF-7: ui/menu/menu_hotstrings.lua was split into menu_hotstrings_custom.lua
--- + menu_hotstrings_management.lua; coerce_mods and its two original call
--- sites (sc_is_default, sc_label) moved intact into menu_hotstrings_custom.lua
--- — this test's hardcoded path is updated to follow it. Separately, sc_fn()
--- (the personal-shortcut-edit dialog builder, a THIRD .mods consumer added
--- after the split) read sc.mods directly with no coerce_mods call, so
--- table.concat(sc.mods, "+") would throw if .mods were ever string-typed
--- (reachable via a hand-edited [hotstrings.editor] TOML entry) — a real, if
--- narrow, bug independent of the path staleness. Fixed the same way as the
--- other two call sites.
---
--- Tests:
---   Source checks: coerce_mods helper present in both files.
---   Source checks: no bare ipairs(sc.mods) / table.concat(sc.mods) remaining.
---   Behavioral: the exact coerce_mods-then-table.concat expression sc_fn now
---     runs does not throw on a string-typed .mods field.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src(rel_path)
	local path = helpers.driver_root() .. rel_path
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, rel_path .. " must be readable")
	local src = fh:read("*a"); fh:close()
	return src
end





-- ===================================================================================
-- ==================================================================================
-- ======= 1/ Source: coerce_mods present in menu_hotstrings and menu_metrics =======
-- ==================================================================================
-- ===================================================================================

helpers.describe("M-13: coerce_mods helper present (source)", function()

	helpers.it("menu_hotstrings.lua defines coerce_mods", function()
		local src = read_src("ui/menu/menu_hotstrings_custom.lua")
		helpers.assert_true(src:find("coerce_mods", 1, true) ~= nil,
			"menu_hotstrings_custom.lua must define coerce_mods to handle string-typed .mods")
	end)

	helpers.it("menu_metrics.lua defines coerce_mods", function()
		local src = read_src("ui/menu/menu_metrics.lua")
		helpers.assert_true(src:find("coerce_mods", 1, true) ~= nil,
			"menu_metrics.lua must define coerce_mods to handle string-typed .mods")
	end)
end)





-- ======================================================================================
-- =====================================================================================
-- ======= 2/ Source: no bare ipairs(sc.mods) or table.concat(sc.mods) remaining =======
-- =====================================================================================
-- ======================================================================================

helpers.describe("M-13: no unguarded sc.mods usage remaining (source)", function()

	helpers.it("menu_hotstrings.lua: ipairs(sc.mods) replaced by coerce_mods", function()
		local src = read_src("ui/menu/menu_hotstrings_custom.lua")
		-- ipairs(sc.mods ...) without coerce_mods wrapping is the crash pattern
		local bare = src:find("ipairs(sc%.mods")
		helpers.assert_true(bare == nil,
			"menu_hotstrings_custom.lua must not call ipairs(sc.mods) directly — use coerce_mods(sc.mods)")
	end)

	helpers.it("menu_hotstrings.lua: table.concat(sc.mods ...) replaced by coerce_mods", function()
		local src = read_src("ui/menu/menu_hotstrings_custom.lua")
		local bare = src:find("table%.concat%(sc%.mods")
		helpers.assert_true(bare == nil,
			"menu_hotstrings_custom.lua must not call table.concat(sc.mods,...) directly — use coerce_mods(sc.mods)")
	end)

	helpers.it("menu_metrics.lua: no bare ipairs on .mods fields", function()
		local src = read_src("ui/menu/menu_metrics.lua")
		-- Check both known field names used in metrics
		local bare1 = src:find("ipairs(state%.metrics_shortcut%.mods")
		local bare2 = src:find("ipairs(state%.apps_time_shortcut%.mods")
		helpers.assert_true(bare1 == nil and bare2 == nil,
			"menu_metrics.lua must not call ipairs on .mods directly — use coerce_mods")
	end)

	helpers.it("menu_metrics.lua: no bare table.concat on .mods fields", function()
		local src = read_src("ui/menu/menu_metrics.lua")
		local bare1 = src:find("table%.concat%(state%.metrics_shortcut%.mods")
		local bare2 = src:find("table%.concat%(state%.apps_time_shortcut%.mods")
		helpers.assert_true(bare1 == nil and bare2 == nil,
			"menu_metrics.lua must not call table.concat on .mods directly — use coerce_mods")
	end)
end)





-- ======================================================================================
-- ======================================================================================
-- ======= 3/ sc_fn() coerces a string-typed .mods before concatenating it (PF-7) =======
-- ======================================================================================
-- ======================================================================================

helpers.describe("PF-7: sc_fn() no longer crashes on string-typed .mods", function()

	helpers.it("source: sc_fn's current_str build goes through coerce_mods, not a bare .mods read", function()
		local src = read_src("ui/menu/menu_hotstrings_custom.lua")
		local fn_start = src:find("local function sc_fn()", 1, true)
		helpers.assert_true(fn_start ~= nil, "sc_fn must still exist in menu_hotstrings_custom.lua")
		local fn_end = src:find("\tend\n", fn_start)
		local body = src:sub(fn_start, fn_end or (fn_start + 800))

		helpers.assert_true(
			body:find("coerce_mods(state.custom_editor_shortcut.mods)", 1, true) ~= nil,
			"sc_fn must build current_str via coerce_mods(state.custom_editor_shortcut.mods)"
		)
		helpers.assert_true(
			body:find("table.concat(state.custom_editor_shortcut.mods", 1, true) == nil,
			"sc_fn must not concatenate state.custom_editor_shortcut.mods directly (the PF-7 crash pattern)"
		)
	end)

	helpers.it("behavioral: the coerce_mods-then-table.concat expression does not throw on a string-typed .mods", function()
		-- Mirrors sc_fn's fixed expression verbatim: coerce_mods(shortcut.mods) then
		-- table.concat + "+" + key. A hand-edited [hotstrings.editor] TOML entry can
		-- persist .mods as a bare string (e.g. mods = "ctrl") instead of a table.
		local function coerce_mods(mods)
			if type(mods) == "table" then return mods end
			if type(mods) == "string" and mods ~= "" then return { mods } end
			return {}
		end
		local function build_current_str(shortcut)
			return table.concat(coerce_mods(shortcut.mods), "+") .. "+" .. (shortcut.key or "")
		end

		local ok_string, result_string = pcall(build_current_str, { mods = "ctrl", key = "v" })
		helpers.assert_true(ok_string, "must not throw when .mods is a bare string")
		helpers.assert_eq(result_string, "ctrl+v")

		local ok_table, result_table = pcall(build_current_str, { mods = { "cmd", "shift" }, key = "s" })
		helpers.assert_true(ok_table, "must still work when .mods is already a table (non-regression)")
		helpers.assert_eq(result_table, "cmd+shift+s")

		local ok_nil, result_nil = pcall(build_current_str, { mods = nil, key = "a" })
		helpers.assert_true(ok_nil, "must not throw when .mods is absent")
		helpers.assert_eq(result_nil, "+a")
	end)
end)
