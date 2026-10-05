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

helpers.describe("the shared inert label template capability", function()
	helpers.it("keeps Linux statuses hidden and cannot bind native callback payloads (metrics-migration-label)", function()
		helpers.with_stub_scope({ "infra.manifest_menu", "infra.i18n", "infra.logger" }, function()
			local renderer = helpers.load_with_stubs("infra.manifest_menu")
			local file = assert(io.open(helpers.shared("tests/corpus/metrics/migration_status_menu.json"), "rb"))
			local corpus = assert(Json.decode(file:read("*a")))
			file:close()
			for _, status in ipairs(corpus.statuses) do
				local deliveries = 0
				local commands = { [status.row.id] = function() deliveries = deliveries + 1 end }
				local children = { [status.row.id] = { { label = "unowned child" } } }
				helpers.assert_eq(renderer.template_rows(status.section, commands, {}, children), {}, "Linux-only label stays hidden on Mac")
				local definition = renderer.get_array(status.section)[1]
				local previous = definition.platforms
				definition.platforms = { "hs" }
				local ok, err = pcall(function()
					local rows = renderer.template_rows(status.section, commands, {}, children)
					helpers.assert_eq(rows, { { label = status.row.i18n, disabled = true } }, "native payload cannot turn an inert label into a command")
					local drawn = renderer.render_rows(rows, "metrics_inert_label_test")
					helpers.assert_eq(drawn[1].title, status.row.i18n)
					helpers.assert_eq(drawn[1].disabled, true)
					helpers.assert_nil(drawn[1].fn)
					helpers.assert_nil(drawn[1].menu)
					helpers.assert_eq(deliveries, 0)
				end)
				definition.platforms = previous
				if not ok then error(err, 0) end
			end
		end)
	end)
end)
