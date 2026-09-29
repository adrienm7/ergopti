--- tests/unit/ui/menu/test_menu_tap_holds_karabiner_off.lua

--- ==============================================================================
--- MODULE: Tap-Holds Say Why They Are Unavailable
--- DESCRIPTION:
--- With « Ergopti uses Karabiner » off, the macOS tap-hold and chord rows are
--- greyed: nothing can deploy them. The Tap-Holds submenu must say why, right
--- above the greyed key rows, and the key-combinations group under Shortcuts
--- again above its chord rows, so the user knows where to turn the integration
--- back on.
--- ==============================================================================

local helpers = require("tests.helpers")

local HINT = "menu.tapholds.karabiner_off_hint"

--- Loads the menu module over a fresh picker cache and a remap double.
--- @param integration_enabled boolean « Ergopti uses Karabiner ».
--- @return table menu
--- @return table karabiner
local function menu_over_double(integration_enabled)
	package.loaded["ui.menu.menu_tap_holds"] = nil
	local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
	menu._reset_picker_cache()
	local karabiner = {
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200,
		DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "None", category = "Special", holdable = true, tappable = true },
		},
		TAP_HOLD_KEYS = { { id = "return_or_enter", label = "Enter" } },
		MOD_COMBOS = { { id = "left_shift+right_shift", label = "Shift chord", group = "Shift" } },
		NON_CANONICAL_COMBOS = {},
		get_enabled = function() return integration_enabled end,
		get_tap_holds_enabled = function() return true end,
		get_mod_combos_enabled = function() return true end,
		get_combo_symmetric = function() return false end,
		get_tap_action = function() return "tab" end,
		get_hold_action = function() return "none" end,
		get_tap_timeout = function() return nil end,
		get_combo_combo_action = function() return "none" end,
		get_combo_tap_action = function() return "none" end,
		get_combo_hold_action = function() return "none" end,
		get_tap_hold_timeout = function() return 200 end,
		get_sticky_timeout = function() return 1000 end,
		get_simultaneous_threshold = function() return 50 end,
	}
	return menu, karabiner
end

--- Builds the Tap-Holds submenu over a remap double.
--- @param integration_enabled boolean « Ergopti uses Karabiner ».
--- @return table rows
local function tap_hold_rows(integration_enabled)
	local menu, karabiner = menu_over_double(integration_enabled)
	local built = menu.build({ karabiner = karabiner, updateMenu = function() end })
	helpers.assert_true(type(built) == "table" and type(built.submenu) == "table",
		"the Tap-Holds submenu must build")
	return built.submenu
end

--- Builds the key-combinations group of the Shortcuts submenu, where the chord
--- rows live, over the same remap double.
--- @param integration_enabled boolean « Ergopti uses Karabiner ».
--- @return table rows
local function key_combination_rows(integration_enabled)
	local menu, karabiner = menu_over_double(integration_enabled)
	local rows = menu.build_key_combinations({ karabiner = karabiner, updateMenu = function() end })
	helpers.assert_true(type(rows) == "table", "the key-combinations group must build")
	return rows
end

--- Asserts a disabled hint leads the greyed row whose title contains `needle`.
--- @param rows table Rendered submenu rows.
--- @param needle string Plain substring of the greyed row's title.
local function assert_hint_leads(rows, needle)
	local target = nil
	for index, row in ipairs(rows) do
		if type(row.title) == "string" and row.title:find(needle, 1, true) then target = index end
	end
	helpers.assert_true(target ~= nil, "the row must be drawn: " .. needle)
	helpers.assert_true(rows[target].disabled == true, "the row stays greyed: " .. needle)
	local at = target - 1
	-- Only section headers may sit between the hint and the rows it explains
	while at > 0 and rows[at].title ~= HINT do
		helpers.assert_true(rows[at].disabled == true and rows[at].fn == nil,
			"only section headers may separate the hint from " .. needle .. ": " .. tostring(rows[at].title))
		at = at - 1
	end
	helpers.assert_true(at > 0, "a hint must lead the greyed rows: " .. needle)
	helpers.assert_true(rows[at].disabled == true, "the hint is a label, not an action")
	helpers.assert_nil(rows[at].fn)
end

helpers.describe("the macOS Tap-Holds submenu when Ergopti does not use Karabiner", function()
	helpers.it("draws a disabled hint right above the greyed key rows", function()
		local rows = tap_hold_rows(false)
		helpers.assert_eq(rows[1].title, "menu.tapholds.enable", "the switch stays the first row")
		assert_hint_leads(rows, "Enter")
	end)

	helpers.it("draws the hint above the greyed chord rows, in their Shortcuts group", function()
		assert_hint_leads(key_combination_rows(false), "Shift chord")
	end)

	helpers.it("draws no hint while the integration is on", function()
		for _, rows in ipairs({ tap_hold_rows(true), key_combination_rows(true) }) do
			for _, row in ipairs(rows) do
				helpers.assert_true(row.title ~= HINT, "an available engine needs no explanation")
			end
		end
	end)
end)
