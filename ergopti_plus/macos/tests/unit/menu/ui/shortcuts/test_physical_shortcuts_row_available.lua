--- tests/unit/menu/ui/shortcuts/test_physical_shortcuts_row_available.lua

--- ==============================================================================
--- MODULE: Physical Shortcuts Row Once Delivery Is Available
--- DESCRIPTION:
--- keyboard_shortcuts.physical_delivery_available answers true since the
--- maintainer's decision of 2026-11-11 (LIN-004), so the « Raccourcis
--- physiques » row of the Shortcuts submenu no longer names the « Pas encore
--- disponible » cause. The cause stays wired: a getter answering false greys
--- the row with it again, never with the generic « reopen it » refusal. This
--- renders the real submenu through the real manifest renderer
--- (physical-delivery-available).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Renders the Shortcuts submenu with the production manifest renderer.
--- @return table rows
local function render_shortcuts_submenu()
	local shortcuts = helpers.load_with_stubs("ui.menu.menu_shortcuts")
	local ManifestMenu = require("menu.engine.manifest_menu")
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

--- The rendered editor row, found by its label.
--- @return table|nil row
local function editor_row()
	local label = "physical_shortcuts.window_title"
	local found = nil
	local function walk(rows)
		for _, row in ipairs(rows or {}) do
			if type(row.title) == "string" and row.title:sub(1, #label) == label then found = row end
			walk(row.menu)
		end
	end
	walk(render_shortcuts_submenu())
	return found
end

helpers.describe("the physical shortcuts row once delivery is available (physical-delivery-available)", function()
	helpers.it("no longer names the « not yet available » cause", function()
		local keyboard = helpers.load_with_stubs("modules.shortcuts.keyboard_shortcuts")
		helpers.assert_eq(keyboard.physical_delivery_available(), true, "the production getter")
		local found = editor_row()
		helpers.assert_true(found ~= nil, "the editor row is drawn")
		helpers.assert_true(found.title:find("physical_shortcuts.delivery_unqualified", 1, true) == nil,
			"the row does not name an unqualified delivery: " .. found.title)
	end)

	helpers.it("a getter answering false greys the row with the « not yet available » cause", function()
		local keyboard = helpers.load_with_stubs("modules.shortcuts.keyboard_shortcuts")
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = keyboard
		local original = keyboard.physical_delivery_available
		keyboard.physical_delivery_available = function() return false end
		local ok, err = pcall(function()
			local found = editor_row()
			helpers.assert_true(found ~= nil, "the editor row is drawn")
			helpers.assert_eq(found.disabled, true, "the row is greyed")
			helpers.assert_true(found.title:find("physical_shortcuts.delivery_unqualified", 1, true) ~= nil,
				"the row names the unqualified delivery: " .. found.title)
			helpers.assert_true(found.title:find("physical_shortcuts.window_unavailable", 1, true) == nil,
				"the generic refusal is not shown: " .. found.title)
		end)
		keyboard.physical_delivery_available = original
		if not ok then error(err, 0) end
	end)
end)
