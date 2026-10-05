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

-- Fixed status expectations are independent of the shared label implementation.
helpers.describe("declared inert Metrics migration statuses", function()
	local function read(relative)
		local file = assert(io.open(helpers.driver_root() .. "/../_shared/" .. relative, "rb"))
		local text = file:read("*a")
		file:close()
		return assert(Json.decode(text))
	end
	local corpus = read("tests/corpus/metrics/migration_status_menu.json")
	local function actual_status(state, receipt)
		local calls = { progress = 0, cancel = 0 }
		local logger = { is_enabled = function() return true end,
			get_privacy_state = function() return {} end }
		if state ~= "unavailable" then
			logger.get_migration_progress = function()
				calls.progress = calls.progress + 1
				return { running = state == "running", scanned = corpus.running.scanned, total = corpus.running.total }
			end
		end
		logger.cancel_migration = function() calls.cancel = calls.cancel + 1; return receipt end
		local rows = helpers.load_module("ui.menu.menu_builder").build({ keylogger = logger })
		local i18n = require("infra.i18n")
		for _, row in ipairs(rows) do
			if row.title == i18n.get("menu.metrics.title") then return row.menu[#row.menu], calls end
		end
		error("Actual Metrics submenu must contain its status")
	end

	for _, status in ipairs(corpus.statuses) do
		helpers.it("keeps actual " .. status.state .. " status inert (metrics-migration-label)", function()
			local row, calls = actual_status(status.state)
			helpers.assert_eq(row.title, require("infra.i18n").get(status.row.i18n))
			helpers.assert_eq(row.disabled, true)
			helpers.assert_nil(row.fn, "an inert status has no dummy callback")
			helpers.assert_nil(row.menu, "an inert status has no child picker")
			helpers.assert_nil(row.checked)
			helpers.assert_eq(calls.progress, status.state == "idle" and 1 or 0)
			helpers.assert_eq(calls.cancel, 0)
		end)

		helpers.it("reads actual " .. status.state .. " shared caption mutations (metrics-migration-label)", function()
			local definition = require("infra.manifest_menu").get_array(status.section)[1]
			local previous = definition.i18n
			definition.i18n = "menu.metrics.unavailable"
			local ok, err = pcall(function()
				local row = actual_status(status.state)
				helpers.assert_eq(row.title, require("infra.i18n").get("menu.metrics.unavailable"))
				helpers.assert_eq(row.disabled, true)
				helpers.assert_nil(row.fn)
			end)
			definition.i18n = previous
			if not ok then error(err, 0) end
		end)
	end

	for _, status in ipairs(corpus.statuses) do
		helpers.it("honors actual " .. status.state .. " platform hiding (metrics-migration-label)", function()
			local definition = require("infra.manifest_menu").get_array(status.section)[1]
			local previous = definition.platforms
			definition.platforms = { "ahk" }
			local ok, err = pcall(function()
				local row, calls = actual_status(status.state)
				helpers.assert_true(row.title ~= require("infra.i18n").get(status.row.i18n), "the hidden status cannot reach the actual tray")
				helpers.assert_eq(calls.progress, status.state == "idle" and 1 or 0, "native state selection is unchanged")
				helpers.assert_eq(calls.cancel, 0)
			end)
			definition.platforms = previous
			if not ok then error(err, 0) end
		end)
	end

	for _, receipt in ipairs({ { name = "false", value = false }, { name = "nil" }, { name = "truthy", value = "accepted" } }) do
		helpers.it("preserves running progress and native " .. receipt.name .. " cancellation policy (metrics-migration-label)", function()
			local row, calls = actual_status("running", receipt.value)
			helpers.assert_eq(row.title, string.format(require("infra.i18n").get("menu.metrics.migration_progress"),
				corpus.running.scanned, corpus.running.total))
			helpers.assert_true(row.disabled ~= true)
			helpers.assert_type(row.fn, "function")
			helpers.assert_eq(calls.progress, 1)
			helpers.assert_nil(row.fn(), "the original native cancellation closure supplies no receipt")
			helpers.assert_eq(calls.cancel, 1)
		end)
	end

	helpers.it("replays inert labels and platform hiding in all 21 locales (metrics-migration-label)", function()
		local locales = read("data/locale_order.json").order
		helpers.assert_eq(#locales, 21)
		for _, code in ipairs(locales) do
			local strings = read("data/locales/" .. code .. ".json")
			for _, platform in ipairs({ "ahk", "hs", "linux" }) do
				local renderer = assert(require("menu.renderer").new({ platform = platform,
					manifest_path = function() return helpers.driver_root() .. "/../_shared/modules/menu/menu_manifest.json" end,
					json_decode = Json.decode,
					i18n = { get = function(key) return assert(strings[key]) end, section = function(key) return assert(strings[key]) end },
					logger = { error = function() end, warn = function() end, debug = function() end },
				}))
				for _, status in ipairs(corpus.statuses) do
					local deliveries = 0
					local rows = renderer.template_rows(status.section, {
						[status.row.id] = function() deliveries = deliveries + 1 end,
					}, {}, { [status.row.id] = { { label = "unowned child" } } })
					helpers.assert_eq(#rows, platform == "linux" and 1 or 0, code .. ": " .. platform)
					if platform == "linux" then
						helpers.assert_eq(rows[1], { label = strings[status.row.i18n], disabled = true }, "no command or child injection")
						if status.locales[code] then helpers.assert_eq(rows[1].label, status.locales[code]) end
					end
					helpers.assert_eq(deliveries, 0)
				end
			end
		end
	end)

	for _, change in ipairs({ { name = "missing identity", field = "id" },
		{ name = "empty caption", field = "i18n", value = "" },
		{ name = "command metadata", field = "command", value = "unowned_command" },
		{ name = "caption getter", field = "caption_getter", value = "unowned_getter" },
		{ name = "checked predicate", field = "checked_when", value = {} },
		{ name = "private disabled flag", field = "disabled", value = false },
		{ name = "foreign field", field = "foreign_field", value = "future" },
		{ name = "uppercase caption field", field = "I18N", value = "wrong_case" },
		{ name = "empty unavailable policy", field = "unavailable", value = "" } }) do
		helpers.it("refuses inert label " .. change.name .. " (metrics-migration-label)", function()
			local renderer = require("infra.manifest_menu")
			local definition = renderer.get_array(corpus.statuses[1].section)[1]
			local previous = definition[change.field]
			definition[change.field] = change.value
			local ok, err = pcall(function()
				helpers.assert_nil(renderer.template_rows(corpus.statuses[1].section), "invalid label metadata cannot publish a partial status")
			end)
			definition[change.field] = previous
			if not ok then error(err, 0) end
		end)
	end
end)
