--- tests/unit/ui/menu/menu_llm/test_models_selector_chooser_close.lua

--- ==============================================================================
--- MODULE: Models Selector Chooser Ownership Tests
--- DESCRIPTION:
--- Exercises replacement of the fallback model chooser when native deletion
--- raises after the chooser has already been presented.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("models selector fallback chooser ownership", function()
	helpers.it("retains a refused exact chooser and blocks its successor", function()
		helpers.with_fresh_modules({
			"ui.menu.menu_llm.models_selector", "ui.model_browser", "infra.i18n",
			"infra.logger", "infra.dialog_util", "infra.deferred_work",
			"hs", "tests.stubs.hs",
		}, function()
			local controls = {delete_throws = false}
			local context = {choosers = {}, deletes = {}, shows = 0}
			local hs_stub = require("tests.stubs.hs")
			hs_stub.__reset()
			hs_stub.chooser = {
				new = function(choice_callback)
					local chooser = {choice_callback = choice_callback}
					function chooser:width() return self end
					function chooser:placeholderText() return self end
					function chooser:queryChangedCallback(callback)
						self.query_callback = callback
						return self
					end
					function chooser:choices() return self end
					function chooser:show()
						context.shows = context.shows + 1
						return self
					end
					function chooser:isVisible() return true end
					function chooser:delete()
						context.deletes[#context.deletes + 1] = self
						if controls.delete_throws then error("synthetic chooser delete refusal") end
						return self
					end
					context.choosers[#context.choosers + 1] = chooser
					return chooser
				end,
			}
			_G.hs = hs_stub
			package.loaded["hs"] = hs_stub
			package.loaded["ui.model_browser"] = {open = function() return false end}
			package.loaded["infra.i18n"] = {
				get = function(key) return key end,
				section = function(key) return key end,
				decorate_section = function(value) return value end,
			}
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.dialog_util"] = {alert = function() return true end}
			package.loaded["infra.deferred_work"] = {
				after = function(_delay, callback) return callback() end,
			}

			local Selector = require("ui.menu.menu_llm.models_selector")
			local menu = Selector.build({
				state = {llm_backend = "ollama", llm_model = "", llm_user_models = {}},
				models_mgr = {
					get_installed_models = function() return {} end,
					get_presets = function()
						return {{label = "Provider", families = {{
							label = "Family",
							models = {{name = "owner/model", urls = {ollama = "owner/model"}}},
						}}}}
					end,
					get_model_info = function() return nil end,
					get_model_ram = function() return 4 end,
					get_actual_model_name = function(name) return name end,
					is_model_installed = function() return false end,
				},
				switch_model = function() return true end,
				disable_model = function() return true end,
				save_prefs = function() return true end,
				update_menu = function() return true end,
				DEFAULT_STATE = {llm_model_mlx = "", llm_model_ollama = ""},
			})
			local browse_action = nil
			for _, item in ipairs(menu) do
				if item.label == "menu.llm.browse_models_entry" then browse_action = item.action end
			end
			helpers.assert_type(browse_action, "function")

			browse_action()
			helpers.assert_eq(#context.choosers, 1)
			helpers.assert_eq(context.shows, 1)
			local exact_owner = context.choosers[1]

			controls.delete_throws = true
			browse_action()
			helpers.assert_eq(#context.choosers, 1,
				"a refused prior chooser must block successor allocation")
			helpers.assert_eq(context.deletes[1], exact_owner,
				"replacement must retain the exact chooser that refused deletion")
			helpers.assert_eq(context.shows, 1)

			controls.delete_throws = false
			browse_action()
			helpers.assert_eq(context.deletes[2], exact_owner,
				"the next replacement must retry the same exact chooser")
			helpers.assert_eq(#context.choosers, 2)
			helpers.assert_eq(context.shows, 2)
		end)
	end)
end)
