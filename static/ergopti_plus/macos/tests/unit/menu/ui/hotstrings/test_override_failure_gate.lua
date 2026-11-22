--- tests/unit/menu/ui/hotstrings/test_override_failure_gate.lua

--- ==============================================================================
--- MODULE: Hotstring Override Failure Gate
--- DESCRIPTION:
--- Drives the real category-delay menu action and proves a rejected override
--- write cannot alter the runtime delay or publish a success-only menu refresh,
--- and that a blank answer removes the override (maintainer decision of
--- 2026-11-22, PCK-13 for overrides).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the real management menu around a stubbed override store and
--- returns the last category-delay action with its observed effects.
--- @param config table Stub of hotstrings.engine.catalogue.config.
--- @param answer string What the prompt answers.
--- @return function target
--- @return table counts { applied, saves, updates, delays }
local function category_delay_action(config, answer)
	helpers.load_with_stubs("core.logger.engine.logger")
	package.loaded["core.ui.engine.dialog_util"] = {
		text_prompt = function() return "OK", answer end,
	}
	package.loaded["hotstrings.engine.catalogue.config"] = config
	package.loaded["menu.engine.manifest_reader"] = {
		default_for = function() return "★" end,
	}
	local renderer = require("menu.engine.manifest_menu")
	local command_row = require("menu.engine.manifest_menu").command_row
	local check_row = require("menu.engine.manifest_menu").check_row
	local get_array = require("menu.engine.manifest_menu").get_array
	local template_rows = require("menu.engine.manifest_menu").template_rows
	local get_root = require("menu.engine.manifest_menu").get_root
	local native_child_rows = require("menu.engine.manifest_menu").native_child_rows
	package.loaded["menu.engine.manifest_menu"] = {
		command_row = command_row,
		check_row = check_row,
		get_array = get_array,
		template_rows = template_rows,
		get_root = get_root,
		native_child_rows = native_child_rows,
		build = function(section, category, dynamic, groups, context, providers)
			if section == "word_expanders_menu" then
				return renderer.build(section, category, dynamic, groups, context, providers)
			end
			return providers.delays_colors()
		end,
	}
	package.loaded["hotstrings.ui.menu.management"] = nil
	local Management = require("hotstrings.ui.menu.management")
	local counts = { applied = 0, saves = 0, updates = 0, delays = {} }
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
			set_delay = function(_, seconds)
				counts.applied = counts.applied + 1
				counts.delays[#counts.delays + 1] = seconds
			end,
		},
		hotstring_editor = {},
		save_prefs = function() counts.saves = counts.saves + 1; return true end,
		updateMenu = function() counts.updates = counts.updates + 1 end,
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
	return target, counts
end

helpers.describe("hotstring category delay is fail-closed", function()
	helpers.it("stops when the canonical override writer returns false", function()
		local target, counts = category_delay_action({
			resolve = function() return { delay = 0.1, has_override = false } end,
			set_override = function() return false end,
		}, "250")
		target()
		helpers.assert_eq(counts.applied, 0)
		helpers.assert_eq(counts.saves, 0, "config.toml is not the canonical override store")
		helpers.assert_eq(counts.updates, 0)
	end)

	helpers.it("removes the override on a blank answer (pck-13-overrides-2026-11-22)", function()
		local overridden, cleared, written = true, {}, 0
		local target, counts = category_delay_action({
			resolve = function()
				return overridden and { delay = 0.3, has_override = true } or { delay = 0.1, has_override = false }
			end,
			set_override = function() written = written + 1; return true end,
			clear_override = function(category, section, field)
				cleared[#cleared + 1] = { category, section, field }
				overridden = false
				return true
			end,
		}, "   ")
		target()
		helpers.assert_eq(written, 0, "no override is written")
		helpers.assert_eq(#cleared, 1, "the override is removed")
		helpers.assert_eq(cleared[1][3], "delay")
		helpers.assert_eq(counts.delays, { 0.1 }, "the running engine takes the inherited delay")
		helpers.assert_eq(counts.updates, 1)
	end)

	helpers.it("keeps the override when its removal is refused (pck-13-overrides-2026-11-22)", function()
		local target, counts = category_delay_action({
			resolve = function() return { delay = 0.3, has_override = true } end,
			set_override = function() return true end,
			clear_override = function() return false end,
		}, "")
		helpers.assert_eq(target(), false)
		helpers.assert_eq(counts.applied, 0)
		helpers.assert_eq(counts.updates, 0)
	end)
end)

return true
