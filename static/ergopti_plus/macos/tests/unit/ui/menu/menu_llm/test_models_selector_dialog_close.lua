--- tests/unit/ui/menu/menu_llm/test_models_selector_dialog_close.lua

--- ==============================================================================
--- MODULE: Models Selector Custom Dialog Opening Tests
--- DESCRIPTION:
--- Drives the real add-model menu action through localized HTML construction.
--- The action must reach the WebView factory instead of indexing an undefined
--- dialog-title variable.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_fixture(callback, initial_state)
	helpers.with_fresh_modules({
		"ui.menu.menu_llm.models_selector", "infra.i18n", "infra.logger",
		"infra.dialog_util", "infra.deferred_work", "ui.ui_builder",
		"hs", "tests.stubs.hs",
	}, function()
		local controls = {delete_throws = false, disable_mode = "success", save_mode = "success"}
		local context = {
			bridges = {},
			deletes = 0,
			disables = 0,
			saves = 0,
			switches = {},
			updates = 0,
			views = {},
		}
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		hs_stub.webview.usercontent.new = function()
			local bridge = {}
			function bridge:setCallback(bridge_callback)
				self.callback = bridge_callback
				return true
			end
			context.bridges[#context.bridges + 1] = bridge
			return bridge
		end
		hs_stub.webview.windowMasks = {titled = 1, closable = 2}
		_G.hs = hs_stub
		package.loaded["hs"] = hs_stub
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			section = function(key) return key end,
			decorate_section = function(value) return value end,
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.dialog_util"] = {
			alert = function() return true end,
			block_alert = function() return "button.remove" end,
		}
		package.loaded["infra.deferred_work"] = {
			after = function(_delay, deferred_callback) deferred_callback(); return true end,
		}
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function() return {width = 520, height = 180} end,
			get_centered_frame = function(width, height)
				return {x = 0, y = 0, w = width, h = height}
			end,
			show_webview = function(options)
				local webview = {options = options}
				function webview:delete()
					context.deletes = context.deletes + 1
					options.on_close()
					if controls.delete_throws then error("synthetic custom dialog delete refusal") end
					return true
				end
				context.views[#context.views + 1] = webview
				return webview
			end,
		}

		local state = initial_state
			or {llm_backend = "ollama", llm_model = "", llm_user_models = {}}
		local Selector = require("ui.menu.menu_llm.models_selector")
		local menu = Selector.build({
			state = state,
			models_mgr = {
				get_installed_models = function() return {} end,
				get_presets = function() return {} end,
				get_model_info = function() return nil end,
				get_model_ram = function() return 0 end,
				is_model_installed = function() return false end,
			},
			switch_model = function(name) context.switches[#context.switches + 1] = name end,
			disable_model = function()
				context.disables = context.disables + 1
				if controls.disable_mode == "false" then return false end
				if controls.disable_mode == "nil" then return nil end
				if controls.disable_mode == "throw" then error("synthetic model disable refusal") end
				return true
			end,
			save_prefs = function()
				context.saves = context.saves + 1
				if controls.save_mode == "false" then return false end
				if controls.save_mode == "nil" then return nil end
				if controls.save_mode == "throw" then error("synthetic preferences save refusal") end
				return true
			end,
			update_menu = function() context.updates = context.updates + 1; return true end,
			DEFAULT_STATE = {llm_model_mlx = "", llm_model_ollama = ""},
		})
		local add_action = nil
		local remove_action = nil
		for _, item in ipairs(menu) do
			if item.label == "menu.llm.add_model_entry" then add_action = item.action end
			if item.label == "menu.llm.my_models" then
				for _, model_item in ipairs(item.items or {}) do
					if model_item.label:find("owner/model", 1, true) then
						for _, model_action in ipairs(model_item.items or {}) do
							if model_action.label == "menu.llm.remove_user_model" then
								remove_action = model_action.action
							end
						end
					end
				end
			end
		end
		helpers.assert_type(add_action, "function")
		callback({
			action = add_action,
			context = context,
			controls = controls,
			remove_action = remove_action,
			state = state,
		})
	end)
end

helpers.describe("models selector custom dialog ownership", function()
	helpers.it("builds localized HTML and reaches the WebView factory", function()
		with_fixture(function(fixture)
			fixture.action()
			helpers.assert_eq(#fixture.context.views, 1,
				"the add-model action must reach the WebView factory")
			helpers.assert_type(fixture.context.bridges[1].callback, "function")
		end)
	end)

	helpers.it("retains a refused exact dialog before applying or replacing it", function()
		with_fixture(function(fixture)
			fixture.action()
			local bridge = fixture.context.bridges[1]
			fixture.controls.delete_throws = true

			helpers.assert_eq(bridge.callback({body = {action = "add", value = " owner/model "}}), false)
			helpers.assert_eq(#fixture.state.llm_user_models, 0,
				"a failed native close must block state mutation")
			helpers.assert_eq(fixture.context.saves, 0,
				"a failed native close must block persistence")
			helpers.assert_eq(#fixture.context.switches, 0,
				"a failed native close must block model activation")

			helpers.assert_eq(fixture.action(), false,
				"a successor must wait for the exact prior dialog to close")
			helpers.assert_eq(#fixture.context.views, 1,
				"a failed replacement close must not allocate another dialog")

			fixture.controls.delete_throws = false
			helpers.assert_eq(bridge.callback({body = {action = "add", value = " owner/model "}}), true)
			helpers.assert_eq(fixture.context.deletes, 3,
				"the same exact dialog must be retried until native deletion commits")
			helpers.assert_eq(#fixture.state.llm_user_models, 1)
			helpers.assert_eq(fixture.state.llm_user_models[1].name, "owner/model")
			helpers.assert_eq(fixture.context.saves, 1)
			helpers.assert_eq(fixture.context.switches[1], "owner/model")
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("rolls back an unpersisted custom model after save " .. mode, function()
			with_fixture(function(fixture)
				fixture.action()
				fixture.controls.save_mode = mode
				local result = fixture.context.bridges[1].callback({
					body = {action = "add", value = "owner/model"},
				})

				helpers.assert_eq(result, false)
				helpers.assert_eq(#fixture.state.llm_user_models, 0,
					"an unpersisted model must not remain in live preferences")
				helpers.assert_eq(fixture.context.saves, 1)
				helpers.assert_eq(#fixture.context.switches, 0,
					"activation must remain fenced after persistence failure")
			end)
		end)
	end

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("restores an unpersisted custom model removal after save " .. mode, function()
			local first = {backend = "ollama", name = "first/model"}
			local exact = {backend = "ollama", name = "owner/model"}
			local last = {backend = "ollama", name = "last/model"}
			local state = {
				llm_backend = "ollama",
				llm_model = "",
				llm_user_models = {first, exact, last},
			}
			with_fixture(function(fixture)
				helpers.assert_type(fixture.remove_action, "function")
				fixture.controls.save_mode = mode
				helpers.assert_eq(fixture.remove_action(), false)

				helpers.assert_eq(#state.llm_user_models, 3)
				helpers.assert_eq(state.llm_user_models[1], first)
				helpers.assert_eq(state.llm_user_models[2], exact,
					"the exact removed entry must return to its original index")
				helpers.assert_eq(state.llm_user_models[3], last)
				helpers.assert_eq(fixture.context.saves, 1)
				helpers.assert_eq(fixture.context.updates, 0)
			end, state)
		end)
	end

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("restores an active custom model after disable " .. mode, function()
			local first = {backend = "ollama", name = "first/model"}
			local exact = {backend = "ollama", name = "owner/model"}
			local last = {backend = "ollama", name = "last/model"}
			local state = {
				llm_backend = "ollama",
				llm_model = "owner/model",
				llm_user_models = {first, exact, last},
			}
			with_fixture(function(fixture)
				helpers.assert_type(fixture.remove_action, "function")
				fixture.controls.disable_mode = mode
				helpers.assert_eq(fixture.remove_action(), false)

				helpers.assert_eq(#state.llm_user_models, 3)
				helpers.assert_eq(state.llm_user_models[1], first)
				helpers.assert_eq(state.llm_user_models[2], exact)
				helpers.assert_eq(state.llm_user_models[3], last)
				helpers.assert_eq(fixture.context.disables, 1)
				helpers.assert_eq(fixture.context.saves, 0)
				helpers.assert_eq(fixture.context.updates, 0)
			end, state)
		end)
	end
end)
