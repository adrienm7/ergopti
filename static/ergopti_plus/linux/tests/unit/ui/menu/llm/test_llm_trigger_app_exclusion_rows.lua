--- tests/unit/ui/menu/llm/test_llm_trigger_app_exclusion_rows.lua

--- ==============================================================================
--- MODULE: Linux AI Trigger Menu: Applications The Trigger Never Runs In
--- DESCRIPTION:
--- Windows and macOS let the user switch the automatic AI trigger off in chosen
--- applications (llm.trigger.disabled_apps); the Linux trigger submenu now draws
--- the same submenu over its own settings owner: one row per excluded
--- application (clicking removes it), the application last typed in, then any
--- other. This drives the real menu builder.
--- ==============================================================================

local helpers = require("tests.helpers")
local Preferences = require("tests.support.llm_preferences_fixture")

helpers.describe("Linux AI menu: trigger application exclusions", function()
	helpers.it("trigger-apps rows: exclude the last application, list it, remove it", function()
		Preferences.with(function()
			local I18n = require("infra.i18n")
			local Triggers = helpers.load_module("modules.llm.trigger_settings")
			Triggers._reset()
			local engine = require("modules.llm.prediction_engine")
			-- A fresh builder over the current module state: an earlier test may have
			-- retired the separator or manifest sources the cached one captured.
			local MenuBuilder = helpers.load_module("ui.menu.menu_builder")
			local original_enabled, original_last = engine.is_enabled, engine.get_agent_last_app
			local ok, err = xpcall(function()
				local ctx = { llm = engine, paused = false, on_quit = function() end, on_menu_changed = function() end }
				ctx.is_paused = function() return ctx.paused end
				engine.init({ is_paused = ctx.is_paused })
				engine.is_enabled = function() return true end
				engine.get_agent_last_app = function() return "Firefox" end

				--- The children of the exclusion row inside the AI trigger submenu.
				local function exclusion_children()
					local title = I18n.get("menu.llm.title")
					local trigger_title = I18n.get("menu.llm.trigger_menu_title")
					for _, top in ipairs(MenuBuilder.build(ctx)) do
						if type(top.title) == "string" and top.title:sub(1, #title) == title then
							for _, child in ipairs(top.menu or {}) do
								if type(child.title) == "string" and child.menu
									and child.title:sub(1, #trigger_title) == trigger_title then
									for _, row in ipairs(child.menu) do
										if type(row.title) == "string" and row.menu and (
											row.title:find(I18n.get("menu.llm.exclude_from_ai"), 1, true) == 1
											or row.title:find(I18n.get("menu.llm.disabled_in_label"):match("^[^%%]+"), 1, true) == 1) then
											return row.menu
										end
									end
								end
							end
						end
					end
					return nil
				end

				local children = exclusion_children()
				helpers.assert_type(children, "table", "the trigger submenu holds the exclusion row")
				local current_title = string.format(I18n.get("app_picker.agent_exclude_current_caption"), "Firefox")
				local add
				for _, row in ipairs(children) do if row.title == current_title then add = row end end
				helpers.assert_type(add, "table", "the application last typed in is offered")

				helpers.assert_true(add.fn() ~= false)
				helpers.assert_eq(Triggers.disabled_apps(), { "firefox" }, "excluded under its normalised identifier")

				children = exclusion_children()
				local remove
				for _, row in ipairs(children) do
					if type(row.title) == "string" and row.title:find("firefox", 1, true) and row.fn then remove = row end
				end
				helpers.assert_type(remove, "table", "the exclusion is listed")
				helpers.assert_true(remove.fn() ~= false)
				helpers.assert_eq(Triggers.disabled_apps(), {}, "clicking it removes the exclusion")
			end, debug.traceback)
			engine.is_enabled, engine.get_agent_last_app = original_enabled, original_last
			Triggers._reset()
			if not ok then error(err, 0) end
		end)
	end)
end)
