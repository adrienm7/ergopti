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

-- Independent provider-template expectations retain the existing header decoration.
helpers.describe("shared checked and section-header templates", function()
	local function with_rows(platform, rows, callback)
		local renderer = assert(require("menu.renderer").new({
			platform = platform,
			manifest_path = function() return helpers.driver_root() .. "/../_shared/modules/menu/menu_manifest.json" end,
			json_decode = Json.decode,
			i18n = {
				get = function(key) return key end,
				section = function(key) return require("menu.labels").decorate_section(key) end,
			},
			logger = { warn = function() end, error = function() end },
		}))
		local declaration = renderer.get_array("metrics_menu")
		local previous = {}
		for index, row in ipairs(declaration) do previous[index] = row end
		for index = #declaration, 1, -1 do declaration[index] = nil end
		for index, row in ipairs(rows) do declaration[index] = row end
		local ok, err = pcall(callback, renderer)
		for index = #declaration, 1, -1 do declaration[index] = nil end
		for index, row in ipairs(previous) do declaration[index] = row end
		if not ok then error(err, 0) end
	end

	for _, platform in ipairs({ "hs", "linux", "ahk" }) do
		helpers.it("decorates inert id-less and named headers on " .. platform .. " (template-header)", function()
			local deliveries = 0
			local header = { type = "section_header", i18n = "menu.gestures.sensitivity_label" }
			with_rows(platform, { header, { type = "---" }, {
				type = "section_header", id = "named_header", i18n = "menu.metrics.privacy_header",
			}}, function(renderer)
				local rows = assert(renderer.template_rows("metrics_menu", {
					named_header = function() deliveries = deliveries + 1 end,
				}, { named_header = function() deliveries = deliveries + 1 end }, {
					named_header = { { label = "unowned child" } },
				}))
				helpers.assert_eq(rows, {
					{ label = "— menu.gestures.sensitivity_label —", disabled = true },
					{ separator = true },
					{ label = "— menu.metrics.privacy_header —", disabled = true },
				})
				local drawn = renderer.render_rows(rows, "template_header_test")
				helpers.assert_eq(drawn[1], { title = "— menu.gestures.sensitivity_label —", disabled = true })
				helpers.assert_eq(drawn[3], { title = "— menu.metrics.privacy_header —", disabled = true })
				helpers.assert_eq(deliveries, 0, "a header cannot invoke native callback or getter payloads")
				header.i18n = "menu.metrics.privacy_header"
				helpers.assert_eq(renderer.template_rows("metrics_menu")[1].label, "— menu.metrics.privacy_header —")
				header.platforms = { "not_this_platform" }
				header.unavailable = "hide"
				helpers.assert_eq(#renderer.template_rows("metrics_menu"), 2, "hidden header does not produce a stand-in")
			end)
		end)

		helpers.it("retains grey header stand-ins on " .. platform .. " (template-header)", function()
			local header = { type = "section_header", i18n = "menu.metrics.privacy_header",
				platforms = { platform }, unavailable = "grey", reason_key = "Not available： detail" }
			with_rows(platform, { header }, function(renderer)
				helpers.assert_eq(renderer.template_rows("metrics_menu"), {
					{ label = "— menu.metrics.privacy_header —", disabled = true },
				}, "applicable grey-policy header retains its ordinary decoration")
				header.platforms = { "other_platform" }
				local rows = assert(renderer.template_rows("metrics_menu"))
				helpers.assert_eq(rows, { { label = "menu.metrics.privacy_header — Not available", disabled = true } },
					"excluded platform uses the original reason-head stand-in")
				helpers.assert_eq(renderer.render_rows(rows, "grey_header_test"), renderer.build("metrics_menu", "", {}, {}, {}))
			end)
		end)

		helpers.it("keeps check delivery and current readiness on " .. platform .. " (template-check)", function()
			local row = { type = "check", id = "owned_check", i18n = "menu.gestures.mode_single",
				checked_when = { "on" }, disabled_when = { "ready" } }
			with_rows(platform, { row }, function(renderer)
				local deliveries, ready, on, receipt = 0, true, true, false
				local commands = { owned_check = function() deliveries = deliveries + 1; return receipt end }
				local getters = { on = function() return on end, ready = function() return ready end }
				local built = assert(renderer.template_rows("metrics_menu", commands, getters))[1]
				helpers.assert_eq(built.checked, true)
				helpers.assert_eq(built.action(), false, "native refusal propagates exactly")
				helpers.assert_eq(deliveries, 1)
				receipt, on = true, false
				helpers.assert_eq(renderer.template_rows("metrics_menu", commands, getters)[1].checked, false)
				helpers.assert_eq(built.action(), true, "literal native acceptance propagates exactly")
				helpers.assert_eq(deliveries, 2)
				ready = false
				helpers.assert_eq(built.action(), false, "held callback rechecks its current declared readiness")
				helpers.assert_eq(deliveries, 2)
				helpers.assert_eq(renderer.template_rows("metrics_menu", commands, getters)[1].disabled, true)
				helpers.assert_nil(renderer.template_rows("metrics_menu", {}, getters), "missing native owner refuses whole template")
			end)
		end)
	end

	helpers.it("retains all twelve existing id-less header declarations (template-header)", function()
		local file = assert(io.open(helpers.driver_root() .. "/../_shared/modules/menu/menu_manifest.json", "rb"))
		local manifest = assert(Json.decode(file:read("*a")))
		file:close()
		local count = 0
		for _, key in ipairs({ "shortcuts_menu", "metrics_menu", "layout_menu", "hotstrings_menu", "tap_holds_menu" }) do
			local definition = manifest[key]
			if type(definition) == "table" then
				for _, header in ipairs(definition) do
					if header.type == "section_header" then
						count = count + 1
						helpers.assert_nil(header.id, "existing headers retain their id-less contract")
						for _, platform in ipairs({ "hs", "linux", "ahk" }) do
							with_rows(platform, { header }, function(renderer)
								local template = assert(renderer.template_rows("metrics_menu"))
								local drawn = renderer.render_rows(template, "legacy_header_test")
								helpers.assert_eq(drawn, renderer.build("metrics_menu", "", {}, {}, {}), "existing root decoration and filtering are identical")
							end)
						end
					end
				end
			end
		end
		helpers.assert_eq(count, 12, "independent existing-header count must not be silently reduced")
	end)

	local invalid = {
		{ field = "id", value = "" }, { field = "id", value = 7 },
		{ field = "i18n", value = "" }, { field = "i18n", value = false },
		{ field = "unavailable", value = "" }, { field = "unavailable", value = "grey" },
		{ field = "reason_key", value = "" }, { field = "reason_key", value = false },
		{ field = "command", value = "unowned" }, { field = "caption_getter", value = "unowned" },
		{ field = "checked_when", value = {} }, { field = "disabled_when", value = {} },
		{ field = "disabled", value = false }, { field = "action", value = function() end },
		{ field = "items", value = {} }, { field = "foreign_field", value = "future" },
		{ field = "I18N", value = "wrong_case" },
	}
	for index, mutation in ipairs(invalid) do
		helpers.it("refuses header metadata " .. mutation.field .. " " .. index .. " (template-header)", function()
			for _, platform in ipairs({ "hs", "linux", "ahk" }) do
				local header = { type = "section_header", i18n = "menu.metrics.privacy_header" }
				header[mutation.field] = mutation.value
				with_rows(platform, { { type = "---" }, header }, function(renderer)
					helpers.assert_nil(renderer.template_rows("metrics_menu"), "invalid header refuses the complete partial template")
				end)
			end
		end)
	end
end)


-- Independent provider expectations exercise the shared template and actual
-- native row materialization, without replacing the established policy owner.
local function with_group_policy_rows(platform, row, callback)
	local diagnostics, calls = {}, 0
	local logger = helpers.make_logger_stub()
	logger.error = function(_, message, ...)
		local ok, formatted = pcall(string.format, message, ...)
		diagnostics[#diagnostics + 1] = ok and formatted or message
	end
	local strings = { ["probe.group"] = "Mode: %s", ["probe.reason"] = "Unavailable： native detail" }
	local i18n = { get = function(key) return strings[key] or key end,
		section = function(key) return strings[key] or key end }
	local renderer = assert(require("menu.renderer").new({ platform = platform,
		manifest_path = function() return helpers.driver_root() .. "/../_shared/modules/menu/menu_manifest.json" end,
		json_decode = function() return { group_policy_probe = { row } } end,
		i18n = i18n, logger = logger,
	}))
	local children = { { label = "Existing native child", action = function() calls = calls + 1; return false end } }
	local fixture = { renderer = renderer, diagnostics = diagnostics, children = children,
		calls = function() return calls end }
	function fixture.rows(getters)
		return renderer.template_rows("group_policy_probe", {}, getters or {}, { owned_group = children })
	end
	return callback(fixture)
end

helpers.describe("Template groups: existing readiness and reason policy (template-group-policy)", function()
	for _, platform in ipairs({ "hs", "linux", "ahk" }) do
		helpers.it("retains exact absent-policy group data and child refusal on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group" }, function(f)
				local rows = assert(f.rows())
				helpers.assert_eq(rows, { { label = "Mode: %s", items = f.children } })
				helpers.assert_true(rows[1].items == f.children, "native child payload identity is retained")
				local drawn = f.renderer.render_rows(rows, "actual_group_probe")
				helpers.assert_nil(drawn[1].disabled)
				helpers.assert_eq(drawn[1].menu[1].fn(), false)
				helpers.assert_eq(f.calls(), 1)
			end)
		end)
		helpers.it("delegates positive group readiness and literal caption to existing owners on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
				disabled_when = { "ready" }, caption_getter = "caption", disabled_reason_key = "probe.reason" }, function(f)
				local rows = assert(f.rows({ ready = function() return true end, caption = function() return "35% & $" end }))
				helpers.assert_eq(rows, { { label = "Mode: 35% & $", items = f.children } })
				local drawn = f.renderer.render_rows(rows, "actual_group_probe")
				helpers.assert_eq(drawn[1].title, "Mode: 35% & $")
				helpers.assert_nil(drawn[1].disabled)
				helpers.assert_eq(drawn[1].menu[1].fn(), false)
			end)
		end)
		for _, posture in ipairs({ { "false", false }, { "nil", nil } }) do
			helpers.it("delegates " .. posture[1] .. " group readiness and exact reason receipt on " .. platform, function()
				with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
					disabled_when = { "ready" }, caption_getter = "caption", disabled_reason_key = "probe.reason" }, function(f)
					local rows = assert(f.rows({ ready = function() return posture[2] end, caption = function() return "Incremental" end }))
					helpers.assert_eq(rows, { { label = "Mode: Incremental", items = f.children,
						disabled = true, disabled_reason_key = "probe.reason" } })
					helpers.assert_true(rows[1].items == f.children)
					local drawn = f.renderer.render_rows(rows, "actual_group_probe")
					helpers.assert_eq(drawn[1].title, "Mode: Incremental — Unavailable")
					helpers.assert_eq(drawn[1].disabled, true)
					helpers.assert_eq(f.calls(), 0, "building a disabled group cannot deliver native work")
					helpers.assert_nil(drawn[1].fn, "a group never gets a dummy actionable callback")
				end)
			end)
		end
		helpers.it("retains disabled group shape without inventing a reason on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
				disabled_when = { "ready" } }, function(f)
				local rows = assert(f.rows({ ready = function() return false end }))
				helpers.assert_eq(rows, { { label = "Mode: %s", items = f.children, disabled = true } })
				helpers.assert_eq(f.renderer.render_rows(rows, "actual_group_probe")[1].title, "Mode: %s")
			end)
		end)
		helpers.it("a missing group getter fails closed and names the missing owner on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
				disabled_when = { "ready" } }, function(f)
				helpers.assert_eq(f.rows()[1].disabled, true)
				helpers.assert_eq(#f.diagnostics, 1)
				helpers.assert_true(f.diagnostics[1]:find("ready", 1, true) ~= nil)
				helpers.assert_true(f.diagnostics[1]:find("owned_group", 1, true) ~= nil)
			end)
		end)
		helpers.it("a throwing group getter retains its actual error receipt on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
				disabled_when = { "ready" } }, function(f)
				local ok, err = pcall(f.rows, { ready = function() error("group-native-read-refused") end })
				helpers.assert_eq(ok, false)
				helpers.assert_true(tostring(err):find("group-native-read-refused", 1, true) ~= nil)
				helpers.assert_eq(f.calls(), 0)
			end)
		end)
		helpers.it("uses every declared group predicate and preserves truthy resolver semantics on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
				disabled_when = { "first", "second" } }, function(f)
				helpers.assert_nil(f.rows({ first = function() return "native-truthy" end, second = function() return 1 end })[1].disabled)
				helpers.assert_eq(f.rows({ first = function() return true end, second = function() return false end })[1].disabled, true)
			end)
		end)
		helpers.it("honors group platform hiding before invoking a native getter on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
				platforms = { "other_platform" }, unavailable = "hide", disabled_when = { "ready" } }, function(f)
				helpers.assert_eq(f.rows({ ready = function() error("hidden native getter executed") end }), {})
			end)
		end)
		helpers.it("refuses missing group child data on " .. platform, function()
			with_group_policy_rows(platform, { type = "group", id = "owned_group", i18n = "probe.group",
				disabled_when = { "ready" } }, function(f)
				helpers.assert_nil(f.renderer.template_rows("group_policy_probe", {}, { ready = function() return true end }, {}))
			end)
		end)
	end
end)
