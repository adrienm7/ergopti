--- tests/meta/test_llm_menu_layout_shared.lua

--- ==============================================================================
--- MODULE: Shared LLM Menu Layout Contract Test (macOS half)
--- DESCRIPTION:
--- The IA submenu's disabled-when-off POLICY (and row order) is a single shared
--- source of truth — _shared/modules/llm/menu_layout.json — consumed by BOTH the
--- macOS renderer (ui/menu/menu_llm/init.lua via ui.menu.menu_llm.menu_layout) and
--- the Windows renderer (windows .../menu_main.ahk). This test pins the macOS half
--- of that contract so the two menus can never drift again (a greying mismatch —
--- backend/model wrongly greyed while the feature is off — was the motivating bug):
---
---   1. The shared JSON declares exactly the canonical rows, in order, with the
---      correct disabled_when_off policy (backend + model usable while off; rest greyed).
---   2. The live MenuLayout policy (what init.lua actually consumes at runtime)
---      matches that canonical policy for every row.
---   3. The built-in fallback in menu_layout.lua mirrors the canonical policy, so the
---      resilience copy cannot drift from the JSON either.
---   4. init.lua is actually spec-DRIVEN: every settings row resolves its greying via
---      MenuLayout.row_disabled(<id>, ...) rather than hardcoding is_disabled/paused.
---
--- The Windows conformance half lives in windows/tests/meta/test_llm_menu_layout_shared.ahk.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()  -- trailing slash

-- Canonical row order + greying policy. greys_off=false -> stays usable while the
-- feature is off (configure before enabling); true -> greyed while off.
local CANON = {
	{ id = "backend",         greys_off = false },
	{ id = "model",           greys_off = false },
	{ id = "profile",         greys_off = true  },
	{ id = "num_predictions", greys_off = true  },
	{ id = "trigger",         greys_off = true  },
	{ id = "generation",      greys_off = true  },
	{ id = "display",         greys_off = true  },
	{ id = "navigation",      greys_off = true  },
}

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end




--- ================================================
--- ======= 1/ Shared JSON is the source ===========
--- ================================================

helpers.describe("llm-menu-layout-shared (macOS): the shared spec + its consumers agree", function()
	helpers.it("menu_layout.json declares the canonical row order + greying policy", function()
		local fh = io.open(DRIVER_ROOT .. "../_shared/modules/llm/menu_layout.json", "r")
		helpers.assert_true(fh ~= nil, "_shared/modules/llm/menu_layout.json must be readable")
		local raw = fh:read("*a")
		fh:close()
		local data = hs.json.decode(raw)
		helpers.assert_true(type(data) == "table" and type(data.rows) == "table", "menu_layout.json must have a 'rows' array")
		helpers.assert_eq(#data.rows, #CANON, "menu_layout.json must declare exactly " .. #CANON .. " rows")
		for i, c in ipairs(CANON) do
			local row = data.rows[i]
			helpers.assert_true(type(row) == "table" and row.id == c.id,
				"menu_layout.json row " .. i .. " must be '" .. c.id .. "' (order is the menu order)")
			helpers.assert_true((row.disabled_when_off == true) == c.greys_off,
				"menu_layout.json row '" .. c.id .. "' disabled_when_off must be " .. tostring(c.greys_off))
		end
	end)

	helpers.it("the live MenuLayout policy matches the canonical policy", function()
		local MenuLayout = helpers.load_with_stubs("ui.menu.menu_llm.menu_layout")
		for _, c in ipairs(CANON) do
			helpers.assert_true(MenuLayout.greys_when_off(c.id) == c.greys_off,
				"MenuLayout.greys_when_off('" .. c.id .. "') must be " .. tostring(c.greys_off))
		end
		-- row_disabled must map the policy to hs's disabled convention: greys-off rows
		-- disable on (off OR paused); the rest disable only on paused.
		helpers.assert_true(MenuLayout.row_disabled("backend", true, false) == nil,
			"backend (stays usable off) must NOT be disabled when off-but-not-paused")
		helpers.assert_true(MenuLayout.row_disabled("backend", true, true) == true,
			"backend must be disabled when paused")
		helpers.assert_true(MenuLayout.row_disabled("profile", true, false) == true,
			"profile (greys off) must be disabled when the feature is off")
	end)

	helpers.it("the menu_layout.lua fallback mirrors the canonical policy", function()
		local src = read_source("local function load_policy") -- ui/menu/menu_llm/menu_layout.lua
		local block = src:match("FALLBACK_GREYS_WHEN_OFF%s*=%s*{(.-)}")
		helpers.assert_true(block ~= nil, "menu_layout.lua must define FALLBACK_GREYS_WHEN_OFF")
		for _, c in ipairs(CANON) do
			local val = block:match(c.id .. "%s*=%s*(%a+)")
			helpers.assert_true(val ~= nil, "fallback must list row '" .. c.id .. "'")
			helpers.assert_true((val == "true") == c.greys_off,
				"fallback row '" .. c.id .. "' must be " .. tostring(c.greys_off) .. " (mirror the JSON)")
		end
	end)

	helpers.it("init.lua resolves every settings row's greying via the shared spec", function()
		local src = read_source("local function format_shortcut_title") -- ui/menu/menu_llm/init.lua
		for _, c in ipairs(CANON) do
			helpers.assert_true(src:find('MenuLayout%.row_disabled%("' .. c.id .. '"', 1, false) ~= nil,
				"init.lua must resolve the '" .. c.id .. "' row greying via MenuLayout.row_disabled (shared spec) — not a hardcoded is_disabled/paused")
		end
	end)
end)
