--- tests/unit/ui/menu/menu_llm/test_user_model_shared_child.lua

--- ==============================================================================
--- MODULE: Shared User-Added Model Child Controls
--- DESCRIPTION:
--- Exercises the actual model provider and native-bound declaration against a
--- handwritten two-row contract. Native model callbacks retain their owners.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("adapters.json_codec")

local function corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menu/user-model-child.json"), "rb"))
	local source = file:read("*a")
	file:close()
	return assert(Json.decode(source))
end

local function with_fixture(callback, initial)
	helpers.with_stub_scope({
		"ui.menu.menu_llm.models_selector", "infra.manifest_menu", "infra.i18n", "infra.paths",
		"infra.logger", "infra.dialog_util", "infra.deferred_work", "ui.ui_builder",
		"adapters.json_codec", "hs", "tests.stubs.hs",
	}, function()
		local native = require("tests.stubs.hs")
		native.__reset()
		_G.hs = native
		package.loaded["hs"] = native
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			section = function(key) return key end,
			decorate_section = function(value) return value end,
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.paths"] = { shared = helpers.shared }
		local effects = {switches = {}, saves = 0, disables = 0, updates = 0, dialogs = 0, paused = false}
		package.loaded["infra.dialog_util"] = {
			alert = function() return true end,
			block_alert = function()
				effects.dialogs = effects.dialogs + 1
				return "button.remove"
			end,
		}
		package.loaded["infra.deferred_work"] = { after = function() return true end }
		package.loaded["ui.ui_builder"] = {can_create_webview = function() return true end}
		local first = {backend = "ollama", name = "first/model", future = {keep = "001"}}
		local exact = {backend = "ollama", name = "owner/model", future = "retain"}
		local last = {backend = "mlx", name = "foreign/model", future = "unowned"}
		local state = {llm_backend = "ollama", llm_model = initial and initial.active or "",
			llm_user_models = {first, exact, last}, llm_enabled = false}
		local selector = require("ui.menu.menu_llm.models_selector")
		local renderer = require("infra.manifest_menu")
		local ctx = {
			state = state, paused = initial and initial.paused or false,
			is_paused = function() return effects.paused end,
			models_mgr = {
				get_installed_models = function() return {} end,
				get_presets = function() return {} end,
				get_model_info = function() return nil end,
			},
			switch_model = function(name) effects.switches[#effects.switches + 1] = name end,
			disable_model = function() effects.disables = effects.disables + 1; return true end,
			save_prefs = function() effects.saves = effects.saves + 1; return true end,
			update_menu = function() effects.updates = effects.updates + 1; return true end,
			DEFAULT_STATE = {llm_model_mlx = "", llm_model_ollama = ""},
		}
		local function rows(name)
			for _, group in ipairs(selector.build(ctx)) do
				if group.label == "menu.llm.my_models" then
					for _, model in ipairs(group.items or {}) do
						if model.label:find(name or "owner/model", 1, true) then return model.items, model end
					end
				end
			end
			return nil
		end
		callback({ctx = ctx, state = state, effects = effects, selector = selector,
			renderer = renderer, rows = rows, first = first, exact = exact, last = last})
	end)
end

helpers.describe("shared user-added model child", function()
	for _, vector in ipairs(corpus().cases) do
		helpers.it("matches the handwritten complete two-row child " .. vector.active .. "/" .. tostring(vector.paused), function()
			with_fixture(function(fixture)
				local rows, parent = fixture.rows()
				helpers.assert_type(rows, "table")
				helpers.assert_eq(#rows, 2)
				for index, expected in ipairs(corpus().rows) do
					helpers.assert_eq(rows[index].label, expected.i18n)
					helpers.assert_type(rows[index].action, "function")
				end
				helpers.assert_eq(rows[1].checked, vector.checked)
				helpers.assert_eq(rows[1].disabled == true, vector.disabled)
				helpers.assert_true(rows[2].disabled ~= true)
				helpers.assert_eq(parent.disabled == true, vector.paused)
				helpers.assert_eq(fixture.effects.saves, 0)
				helpers.assert_eq(#fixture.effects.switches, 0)
			end, vector)
		end)
	end

	helpers.it("uses current shared labels and complete shared child order", function()
		with_fixture(function(fixture)
			local declaration = fixture.renderer.get_array("llm_user_model_controls")
			helpers.assert_eq(#declaration, 2)
			declaration[1].i18n = "common.restore_recommended"
			declaration[2].i18n = "common.restore_default"
			declaration[1], declaration[2] = declaration[2], declaration[1]
			local rows = fixture.rows()
			helpers.assert_eq(#rows, 2)
			helpers.assert_eq(rows[1].label, "common.restore_default")
			helpers.assert_eq(rows[2].label, "common.restore_recommended")
		end)
	end)

	helpers.it("refuses a missing child declaration rather than publishing undeclared callbacks", function()
		with_fixture(function(fixture)
			local declaration = fixture.renderer.get_array("llm_user_model_controls")
			for index = #declaration, 1, -1 do table.remove(declaration, index) end
			helpers.assert_eq(fixture.rows(), nil)
			helpers.assert_eq(fixture.effects.saves, 0)
			helpers.assert_eq(#fixture.effects.switches, 0)
		end)
	end)

	helpers.it("binds the selected native model independently for every user row", function()
		with_fixture(function(fixture)
			local first = fixture.rows("first/model")
			local exact = fixture.rows("owner/model")
			helpers.assert_eq(first[1].action(), nil)
			helpers.assert_eq(exact[1].action(), nil)
			helpers.assert_eq(fixture.effects.switches[1], "first/model")
			helpers.assert_eq(fixture.effects.switches[2], "owner/model")
			helpers.assert_eq(fixture.effects.saves, 0)
		end)
	end)

	helpers.it("rechecks live native pause before invoking a retained Select callback", function()
		with_fixture(function(fixture)
			local rows = fixture.rows()
			fixture.effects.paused = true
			helpers.assert_eq(rows[1].action(), false)
			helpers.assert_eq(#fixture.effects.switches, 0)
			helpers.assert_eq(fixture.effects.saves, 0)
		end)
	end)

	for _, reader in ipairs({false, function() return nil end, function() return "false" end,
		function() error("native pause read refused") end}) do
		helpers.it("refuses invalid explicit native pause evidence " .. type(reader), function()
			with_fixture(function(fixture)
				fixture.ctx.is_paused = reader
				local rows = fixture.rows()
				helpers.assert_eq(rows[1].disabled, true)
				helpers.assert_eq(rows[1].action(), false)
				helpers.assert_eq(#fixture.effects.switches, 0)
			end)
		end)
	end

	for _, mode in ipairs({"withdraw", "backend", "declaration"}) do
		helpers.it("refuses both retained callbacks after current owner " .. mode, function()
			with_fixture(function(fixture)
				local rows = fixture.rows()
				if mode == "withdraw" then table.remove(fixture.state.llm_user_models, 2)
				elseif mode == "backend" then fixture.state.llm_backend = "mlx"
				else
					local declaration = fixture.renderer.get_array("llm_user_model_controls")
					for index = #declaration, 1, -1 do table.remove(declaration, index) end
				end
				helpers.assert_eq(rows[1].action(), false)
				helpers.assert_eq(rows[2].action(), false)
				helpers.assert_eq(#fixture.effects.switches, 0)
				helpers.assert_eq(fixture.effects.dialogs, 0)
				helpers.assert_eq(fixture.effects.saves, 0)
				helpers.assert_eq(fixture.effects.disables, 0)
			end)
		end)
	end

	helpers.it("preserves exact inactive removal, neighbours, native save and refresh", function()
		with_fixture(function(fixture)
			local rows = fixture.rows()
			helpers.assert_eq(rows[2].action(), nil)
			helpers.assert_eq(#fixture.state.llm_user_models, 2)
			helpers.assert_eq(fixture.state.llm_user_models[1], fixture.first)
			helpers.assert_eq(fixture.state.llm_user_models[2], fixture.last)
			helpers.assert_eq(fixture.first.future.keep, "001")
			helpers.assert_eq(fixture.last.future, "unowned")
			helpers.assert_eq(fixture.effects.saves, 1)
			helpers.assert_eq(fixture.effects.updates, 1)
			helpers.assert_eq(fixture.effects.disables, 0)
		end)
	end)

	helpers.it("retains active removal delegation to the exact native disable owner", function()
		with_fixture(function(fixture)
			local rows = fixture.rows()
			helpers.assert_eq(rows[2].action(), true)
			helpers.assert_eq(#fixture.state.llm_user_models, 2)
			helpers.assert_eq(fixture.effects.disables, 1)
			helpers.assert_eq(fixture.effects.saves, 0)
			helpers.assert_eq(fixture.effects.updates, 0)
		end, {active = "owner/model"})
	end)
end)
