--- tests/unit/ui/menu/menu_llm/test_models_browser_shared_command.lua

--- ==============================================================================
--- MODULE: Shared Models Browser Command Tests
--- DESCRIPTION:
--- Exercises the real native-bound command row, model provider and deferred
--- browser admission without changing model settings or starting an AI backend.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Exercises one real provider with observable native presentation ports.
--- @param callback function Receives the provider row and held native ports.
local function with_browser(callback)
	helpers.with_stub_scope({
		"ui.menu.menu_llm.models_selector", "ui.model_browser", "ui.ui_builder", "infra.i18n",
		"infra.logger", "infra.dialog_util", "infra.deferred_work", "infra.paths",
		"infra.manifest_menu", "adapters.json_codec", "hs", "tests.stubs.hs",
	}, function()
		local controls = { paused = false, shows = 0, deferred = {} }
		local native = require("tests.stubs.hs")
		native.__reset()
		_G.hs = native
		package.loaded["hs"] = native
		local i18n = {
			get = function(key) return key end,
			section = function(key) return key end,
			decorate_section = function(value) return value end,
		}
		package.loaded["infra.i18n"] = i18n
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.dialog_util"] = { alert = function() return true end }
		package.loaded["infra.paths"] = { shared = helpers.shared }
		package.loaded["infra.deferred_work"] = {
			after = function(_, work)
				controls.deferred[#controls.deferred + 1] = work
				return true
			end,
		}
		package.loaded["ui.model_browser"] = {
			open = function()
				controls.shows = controls.shows + 1
				return true
			end,
		}
		local Selector = require("ui.menu.menu_llm.models_selector")
		local Renderer = require("infra.manifest_menu")
		local ctx = {
			state = { llm_backend = "ollama", llm_model = "", llm_user_models = {}, llm_enabled = false },
			models_mgr = {
				get_installed_models = function() return {} end,
				get_presets = function() return {} end,
				get_model_info = function() return nil end,
			},
			is_paused = function() return controls.paused end,
			paused = false,
			switch_model = function() controls.switches = (controls.switches or 0) + 1; return false end,
			disable_model = function() return false end,
			save_prefs = function() controls.writes = (controls.writes or 0) + 1; return false end,
			update_menu = function() return false end,
			DEFAULT_STATE = { llm_model_mlx = "", llm_model_ollama = "" },
		}
		callback({ controls = controls, ctx = ctx, renderer = Renderer, selector = Selector, native = native })
	end)
end

--- Finds an independently expected browser label in actual provider data.
--- @param rows table Provider rows.
--- @param label string Expected translated label.
--- @return table|nil row
local function find_row(rows, label)
	for _, row in ipairs(rows) do
		if row.label == label then return row end
	end
	return nil
end

helpers.describe("shared models browser command", function()
	helpers.it("uses the canonical label while AI is off without publishing settings", function()
		with_browser(function(fixture)
			local declaration = fixture.renderer.get_array("llm_model_commands")
			helpers.assert_eq(declaration[1].id, "llm_browse_models")
			declaration[1].i18n = "common.restore_recommended"
			local row = find_row(fixture.selector.build(fixture.ctx), "common.restore_recommended")
			helpers.assert_type(row, "table")
			helpers.assert_type(row.action, "function")
			helpers.assert_true(row.disabled ~= true)
			row.action()
			helpers.assert_eq(#fixture.controls.deferred, 1)
			fixture.controls.deferred[1]()
			helpers.assert_eq(fixture.controls.shows, 1)
			helpers.assert_eq(fixture.controls.writes, nil)
			helpers.assert_eq(fixture.controls.switches, nil)
		end)
	end)

	helpers.it("refuses a retained callback after the native pause owner changes", function()
		with_browser(function(fixture)
			local row = find_row(fixture.selector.build(fixture.ctx), "menu.llm.browse_models_entry")
			helpers.assert_type(row.action, "function")
			fixture.controls.paused = true
			helpers.assert_eq(row.action(), false)
			helpers.assert_eq(#fixture.controls.deferred, 0)
			helpers.assert_eq(fixture.controls.shows, 0)
		end)
	end)

	helpers.it("rechecks the actual pause owner after deferred scheduling acknowledgement", function()
		with_browser(function(fixture)
			local row = find_row(fixture.selector.build(fixture.ctx), "menu.llm.browse_models_entry")
			row.action()
			helpers.assert_eq(#fixture.controls.deferred, 1)
			fixture.controls.paused = true
			helpers.assert_eq(fixture.controls.deferred[1](), false)
			helpers.assert_eq(fixture.controls.shows, 0)
		end)
	end)

	helpers.it("keeps missing or invalid native evidence disabled", function()
		with_browser(function(fixture)
			for _, reader in ipairs({ false, function() return nil end, function() return "false" end,
				function() error("native pause read refused") end }) do
				fixture.ctx.is_paused = reader
				local row = find_row(fixture.selector.build(fixture.ctx), "menu.llm.browse_models_entry")
				helpers.assert_eq(row.disabled, true)
				helpers.assert_eq(row.action(), false)
			end
			fixture.ctx.is_paused = function() return false end
			fixture.native.webview = nil
			fixture.native.chooser = nil
			local row = find_row(fixture.selector.build(fixture.ctx), "menu.llm.browse_models_entry")
			helpers.assert_eq(row.disabled, true)
			helpers.assert_eq(row.action(), false)
			helpers.assert_eq(#fixture.controls.deferred, 0)
		end)
	end)
end)

helpers.describe("model browser factory capability", function()
	helpers.it("uses the actual factory capability without allocating a window", function()
		with_browser(function(fixture)
			local calls = 0
			fixture.native.chooser = nil
			fixture.native.webview.new = function() calls = calls + 1; return nil end
			local row = find_row(fixture.selector.build(fixture.ctx), "menu.llm.browse_models_entry")
			helpers.assert_true(row.disabled ~= true)
			helpers.assert_eq(calls, 0)
			fixture.native.webview.new = false
			helpers.assert_eq(row.action(), false)
			helpers.assert_eq(#fixture.controls.deferred, 0)
			helpers.assert_eq(calls, 0)
		end)
	end)

	helpers.it("refuses an unavailable or non-Boolean factory acknowledgement", function()
		with_browser(function(fixture)
			fixture.native.chooser = nil
			for _, capability in ipairs({ false, function() return "true" end,
				function() return nil end, function() error("factory unavailable") end }) do
				package.loaded["ui.ui_builder"] = { can_create_webview = capability }
				local row = find_row(fixture.selector.build(fixture.ctx), "menu.llm.browse_models_entry")
				helpers.assert_eq(row.disabled, true)
				helpers.assert_eq(row.action(), false)
			end
			helpers.assert_eq(#fixture.controls.deferred, 0)
			helpers.assert_eq(fixture.controls.shows, 0)
		end)
	end)
end)


-- Handwritten physical tail: boundary, real shared browser, original native Add.
local function boundary_owner(renderer, id)
	for _, row in ipairs(renderer.get_array("llm_menu")) do
		if row.id == id then return row end
	end
	error("actual model provider declaration is absent")
end

helpers.describe("declared model picker tail boundary", function()
	helpers.it("keeps the physical browser and Add order in both captured pause states", function()
		for _, paused in ipairs({false, true}) do
			with_browser(function(f)
				f.ctx.paused, f.controls.paused = paused, paused
				local owner = boundary_owner(f.renderer, "llm_model")
				helpers.assert_eq(owner.status_rows.model_picker_tail, {{type = "---"}})
				local rows = f.selector.build(f.ctx)
				local at
				for i, row in ipairs(rows) do if row.label == "menu.llm.browse_models_entry" then at = i end end
				helpers.assert_type(at, "number")
				helpers.assert_eq(rows[at - 1].separator, true)
				helpers.assert_eq(rows[at + 1].label, "menu.llm.add_model_entry")
				helpers.assert_eq(rows[at + 1].disabled, paused or nil)
				helpers.assert_type(rows[at + 1].action, "function")
				helpers.assert_eq(#rows, 5, "No model, original head boundary, declared tail boundary, browser, Add")
				local rendered = f.renderer.render_rows(rows, "llm_model")
				local native_at
				for i, row in ipairs(rendered) do if row.title == "menu.llm.browse_models_entry" then native_at = i end end
				helpers.assert_eq(rendered[native_at - 1].title, "-")
				helpers.assert_eq(rendered[native_at + 1].title, "menu.llm.add_model_entry")

				helpers.assert_eq(#f.controls.deferred, 0)
				helpers.assert_eq(f.controls.shows, 0)
				helpers.assert_eq(f.controls.writes, nil)
			end)
		end
	end)

	helpers.it("consumes the actual inert declaration before the unchanged browser owner", function()
		with_browser(function(f)
			boundary_owner(f.renderer, "llm_model").status_rows.model_picker_tail = {{type="label", i18n="common.restore_recommended"}}
			local rows = f.selector.build(f.ctx)
			local at
			for i, row in ipairs(rows) do if row.label == "menu.llm.browse_models_entry" then at = i end end
			helpers.assert_eq(rows[at - 1].label, "common.restore_recommended")
			helpers.assert_eq(rows[at - 1].disabled, true)
			helpers.assert_eq(rows[at - 1].action, nil)
			helpers.assert_eq(rows[at + 1].label, "menu.llm.add_model_entry")
			rows[at].action()
			helpers.assert_eq(#f.controls.deferred, 1)
			f.controls.deferred[1]()
			helpers.assert_eq(f.controls.shows, 1)
		end)
	end)

	for _, mode in ipairs({"missing", "wrong_owner", "clicked", "extra_callback"}) do
		helpers.it("refuses " .. mode .. " boundary data while keeping both real neighboring owners", function()
			with_browser(function(f)
				local owner = boundary_owner(f.renderer, "llm_model")
				local effects = 0
				if mode == "missing" then owner.status_rows.model_picker_tail = nil
				elseif mode == "wrong_owner" then owner.id = "foreign_model"
				elseif mode == "clicked" then owner.status_rows.model_picker_tail = {{type="command", id="foreign", action=function() effects=effects+1 end}}
				else owner.status_rows.model_picker_tail = {{type="---", action=function() effects=effects+1 end}} end
				local rows = f.selector.build(f.ctx)
				local at
				for i, row in ipairs(rows) do if row.label == "menu.llm.browse_models_entry" then at = i end end
				helpers.assert_type(at, "number")
				helpers.assert_eq(#rows, 4, "only the original head boundary survives; refused tail cannot fabricate another")
				helpers.assert_eq(rows[at + 1].label, "menu.llm.add_model_entry")
				helpers.assert_type(rows[at + 1].action, "function")
				helpers.assert_eq(effects, 0)
				helpers.assert_eq(#f.controls.deferred, 0)
				helpers.assert_eq(f.controls.writes, nil)
			end)
		end)
	end
end)
