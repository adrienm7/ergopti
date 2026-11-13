--- tests/unit/menu/ui/shortcuts/test_checkmarks_show_preference.lua

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

-- Cmd+* is the named built-in left since schema v20 made Ctrl+G a keyboard slot.
local DISABLED_ID = "cmd_star"

--- Builds the real Shortcuts submenu around the given registry and returns
--- the named Cmd rows, the only ones the stubbed renderer hands back.
--- @param bindings table Real Bindings module.
--- @param state_shortcuts boolean Shortcuts master switch.
--- @return table rows Menu rows.
local function build_cmd_rows(bindings, state_shortcuts)
	return helpers.with_fresh_modules({
		"ui.menu.menu_shortcuts", "core.timing.engine.deferred_work", "core.fs.engine.dir",
		"core.ui.engine.dialog_util", "modules.shortcuts", "menu.ui.builder.utils",
		"menu.engine.manifest_menu", "ui.menu.shortcut_utils", "layouts.ui.menu.keyboard_slots",
		"menu.engine.manifest_reader", "core.i18n.engine.i18n",
	}, function()
		local text = package.loaded["modules.shortcuts.actions.text"]
		text.WRAP_GROUPS = {}
		text.build_active_wrap_pairs = function() return {} end
		package.loaded["core.timing.engine.deferred_work"] = { after = function() return true end }
		package.loaded["core.fs.engine.dir"] = { entries = function() return {} end }
		package.loaded["core.ui.engine.dialog_util"] = {}
		package.loaded["modules.shortcuts"] = {
			DEFAULT_STATE = { chatgpt_url = "https://example.test", shortcuts = true },
		}
		package.loaded["core.i18n.engine.i18n"] = {
			get = function(key) return key end,
			decorate_section = function(value) return value end,
			section = function(value) return value end,
		}
		package.loaded["menu.ui.builder.utils"] = {}
		local native_renderer = require("menu.engine.manifest_menu")
		assert(type(native_renderer.template_rows) == "function")
		package.loaded["menu.engine.manifest_menu"] = {
			group_receiver = native_renderer.group_receiver,
			template_rows = native_renderer.template_rows,
			build = function(_, _, _, _, _, lists) return lists.keyboard_slots() end,
		}
		package.loaded["ui.menu.shortcut_utils"] = {}
		package.loaded["layouts.ui.menu.keyboard_slots"] = {
			provide_rows = function(_, _, fixed_by_prefix) return fixed_by_prefix.primary_ end,
		}
		package.loaded["menu.engine.manifest_reader"] = { default_for = function() return "star" end }

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

--- Asserts one checkmark per named Cmd shortcut, the rows following the
--- registry's own order of its cmd_* entries.
--- @param bindings table Real Bindings module.
--- @param rows table Rendered rows.
--- @param context string Diagnostic context.
local function assert_checkmarks(bindings, rows, context)
	local compared = 0
	for _, entry in ipairs(bindings.list_shortcuts()) do
		if entry.id:sub(1, 4) == "cmd_" then
			compared = compared + 1
			local row = rows[compared]
			helpers.assert_true(type(row) == "table", context .. ": a row is drawn for " .. entry.id)
			helpers.assert_eq(row.checked == true, entry.id ~= DISABLED_ID,
				context .. ": row checkmark for " .. entry.id)
		end
	end
	helpers.assert_true(compared >= 1, "the Cmd rows must be rendered, or nothing was compared")
	helpers.assert_eq(#rows, compared, context .. ": one row per named Cmd shortcut")
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
			assert_checkmarks(bindings, build_cmd_rows(bindings, true), "running")
			helpers.assert_eq(bindings.pause(), true)
			assert_checkmarks(bindings, build_cmd_rows(bindings, false), "layer off")
		end)
	end)
end)

return true
