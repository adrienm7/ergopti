--- tests/unit/ui/menu/shortcuts/test_keyboard_group_scope.lua

--- ==============================================================================
--- MODULE: Regression — each modifier group restores and clears its own slots
--- DESCRIPTION:
--- The keyboard-slot groups (Option, Ctrl, Ctrl+Shift, Cmd, Cmd+Shift) only
--- offered their Add row: putting one group back to Ergopti's preset or
--- emptying it took one picker per slot. Each group now opens with
--- « ↺ Restaurer les valeurs conseillées » and « ✕ Tout effacer », the
--- Shortcuts scope narrowed to that group's slots and their parameters. This
--- applies both through the real scope owner, then renders the real submenu.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.shortcuts_scope_fixture")
local Codec = require("toml_codec")

local SOURCE = '[shortcuts]\nenabled = true\n'
	.. 'keyboard = { cmd_a = "send_text", hs_ctrl_x = "send_text", hs_ctrl_space = "send_text" }\n'
	.. '[gestures]\naction_parameters = { keyboard__cmd_a__send_text = "cmd", keyboard__hs_ctrl_x__send_text = "ctrl" }\n'

--- The select of the Ctrl group, built the way the menu builds it.
--- @param keyboard table The fixture's keyboard registry.
--- @return function select
local function ctrl_group(keyboard)
	local ids = {}
	for _, slot in ipairs(keyboard.available_slots("hs_ctrl_")) do ids[#ids + 1] = slot.id end
	return require("ui.menu.shortcuts_scope").keyboard_group_rows(ids, keyboard.binding_id)
end

helpers.describe("macOS keyboard group scope", function()
	helpers.it("the group's clear empties its slots and parameters and leaves the other groups", function()
		Fixture.run(function(f)
			local committed, detail = f.owner.apply("clear", ctrl_group(f.keyboard))
			helpers.assert_eq(committed, true, detail)
			local decoded = Codec.decode(f.files.config)
			helpers.assert_nil(decoded.shortcuts.keyboard.hs_ctrl_x, "a user Ctrl slot is removed")
			helpers.assert_nil(decoded.shortcuts.keyboard.hs_ctrl_space, "a shipped Ctrl slot is emptied")
			helpers.assert_nil(decoded.gestures.action_parameters.keyboard__hs_ctrl_x__send_text)
			helpers.assert_eq(decoded.shortcuts.keyboard.cmd_a, "send_text", "the Cmd group is untouched")
			helpers.assert_eq(decoded.gestures.action_parameters.keyboard__cmd_a__send_text, "cmd")
			helpers.assert_eq(f.keyboard.get_action("hs_ctrl_space"), "none")
			helpers.assert_eq(f.keyboard.get_action("cmd_a"), "send_text")
		end, SOURCE)
	end)

	helpers.it("the group's restore brings its shipped slot back and removes the user's additions", function()
		Fixture.run(function(f)
			local committed, detail = f.owner.apply("recommended", ctrl_group(f.keyboard))
			helpers.assert_eq(committed, true, detail)
			local decoded = Codec.decode(f.files.config)
			helpers.assert_nil(decoded.shortcuts.keyboard.hs_ctrl_x, "a user Ctrl slot is removed")
			helpers.assert_eq(decoded.shortcuts.keyboard.hs_ctrl_space, "llm_generate_prediction",
				"the shipped Ctrl+Space slot takes its recommended action")
			helpers.assert_eq(decoded.shortcuts.keyboard.cmd_a, "send_text", "the Cmd group is untouched")
			helpers.assert_eq(decoded.gestures.action_parameters.keyboard__cmd_a__send_text, "cmd")
			helpers.assert_eq(f.keyboard.get_action("hs_ctrl_space"), "llm_generate_prediction")
		end, SOURCE)
	end)
end)

--- Renders the real Shortcuts submenu with a recording group scope port.
--- @param calls table Receives { prefix, mode } per click.
--- @return table rows
local function render_shortcuts_submenu(calls)
	local shortcuts = helpers.load_with_stubs("ui.menu.menu_shortcuts")
	local ManifestMenu = require("infra.manifest_menu")
	local item = shortcuts.build({
		state      = { shortcuts = true },
		save_prefs = function() return true end,
		updateMenu = function() end,
		applyTriggerChar = function(text) return text end,
		apply_keyboard_group_scope = function(prefix, mode)
			calls[#calls + 1] = { prefix = prefix, mode = mode }
			return true
		end,
		shortcuts  = {
			list_shortcuts = function() return {} end,
			is_enabled            = function() return true end,
			set_wrap_pairs_getter = function() end,
		},
	})
	local row = ManifestMenu.render_rows({ item }, "top_level")[1]
	helpers.assert_true(type(row) == "table" and type(row.menu) == "table", "Shortcuts must render a submenu")
	return row.menu
end

helpers.describe("macOS keyboard group submenus open with their restore and clear", function()
	helpers.it("every bindable modifier group starts with restore, clear and a separator", function()
		local calls = {}
		local rows = render_shortcuts_submenu(calls)
		local seen = 0
		for _, group in ipairs({
			{ key = "menu.shortcuts.alt_group", prefix = "hs_option_" },
			{ key = "menu.shortcuts.ctrl_group", prefix = "hs_ctrl_" },
			{ key = "menu.shortcuts.ctrl_shift_group", prefix = "hs_ctrl_shift_" },
			{ key = "menu.shortcuts.cmd_group", prefix = "cmd_" },
			{ key = "menu.shortcuts.cmd_shift_group", prefix = "cmd_shift_" },
		}) do
			for _, entry in ipairs(rows) do
				if entry.title == group.key then
					seen = seen + 1
					local menu = entry.menu
					helpers.assert_true(type(menu) == "table" and #menu >= 4, group.key .. " must render its rows")
					helpers.assert_true(menu[1].title:find("common.restore_recommended", 1, true) == 1,
						group.key .. " opens with its restore, got " .. tostring(menu[1].title))
					helpers.assert_true(menu[2].title:find("common.clear_to_system", 1, true) == 1,
						group.key .. " follows with its clear, got " .. tostring(menu[2].title))
					helpers.assert_eq(menu[3].title, "-", group.key .. " closes its first group")
					local before = #calls
					menu[1].fn()
					menu[2].fn()
					helpers.assert_eq(#calls, before + 2, group.key .. " rows reach the scope port")
					helpers.assert_eq(calls[before + 1].prefix, group.prefix)
					helpers.assert_eq(calls[before + 1].mode, "recommended")
					helpers.assert_eq(calls[before + 2].prefix, group.prefix)
					helpers.assert_eq(calls[before + 2].mode, "clear")
				end
			end
		end
		helpers.assert_eq(seen, 5, "the five bindable modifier groups are drawn")
	end)
end)
