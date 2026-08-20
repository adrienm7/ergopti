--- tests/unit/ui/menu/test_hotstrings_override_failure_gate.lua

--- ==============================================================================
--- MODULE: Hotstring Override Failure Gate
--- DESCRIPTION:
--- Drives the real category-delay menu action and proves a rejected override
--- write cannot alter the runtime delay or publish a success-only menu refresh.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("hotstring category delay is fail-closed", function()
	helpers.it("stops when the canonical override writer returns false", function()
		helpers.load_with_stubs("infra.logger")
		package.loaded["infra.dialog_util"] = {
			text_prompt = function() return "OK", "250" end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = {
			resolve = function() return { delay = 0.1, has_override = false } end,
			set_override = function() return false end,
		}
		package.loaded["infra.manifest_reader"] = {
			default_for = function() return "★" end,
		}
		package.loaded["infra.manifest_menu"] = {
			build = function(_, _, _, _, _, providers)
				return providers.delays_colors()
			end,
		}
		package.loaded["ui.menu.menu_hotstrings_management"] = nil
		local Management = require("ui.menu.menu_hotstrings_management")
		local applied, saves, updates = 0, 0, 0
		local built = Management.build_management({
			state = { delays = {}, trigger_char = "★" },
			paused = false,
			keymap = {
				DELAYS_DEFAULT = {
					STAR_TRIGGER = 0.1,
					autocorrection = 0.1,
					llm_prediction = 0.1,
					dynamichotstrings = 0.1,
				},
				DEFAULT_STATE = { expansion_delay = 0.1 },
				set_delay = function() applied = applied + 1 end,
			},
			hotstring_editor = {},
			save_prefs = function() saves = saves + 1; return true end,
			updateMenu = function() updates = updates + 1 end,
		})

		local delays
		for _, row in ipairs(built.menu or {}) do
			if type(row.menu) == "table" or type(row.items) == "table" then
				delays = row.menu or row.items
			end
		end
		helpers.assert_type(delays, "table")
		local target
		for _, row in ipairs(delays) do
			if type(row.fn) == "function" or type(row.action) == "function" then
				target = row.fn or row.action
			end
		end
		helpers.assert_type(target, "function")
		target()
		helpers.assert_eq(applied, 0)
		helpers.assert_eq(saves, 0, "config.toml is not the canonical override store")
		helpers.assert_eq(updates, 0)
	end)
end)

return true
