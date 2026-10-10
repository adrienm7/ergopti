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
		local root, selected = native.get_root(), {}
		for _, row in ipairs(native.get_array("top_level")) do
			if row.id == "llm" then selected[#selected + 1] = row end
		end
		root.top_level = selected
		local facade = {}; for key, value in pairs(native) do facade[key] = value end
		facade.build = function(_, _, _, _, _, providers)
			return native.render_rows(providers.llm_models(), "llm_models")
		end
		package.loaded["infra.manifest_menu"] = facade
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


local function picker_boundary_owner(renderer)
	for _, row in ipairs(renderer.get_array("llm_menu")) do
		if row.id == "llm_models" then return row end
	end
	error("actual Linux model provider is absent")
end

helpers.describe("declared model picker tail boundary", function()
	helpers.it("retains the native empty-list condition and installed-model/browser order", function()
		for _, models in ipairs({{}, {"installed-one", "installed-two"}}) do
			with_browser(function(f)
				f.ctx.llm.get_models = function() return models end
				helpers.assert_eq(picker_boundary_owner(f.renderer).status_rows.model_picker_tail, {{type="---"}})
				local browser = find_row(f.builder.build(f.ctx), "menu.llm.browse_models_entry")
				helpers.assert_type(browser.fn, "function")
				-- Capture the actual canonical rows before their real native lowering.
				local original = f.renderer.render_rows
				local actual
				f.renderer.render_rows = function(rows, id) if id == "llm_models" then actual=rows end;return original(rows,id) end
				f.builder.build(f.ctx)
				helpers.assert_eq(#actual, #models > 0 and #models+2 or 1)
				for i, name in ipairs(models) do helpers.assert_eq(actual[i].label,name) end
				if #models > 0 then helpers.assert_eq(actual[#models+1].separator,true) end
				helpers.assert_eq(actual[#actual].label,"menu.llm.browse_models_entry")
				helpers.assert_eq(f.controls.shows,0)
			end)
		end
	end)

	helpers.it("consumes the shared inert presentation and keeps exact native browser acknowledgement", function()
		with_browser(function(f)
			f.ctx.llm.get_models=function()return{"native-model"}end
			picker_boundary_owner(f.renderer).status_rows.model_picker_tail={{type="label",i18n="common.restore_recommended"}}
			local rows=f.builder.build(f.ctx)
			local presentation=find_row(rows,"common.restore_recommended")
			helpers.assert_type(presentation,"table")
			helpers.assert_eq(presentation.disabled,true)
			helpers.assert_eq(presentation.fn,nil)
			local browser=find_row(rows,"menu.llm.browse_models_entry")
			helpers.assert_eq(browser.fn(),true)
			helpers.assert_eq(f.controls.kind,"model_browser")
			helpers.assert_eq(f.controls.shows,1)
		end)
	end)

	for _, mode in ipairs({"missing", "wrong_owner", "clicked", "extra_callback"}) do
		helpers.it("refuses " .. mode .. " boundary while retaining native model and browser data",function()
			with_browser(function(f)
				f.ctx.llm.get_models=function()return{"native-model"}end
				local owner=picker_boundary_owner(f.renderer)
				local effects=0
				if mode=="missing"then owner.status_rows.model_picker_tail=nil
				elseif mode=="wrong_owner"then owner.id="foreign_models"
				elseif mode=="clicked"then owner.status_rows.model_picker_tail={{type="command",id="foreign",action=function()effects=effects+1 end}}
				else owner.status_rows.model_picker_tail={{type="---",action=function()effects=effects+1 end}}end
				local actual
				local original=f.renderer.render_rows
				f.renderer.render_rows=function(rows,id)if id=="llm_models"then actual=rows end;return original(rows,id)end
				local rows=f.builder.build(f.ctx)
				helpers.assert_eq(#actual,2)
				helpers.assert_eq(actual[1].label,"native-model")
				helpers.assert_eq(actual[2].label,"menu.llm.browse_models_entry")
				helpers.assert_type(find_row(rows,"native-model").fn,"function")
				helpers.assert_type(find_row(rows,"menu.llm.browse_models_entry").fn,"function")
				helpers.assert_eq(effects,0)
				helpers.assert_eq(f.controls.shows,0)
			end)
		end)
	end
end)
