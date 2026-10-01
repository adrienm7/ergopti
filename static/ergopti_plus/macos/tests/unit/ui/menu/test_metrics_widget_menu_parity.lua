--- tests/unit/ui/menu/test_metrics_widget_menu_parity.lua

--- ==============================================================================
--- MODULE: Native Metrics Widget Menu Parity (macOS)
--- DESCRIPTION:
--- Renders the actual Metrics submenu for the state vectors shared with Windows
--- and Linux. Native effects stay outside this rendering-only fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local handle = assert(io.open(helpers.shared("tests/corpus/metrics/widget_menu_vectors.json"), "rb"))
local fixture = assert(Json.decode(handle:read("*a")))
handle:close()
handle = assert(io.open(helpers.shared("modules/menu/menu_manifest.json"), "rb"))
local declared = assert(Json.decode(handle:read("*a"))).metrics_menu
handle:close()

require("test.metrics_widget_menu_contract").register(helpers, {
	fixture = fixture,
	declared = declared,
	translate = function(key) return require("infra.i18n").get(key) end,
	build = function(values)
		local menu = helpers.load_with_stubs("ui.menu.menu_metrics")
		return menu.build({
			state = {
				keylogger_enabled = values.keylogger_enabled,
				keylogger_float_wpm = values.wpm_widget_visible,
				keylogger_float_colors = values.metrics_widget_colors,
				keylogger_float_graph = values.metrics_widget_graph,
			},
			save_prefs = function() return true end,
			updateMenu = function() return true end,
		}).submenu
	end,
})
