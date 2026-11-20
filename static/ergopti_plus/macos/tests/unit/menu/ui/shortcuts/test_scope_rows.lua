--- tests/unit/menu/ui/shortcuts/test_scope_rows.lua

--- ==============================================================================
--- MODULE: Regression — the Shortcuts submenu's restore and clear rows (macOS)
--- DESCRIPTION:
--- macOS drew « Restaurer les valeurs conseillées » and « Tout effacer » of the
--- Shortcuts submenu greyed, with a « not on macOS yet » reason, while Windows
--- and Linux applied them: the key combinations live in the remap file that
--- Karabiner applies, and only the Configuration menu composed them with the
--- shortcut preferences.
---
--- ROOT CAUSE ENCODED:
--- The shared declaration limited both rows to ahk and linux, and the submenu
--- registered no command for them. The submenu now registers both on the same
--- composition the Configuration menu runs for its Shortcuts step, narrowed to
--- the Shortcuts scope: its key combinations through the remap engine, then its
--- config.toml rows.
--- ==============================================================================

local helpers = require("tests.helpers")
local ConfigKeys = require("settings.engine.keys")

--- Builds the real Shortcuts submenu over doubles and returns its commands.
--- @param apply function|nil The menu context's apply_shortcuts_scope.
--- @return table commands The commands the submenu registered.
local function build(apply)
	local render_ctx = nil
	helpers.load_with_stubs("core.logger.engine.logger")
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	package.loaded["core.fs.engine.dir"] = { entries = function() return {} end }
	package.loaded["core.ui.engine.dialog_util"] = {}
	package.loaded["modules.shortcuts"] = {
		DEFAULT_STATE = { chatgpt_url = "https://example.test", shortcuts = true },
	}
	package.loaded["modules.shortcuts.actions.text"] = {
		WRAP_GROUPS = {},
		build_active_wrap_pairs = function() return {} end,
	}
	package.loaded["core.i18n.engine.i18n"] = {
		get = function(key) return key end,
		section = function(key) return key end,
		decorate_section = function(value) return value end,
	}
	package.loaded["menu.ui.builder.utils"] = {}
	package.loaded["menu.engine.manifest_menu"] = require("tests.support.declared_menu_parent_fixture").stub(
		function(_, _, _, _, ctx)
			render_ctx = ctx
			return {}
		end)
	package.loaded["ui.menu.shortcut_utils"] = {}
	package.loaded["ui.menu.menu_keyboard_slots"] = { provide_rows = function() return {} end }
	package.loaded["menu.engine.manifest_reader"] = { default_for = function() return "★" end }
	package.loaded["ui.menu.menu_tap_keys"] = { provide_rows = function() return {} end }
	package.loaded["ui.menu.menu_shortcuts"] = nil
	local MenuShortcuts = require("ui.menu.menu_shortcuts")
	MenuShortcuts.build({
		shortcuts = {},
		state = { shortcuts = true, chatgpt_url = "https://example.test", wrap_symbol_states = {},
			custom_wrap_symbols = {} },
		applyTriggerChar = function(value) return value end,
		save_prefs = function() return true end,
		notify_feature = function() end,
		updateMenu = function() end,
		commands = {},
		state_getters = {},
		apply_shortcuts_scope = apply,
	})
	assert(render_ctx and render_ctx.commands, "the submenu renders through its declaration")
	return render_ctx.commands
end

--- Reads the shared declaration of one Shortcuts row.
--- @param id string Row id.
--- @return table|nil row
local function declared(id)
	local file = assert(io.open(require("core.fs.engine.paths").shared("menu/data/menu_manifest.json"), "rb"))
	local text = assert(file:read("*a"))
	assert(file:close())
	for _, row in ipairs(require("core.text.engine.json").decode(text).shortcuts_menu) do
		if row.id == id then return row end
	end
	return nil
end

helpers.describe("the macOS Shortcuts restore and clear rows", function()
	helpers.it("declares both rows for every platform (shortcuts-scope-macos)", function()
		for _, id in ipairs({ "scope_restore", "scope_clear" }) do
			local row = declared(id)
			helpers.assert_type(row, "table", id .. " is declared")
			helpers.assert_nil(row.platforms, id .. " is drawn on every platform, macOS included")
			helpers.assert_nil(row.reason_key, id .. " carries no platform reason")
		end
	end)

	helpers.it("runs the composed Shortcuts scope for each row (shortcuts-scope-macos)", function()
		local modes = {}
		local commands = build(function(mode)
			modes[#modes + 1] = mode
			return true
		end)
		local restore = commands[ConfigKeys.COMMAND.SCOPE_RESTORE]
		local clear = commands[ConfigKeys.COMMAND.SCOPE_CLEAR]
		helpers.assert_type(restore, "function", "the restore row has its command")
		helpers.assert_type(clear, "function", "the clear row has its command")
		helpers.assert_eq(restore(), true)
		helpers.assert_eq(clear(), true)
		helpers.assert_eq(modes, { "recommended", "clear" })
	end)

	helpers.it("refuses when the menu has no composed owner (shortcuts-scope-macos)", function()
		local commands = build(nil)
		helpers.assert_eq(commands[ConfigKeys.COMMAND.SCOPE_RESTORE](), false)
		helpers.assert_eq(commands[ConfigKeys.COMMAND.SCOPE_CLEAR](), false)
	end)
end)
