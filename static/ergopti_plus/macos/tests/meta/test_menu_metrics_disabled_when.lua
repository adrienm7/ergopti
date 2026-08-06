--- tests/meta/test_menu_metrics_disabled_when.lua

--- ==============================================================================
--- MODULE: Metrics Menu disabled_when Contract Test (MG-1/MG-2, macOS half)
--- DESCRIPTION:
--- Pins the declarative disabled_when predicate the shared manifest now carries
--- for every metrics_menu item, behaviourally exercises the shared resolver
--- (ManifestMenu.resolve_disabled_when) against the REAL manifest data, and
--- asserts the macOS driver actually delegates to it instead of re-deriving
--- the dependency graph by hand (MG-1) — plus that the previously dead
--- depends_on on menubar_colors is now a load-bearing disabled_when, rendered
--- through a "dynamic" (not silently-skipped "feature") entry (MG-2).
---
--- The Windows half lives in windows/tests/meta/test_menu_metrics_disabled_when.ahk.
--- ==============================================================================

local helpers = require("tests.helpers")

-- id -> canonical disabled_when key array (order matches the manifest).
local CANON = {
	{ id = "show_typing",        keys = { "keylogger_enabled" } },
	{ id = "shortcut_typing",    keys = { "keylogger_enabled" } },
	{ id = "show_apps",          keys = { "keylogger_enabled" } },
	{ id = "shortcut_apps",      keys = { "keylogger_enabled" } },
	{ id = "wpm_menubar",        keys = { "keylogger_enabled" } },
	{ id = "menubar_colors",     keys = { "keylogger_enabled", "wpm_menubar_visible" } },
	{ id = "wpm_widget",         keys = { "keylogger_enabled" } },
	{ id = "widget_colors",      keys = { "keylogger_enabled", "wpm_widget_visible" } },
	{ id = "include_realtime",   keys = { "keylogger_enabled", "wpm_widget_visible" } },
	{ id = "reset_wpm_position", keys = { "keylogger_enabled", "wpm_widget_visible" } },
	{ id = "filter_private",     keys = { "keylogger_enabled" } },
	{ id = "filter_secure",      keys = { "keylogger_enabled" } },
	{ id = "filter_sysauth",     keys = { "keylogger_enabled" } },
	{ id = "exclude_apps",       keys = { "keylogger_enabled" } },
	{ id = "encryption",         keys = { "keylogger_enabled" } },
}

local ALL_KEYS = { "keylogger_enabled", "wpm_widget_visible", "wpm_menubar_visible" }

local function all_true_getters()
	local g = {}
	for _, k in ipairs(ALL_KEYS) do
		g[k] = function() return true end
	end
	return g
end

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

--- The shared menu manifest, parsed.
---
--- Read through the renderer's own loader rather than by opening the JSON here:
--- the path differs between a checkout and an installed bundle, and a second
--- resolver would be a second thing to get wrong.
--- @return table
local function load_manifest()
	local ManifestMenu = helpers.load_with_stubs("infra.manifest_menu")
	local root = type(ManifestMenu.get_root) == "function" and ManifestMenu.get_root() or nil
	helpers.assert_true(type(root) == "table",
		"the shared manifest must load — a test that cannot read it would agree with any driver")
	return root
end



--- =========================================
--- ===== 1/ Manifest matches the canon =====
--- =========================================

helpers.describe("menu-metrics-disabled-when (macOS): manifest + resolver agree with the canonical graph", function()
	helpers.it("menu_manifest.json declares the canonical disabled_when for every item", function()
		local fh = io.open(helpers.shared("modules/menu/menu_manifest.json"), "r")
		helpers.assert_true(fh ~= nil, "menu_manifest.json must be readable")
		local raw = fh:read("*a")
		fh:close()
		local data = hs.json.decode(raw)
		helpers.assert_true(type(data) == "table" and type(data.metrics_menu) == "table",
			"menu_manifest.json must have a metrics_menu array")

		local by_id = {}
		for _, entry in ipairs(data.metrics_menu) do
			if type(entry) == "table" and type(entry.id) == "string" then
				by_id[entry.id] = entry
			end
		end

		for _, c in ipairs(CANON) do
			local entry = by_id[c.id]
			helpers.assert_true(entry ~= nil, "metrics_menu must declare an item with id '" .. c.id .. "'")
			helpers.assert_true(type(entry.disabled_when) == "table",
				"metrics_menu item '" .. c.id .. "' must declare disabled_when")
			helpers.assert_eq(#entry.disabled_when, #c.keys,
				"metrics_menu item '" .. c.id .. "' disabled_when must have " .. #c.keys .. " key(s)")
			for i, key in ipairs(c.keys) do
				helpers.assert_eq(entry.disabled_when[i], key,
					"metrics_menu item '" .. c.id .. "' disabled_when[" .. i .. "] must be '" .. key .. "'")
			end
		end
	end)

	helpers.it("menubar_colors depends_on is now load-bearing disabled_when (MG-2)", function()
		local fh = io.open(helpers.shared("modules/menu/menu_manifest.json"), "r")
		local raw = fh:read("*a")
		fh:close()
		local data = hs.json.decode(raw)
		local entry = nil
		for _, e in ipairs(data.metrics_menu) do
			if type(e) == "table" and e.id == "menubar_colors" then entry = e end
		end
		helpers.assert_true(entry ~= nil, "metrics_menu must declare a menubar_colors item")
		helpers.assert_eq(entry.type, "dynamic",
			"menubar_colors must be type=dynamic — type=feature is silently skipped by M.build (MG-2)")
		helpers.assert_true(entry.depends_on == nil,
			"menubar_colors must no longer carry the dead depends_on key — superseded by disabled_when")
	end)




	--- =================================================
	--- ===== 2/ Resolver behaves against real data =====
	--- =================================================

	helpers.it("ManifestMenu.resolve_disabled_when enforces AND semantics against the real manifest", function()
		local ManifestMenu = helpers.load_with_stubs("infra.manifest_menu")
		for _, c in ipairs(CANON) do
			-- Every required key true -> enabled.
			helpers.assert_true(
				ManifestMenu.resolve_disabled_when("metrics_menu", c.id, all_true_getters()) == false,
				"'" .. c.id .. "' must be enabled when every disabled_when key is true")

			-- Flipping any single required key to false -> disabled.
			for _, flip_key in ipairs(c.keys) do
				local getters = all_true_getters()
				getters[flip_key] = function() return false end
				helpers.assert_true(
					ManifestMenu.resolve_disabled_when("metrics_menu", c.id, getters) == true,
					"'" .. c.id .. "' must be disabled when '" .. flip_key .. "' is false")
			end
		end
	end)




	--- ============================================
	--- ===== 3/ macOS driver delegates (MG-1) =====
	--- ============================================

	helpers.it("every canonical item's greying is resolved by the shared resolver", function()
		local src = read_source("\"dialog.metrics.security_warning_title\"") -- ui/menu/menu_metrics.lua
		local manifest = load_manifest()
		for _, c in ipairs(CANON) do
			-- TWO ways to satisfy the invariant, and the invariant is what matters:
			-- the greying must come from the shared resolver reading the manifest,
			-- never from a condition re-derived in this driver.
			--
			--   1. the driver calls the resolver itself, for a row it still builds;
			--   2. the row is declared `type = "check"`, and the SHARED renderer
			--      calls the same resolver while materialising it.
			--
			-- The second is the direction this menu is moving in: the three privacy
			-- filters left this file entirely on 2026-08-06 and the row is now built
			-- once for all three drivers. Asserting only on (1) would have made that
			-- migration look like a regression while the resolver was in fact being
			-- called by more shared code than before.
			local needle = 'ManifestMenu.resolve_disabled_when("metrics_menu", "' .. c.id .. '", STATE_GETTERS)'
			local resolved_here = src:find(needle, 1, true) ~= nil

			local declared_check = false
			for _, entry in ipairs(manifest.metrics_menu or {}) do
				if type(entry) == "table" and entry.id == c.id and entry.type == "check" then
					declared_check = true
				end
			end

			helpers.assert_true(resolved_here or declared_check,
				"'" .. c.id .. "' greying must come from the shared resolver: either this "
					.. "file calls ManifestMenu.resolve_disabled_when for it, or the manifest "
					.. "declares it type=check so the shared renderer does. A hardcoded "
					.. "condition here is what neither allows")

			-- And the two must not BOTH be true: a row the renderer builds and the
			-- driver also builds appears twice.
			helpers.assert_true(not (resolved_here and declared_check),
				"'" .. c.id .. "' is declared type=check AND still resolved in this file — "
					.. "the renderer builds that row now, so a handler here draws it a second time")
		end
	end)

	helpers.it("the shared STATE_GETTERS table reads the correct Lua state", function()
		local src = read_source("\"dialog.metrics.security_warning_title\"") -- ui/menu/menu_metrics.lua
		helpers.assert_true(src:find("keylogger_enabled%s*=%s*function%(%) return state%.keylogger_enabled end") ~= nil,
			"STATE_GETTERS must map keylogger_enabled to state.keylogger_enabled")
		helpers.assert_true(src:find("wpm_widget_visible%s*=%s*function%(%) return state%.keylogger_float_wpm end") ~= nil,
			"STATE_GETTERS must map wpm_widget_visible to state.keylogger_float_wpm")
		helpers.assert_true(src:find("wpm_menubar_visible%s*=%s*function%(%) return state%.keylogger_menubar_wpm end") ~= nil,
			"STATE_GETTERS must map wpm_menubar_visible to state.keylogger_menubar_wpm")
	end)
end)
