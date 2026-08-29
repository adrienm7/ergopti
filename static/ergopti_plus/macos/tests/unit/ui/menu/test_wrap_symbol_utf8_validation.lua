--- tests/unit/ui/menu/test_wrap_symbol_utf8_validation.lua

--- ==============================================================================
--- MODULE: Wrap-Symbol UTF-8 Validation Regression
--- DESCRIPTION:
--- Drives the real custom-symbol menu action. Malformed single-character input
--- must be rejected before persistence instead of reaching the pasteboard path.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Runs the real custom-symbol action with scripted prompt results.
--- @param responses table Array of {button, value} prompt results.
--- @return table result Side-effect counters and committed custom symbols.
local function run_action(responses)
	local result
	helpers.with_fresh_modules({
		"ui.menu.menu_shortcuts",
		"infra.logger",
		"infra.deferred_work",
		"infra.fs_dir",
		"infra.dialog_util",
		"modules.shortcuts",
		"modules.shortcuts.actions.text",
		"infra.i18n",
		"ui.menu.menu_utils",
		"infra.manifest_menu",
		"ui.menu.shortcut_utils",
		"ui.menu.menu_keyboard_slots",
		"infra.manifest_reader",
	}, function()
		local prompt_index = 0
		local alerts = 0
		local saves = 0
		local updates = 0
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.deferred_work"] = { after = function() return true end }
		package.loaded["infra.fs_dir"] = { entries = function() return {} end }
		package.loaded["infra.dialog_util"] = {
			text_prompt = function()
				prompt_index = prompt_index + 1
				local response = responses[prompt_index]
				if not response then error("unexpected prompt", 0) end
				return response[1], response[2]
			end,
			block_alert = function()
				alerts = alerts + 1
				return true
			end,
		}
		package.loaded["modules.shortcuts"] = {
			DEFAULT_STATE = { chatgpt_url = "https://example.test", shortcuts = true },
		}
		package.loaded["modules.shortcuts.actions.text"] = {
			WRAP_GROUPS = {},
			build_active_wrap_pairs = function() return {} end,
		}
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			section = function(key) return key end,
			decorate_section = function(value) return value end,
		}
		package.loaded["ui.menu.menu_utils"] = {}
		package.loaded["infra.manifest_menu"] = {
			build = function(_, _, _, _, _, providers)
				return providers.wrap_symbols_menu()
			end,
		}
		package.loaded["ui.menu.shortcut_utils"] = {}
		package.loaded["ui.menu.menu_keyboard_slots"] = {
			provide_rows = function() return {} end,
		}
		package.loaded["infra.manifest_reader"] = {
			default_for = function() return "star" end,
		}

		local state = {
			shortcuts = true,
			chatgpt_url = "https://example.test",
			wrap_symbol_states = {},
			custom_wrap_symbols = {},
		}
		local MenuShortcuts = require("ui.menu.menu_shortcuts")
		local item = MenuShortcuts.build({
			base_dir = "/fixture/driver/",
			shortcuts = {
				list_shortcuts = function() return {} end,
				resume_bindings = function() return true end,
				pause_bindings = function() return true end,
				set_wrap_pairs_getter = function() return true end,
			},
			state = state,
			paused = false,
			applyTriggerChar = function(value) return value end,
			save_prefs = function() saves = saves + 1; return true end,
			notify_feature = function() end,
			updateMenu = function() updates = updates + 1 end,
			commands = {},
			state_getters = {},
		})
		local wrap_row = item.submenu[1]
		helpers.assert_type(wrap_row.items, "table")
		local add_row = wrap_row.items[#wrap_row.items]
		helpers.assert_type(add_row.action, "function")
		local call_ok, committed = pcall(add_row.action)
		result = {
			call_ok = call_ok,
			committed = committed,
			alerts = alerts,
			saves = saves,
			updates = updates,
			prompts = prompt_index,
			custom = state.custom_wrap_symbols,
		}
	end)
	return result
end





-- ==================================================
-- ==================================================
-- ======= 1/ Exact Unicode Scalar Validation =======
-- ==================================================
-- ==================================================

helpers.describe("custom wrap symbols accept one exact Unicode scalar", function()
	local invalid_values = {
		{ "isolated continuation", string.char(0x80) },
		{ "truncated two-byte sequence", string.char(0xC2) },
		{ "truncated three-byte sequence", string.char(0xE2, 0x82) },
		{ "overlong three-byte sequence", string.char(0xE0, 0x80, 0x80) },
		{ "UTF-16 surrogate", string.char(0xED, 0xA0, 0x80) },
		{ "overlong four-byte sequence", string.char(0xF0, 0x80, 0x80, 0x80) },
		{ "codepoint above U+10FFFF", string.char(0xF4, 0x90, 0x80, 0x80) },
	}

	for _, vector in ipairs(invalid_values) do
		helpers.it("rejects an invalid opening " .. vector[1], function()
			local result = run_action({
				{ "button.ok", vector[2] },
				{ "button.cancel", "" },
			})
			helpers.assert_true(result.call_ok)
			helpers.assert_eq(result.alerts, 1)
			helpers.assert_eq(result.saves, 0)
			helpers.assert_eq(result.updates, 0)
			helpers.assert_eq(#result.custom, 0)
		end)
	end

	helpers.it("rejects an invalid closing scalar instead of substituting the opener", function()
		local result = run_action({
			{ "button.ok", "(" },
			{ "button.ok", string.char(0xED, 0xA0, 0x80) },
			{ "button.cancel", "" },
		})
		helpers.assert_true(result.call_ok)
		helpers.assert_eq(result.alerts, 1)
		helpers.assert_eq(result.saves, 0)
		helpers.assert_eq(result.updates, 0)
		helpers.assert_eq(#result.custom, 0)
	end)

	helpers.it("persists valid ASCII and four-byte scalars exactly", function()
		local emoji = string.char(0xF0, 0x9F, 0x98, 0x80)
		local result = run_action({
			{ "button.ok", "(" },
			{ "button.ok", emoji },
		})
		helpers.assert_true(result.call_ok)
		helpers.assert_eq(result.committed, true)
		helpers.assert_eq(result.alerts, 0)
		helpers.assert_eq(result.saves, 1)
		helpers.assert_eq(result.updates, 1)
		helpers.assert_eq(result.custom, { { left = "(", right = emoji } })
	end)
end)

return true
