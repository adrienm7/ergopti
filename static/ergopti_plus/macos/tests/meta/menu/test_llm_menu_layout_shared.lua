--- tests/meta/menu/test_llm_menu_layout_shared.lua

--- ==============================================================================
--- MODULE: Shared LLM Menu Layout Contract Test (macOS half)
--- DESCRIPTION:
--- The IA submenu's disabled-when-off POLICY (and row order) is a single shared
--- source of truth — the menu manifest's ``llm_menu`` key — consumed by BOTH the
--- macOS renderer (ui/menu/menu_llm/init.lua via ui.menu.menu_llm.menu_layout) and
--- the Windows renderer (windows .../menu_main.ahk). This test pins the macOS half
--- of that contract so the two menus can never drift again (a greying mismatch —
--- backend/model wrongly greyed while the feature is off — was the motivating bug):
---
---   1. The manifest declares exactly the canonical rows, in order, with the
---      correct disabled_when_off policy (backend + model usable while off; rest greyed).
---   2. The live MenuLayout policy (what init.lua actually consumes at runtime)
---      matches that canonical policy for every row.
---   3. The built-in fallback in menu_layout.lua mirrors the canonical policy, so the
---      resilience copy cannot drift from the manifest either.
---   4. init.lua is actually spec-DRIVEN: every settings row resolves its greying via
---      MenuLayout.row_disabled(<id>, ...) rather than hardcoding is_disabled/paused.
---   5. The retired second description has not come back.
---
--- MOVED 2026-08-07: this contract used to read _shared/modules/llm/menu_layout.json,
--- a spec file of its own. One menu therefore had TWO shared descriptions — that
--- file and the manifest's ``llm_menu`` key, which described a two-row menu only
--- the Linux driver drew — and neither mentioned the other. Case 5 below is what
--- stops a second description from being reintroduced.
---
--- The Windows conformance half lives in windows/tests/meta/test_llm_menu_layout_shared.ahk.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()  -- trailing slash

-- Canonical row order + greying policy. greys_off=false -> stays usable while the
-- feature is off (configure before enabling); true -> greyed while off.
-- The Backend chooser moved to the model selector page on 2026-10-27; the
-- model row is the page's button.
local CANON = {
	{ id = "llm_model",               greys_off = false },
	{ id = "llm_profile",             greys_off = true },
	{ id = "llm_trigger",             greys_off = true },
	{ id = "llm_generation_settings", greys_off = true },
	{ id = "llm_display",             greys_off = true },
	{ id = "llm_navigation",          greys_off = true },
}

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

--- Reads and decodes the whole shared menu manifest.
--- @return table The decoded manifest.
local function manifest()
	local fh = io.open(DRIVER_ROOT .. "../_shared/modules/menu/menu_manifest.json", "r")
	helpers.assert_true(fh ~= nil, "_shared/modules/menu/menu_manifest.json must be readable")
	local raw = fh:read("*a")
	fh:close()
	return hs.json.decode(raw)
end

--- Reads the manifest's llm_menu rows that this driver renders: the declared
--- ``dynamic`` rows visible on "hs". Linux's two inline `list` rows and the
--- separator between them are not settings rows and are filtered out here exactly
--- as menu_layout.lua filters them at runtime.
--- @return table Ordered list of manifest rows.
local function manifest_rows()
	local fh = io.open(DRIVER_ROOT .. "../_shared/modules/menu/menu_manifest.json", "r")
	helpers.assert_true(fh ~= nil, "_shared/modules/menu/menu_manifest.json must be readable")
	local raw = fh:read("*a")
	fh:close()
	local data = hs.json.decode(raw)
	helpers.assert_true(type(data) == "table" and type(data.llm_menu) == "table",
		"menu_manifest.json must have an 'llm_menu' array")
	local rows = {}
	for _, row in ipairs(data.llm_menu) do
		-- The settings rows are the ones declaring a greying policy, whatever their
		-- type: the model and profile rows are `list` rows since 2026-10-31.
		if type(row) == "table" and type(row.disabled_when_off) == "boolean" then
			local visible = true
			if type(row.platforms) == "table" then
				visible = false
				for _, p in ipairs(row.platforms) do
					if p == "hs" then visible = true; break end
				end
			end
			if visible then rows[#rows + 1] = row end
		end
	end
	return rows
end




--- ================================================
--- ======= 1/ The manifest is the source ==========
--- ================================================

helpers.describe("llm-menu-layout-shared (macOS): the shared spec + its consumers agree", function()
	helpers.it("the manifest declares the canonical row order + greying policy", function()
		local rows = manifest_rows()
		helpers.assert_eq(#rows, #CANON, "llm_menu must declare exactly " .. #CANON .. " macOS row(s)")
		for i, c in ipairs(CANON) do
			local row = rows[i]
			helpers.assert_true(row.id == c.id,
				"llm_menu row " .. i .. " must be '" .. c.id .. "' (order is the menu order)")
			helpers.assert_true((row.disabled_when_off == true) == c.greys_off,
				"llm_menu row '" .. c.id .. "' disabled_when_off must be " .. tostring(c.greys_off))
			helpers.assert_eq(row.health_dot, nil,
				"llm_menu row '" .. c.id .. "' must not carry a health dot — the AI title does")
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
		helpers.assert_true(MenuLayout.row_disabled("llm_model", true, false) == nil,
			"llm_model (stays usable off) must NOT be disabled when off-but-not-paused")
		helpers.assert_true(MenuLayout.row_disabled("llm_model", true, true) == true,
			"llm_model must be disabled when paused")
		helpers.assert_true(MenuLayout.row_disabled("llm_profile", true, false) == true,
			"llm_profile (greys off) must be disabled when the feature is off")
		helpers.assert_eq(MenuLayout.has_health_dot, nil,
			"no submenu row carries the health dot any more — the AI title does")
	end)

	helpers.it("the AI title health dot comes from the top-level llm declaration", function()
		local data = manifest()
		local llm_top
		for _, entry in ipairs(data.top_level) do
			if entry.id == "llm" then llm_top = entry end
		end
		helpers.assert_true(type(llm_top) == "table", "top_level must declare the llm entry")
		helpers.assert_eq(llm_top.health_dot.ready, "🟢")
		helpers.assert_eq(llm_top.health_dot.warming, "🟡")
		helpers.assert_eq(llm_top.health_dot.unreachable, "🔴")
		local MenuLayout = helpers.load_with_stubs("ui.menu.menu_llm.menu_layout")
		for status, glyph in pairs(llm_top.health_dot) do
			helpers.assert_eq(MenuLayout.title_health_dot(status), glyph,
				"title_health_dot('" .. status .. "') must read the manifest glyph")
		end
		helpers.assert_eq(MenuLayout.title_health_dot("unknown"), nil)
		local src = read_source("local function format_shortcut_title") -- ui/menu/menu_llm/init.lua
		helpers.assert_true(src:find("MenuLayout%.title_health_dot%(health_status%)") ~= nil,
			"init.lua must take the title glyph from the manifest, not a literal")
		helpers.assert_true(src:find('"🟢 "', 1, true) == nil and src:find('"🔴 "', 1, true) == nil,
			"init.lua must not hardcode a health glyph")
	end)

	helpers.it("the menu_layout.lua fallback mirrors the canonical policy", function()
		local src = read_source("local function load_policy") -- ui/menu/menu_llm/menu_layout.lua
		local block = src:match("FALLBACK_GREYS_WHEN_OFF%s*=%s*{(.-)}")
		helpers.assert_true(block ~= nil, "menu_layout.lua must define FALLBACK_GREYS_WHEN_OFF")
		for _, c in ipairs(CANON) do
			local val = block:match(c.id .. "%s*=%s*(%a+)")
			helpers.assert_true(val ~= nil, "fallback must list row '" .. c.id .. "'")
			helpers.assert_true((val == "true") == c.greys_off,
				"fallback row '" .. c.id .. "' must be " .. tostring(c.greys_off) .. " (mirror the manifest)")
		end
	end)

	helpers.it("init.lua resolves every settings row's greying via the shared spec", function()
		local src = read_source("local function format_shortcut_title") -- ui/menu/menu_llm/init.lua
		for _, c in ipairs(CANON) do
			helpers.assert_true(src:find('MenuLayout%.row_disabled%("' .. c.id .. '"', 1, false) ~= nil,
				"init.lua must resolve the '" .. c.id .. "' row greying via MenuLayout.row_disabled (shared spec) — not a hardcoded is_disabled/paused")
		end
	end)

	helpers.it("the manifest PLACES the rows — init.lua no longer orders them itself", function()
		local src = read_source("local function format_shortcut_title") -- ui/menu/menu_llm/init.lua
		helpers.assert_true(src:find('ManifestMenu%.build%("llm_menu"') ~= nil,
			"init.lua must build this menu through the shared renderer")
		-- The settings rows that are not groups are declared `list` rows: init.lua
		-- supplies their DATA under the declared id and hands the renderer no
		-- handler table, so no row is placed by platform code.
		for _, row in ipairs(manifest_rows()) do
			if row.type == "list" then
				helpers.assert_true(src:find("list_providers%." .. row.id .. "%s*=%s*function") ~= nil,
					"init.lua must supply the declared list row '" .. row.id .. "' as provider DATA")
			end
		end
		helpers.assert_true(src:find('ManifestMenu%.build%("llm_menu", "LLM", nil, group_builders') ~= nil,
			"init.lua must pass the renderer no dynamic handler table — the row type is retired")
		-- The rows used to be appended to the menu as they were built, which is why
		-- the model row sat ninth here and second on Windows from one shared spec.
		helpers.assert_true(src:find("table%.insert%(main_menu") == nil,
			"init.lua must not append settings rows to the menu directly — the order is " ..
			"the manifest's, and an in-place insert silently escapes it")
	end)

	helpers.it("the retired second description has not come back", function()
		local fh = io.open(DRIVER_ROOT .. "../_shared/modules/llm/menu_layout.json", "r")
		if fh then fh:close() end
		helpers.assert_true(fh == nil,
			"_shared/modules/llm/menu_layout.json must not exist — the IA menu is described in the " ..
			"menu manifest's llm_menu key, and a second shared description would drift from it")
	end)
end)


helpers.describe("shared fixed LLM group declarations", function()
	helpers.it("the selected parents are genuine groups with unchanged native policy", function()
		local groups = { llm_trigger = true, llm_display = true, llm_navigation = true }
		local count = 0
		local additional_groups = 0
		for _, row in ipairs(manifest_rows()) do
			if groups[row.id] then
				helpers.assert_eq(row.type, "group")
				helpers.assert_eq(row.disabled_when_off, true)
				helpers.assert_eq(row.health_dot, nil)
				count = count + 1
			elseif row.id == "llm_generation_settings" then
				helpers.assert_eq(row.type, "group")
				helpers.assert_eq(row.disabled_when_off, true)
				helpers.assert_eq(row.health_dot, nil)
				additional_groups = additional_groups + 1
			else
				helpers.assert_eq(row.type, "list", "the model and profile rows are list rows whose providers supply DATA")
			end
		end
		helpers.assert_eq(count, 3)
		helpers.assert_eq(additional_groups, 1)
	end)
end)

helpers.describe("Single manual LLM profile selection", function()
	helpers.it("retires shortcut overrides without losing the original transaction returns", function()
		local source = read_source("deps.settle_llm_switcher_recovery = switcher.settle_recovery_debts")
		require("test.manual_profile_selection").assert_selection(helpers, "hs", source)
	end)
end)
