--- tests/unit/ui/test_models_browser_shared_command.lua

--- ==============================================================================
--- MODULE: Shared Models Browser Command Tests
--- DESCRIPTION:
--- Drives the actual tray model provider and native-bound shared command row.
--- Browser availability and the native acknowledgement cannot become a model
--- selection, settings write or AI bootstrap request.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Exercises the browser provider with its unrelated tray surfaces isolated.
--- @param callback function Receives native rows and observable browser ports.
local function with_browser(callback)
	local names = { "ui.menu.menu_builder", "ui.menu.llm_backend_rows", "infra.manifest_menu", "infra.paths", "infra.i18n",
		"window_titles", "action_parameter_label", "hotstrings.extensions", "hotstrings.languages",
		"_generated.locale_table", "keymap.magic_key_source", "modules.hotstrings.magic_key",
		"modules.hotstrings.preview_settings", "modules.hotstrings.repeat_key", "ui.modal",
		"ui.text_prompt", "llm.trigger_policy", "infra.version", "infra.installation",
		"updater.version_label", "updater.schedule" }
	local saved = {}
	for _, name in ipairs(names) do
		saved[name] = package.loaded[name]
		if name == "ui.menu.llm_backend_rows" then package.loaded[name] = nil
		else package.loaded[name] = {} end
	end
	local ok, err = xpcall(function()
		local controls = { shows = 0, result = true }
		local source = debug.getinfo(1, "S").source:gsub("^@", "")
		local driver = assert(source:match("^(.*)/tests/unit/ui/"))
		package.loaded["infra.paths"] = { shared = function(relative)
			return driver .. "/../_shared/" .. relative
		end }
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			section = function(key) return key end,
		}
		package.loaded["infra.manifest_menu"] = nil
		local native = require("infra.manifest_menu")
		package.loaded["infra.manifest_menu"] = setmetatable({
			get_array = function(key)
				if key == "top_level" then return { { id = "llm" } } end
				return native.get_array(key)
			end,
			build = function(_, _, _, _, _, providers)
				return native.render_rows(providers.llm_models(), "llm_models")
			end,
		}, { __index = native })
		package.loaded["ui.menu.menu_builder"] = nil
		local Builder = require("ui.menu.menu_builder")
		local ctx = {
			llm = {
				is_enabled = function() return false end,
				get_models = function() return {} end,
			},
			webview = { show = function(kind)
				controls.kind = kind
				controls.shows = controls.shows + 1
				return controls.result
			end },
			on_quit = function() end,
		}
		callback({ ctx = ctx, controls = controls, builder = Builder, renderer = native })
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

--- Finds the actual browser command in native-rendered row data.
--- @param rows table Native rows.
--- @param label string Expected translated label.
--- @return table|nil row
local function find_row(rows, label)
	for _, row in ipairs(rows or {}) do
		if row.title == label then return row end
		local nested = find_row(row.menu, label)
		if nested then return nested end
	end
	return nil
end

helpers.describe("shared models browser command", function()
	helpers.it("uses the canonical label with AI off and requires exact browser acknowledgement", function()
		with_browser(function(fixture)
			local declaration = fixture.renderer.get_array("llm_model_commands")
			helpers.assert_eq(declaration[1].id, "llm_browse_models")
			declaration[1].i18n = "common.restore_recommended"
			local row = find_row(fixture.builder.build(fixture.ctx), "common.restore_recommended")
			helpers.assert_type(row, "table")
			helpers.assert_type(row.fn, "function")
			helpers.assert_true(row.disabled ~= true)
			helpers.assert_eq(row.fn(), true)
			helpers.assert_eq(fixture.controls.kind, "model_browser")
			for _, result in ipairs({ false, 1, "true" }) do
				fixture.controls.result = result
				helpers.assert_eq(row.fn(), false)
			end
			fixture.controls.result = nil
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.controls.shows, 5)
		end)
	end)

	helpers.it("disables a missing browser port and refuses a held callback after capability loss", function()
		with_browser(function(fixture)
			local row = find_row(fixture.builder.build(fixture.ctx), "menu.llm.browse_models_entry")
			helpers.assert_type(row.fn, "function")
			fixture.ctx.webview = nil
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.controls.shows, 0)
			row = find_row(fixture.builder.build(fixture.ctx), "menu.llm.browse_models_entry")
			helpers.assert_eq(row.disabled, true)
		end)
	end)
end)
