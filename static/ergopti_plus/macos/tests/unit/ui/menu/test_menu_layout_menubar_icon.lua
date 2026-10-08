--- tests/unit/ui/menu/test_menu_layout_menubar_icon.lua

--- ==============================================================================
--- MODULE: Layout Submenu — One Menubar Icon Row, Stored In config.toml
--- DESCRIPTION:
--- The menubar icon was two sibling rows of « Disposition clavier », one per
--- variant, and the choice lived in hs.settings rather than in config.toml. It
--- is ONE row now, « Icône de la barre des menus », whose submenu offers v1 and
--- v2 with the current one ticked; it is the last row of the custom-layout section,
--- and choosing a value stores it in the state config.toml [ui] is written from.
--- Rendered through the exact tray call Builder.generate makes.
--- ==============================================================================

local helpers = require("tests.helpers")
local LayoutFixture = require("tests.support.layout_legacy_caption_fixture")

--- Builds the layout row and renders it the way the tray root does.
--- @param ctx table Menu context.
--- @return table rendered submenu rows
local function tray_rows(ctx)
	local layout = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")
	local ManifestMenu = LayoutFixture.install(require("infra.i18n"))
	local item = layout.build(ctx)
	helpers.assert_true(type(item) == "table", "menu_keyboard_layout.build must return a row")
	local row = ManifestMenu.render_rows({ item }, "top_level")[1]
	helpers.assert_true(type(row) == "table" and type(row.menu) == "table", "the layout submenu must render")
	return row.menu
end

--- A context with live state, as ui.menu.init supplies.
--- @param icon string Current menubar icon value.
--- @return table ctx, table calls
local function make_ctx(icon)
	local calls = { saves = 0, icons = 0, updates = 0 }
	local ctx = {
		base_dir     = helpers.driver_root(),
		state        = { layout_pause_switch_enabled = false, menubar_icon = icon },
		save_prefs   = function() calls.saves = calls.saves + 1; return true end,
		refresh_icon = function() calls.icons = calls.icons + 1 end,
		updateMenu   = function() calls.updates = calls.updates + 1 end,
		do_reload    = function() end,
		keymap       = {
			is_section_enabled = function() return false end,
			is_group_enabled   = function() return false end,
			get_sections       = function() return {} end,
		},
	}
	return ctx, calls
end

--- Position of the first row titled `title`, or nil.
--- @param rows table
--- @param title string
--- @return number|nil
local function index_of(rows, title)
	for index, row in ipairs(rows) do
		if row.title == title then return index end
	end
	return nil
end

helpers.describe("layout submenu: the menubar icon is one choice row", LayoutFixture.scoped(function()
	helpers.it("draws one « Icône de la barre des menus » row with v1 and v2, the current one ticked", function()
		local ctx = make_ctx("v2")
		local rows = tray_rows(ctx)
		local at = index_of(rows, "menu.layout.menubar_icon")
		helpers.assert_true(at ~= nil, "the menubar icon row must be drawn")
		local choices = rows[at].menu
		helpers.assert_type(choices, "table", "the icon values hang under the row")
		helpers.assert_eq(#choices, 2)
		helpers.assert_eq(choices[1].title, "menu.layout.menubar_icon.v1")
		helpers.assert_eq(choices[2].title, "menu.layout.menubar_icon.v2")
		helpers.assert_eq(choices[1].checked, false)
		helpers.assert_eq(choices[2].checked, true, "the stored value is ticked")
		helpers.assert_nil(index_of(rows, "menu.layout.logo_default"), "the per-variant rows are gone")
		helpers.assert_nil(index_of(rows, "menu.layout.logo_custom"), "the per-variant rows are gone")
	end)

	helpers.it("is the last row of the custom-layout section", function()
		local rows = tray_rows(make_ctx("v1"))
		local header = index_of(rows, require("infra.i18n").section("menu.layout.header_custom"))
		local at = index_of(rows, "menu.layout.menubar_icon")
		helpers.assert_true(header ~= nil and at ~= nil and header < at,
			"the icon row belongs to the custom-layout section")
		for index = header + 1, at - 1 do
			helpers.assert_true(rows[index].title ~= "-", "no separator may split the custom-layout section before the icon row")
		end
		helpers.assert_eq(rows[at + 1].title, "-", "a separator must close the custom-layout section right after the icon row")
	end)

	helpers.it("choosing a value stores it in the saved state and redraws the icon", function()
		local ctx, calls = make_ctx("v2")
		local rows = tray_rows(ctx)
		local choices = rows[index_of(rows, "menu.layout.menubar_icon")].menu
		choices[1].fn()
		helpers.assert_eq(ctx.state.menubar_icon, "v1", "the choice lands in the state config.toml is written from")
		helpers.assert_eq(calls.saves, 1, "the choice must be saved")
		helpers.assert_eq(calls.icons, 1, "the menubar icon must be redrawn")
	end)

	helpers.it("defaults to the manifest's value", function()
		local layout = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")
		local Manifest = require("infra.manifest_reader")
		helpers.assert_eq(layout.DEFAULT_STATE.menubar_icon, Manifest.default_for("ui.menubar_icon"))
		helpers.assert_eq(layout.DEFAULT_STATE.menubar_icon, "v1")
	end)
end))

helpers.describe("layout submenu: the icon choice is stored in config.toml, not hs.settings", function()
	helpers.it("no production source keeps the retired hs.settings key", function()
		local everything = helpers.read_driver_source(nil)
		helpers.assert_true(type(everything) == "string" and #everything > 100000,
			"the production sources must be read")
		helpers.assert_nil(helpers.read_driver_source("menubar_logo_variant"),
			"no source may read or migrate the hs.settings icon key")
	end)

	helpers.it("config.toml [ui] menubar_icon loads into the state", function()
		local tmp = os.tmpname()
		pcall(os.remove, tmp)
		local fh = assert(io.open(tmp, "w"))
		fh:write("[ui]\nmenubar_icon = \"v2\"\n")
		fh:close()
		local Prefs = helpers.load_with_stubs("infra.preferences")
		local flat = Prefs.load(tmp)
		pcall(os.remove, tmp)
		helpers.assert_eq(flat.menubar_icon, "v2", "[ui] menubar_icon must reach the menu state")
	end)
end)
