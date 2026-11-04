--- tests/unit/ui/menu/keyboard_layout/test_menu_layout_virtual_keyboard.lua

--- ==============================================================================
--- MODULE: Layout Submenu — Karabiner Virtual Keyboard Choice
--- DESCRIPTION:
--- One manifest `choice` row offers Automatic, ISO and ANSI with the stored value
--- ticked. Choosing a value stores it in the state config.toml [layout] is written
--- from and asks the Karabiner bridge to redeploy; a refused save restores the
--- previous value and redeploys nothing. Rendered through the exact tray call
--- Builder.generate makes.
--- ==============================================================================

local helpers = require("tests.helpers")
local LayoutFixture = require("tests.support.layout_legacy_caption_fixture")

local ROW = "menu.layout.virtual_keyboard"

--- Builds the layout row and renders it the way the tray root does.
--- @param ctx table Menu context.
--- @return table rendered submenu rows
local function tray_rows(ctx)
	local layout = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")
	local ManifestMenu = LayoutFixture.install(require("infra.i18n"))
	local item = layout.build(ctx)
	local row = ManifestMenu.render_rows({ item }, "top_level")[1]
	helpers.assert_true(type(row) == "table" and type(row.menu) == "table", "the layout submenu must render")
	return row.menu
end

--- A context with live state, as ui.menu.init supplies.
--- @param choice string Current virtual keyboard choice.
--- @param save_ok boolean Whether the preference save succeeds.
--- @return table ctx, table calls
local function make_ctx(choice, save_ok)
	local calls = { saves = 0, regenerations = 0, updates = 0 }
	local ctx = {
		base_dir     = helpers.driver_root(),
		state        = { layout_pause_switch_enabled = false, menubar_icon = "v1", layout_virtual_keyboard = choice },
		save_prefs   = function() calls.saves = calls.saves + 1; return save_ok end,
		refresh_icon = function() end,
		updateMenu   = function() calls.updates = calls.updates + 1 end,
		do_reload    = function() end,
		karabiner    = { regenerate = function() calls.regenerations = calls.regenerations + 1; return true end },
		keymap       = {
			is_section_enabled = function() return false end,
			is_group_enabled   = function() return false end,
			get_sections       = function() return {} end,
		},
	}
	return ctx, calls
end

--- The choice rows hanging under the virtual keyboard row.
--- @param rows table
--- @return table choices
local function choices_of(rows)
	for _, row in ipairs(rows) do
		if row.title == ROW then return row.menu end
	end
	error("the virtual keyboard row must be drawn")
end

helpers.describe("layout submenu: the Karabiner virtual keyboard is one choice row", LayoutFixture.scoped(function()
	helpers.it("offers Automatic, ISO and ANSI with the stored value ticked", function()
		local choices = choices_of(tray_rows((make_ctx("iso", true))))
		helpers.assert_eq(#choices, 3)
		helpers.assert_eq(choices[1].title, ROW .. ".auto")
		helpers.assert_eq(choices[2].title, ROW .. ".iso")
		helpers.assert_eq(choices[3].title, ROW .. ".ansi")
		helpers.assert_eq(choices[1].checked, false)
		helpers.assert_eq(choices[2].checked, true, "the stored value is ticked")
		helpers.assert_eq(choices[3].checked, false)
	end)

	helpers.it("stores the choice and redeploys the Karabiner config", function()
		local ctx, calls = make_ctx("auto", true)
		choices_of(tray_rows(ctx))[3].fn()
		helpers.assert_eq(ctx.state.layout_virtual_keyboard, "ansi", "the choice lands in the saved state")
		helpers.assert_eq(calls.saves, 1)
		helpers.assert_eq(calls.regenerations, 1, "the deployed config names its keys for the new product")
	end)

	helpers.it("keeps the previous choice and redeploys nothing when the save is refused", function()
		local ctx, calls = make_ctx("auto", false)
		choices_of(tray_rows(ctx))[2].fn()
		helpers.assert_eq(ctx.state.layout_virtual_keyboard, "auto")
		helpers.assert_eq(calls.regenerations, 0)
	end)

	helpers.it("defaults to the manifest's value", function()
		local layout = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")
		helpers.assert_eq(layout.DEFAULT_STATE.layout_virtual_keyboard,
			require("infra.manifest_reader").default_for("layout.virtual_keyboard"))
		helpers.assert_eq(layout.DEFAULT_STATE.layout_virtual_keyboard, "auto")
	end)

	helpers.it("loads [layout] virtual_keyboard from config.toml into the state", function()
		local tmp = os.tmpname()
		pcall(os.remove, tmp)
		local fh = assert(io.open(tmp, "w"))
		fh:write("[layout]\nvirtual_keyboard = \"iso\"\n")
		fh:close()
		local Prefs = helpers.load_with_stubs("infra.preferences")
		local flat = Prefs.load(tmp)
		pcall(os.remove, tmp)
		helpers.assert_eq(flat.layout_virtual_keyboard, "iso")
	end)
end))
