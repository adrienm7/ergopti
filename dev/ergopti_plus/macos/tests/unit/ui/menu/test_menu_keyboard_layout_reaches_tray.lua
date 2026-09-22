--- tests/unit/ui/menu/test_menu_keyboard_layout_reaches_tray.lua

--- ==============================================================================
--- MODULE: Regression — the Keyboard layout submenu reaches the tray populated
--- DESCRIPTION:
--- The tray root is rendered as provider DATA: a component row hands over
--- `items` (rows to materialise) or `submenu` (a tree already materialised).
--- menu_keyboard_layout returned the rows ManifestMenu.build had ALREADY turned
--- into `title`/`fn` rows under `items`, so the tray renderer dropped every one
--- of them and the submenu opened empty on the real menu bar.
---
--- The same builder also asked the renderer for the pause/resume pickers before
--- it had collected them, so `layout_switching` always rendered nothing.
---
--- Both cases go through the exact render call Builder.generate makes.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the layout row and renders it the way the tray root does.
--- @param ctx table Menu context.
--- @return table|nil rendered The materialised tray row.
local function tray_row(ctx)
	local layout = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")
	local ManifestMenu = require("infra.manifest_menu")
	local item = layout.build(ctx)
	helpers.assert_true(type(item) == "table", "menu_keyboard_layout.build must return a row")
	return ManifestMenu.render_rows({ item }, "top_level")[1]
end

--- Collects every title in a rendered submenu.
--- @param rows table
--- @return table<string, boolean>
local function titles(rows)
	local set = {}
	for _, row in ipairs(rows or {}) do
		if type(row) == "table" and type(row.title) == "string" then set[row.title] = true end
	end
	return set
end

--- A context with live state and a magic-key section, as ui.menu.init supplies.
--- @return table
local function make_ctx()
	return {
		base_dir   = helpers.driver_root(),
		state      = { layout_pause_switch_enabled = true },
		save_prefs = function() return true end,
		updateMenu = function() end,
		do_reload  = function() end,
		keymap     = {
			is_section_enabled = function() return true end,
			is_group_enabled   = function() return true end,
			get_sections       = function()
				return { { name = "replace", description = "Replace J with the magic key" } }
			end,
		},
	}
end

helpers.describe("Keyboard layout submenu reaches the tray populated", function()
	helpers.it("the rendered tray row carries a non-empty submenu", function()
		local row = tray_row(make_ctx())
		helpers.assert_true(type(row) == "table", "the layout row must survive the tray render")
		helpers.assert_true(type(row.menu) == "table" and #row.menu > 0,
			"the Keyboard layout submenu reached the tray empty — materialised rows handed over as `items` "
			.. "are dropped by the tray renderer; they must be handed over as `submenu`")
		local seen = titles(row.menu)
		helpers.assert_true(seen["— menu.layout.header_ergopti —"] or seen["menu.layout.header_ergopti"],
			"the manifest's Ergopti header must be in the rendered submenu")
		helpers.assert_true(seen["menu.layout.logo_default"], "the logo rows must be in the rendered submenu")
	end)

	helpers.it("the pause/resume pickers are collected before the manifest renders them", function()
		local row = tray_row(make_ctx())
		local seen = titles(row and row.menu)
		helpers.assert_true(seen["menu.layout.pause_layout_enabled"],
			"`layout_switching` rendered nothing — the provider was read before its rows were collected")
	end)

	helpers.it("the magic-key replacement row is placed by the renderer", function()
		local row = tray_row(make_ctx())
		local seen = titles(row and row.menu)
		helpers.assert_true(seen["Replace J with the magic key"],
			"the magic-key replacement row must reach the rendered submenu")
	end)
end)
