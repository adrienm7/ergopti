--- tests/unit/ui/menu/test_configured_shortcut_labels.lua

--- ==============================================================================
--- MODULE: Configured Shortcut Row Labels
--- DESCRIPTION:
--- Actual keyboard, tap-key and script-control providers must read each
--- binding's saved parameter and replace the translated marker in its row.
--- ==============================================================================

local helpers = require("tests.helpers")
local keyboard_binding = require("modules.shortcuts.keyboard_shortcuts").binding_id
local tap_binding = require("modules.shortcuts.tap_keys").binding_id
local script_prefix = require("modules.shortcuts.script_control").BINDING_PREFIX
local names = {
	"ui.menu.menu_keyboard_slots", "ui.menu.menu_tap_keys", "ui.menu.menu_shortcuts",
	"modules.shortcuts", "modules.shortcuts.tap_keys", "modules.shortcuts.bindings",
	"modules.shortcuts.actions.text", "infra.i18n", "infra.logger", "infra.manifest_menu",
	"infra.deferred_work", "adapters.input_source_broker", "ui.menu.menu_utils",
	"infra.paths", "menu.renderer",
}

helpers.describe("configured shortcut row labels", function()
	for _, surface in ipairs({ "keyboard", "tap", "script" }) do
		helpers.it("shows the saved parameter in the real " .. surface .. " provider", function()
			helpers.with_fresh_modules(names, function()
				local parameters = {
					[keyboard_binding("hs_ctrl_a")] = "https://keyboard.example/?q=[x]&p=50%",
					[tap_binding("number_row_left")] = "https://tap.example",
					[script_prefix .. "script_altgr_enter"] = "https://script.example",
				}
				local reads = {}
				local gestures = {
					is_assignable = function() return true end,
					get_action_label = function(action) return action == "open_url" and "Open [configurable]" or action end,
					get_action_parameter = function(binding, action)
						helpers.assert_eq(action, "open_url")
						reads[#reads + 1] = binding
						return parameters[binding] or ""
					end,
				}
				local shortcuts = {
					DEFAULT_STATE = { shortcuts = true },
					get_keyboard_slot_groups = function() return { { prefix = "hs_ctrl_", group_key = "menu.shortcuts.ctrl_group", add_key = "menu.shortcuts.ctrl_add" } } end,
					assigned_keyboard_slots = function() return { { id = "hs_ctrl_a", action = "open_url" } } end,
					get_keyboard_slot_label = function() return "Ctrl+A" end,
					keyboard_binding_id = keyboard_binding,
				}
				package.loaded["modules.shortcuts"] = shortcuts
				package.loaded["modules.shortcuts.tap_keys"] = {
					ensure_loaded = function() end, keys = function() return { { id = "number_row_left" } } end,
					get_action = function() return "open_url" end, display_name = function() return "Left" end,
					binding_id = tap_binding,
				}
				package.loaded["modules.shortcuts.bindings"] = {}
				package.loaded["modules.shortcuts.actions.text"] = {}
				package.loaded["infra.i18n"] = {
					get = function(key) return key:find("right_opt", 1, true) and "%s" or key end,
					section = function(key) return key end,
					decorate_section = function(label) return label end,
				}
				package.loaded["infra.logger"] = helpers.make_logger_stub()
				package.loaded["infra.deferred_work"] = {}
				package.loaded["adapters.input_source_broker"] = { subscribe = function() return true end }
				package.loaded["ui.menu.menu_utils"] = {}
				package.loaded["infra.paths"] = { shared = helpers.shared }
				-- The Shortcuts submenu opens the script chords' group, whose rows
				-- are its provider's.
				local actual_manifest = require("infra.manifest_menu")
				package.loaded["infra.manifest_menu"] = {
					template_rows = actual_manifest.template_rows,
					build = function(key, _, _, groups, _, providers)
						if key == "shortcuts_menu" then return groups.script_control() end
						return providers.script_control_shortcuts()
					end,
				}
				local ctx = { gestures = gestures, shortcuts = shortcuts, updateMenu = function() end,
					state = { shortcuts = true, script_control_enabled = true,
						script_control_shortcuts = { script_altgr_enter = "open_url", script_altgr_backspace = "none",
							script_altgr_delete = "none", script_altgr_escape = "none" } },
					script_control = { ACTIONS = { "none", "open_url" }, SCRIPT_BINDING_PREFIX = script_prefix,
						script_chord_slots = function()
							return { { id = "script_altgr_enter" }, { id = "script_altgr_backspace" },
								{ id = "script_altgr_delete" }, { id = "script_altgr_escape" } }
						end } }
				local label, expected
				if surface == "keyboard" then
					label = require("ui.menu.menu_keyboard_slots").provide_rows(ctx)[1].items[1].label
					expected = parameters[keyboard_binding("hs_ctrl_a")]
				elseif surface == "tap" then
					label = require("ui.menu.menu_tap_keys").provide_rows(ctx)[1].label
					expected = parameters[tap_binding("number_row_left")]
				else
					local menu = require("ui.menu.menu_shortcuts").build(ctx)
					label = menu.submenu[1].label
					expected = parameters[script_prefix .. "script_altgr_enter"]
				end
				helpers.assert_true(label:find("Open [" .. expected .. "]", 1, true) ~= nil, label)
				helpers.assert_true(label:find("[configurable]", 1, true) == nil, label)
				helpers.assert_true(#reads > 0, "the real provider must consult the binding owner")
			end)
		end)
	end
end)
