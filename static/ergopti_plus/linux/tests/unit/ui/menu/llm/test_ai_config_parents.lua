--- tests/unit/ui/menu/llm/test_ai_config_parents.lua

--- ==============================================================================
--- MODULE: Regression - Linux AI rows that write config.toml name their cause
--- DESCRIPTION:
--- The switch and the restore row grey with « Saved by a newer version » when
--- config.toml refuses writes, but the profile parent and the inline model/API
--- list only knew about the pause: they stayed live over a file every click of
--- theirs was going to be refused on, and a tray kept open across a reload onto
--- a newer file ran the click anyway (ai-submenus-newer-config-2026-10-23).
--- ==============================================================================

local helpers = require("tests.helpers")
local Preferences = require("tests.support.llm_preferences_fixture")
local ConfigGuard = require("ui.menu.llm_config_guard")

helpers.describe("Linux AI configuration guard (ai-submenus-newer-config-2026-10-23)", function()
	helpers.it("greys the actionable rows of a list with the cause and wraps nothing when writable", function()
		local rows = { { label = "a", action = function() end }, { separator = true }, { label = "b", items = {} } }
		ConfigGuard.grey_list(rows, nil, "")
		helpers.assert_eq(#rows, 3, "a writable file leaves the list untouched")
		helpers.assert_nil(rows[1].disabled)
		ConfigGuard.grey_list(rows, "menu.read_only.newer_schema", "cause")
		helpers.assert_eq(#rows, 4, "one inert row names the cause")
		helpers.assert_eq(rows[1].label, "cause")
		helpers.assert_eq(rows[1].disabled, true)
		helpers.assert_eq(rows[2].disabled, true)
		helpers.assert_nil(rows[3].disabled, "a separator keeps its shape")
		helpers.assert_eq(rows[4].disabled, true)
	end)

	helpers.it("greys the profile parent with the newer cause and refuses its retained rows", function()
		Preferences.with(function()
			local Migrate = require("config_migrate")
			local I18n = require("infra.i18n")
			local old_reason, old_status = Migrate.read_only_reason, Migrate.read_only_status
			local blocked = false
			Migrate.read_only_reason = function() return blocked and "newer" or nil end
			Migrate.read_only_status = function() return blocked and "newer" or nil end
			local engine = require("modules.llm.prediction_engine")
			local original_enabled = engine.is_enabled
			local Logger = require("logger.shim")
			local old_warn = Logger.warn
			local ok, err = xpcall(function()
				local ctx = { llm = engine, paused = false, on_quit = function() end, on_menu_changed = function() end }
				ctx.is_paused = function() return ctx.paused end
				engine.init({ is_paused = ctx.is_paused })
				-- The profile parent is live only while the category is on.
				engine.is_enabled = function() return true end
				local refusals = 0
				Logger.warn = function(_, message)
					if type(message) == "string" and message:find("click refused", 1, true) then refusals = refusals + 1 end
				end

				--- Finds the profile parent inside the built AI tray row, and the AI rows.
				local function profile_parent()
					local title = I18n.get("menu.llm.title")
					for _, top in ipairs(require("ui.menu.menu_builder").build(ctx)) do
						if type(top.title) == "string" and top.title:sub(1, #title) == title then
							for _, child in ipairs(top.menu or {}) do
								if type(child.title) == "string" and child.menu
									and child.title:find(I18n.get("menu.profiles.profile_label_prefix"):match("^[^%%]+"), 1, true) then
									return child, top.menu
								end
							end
						end
					end
					return nil
				end

				local writable = profile_parent()
				helpers.assert_type(writable, "table", "the writable profile parent is built")
				helpers.assert_true(writable.disabled ~= true, "a writable file leaves the parent live")
				local leaf
				for _, child in ipairs(writable.menu) do
					if type(child.fn) == "function" then leaf = child; break end
				end
				helpers.assert_type(leaf, "table", "the profile submenu offers a clickable row")
				leaf.fn()
				helpers.assert_eq(refusals, 0, "while writable the retained row is not refused by the guard")

				blocked = true
				helpers.assert_eq(leaf.fn(), false, "a retained row rechecks the configuration")
				helpers.assert_eq(refusals, 1, "the click is refused by the configuration guard and logged")

				local greyed, ai_rows = profile_parent()
				helpers.assert_type(greyed, "table", "the greyed profile parent is still built")
				helpers.assert_eq(greyed.disabled, true)
				local head = I18n.get("menu.read_only.newer_schema"):match("^([^:]+)"):gsub("%s+$", "")
				helpers.assert_true(greyed.title:find(head, 1, true) ~= nil,
					"the parent names the newer configuration as its cause: " .. tostring(greyed.title))
				local cause = I18n.get("menu.read_only.newer_schema")
				local named = false
				for _, row in ipairs(ai_rows) do
					if row.title == cause and row.disabled == true then named = true end
				end
				helpers.assert_true(named, "the inline model list opens with one inert row naming the cause")
			end, debug.traceback)
			Logger.warn, engine.is_enabled = old_warn, original_enabled
			Migrate.read_only_reason, Migrate.read_only_status = old_reason, old_status
			if not ok then error(err, 0) end
		end)
	end)
end)
