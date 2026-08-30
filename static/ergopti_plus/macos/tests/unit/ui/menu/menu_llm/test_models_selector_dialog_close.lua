--- tests/unit/ui/menu/menu_llm/test_models_selector_dialog_close.lua

--- ==============================================================================
--- MODULE: Models Selector Custom Dialog Opening Tests
--- DESCRIPTION:
--- Drives the real add-model menu action through localized HTML construction.
--- The action must reach the WebView factory instead of indexing an undefined
--- dialog-title variable.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("models selector custom dialog opening", function()
	helpers.it("builds localized HTML and reaches the WebView factory", function()
		helpers.with_fresh_modules({
			"ui.menu.menu_llm.models_selector", "infra.i18n", "infra.logger",
			"infra.dialog_util", "infra.deferred_work", "ui.ui_builder",
			"hs", "tests.stubs.hs",
		}, function()
			local controls = {delete_throws = false}
			local context = {
				bridges = {},
				deletes = 0,
				saves = 0,
				switches = {},
				views = {},
			}
			local hs_stub = require("tests.stubs.hs")
			hs_stub.__reset()
			hs_stub.webview.usercontent.new = function()
				local bridge = {}
				function bridge:setCallback(callback)
					self.callback = callback
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
			package.loaded["infra.dialog_util"] = {alert = function() return true end}
			package.loaded["infra.deferred_work"] = {
				after = function(_delay, callback) callback(); return true end,
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
						if controls.delete_throws then error("synthetic custom dialog delete refusal") end
						return true
					end
					context.views[#context.views + 1] = webview
					return webview
				end,
			}

			local state = {llm_backend = "ollama", llm_model = "", llm_user_models = {}}
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
				disable_model = function() return true end,
				save_prefs = function() context.saves = context.saves + 1; return true end,
				update_menu = function() return true end,
				DEFAULT_STATE = {llm_model_mlx = "", llm_model_ollama = ""},
			})
			local add_action = nil
			for _, item in ipairs(menu) do
				if item.label == "menu.llm.add_model_entry" then add_action = item.action end
			end
			helpers.assert_type(add_action, "function")

			add_action()
			helpers.assert_eq(#context.views, 1,
				"the add-model action must reach the WebView factory")
			helpers.assert_type(context.bridges[1].callback, "function")
		end)
	end)
end)
