--- tests/unit/ui/menu/test_menu_metrics_reaches_tray.lua

--- ==============================================================================
--- MODULE: Regression — the Metrics submenu reaches the tray populated
--- DESCRIPTION:
--- The tray root is rendered as provider DATA, where a subtree hangs on `items`
--- (rows to materialise) or `submenu` (a tree already materialised). The
--- Metrics row hung its already-rendered tree on `menu`, a field the renderer
--- never reads on a provider row, so the Metrics entry opened empty on the real
--- menu bar. This renders the real row through the tray's own call.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("Metrics submenu reaches the tray populated", function()
	helpers.it("the rendered tray row carries the manifest's metrics rows", function()
		local metrics = helpers.load_with_stubs("ui.menu.menu_metrics")
		local ManifestMenu = require("infra.manifest_menu")
		local item = metrics.build({
			state      = {},
			save_prefs = function() return true end,
			updateMenu = function() end,
		})
		helpers.assert_true(type(item) == "table", "menu_metrics.build must return a row")
		helpers.assert_nil(item.menu,
			"a provider row never carries `menu`: the renderer does not read it")

		local row = ManifestMenu.render_rows({ item }, "top_level")[1]
		helpers.assert_true(type(row) == "table" and type(row.menu) == "table" and #row.menu > 0,
			"the Metrics submenu reached the tray empty")
		local found = false
		for _, entry in ipairs(row.menu) do
			if entry.title == "menu.metrics.show_typing" then found = true end
		end
		helpers.assert_true(found, "the manifest's show_typing row must be in the rendered Metrics submenu")
	end)
end)
