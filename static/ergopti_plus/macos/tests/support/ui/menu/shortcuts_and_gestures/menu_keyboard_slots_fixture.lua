--- tests/support/ui/menu/shortcuts_and_gestures/menu_keyboard_slots_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_menu_keyboard_slots
--- DESCRIPTION:
--- Prelude shared by the test_menu_keyboard_slots_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")
local MODULES = {
	"core.fs.adapters.file_system", "platform.input.hotkey_registrar", "settings.engine.paths",
	"settings.engine.preferences.preferences", "core.timing.engine.deferred_work", "core.ui.engine.dialog_util", "core.logger.engine.logger",
	"shortcuts.engine", "shortcuts.engine.bindings", "shortcuts.engine.keyboard_shortcuts",
	"shortcuts.engine.tap_keys", "shortcuts.engine.script_control", "gestures.engine.actions",
	"shortcuts.ui.action_picker", "layouts.ui.menu.keyboard_slots", "shortcuts.ui.menu.utils",
	"tests.support.keyboard_config_fixture", "menu.engine.manifest_menu", "menu.engine.renderer", "core.i18n.engine.i18n",
	"settings.ui.menu.preferences_transaction", "menu.ui.transactions.program_parameter_transaction", "menu.ui.transactions.global_actions_transaction",
}

--- Owns the real facade and its canonical persistence boundary for one UI case.
local function it(name, callback)
	helpers.it(name, function()
		return helpers.with_stub_scope(MODULES, callback)
	end)
end




-- ==========================================
-- ==========================================
-- ======= 1/ Harness =======================
-- ==========================================
-- ==========================================

-- The catalogue's first alphabetic key, used wherever a case needs "some slot"
-- and its identity does not matter.
local FIRST_KEY = "a"

--- Builds a menu context with a gesture registry the picker can offer.
--- @return table ctx, table updates A counter table the context increments.
local function make_ctx()
	local updates = { count = 0 }
	local ctx = {
		gestures = {
			get_sg_names = function() return { "#header", "lookup", "select_line" } end,
			get_action_label = function(id) return "Label:" .. id end,
		},
		updateMenu = function() updates.count = updates.count + 1 end,
	}
	return ctx, updates
end

--- Separates physical Add flows from the fixed contextual editor row.
--- @param shortcuts table Real shortcut facade.
--- @return table groups
local function physical_groups(shortcuts)
	local groups = {}
	for _, group in ipairs(shortcuts.get_keyboard_slot_groups()) do
		if not group.fixed then groups[#groups + 1] = group end
	end
	return groups
end

--- Finds the corresponding physical rows without depending on contextual placement.
--- @param rows table Complete group rows.
--- @param shortcuts table Real shortcut facade.
--- @return table physical
local function physical_rows(rows, shortcuts)
	local physical = {}
	for index, group in ipairs(shortcuts.get_keyboard_slot_groups()) do
		if not group.fixed then physical[#physical + 1] = rows[index] end
	end
	return physical
end

--- Loads the UI module together with a recording ActionPicker.
--- The picker is replaced rather than stubbed at the hs layer because these
--- cases are about WHAT is offered and what is done with the answer, not about
--- whether a webview opens.
--- @return table ui, table shortcuts, table picker
local function fresh()
	local files = helpers.load_with_stubs("core.fs.adapters.file_system")
	local read_resource = files.read_with_status
	local persisted = {}
	require("tests.support.keyboard_config_fixture").install(persisted)
	local read_config = files.read_with_status
	files.read_with_status = function(path, ...)
		if path == "keyboard-fixture-config" then return read_config(path, ...) end
		return read_resource(path, ...)
	end
	package.loaded["core.timing.engine.deferred_work"] = {
		after = function(_, callback)
			callback()
			return true
		end,
	}
	local ui = require("layouts.ui.menu.keyboard_slots")
	local shortcuts = require("shortcuts.engine")
	local picker = require("shortcuts.ui.action_picker")

	picker.opened = {}
	picker.open = function(opts, on_confirm)
		picker.opened[#picker.opened + 1] = { opts = opts, confirm = on_confirm }
	end

	return ui, shortcuts, picker, persisted
end

return {
	FIRST_KEY = FIRST_KEY,
	MODULES = MODULES,
	fresh = fresh,
	it = it,
	make_ctx = make_ctx,
	physical_groups = physical_groups,
	physical_rows = physical_rows,
}
