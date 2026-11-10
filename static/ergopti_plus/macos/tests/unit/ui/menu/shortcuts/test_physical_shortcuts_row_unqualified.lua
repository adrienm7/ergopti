--- tests/unit/ui/menu/shortcuts/test_physical_shortcuts_row_unqualified.lua

--- ==============================================================================
--- MODULE: Physical Shortcuts Row While Delivery Is Unqualified
--- DESCRIPTION:
--- The Mac check « Physical shortcut delivery » (TODO, To confirm on the Mac)
--- asks that, while keyboard_shortcuts.physical_delivery_available is false,
--- the « Raccourcis physiques » row of the Shortcuts submenu is greyed with its
--- « Pas encore disponible » cause, not the generic « reopen it » refusal. This
--- renders the real submenu through the real manifest renderer and the real
--- delivery getter, as the Linux tray test does
--- (physical-delivery-unqualified).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Renders the Shortcuts submenu with the production manifest renderer.
--- @return table rows
local function render_shortcuts_submenu()
	local shortcuts = helpers.load_with_stubs("ui.menu.menu_shortcuts")
	local ManifestMenu = require("infra.manifest_menu")
	local item = shortcuts.build({
		state      = { shortcuts = true },
		save_prefs = function() return true end,
		updateMenu = function() end,
		applyTriggerChar = function(text) return text end,
		shortcuts  = {
			list_shortcuts        = function() return {} end,
			is_enabled            = function() return true end,
			set_wrap_pairs_getter = function() end,
		},
	})
	local row = ManifestMenu.render_rows({ item }, "top_level")[1]
	helpers.assert_true(type(row) == "table" and type(row.menu) == "table", "Shortcuts must render a submenu")
	return row.menu
end

helpers.describe("the physical shortcuts row while delivery is unqualified (physical-delivery-unqualified)", function()
	helpers.it("is greyed with the « not yet available » cause", function()
		local keyboard = helpers.load_with_stubs("modules.shortcuts.keyboard_shortcuts")
		helpers.assert_eq(keyboard.physical_delivery_available(), false, "the production getter")
		local label = "physical_shortcuts.window_title"
		local found = nil
		local function walk(rows)
			for _, row in ipairs(rows or {}) do
				if type(row.title) == "string" and row.title:sub(1, #label) == label then found = row end
				walk(row.menu)
			end
		end
		walk(render_shortcuts_submenu())
		helpers.assert_true(found ~= nil, "the editor row is drawn")
		helpers.assert_eq(found.disabled, true, "the row is greyed")
		helpers.assert_true(found.title:find("physical_shortcuts.delivery_unqualified", 1, true) ~= nil,
			"the row names the unqualified delivery: " .. found.title)
		helpers.assert_true(found.title:find("physical_shortcuts.window_unavailable", 1, true) == nil,
			"the generic refusal is not shown: " .. found.title)
	end)
end)
