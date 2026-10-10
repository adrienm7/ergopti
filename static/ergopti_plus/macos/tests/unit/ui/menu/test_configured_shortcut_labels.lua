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
					group_receiver = actual_manifest.group_receiver,
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


-- Actual catalogues contain headings and actions, never the retired boundary tokens.
local catalogue_scope = require("tests.support.layout_legacy_caption_fixture").scoped
helpers.describe("real script-action catalogue projection", function()
	for _, language in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		helpers.it("preserves every genuine script action and heading in " .. language, catalogue_scope(function()
			-- Establish the existing controlled native environment before publishing translation.
			helpers.load_with_stubs("action_parameter_label")
			local Json = require("adapters.json_codec")
			local function read(relative)
				local file = assert(io.open(helpers.shared(relative), "rb"))
				local bytes = assert(file:read("*a")); assert(file:close())
				return assert(Json.decode(bytes))
			end
			local expected = read("tests/corpus/menus/script_action_original_catalogue_projection.json").locales[language].rows
			local dictionary = read("data/locales/" .. language .. ".json")
			local translator = package.loaded["infra.i18n"]
			translator.get = function(key) return dictionary[key] or key end
			translator.format = function(key, ...)
				local result, args = translator.get(key), table.pack(...)
				for n = 1, args.n do result = result:gsub("{" .. n .. "}", function() return tostring(args[n]) end) end
				return result
			end
			translator.section = function(key) return translator.decorate_section(translator.get(key)) end
			package.loaded["modules.gestures.actions"], package.loaded["modules.shortcuts.script_control"] = nil, nil
			local actions = require("modules.gestures.actions")
			local script = require("modules.shortcuts.script_control")
			helpers.assert_eq(script.ACTIONS, actions.SG_NAMES)
			helpers.assert_eq(#script.ACTIONS, 826)
			for index, row in ipairs(expected) do
				helpers.assert_eq(script.ACTIONS[index], row[1], "genuine catalogue order " .. index)
				helpers.assert_true(row[1] ~= "-" and row[1] ~= "--", "original catalogue has no retired token")
			end
			package.loaded["infra.manifest_menu"] = nil
			local actual = require("infra.manifest_menu")
			local captured, frame
			package.loaded["infra.manifest_menu"] = {
				group_receiver = actual.group_receiver, template_rows = actual.template_rows,
				build = function(key, category, dynamic, groups, context, providers)
					if key == "shortcuts_menu" then return groups.script_control() end
					if key == "script_control_group" then
						local provider = providers.script_control_shortcuts
						providers.script_control_shortcuts = function() captured = provider(); return captured end
					end
					local rows = actual.build(key, category, dynamic, groups, context, providers)
					if key == "script_control_group" then frame = rows end
					return rows
				end,
			}
			local published, saves, updates = {}, 0, 0
			local control = { ACTIONS = script.ACTIONS, SCRIPT_BINDING_PREFIX = script.BINDING_PREFIX,
				script_chord_slots = script.slots,
				set_shortcut_action = function(slot, action) published[#published + 1] = { slot, action }; return true end }
			local state = { shortcuts = true, script_control_enabled = true, script_control_shortcuts = {} }
			for _, slot in ipairs(control.script_chord_slots()) do state.script_control_shortcuts[slot.id] = "none" end
			local gesture_exports = { get_action_label = actions.get_label,
				get_action_parameter = actions.get_action_parameter, get_action_parameter_spec = actions.get_action_parameter_spec }
			local context = { gestures = gesture_exports, shortcuts = {}, script_control = control, state = state,
				save_prefs = function() saves = saves + 1; return true end,
				updateMenu = function() updates = updates + 1 end }
			package.loaded["ui.menu.menu_shortcuts"] = nil
			local owner = require("ui.menu.menu_shortcuts")
			for _, paused in ipairs({ false, true }) do
				context.paused = paused
				helpers.assert_true(owner.build(context) ~= nil, "actual canonical parent receives its finished frame")
				local boundaries = 0
				for _, row in ipairs(frame) do if row.title == "-" then boundaries = boundaries + 1 end end
				helpers.assert_eq(boundaries, 1, "the genuine declared controls/slots separator survives")
				helpers.assert_eq(#captured, #control.script_chord_slots())
				for _, slot in ipairs(captured) do
					helpers.assert_eq(#slot.items, #expected)
					for index, row in ipairs(slot.items) do
						local original = expected[index]
						helpers.assert_eq(row.label, original[2], "original native projection " .. index)
						helpers.assert_nil(row.separator, "no genuine action becomes an invented boundary")
						if original[3] == "heading" then
							helpers.assert_eq(row.disabled, true); helpers.assert_nil(row.action)
						else
							helpers.assert_eq(row.disabled == true, paused)
							helpers.assert_eq(type(row.action), paused and "nil" or "function")
							helpers.assert_eq(row.checked == true, original[1] == "none")
						end
					end
				end
			end
			context.paused = false; owner.build(context)
			for index, row in ipairs(expected) do
				if row[1] == "save" then
					captured[1].items[index].action()
					helpers.assert_eq(saves, 1); helpers.assert_eq(updates, 1)
					helpers.assert_eq(published[1], { control.script_chord_slots()[1].id, "save" })
					helpers.assert_eq(state.script_control_shortcuts[control.script_chord_slots()[1].id], "save")
				end
			end
		end))
	end
end)
