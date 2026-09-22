--- tests/unit/ui/menu/test_menu_shortcuts_wrap_groups_populated.lua

--- ==============================================================================
--- MODULE: Regression — every wrap-symbol group opens a populated submenu
--- DESCRIPTION:
--- The wrap-symbols tree is provider DATA rendered by the shared renderer, which
--- reads a row's subtree from `items`. Each symbol group hung its rows on
--- `menu`, a field the renderer never reads on a provider row, so every group of
--- Shortcuts > wrap symbols opened empty. This renders the real Shortcuts row
--- through the tray's own call and opens every group.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("Shortcuts wrap-symbol groups are populated", function()
	helpers.it("every group under the wrap-symbols row has rows", function()
		local shortcuts = helpers.load_with_stubs("ui.menu.menu_shortcuts")
		local ManifestMenu = require("infra.manifest_menu")
		local item = shortcuts.build({
			state      = { shortcuts = true },
			save_prefs = function() return true end,
			updateMenu = function() end,
			shortcuts  = {
				list_shortcuts        = function() return {} end,
				is_enabled            = function() return true end,
				set_wrap_pairs_getter = function() end,
			},
		})
		helpers.assert_true(type(item) == "table", "menu_shortcuts.build must return a row")
		local row = ManifestMenu.render_rows({ item }, "top_level")[1]
		helpers.assert_true(type(row) == "table" and type(row.menu) == "table", "Shortcuts must render a submenu")

		local wrap
		for _, entry in ipairs(row.menu) do
			if entry.title == "menu.shortcuts.wrap_symbols" then wrap = entry end
		end
		helpers.assert_true(wrap ~= nil and type(wrap.menu) == "table", "the wrap-symbols row must render")

		local groups = 0
		for _, entry in ipairs(wrap.menu) do
			if entry.menu ~= nil then
				groups = groups + 1
				helpers.assert_true(type(entry.menu) == "table" and #entry.menu > 0,
					"wrap-symbol group '" .. tostring(entry.title) .. "' opened empty — its rows must be `items`")
			end
		end
		helpers.assert_true(groups > 0, "the manifest's wrap-symbol groups must render, or this test measures nothing")
	end)
end)
