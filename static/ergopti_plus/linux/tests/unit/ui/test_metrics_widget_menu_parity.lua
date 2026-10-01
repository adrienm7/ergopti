--- tests/unit/ui/test_metrics_widget_menu_parity.lua

--- ==============================================================================
--- MODULE: Native Metrics Widget Menu Parity (Linux)
--- DESCRIPTION:
--- Renders the actual tray against the same Metrics state vectors as macOS and
--- Windows, replacing only the native widget boundary with recording state.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local handle = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/metrics/widget_menu_vectors.json", "rb"))
local fixture = assert(Json.decode(handle:read("*a")))
handle:close()
handle = assert(io.open(helpers.driver_root() .. "/../_shared/modules/menu/menu_manifest.json", "rb"))
local declared = assert(Json.decode(handle:read("*a"))).metrics_menu
handle:close()

require("test.metrics_widget_menu_contract").register(helpers, {
	fixture = fixture,
	declared = declared,
	translate = function(key) return require("infra.i18n").get(key) end,
	build = function(values)
		local previous = package.loaded["ui.wpm.widget"]
		package.loaded["ui.wpm.widget"] = {
			is_running = function() return values.wpm_widget_visible end,
			uses_source_colors = function() return values.metrics_widget_colors end,
			uses_graph = function() return values.metrics_widget_graph end,
		}
		local ok, result = xpcall(function()
			local rows = helpers.load_module("ui.menu.menu_builder").build({
				keylogger = {
					is_enabled = function() return values.keylogger_enabled end,
					get_privacy_state = function() return {} end,
				},
			})
			local label = require("infra.i18n").get("menu.metrics.title")
			for _, row in ipairs(rows) do
				if row.title == label then return row.menu end
			end
			error("Metrics must reach the actual tray")
		end, debug.traceback)
		package.loaded["ui.wpm.widget"] = previous
		if not ok then error(result, 0) end
		return result
	end,
})

helpers.describe("Metrics widget commands", function()
	for _, spec in ipairs(fixture.rows) do
		for _, accepted in ipairs({ false, true }) do
			helpers.it("metrics-widget-command " .. spec.id .. " " .. tostring(accepted), function()
				local calls = { start = 0, stop = 0, colors = 0, graph = 0, rebuild = 0 }
				local previous = package.loaded["ui.wpm.widget"]
				local widget = {
					is_running = function() return true end,
					uses_source_colors = function() return false end,
					uses_graph = function() return false end,
					start = function() calls.start = calls.start + 1; return accepted end,
					stop = function() calls.stop = calls.stop + 1; return accepted end,
					set_use_source_colors = function(value)
						helpers.assert_eq(value, true)
						calls.colors = calls.colors + 1
						return accepted
					end,
					set_graph = function(value)
						helpers.assert_eq(value, true)
						calls.graph = calls.graph + 1
						return accepted
					end,
				}
				package.loaded["ui.wpm.widget"] = widget
				local ok, err = xpcall(function()
					local rows = helpers.load_module("ui.menu.menu_builder").build({
						keylogger = { is_enabled = function() return true end,
							get_privacy_state = function() return {} end },
						on_menu_changed = function() calls.rebuild = calls.rebuild + 1 end,
					})
					local metrics
					for _, row in ipairs(rows) do
						if row.title == require("infra.i18n").get("menu.metrics.title") then metrics = row.menu end
					end
					local start
					for index, row in ipairs(metrics) do
						if row.title == require("infra.i18n").get(fixture.rows[1].i18n) then start = index end
					end
					local offset = spec.id == "wpm_widget" and 0 or spec.id == "widget_colors" and 1 or 2
					helpers.assert_eq(metrics[start + offset].fn(), accepted)
					helpers.assert_eq(calls.start, 0, "a refused stop must never fall through to start")
					helpers.assert_eq(calls.stop, spec.id == "wpm_widget" and 1 or 0)
					helpers.assert_eq(calls.colors, spec.id == "widget_colors" and 1 or 0)
					helpers.assert_eq(calls.graph, spec.id == "include_realtime" and 1 or 0)
					helpers.assert_eq(calls.rebuild, accepted and 1 or 0, "only an acknowledged native commit rebuilds the menu")
				end, debug.traceback)
				package.loaded["ui.wpm.widget"] = previous
				if not ok then error(err, 0) end
			end)
		end
	end
end)
