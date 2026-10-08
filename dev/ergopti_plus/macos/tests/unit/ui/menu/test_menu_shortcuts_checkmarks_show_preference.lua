--- tests/unit/ui/menu/test_menu_shortcuts_checkmarks_show_preference.lua

--- ==============================================================================
--- MODULE: Shortcut Row Checkmarks Show The Preference
--- DESCRIPTION:
--- Each named-shortcut row read its checkmark from the live native binding, so
--- while the Shortcuts layer was off or paused every row showed unchecked and
--- nothing told the user which shortcuts would come back. The rows are drawn
--- here from the real Bindings registry behind a real pause.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.shortcut_bindings_fixture")

local DISABLED_ID = "ctrl_d"

--- Builds the real Shortcuts submenu around the given registry and returns
--- the named Ctrl rows, the only ones the stubbed renderer hands back.
--- @param bindings table Real Bindings module.
--- @param state_shortcuts boolean Shortcuts master switch.
--- @return table rows Menu rows.
local function build_ctrl_rows(bindings, state_shortcuts)
	return helpers.with_fresh_modules({
		"ui.menu.menu_shortcuts", "infra.deferred_work", "infra.fs_dir",
		"infra.dialog_util", "modules.shortcuts", "ui.menu.menu_utils",
		"infra.manifest_menu", "ui.menu.shortcut_utils", "ui.menu.menu_keyboard_slots",
		"infra.manifest_reader", "infra.i18n",
	}, function()
		local text = package.loaded["modules.shortcuts.actions.text"]
		text.WRAP_GROUPS = {}
		text.build_active_wrap_pairs = function() return {} end
		package.loaded["infra.deferred_work"] = { after = function() return true end }
		package.loaded["infra.fs_dir"] = { entries = function() return {} end }
		package.loaded["infra.dialog_util"] = {}
		package.loaded["modules.shortcuts"] = {
			DEFAULT_STATE = { chatgpt_url = "https://example.test", shortcuts = true },
		}
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			decorate_section = function(value) return value end,
			section = function(value) return value end,
		}
		package.loaded["ui.menu.menu_utils"] = {}
		local native_renderer = require("infra.manifest_menu")
		assert(type(native_renderer.template_rows) == "function")
		package.loaded["infra.manifest_menu"] = {
			template_rows = native_renderer.template_rows,
			build = function(_, _, _, _, _, lists) return lists.keyboard_slots() end,
		}
		package.loaded["ui.menu.shortcut_utils"] = {}
		package.loaded["ui.menu.menu_keyboard_slots"] = {
			provide_rows = function(_, _, fixed_by_prefix) return fixed_by_prefix.hs_ctrl_ end,
		}
		package.loaded["infra.manifest_reader"] = { default_for = function() return "star" end }

		local item = require("ui.menu.menu_shortcuts").build({
			shortcuts = bindings,
			state = {
				shortcuts = state_shortcuts,
				chatgpt_url = "https://example.test",
				wrap_symbol_states = {},
				custom_wrap_symbols = {},
			},
			paused = false,
			applyTriggerChar = function(value) return value end,
			save_prefs = function() return true end,
			notify_feature = function() end,
			updateMenu = function() end,
			commands = {},
			state_getters = {},
		})
		return item.submenu
	end)
end

--- Asserts one checkmark per named Ctrl shortcut, matched by its key label.
--- @param bindings table Real Bindings module.
--- @param rows table Rendered rows.
--- @param context string Diagnostic context.
local function assert_checkmarks(bindings, rows, context)
	local checked_by_key = {}
	for _, row in ipairs(rows) do
		local key = type(row.label) == "string" and row.label:match("^Ctrl %+ (%S+) :")
		if key then checked_by_key[key] = row.checked == true end
	end
	local compared = 0
	for id in pairs(Fixture.index(bindings)) do
		local letter = id:match("^ctrl_(%a)$")
		if letter then
			compared = compared + 1
			helpers.assert_eq(checked_by_key[letter:upper()], id ~= DISABLED_ID,
				context .. ": row checkmark for " .. id)
		end
	end
	helpers.assert_true(compared > 1, "the Ctrl rows must be rendered, or nothing was compared")
end





-- ======================================================
-- ======================================================
-- ======= 1/ Checkmarks Survive A Released Layer =======
-- ======================================================
-- ======================================================

helpers.describe("menu_shortcuts: row checkmarks show the preference (shortcut-preference-vs-binding)", function()
	helpers.it("keeps the checkmarks while the Shortcuts layer is off", function()
		Fixture.with_recommended_bindings(function(bindings)
			helpers.assert_eq(bindings.start(), true)
			helpers.assert_eq(bindings.disable(DISABLED_ID), true)
			assert_checkmarks(bindings, build_ctrl_rows(bindings, true), "running")
			helpers.assert_eq(bindings.pause(), true)
			assert_checkmarks(bindings, build_ctrl_rows(bindings, false), "layer off")
		end)
	end)
end)

return true
