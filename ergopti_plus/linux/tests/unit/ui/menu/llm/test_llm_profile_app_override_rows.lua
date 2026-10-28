--- tests/unit/ui/menu/llm/test_llm_profile_app_override_rows.lua

--- ==============================================================================
--- MODULE: Linux Per-Application Profile Rows
--- DESCRIPTION:
--- The AI menu's profile submenu offers the per-application overrides Windows
--- already has: a row mapping the application last typed in to the profile in
--- force, and one row per mapping that clears it. This drives the real menu
--- builder, the real shared frame and the real settings owner.
--- ==============================================================================

local helpers = require("tests.helpers")
local Preferences = require("tests.support.llm_preferences_fixture")

helpers.describe("Linux AI menu: per-application profile overrides", function()
	helpers.it("app-profile rows: map the last application, list it, clear it", function()
		Preferences.with(function()
			local I18n = require("infra.i18n")
			local Settings = helpers.load_module("modules.llm.profile_settings")
			Settings._reset()
			local engine = require("modules.llm.prediction_engine")
			-- A fresh builder over the current module state: an earlier test may have
			-- retired the separator or manifest sources the cached one captured.
			local MenuBuilder = helpers.load_module("ui.menu.menu_builder")
			local original_enabled, original_last = engine.is_enabled, engine.get_agent_last_app
			local ok, err = xpcall(function()
				local rebuilt = 0
				local ctx = { llm = engine, paused = false, on_quit = function() end,
					on_menu_changed = function() rebuilt = rebuilt + 1 end }
				ctx.is_paused = function() return ctx.paused end
				engine.init({ is_paused = ctx.is_paused })
				engine.is_enabled = function() return true end
				engine.get_agent_last_app = function() return "Firefox" end

				--- The children of the per-application group inside the profile parent.
				local function group_children()
					local title = I18n.get("menu.llm.title")
					for _, top in ipairs(MenuBuilder.build(ctx)) do
						if type(top.title) == "string" and top.title:sub(1, #title) == title then
							for _, child in ipairs(top.menu or {}) do
								if type(child.title) == "string" and child.menu
									and child.title:find(I18n.get("menu.profiles.profile_label_prefix"):match("^[^%%]+"), 1, true) then
									for _, row in ipairs(child.menu) do
										if type(row.title) == "string" and row.menu
											and row.title:find(I18n.get("menu.profiles.per_app_overrides"), 1, true) then
											return row.menu
										end
									end
								end
							end
						end
					end
					return nil
				end

				local children = group_children()
				helpers.assert_type(children, "table", "the profile submenu holds the per-application group")
				local add_title = I18n.get("menu.profiles.override_active_app_with_current")
				local add
				for _, row in ipairs(children) do if row.title == add_title then add = row end end
				helpers.assert_type(add, "table", "the group opens with the mapping row")
				helpers.assert_eq(#children, 1, "no mapping yet: no clear row, no separator")

				helpers.assert_true(add.fn() ~= false, "the mapping row maps the application last typed in")
				helpers.assert_eq(Settings.app_overrides().firefox, Settings.effective_profile(engine.get_current_model and engine.get_current_model() or nil),
					"to the profile in force")
				helpers.assert_true(rebuilt > 0, "the menu is redrawn")

				children = group_children()
				local clear
				for _, row in ipairs(children) do
					if type(row.title) == "string" and row.title:find("firefox  →  ", 1, true) == 1 then clear = row end
				end
				helpers.assert_type(clear, "table", "the mapping is listed under its normalised application")
				helpers.assert_true(clear.fn() ~= false)
				helpers.assert_nil(Settings.app_overrides().firefox, "clicking the mapping clears it")
			end, debug.traceback)
			engine.is_enabled, engine.get_agent_last_app = original_enabled, original_last
			Settings._reset()
			if not ok then error(err, 0) end
		end)
	end)
end)
