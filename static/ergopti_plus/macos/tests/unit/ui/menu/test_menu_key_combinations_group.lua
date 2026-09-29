--- tests/unit/ui/menu/test_menu_key_combinations_group.lua

--- ==============================================================================
--- MODULE: « Combinaisons de touches » Under Shortcuts
--- DESCRIPTION:
--- The modifier combinations left the Tap-Holds submenu for their own group
--- under Shortcuts: a first-row switch (the persisted [mod_combos] enabled),
--- the symmetry check, the chord delay, the tap → chord copy and one row per
--- pair whose three slots say what each one waits for.
---
--- ROOT CAUSE ENCODED:
--- the pairs, their delay, symmetry and bulk copy sat in the Tap-Holds submenu
--- under « Raccourcis modificateurs », switched by the Tap-Holds switch, and
--- their slots read « Combo », « Tap » and « Hold », which did not say that
--- the last two mean « hold key 1, then tap or hold key 2 ».
--- ==============================================================================

local helpers = require("tests.helpers")

--- A remap double recording the switch writes and the regenerations.
--- @param observed table Mutable observation table.
--- @return table
local function remap_double(observed)
	return {
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200,
		DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "None", category = "Spécial", holdable = true, tappable = true },
		},
		TAP_HOLD_KEYS = { { id = "left_shift", label = "Left Shift" } },
		MOD_COMBOS = { { id = "shift_pair", label = "Shift pair", group = "Shift" } },
		NON_CANONICAL_COMBOS = {},
		get_enabled = function() return true end,
		get_tap_holds_enabled = function() return true end,
		get_mod_combos_enabled = function() return observed.combos end,
		set_mod_combos_enabled = function(value)
			observed.writes[#observed.writes + 1] = value
			observed.combos = value
			return true
		end,
		regenerate = function(on_done)
			observed.regenerations = observed.regenerations + 1
			if on_done then on_done(true, "ready") end
			return true
		end,
		get_combo_symmetric = function() return false end,
		get_tap_action = function() return "none" end,
		get_hold_action = function() return "none" end,
		get_tap_timeout = function() return nil end,
		get_combo_combo_action = function() return "none" end,
		get_combo_tap_action = function() return "none" end,
		get_combo_hold_action = function() return "none" end,
		get_tap_hold_timeout = function() return 200 end,
		get_sticky_timeout = function() return 1000 end,
		get_simultaneous_threshold = function() return 50 end,
	}
end

--- Every title of a rendered tree, depth first.
--- @param rows table
--- @param out table|nil
--- @return table
local function titles(rows, out)
	out = out or {}
	for _, row in ipairs(rows or {}) do
		if type(row.title) == "string" then out[#out + 1] = row.title end
		titles(row.menu, out)
	end
	return out
end

--- Whether any title starts with `prefix`.
--- @param list table
--- @param prefix string
--- @return boolean
local function has_prefix(list, prefix)
	for _, title in ipairs(list) do
		if title:sub(1, #prefix) == prefix then return true end
	end
	return false
end

helpers.describe("the key combinations are a group of their own under Shortcuts", function()
	helpers.it("opens with its own switch, which persists and redeploys", function()
		local observed = { combos = true, writes = {}, regenerations = 0 }
		local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
		local group = menu.build_key_combinations({ karabiner = remap_double(observed), updateMenu = function() end })
		helpers.assert_not_nil(group, "the group is built")
		local first = group[1]
		helpers.assert_eq(first.title, "menu.shortcuts.key_combinations_enable", "the first row is the switch")
		helpers.assert_eq(first.checked, true, "ticked while the combinations are on")
		first.fn()
		helpers.assert_eq(observed.writes[1], false, "a click turns them off")
		helpers.assert_eq(observed.regenerations, 1, "the rules are redeployed")

		local all = titles(group)
		for _, key in ipairs({ "menu.tapholds.symmetric", "menu.tapholds.copy_tap_to_combo" }) do
			helpers.assert_true(has_prefix(all, key), key .. " is in the group")
		end
		helpers.assert_true(has_prefix(all, "menu.tapholds.simultaneous_title"), "the chord delay is in the group")
		helpers.assert_true(has_prefix(all, "Shift pair  :"), "every pair has its row")
		for _, key in ipairs({ "menu.shortcuts.key_combinations_chord",
			"menu.shortcuts.key_combinations_hold_tap", "menu.shortcuts.key_combinations_hold_hold" }) do
			helpers.assert_true(has_prefix(all, key), "each pair spells out its slot: " .. key)
		end
	end)

	helpers.it("leaves no combination row in the Tap-Holds submenu", function()
		local observed = { combos = true, writes = {}, regenerations = 0 }
		local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
		local built = menu.build({ karabiner = remap_double(observed), updateMenu = function() end })
		local all = titles(built.submenu)
		helpers.assert_true(has_prefix(all, "tap_hold.group.left_shift  :"), "the key rows are still there")
		for _, prefix in ipairs({ "Shift pair", "menu.tapholds.symmetric", "menu.tapholds.copy_tap_to_combo",
			"menu.tapholds.simultaneous_title", "— menu.tapholds.header_shortcuts —" }) do
			helpers.assert_eq(has_prefix(all, prefix), false, "moved out of Tap-Holds: " .. prefix)
		end
		helpers.assert_true(has_prefix(all, "menu.tapholds.tap_hold_title"), "the tap / hold delay stays")
		helpers.assert_true(has_prefix(all, "menu.tapholds.sticky_title"), "the sticky delay stays")
	end)
end)
