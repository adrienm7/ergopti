--- tests/unit/ui/menu/test_menu_layout_input_sources_header.lua

--- ==============================================================================
--- MODULE: Layout Submenu — A Header Over The Input Sources
--- DESCRIPTION:
--- The input-source list of « Disposition clavier » followed the Ergopti rows
--- with nothing to say what it was. It sits under its own disabled header now,
--- « Sources de saisie », as approved. Rendered through the exact tray call
--- Builder.generate makes.
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

helpers.describe("layout submenu: the input sources have their own header", LayoutFixture.scoped(function()
	helpers.it("draws « Sources de saisie » right before the input-source rows", function()
		local rows = tray_rows(make_ctx("v1"))
		local header = index_of(rows, require("infra.i18n").section("menu.layout.active_layouts"))
		helpers.assert_true(header ~= nil, "the input sources must sit under their own header")
		helpers.assert_eq(rows[header].disabled, true, "a header is a disabled label")
		helpers.assert_eq(rows[header - 1].title, "-", "a separator opens the input-source section")
		helpers.assert_true(rows[header + 1] ~= nil and rows[header + 1].title ~= "-",
			"the header is followed by the input-source rows")
	end)
end))
