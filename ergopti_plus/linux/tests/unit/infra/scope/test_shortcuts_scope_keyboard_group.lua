--- tests/unit/infra/scope/test_shortcuts_scope_keyboard_group.lua

--- ==============================================================================
--- MODULE: Regression — each modifier group restores and clears its own slots
--- DESCRIPTION:
--- The keyboard-slot groups (Ctrl, Ctrl+Shift, Alt, Super) listed their slots
--- and nothing else: putting one group back to Ergopti's preset or emptying it
--- took one picker per slot. Each group now opens with « ↺ Restaurer les
--- valeurs conseillées » and « ✕ Tout effacer », the Shortcuts scope narrowed
--- to that group's slots and their parameters. This applies both through the
--- real scope owner, then clicks them in the real tray.
--- ==============================================================================

package.loaded["tests.support.infra.scope.shortcuts_scope_fixture"] = nil
local Fixture = require("tests.support.infra.scope.shortcuts_scope_fixture")
local helpers, declared_parent, Sandbox, Codec, with_scope =
	Fixture.helpers, Fixture.declared_parent, Fixture.Sandbox, Fixture.Codec, Fixture.with_scope

local SOURCE = '[shortcuts]\nenabled = true\n'
	.. '[shortcuts.keyboard]\nctrl_j = "open_url"\nctrl_k = "enter"\nsuper_j = "enter"\nalt_k = "enter"\nforeign_slot = "keep"\n'
	.. '[shortcuts.tap_keys]\nnumber_row_left = "send_text"\n'
	.. '[gesture_parameters]\nkeyboard__ctrl_j__open_url = "https://ctrl.example"\n'
	.. 'tap_3__open_url = "https://gesture.example"\n'
	.. '[other]\nvalue = 42\n'

--- A scope owner narrowed to the Ctrl group, on the fixture's file.
local function ctrl_group(controls, path, backup)
	return require("infra.shortcuts_scope").new({ path = path, backup_path = backup .. ".ctrl",
		files = controls.files, is_paused = function() return controls.paused end, only = "keyboard_group:ctrl_" })
end

helpers.describe("Linux keyboard group scope", function()
	helpers.it("the group's clear empties its slots and parameters and leaves the other groups", function()
		with_scope(function(_, owners, controls, path, backup)
			helpers.assert_true(ctrl_group(controls, path, backup).apply("clear"))
			local config = Codec.decode(Sandbox.read_bytes(path))
			local keyboard = config.shortcuts.keyboard or {}
			helpers.assert_eq(keyboard.ctrl_j, nil, "a Ctrl slot is emptied")
			helpers.assert_eq(keyboard.ctrl_k, nil, "a Ctrl slot is emptied")
			helpers.assert_eq(config.gesture_parameters.keyboard__ctrl_j__open_url, nil, "its parameter goes with it")
			helpers.assert_eq(keyboard.super_j, "enter", "the Super group is untouched")
			helpers.assert_eq(keyboard.alt_k, "enter", "the Alt group is untouched")
			helpers.assert_eq(keyboard.foreign_slot, "keep", "an unknown key stays")
			helpers.assert_eq(config.shortcuts.tap_keys.number_row_left, "send_text", "the tap keys are untouched")
			helpers.assert_eq(config.gesture_parameters.tap_3__open_url, "https://gesture.example")
			helpers.assert_eq(config.other.value, 42)
			helpers.assert_eq(owners.keyboard.get_action("ctrl_j") or "none", "none")
			helpers.assert_eq(owners.keyboard.get_action("super_j"), "enter")
			os.remove(backup .. ".ctrl")
		end, SOURCE)
	end)

	helpers.it("the group's restore brings its shipped slot back and removes the user's additions", function()
		with_scope(function(_, owners, controls, path, backup)
			helpers.assert_true(ctrl_group(controls, path, backup).apply("recommended"))
			local config = Codec.decode(Sandbox.read_bytes(path))
			local keyboard = config.shortcuts.keyboard or {}
			helpers.assert_eq(keyboard.ctrl_j, nil, "a user Ctrl slot is removed")
			helpers.assert_eq(keyboard.ctrl_g, "open_chatgpt", "the shipped Ctrl+G slot takes its recommended action")
			helpers.assert_eq(keyboard.super_j, "enter", "the Super group is untouched")
			helpers.assert_eq(keyboard.super_space, nil, "another group's preset is not applied")
			helpers.assert_eq(owners.keyboard.get_action("ctrl_g"), "open_chatgpt")
			os.remove(backup .. ".ctrl")
		end, SOURCE)
	end)

	helpers.it("refuses a narrowing that names no bindable group", function()
		with_scope(function(_, _, controls, path, backup)
			for _, only in ipairs({ "keyboard_group:contextual", "keyboard_group:nope_", "keyboard" }) do
				local built = pcall(require("infra.shortcuts_scope").new, { path = path, backup_path = backup,
					files = controls.files, is_paused = function() return false end, only = only })
				helpers.assert_eq(built, false, only)
			end
		end, SOURCE)
	end)

	helpers.it("each bindable group of the tray opens with its restore and clear, which ask nothing", function()
		with_scope(function(_, _, controls, path)
			local renderer = require("infra.manifest_menu")
			local root = renderer.get_root()
			local top, execute = root.top_level, os.execute
			local questions, changed = 0, 0
			-- The contextual slot reads the physical magic-key source: this test
			-- owns it rather than inheriting another test's initialized owner.
			local saved_source = package.loaded["modules.hotstrings.magic_key_source"]
			local saved_magic = package.loaded["modules.hotstrings.magic_key"]
			package.loaded["modules.hotstrings.magic_key_source"] = {
				editor_source = function() return { generation = 1, status = "unavailable", candidates = {} } end,
				known_codes = function() return {} end,
			}
			package.loaded["modules.hotstrings.magic_key"] = { get = function() return "★" end, is_customised = function() return false end }
			local passed, err = pcall(function()
				root.top_level = declared_parent(top, "shortcuts")
				os.execute = function(command)
					if command:find("command -v zenity", 1, true) then return 0 end
					if command:find("zenity --question", 1, true) then questions = questions + 1; return 1 end
					return execute(command)
				end
				local i18n = require("infra.i18n")
				local function groups()
					local menu = require("ui.menu.menu_builder").build({ shortcuts = require("modules.shortcuts.manager"),
						paused = false, is_paused = function() return controls.paused end,
						on_menu_changed = function() changed = changed + 1 end })
					local found = {}
					for _, item in ipairs(menu) do
						if item.title == i18n.get("menu.shortcuts.title") then
							for _, row in ipairs(item.menu or {}) do found[row.title] = row end
						end
					end
					return found
				end
				local drawn = groups()
				for _, key in ipairs({ "menu.shortcuts.ctrl_group", "menu.shortcuts.ctrl_shift_group",
					"menu.shortcuts.alt_group", "menu.shortcuts.super_group" }) do
					local row = drawn[i18n.get(key)]
					helpers.assert_eq(type(row), "table", key .. " is drawn")
					helpers.assert_eq(row.menu[1].title, i18n.get("common.restore_recommended"), key)
					helpers.assert_eq(row.menu[2].title, i18n.get("common.clear_to_system"), key)
					helpers.assert_eq(row.menu[3].title, "-", key)
				end
				local contextual = drawn[i18n.get("menu.shortcuts.group_contextual")]
				if contextual then
					helpers.assert_true(contextual.menu[1].title ~= i18n.get("common.restore_recommended"),
						"the contextual slot has no modifier group to restore")
				end
				drawn[i18n.get("menu.shortcuts.ctrl_group")].menu[2].fn()
				helpers.assert_eq(questions, 0, "the group's clear asks nothing")
				local keyboard = Codec.decode(Sandbox.read_bytes(path)).shortcuts.keyboard or {}
				helpers.assert_eq(keyboard.ctrl_j, nil)
				helpers.assert_eq(keyboard.super_j, "enter")
				groups()[i18n.get("menu.shortcuts.super_group")].menu[1].fn()
				helpers.assert_eq(questions, 0, "the group's restore asks nothing")
				keyboard = Codec.decode(Sandbox.read_bytes(path)).shortcuts.keyboard or {}
				helpers.assert_eq(keyboard.super_j, nil, "a user Super slot is removed")
				helpers.assert_eq(keyboard.super_space, "llm_generate_prediction")
				helpers.assert_eq(changed, 2)
			end)
			root.top_level, os.execute = top, execute
			package.loaded["modules.hotstrings.magic_key_source"] = saved_source
			package.loaded["modules.hotstrings.magic_key"] = saved_magic
			if not passed then error(err, 0) end
		end, SOURCE)
	end)
end)
