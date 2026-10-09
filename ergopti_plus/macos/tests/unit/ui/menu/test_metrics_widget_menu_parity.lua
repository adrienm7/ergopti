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

-- Independent provider-template expectations retain the existing header decoration.
helpers.describe("shared checked and section-header templates", function()
	local function with_rows(platform, rows, callback)
		local renderer = assert(require("menu.renderer").new({
			platform = platform,
			manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
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
		local file = assert(io.open(helpers.shared("modules/menu/menu_manifest.json"), "rb"))
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
