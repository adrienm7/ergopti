--- tests/unit/ui/menu/test_pause_checked_state.lua

--- ==============================================================================
--- MODULE: ui.menu — pause/checked state regression
--- DESCRIPTION:
--- Locks down the bug where pausing the script unchecked all feature submenus
--- (Hotstrings, Gestes, Raccourcis, IA, Script Control). Pausing disables the
--- functions but must not remove the visual checkmark indicating the feature's
--- configured state. Metrics and Karabiner were already correct — they never
--- used `and not paused` in their checked expressions.
---
--- Root cause: `checked = (X and not paused) or nil` was used across all menu
--- modules. The fix replaces it with `checked = X or nil` so the checkmark
--- reflects the user's configured state, independently of the pause state.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads a source file via the active package.path.
--- @param module_name string Dot-separated module name (e.g. "ui.menu.menu_gestures").
--- @return string Source text.
local function read_source(module_name)
	local path = package.searchpath(module_name, package.path)
	helpers.assert_true(
		type(path) == "string" and path ~= "",
		"could not resolve " .. module_name .. " on package.path"
	)
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "could not open " .. module_name)
	local src = fh:read("*a")
	fh:close()
	return src
end

--- Returns the number of times `pattern` appears in `src`.
--- @param src string Source text.
--- @param pattern string Lua string pattern.
--- @return number
local function count_matches(src, pattern)
	local n = 0
	for _ in src:gmatch(pattern) do n = n + 1 end
	return n
end




-- ========================================================================
-- ========================================================================
-- ======= 1/ No `and not paused` in checked expressions =================
-- ========================================================================
-- ========================================================================

-- Each of these files previously used `checked = (X and not paused) or nil`,
-- which caused all checkmarks to vanish when the script was paused. Every
-- occurrence must have been removed.

local MENU_MODULES = {
	"ui.menu.menu_gestures",
	"ui.menu.menu_hotstrings",
	"ui.menu.menu_shortcuts",
	"ui.menu.builder",
	"ui.menu.menu_llm.init",
}

helpers.describe("pause: checked state must not depend on pause", function()
	for _, mod in ipairs(MENU_MODULES) do
		helpers.it(mod .. " has no `checked = (X and not paused)` pattern", function()
			local src = read_source(mod)
			-- The exact form of the bug: the boolean guard `not paused` inside a
			-- checked expression. A legit `not paused` can still appear in `fn` or
			-- `disabled` — we only care about the `checked` field.
			-- Strategy: find all lines that contain `checked` and assert none also
			-- contain `not paused` on the same line.
			local bad_count = 0
			for line in src:gmatch("[^\n]+") do
				if line:find("checked") and line:find("not paused") and line:find("not ctx%.paused") then
					bad_count = bad_count + 1
				end
			end
			helpers.assert_eq(
				bad_count, 0,
				mod .. ": found `checked` lines still containing `not paused` / `not ctx.paused` — " ..
				"pausing must NOT remove the visual checkmark from configured features"
			)
		end)
	end
end)


helpers.describe("pause: menu_keyboard_layout replace section", function()
	helpers.it("replace_enabled checked does not depend on hs_paused", function()
		local src = read_source("ui.menu.menu_keyboard_layout")
		-- Count lines that have both `checked` and `not hs_paused`
		local bad = 0
		for line in src:gmatch("[^\n]+") do
			if line:find("checked") and line:find("not hs_paused") then
				bad = bad + 1
			end
		end
		helpers.assert_eq(bad, 0,
			"menu_keyboard_layout: checked still gated on `not hs_paused`")
	end)
end)
