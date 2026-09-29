--- tests/unit/ui/menu/test_menu_tap_holds_karabiner_off.lua

--- ==============================================================================
--- MODULE: Tap-Holds Say Why They Are Unavailable
--- DESCRIPTION:
--- With « Ergopti uses Karabiner » off, the macOS tap-hold and chord rows are
--- greyed: nothing can deploy them. The submenu must say why, right above the
--- first greyed key row, so the user knows where to turn the integration back on.
--- ==============================================================================

local helpers = require("tests.helpers")

local HINT = "menu.tapholds.karabiner_off_hint"

--- Builds the Tap-Holds submenu over a remap double.
--- @param integration_enabled boolean « Ergopti uses Karabiner ».
--- @return table rows
local function tap_hold_rows(integration_enabled)
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
		MOD_COMBOS = {},
		NON_CANONICAL_COMBOS = {},
		get_enabled = function() return integration_enabled end,
		get_tap_holds_enabled = function() return true end,
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
	local built = menu.build({ karabiner = karabiner, updateMenu = function() end })
	helpers.assert_true(type(built) == "table" and type(built.submenu) == "table",
		"the Tap-Holds submenu must build")
	return built.submenu
end

helpers.describe("the macOS Tap-Holds submenu when Ergopti does not use Karabiner", function()
	helpers.it("draws a disabled hint right above the greyed key rows", function()
		local rows = tap_hold_rows(false)
		helpers.assert_eq(rows[1].title, "menu.tapholds.enable", "the switch stays the first row")
		local at = nil
		for index, row in ipairs(rows) do
			if row.title == HINT then at = index end
		end
		helpers.assert_true(at ~= nil, "the hint must be drawn")
		helpers.assert_true(rows[at].disabled == true, "the hint is a label, not an action")
		helpers.assert_nil(rows[at].fn)
		local key_at = nil
		for index, row in ipairs(rows) do
			if type(row.title) == "string" and row.title:find("Enter", 1, true) then key_at = index end
		end
		helpers.assert_true(key_at ~= nil, "the key row must be drawn")
		-- Only the keys section headers may sit between the hint and a key row
		helpers.assert_true(at < key_at,
			string.format("the hint must lead the key rows (hint %d, key %d)", at, key_at))
		for index = at + 1, key_at - 1 do
			helpers.assert_true(rows[index].disabled == true and rows[index].fn == nil,
				"only section headers may separate the hint from the keys: " .. tostring(rows[index].title))
		end
		helpers.assert_true(rows[key_at].disabled == true, "the key rows stay greyed")
	end)

	helpers.it("draws no hint while the integration is on", function()
		for _, row in ipairs(tap_hold_rows(true)) do
			helpers.assert_true(row.title ~= HINT, "an available engine needs no explanation")
		end
	end)
end)
