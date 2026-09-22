--- tests/unit/ui/menu/test_menu_tap_holds_feature_switch.lua

--- ==============================================================================
--- MODULE: The Tap-Holds Submenu Draws Its Feature Switch
--- DESCRIPTION:
--- The shared `tapholds_toggle` row reaches the macOS tray because this driver
--- registers its command. Clicking it switches the feature, persists it and
--- redeploys, without touching a single per-key assignment.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Remap double recording the switch and every assignment write.
--- @param observed table Mutable observation table.
--- @return table remap_double
local function remap_double(observed)
	return {
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200,
		DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "None", category = "Special", holdable = true, tappable = true },
		},
		TAP_HOLD_KEYS = { { id = "return_or_enter", label = "Enter" } },
		MOD_COMBOS = {},
		NON_CANONICAL_COMBOS = {},
		get_enabled = function() return true end,
		get_tap_holds_enabled = function() return observed.enabled end,
		set_tap_holds_enabled = function(value)
			observed.switch_writes[#observed.switch_writes + 1] = value
			observed.enabled = value
			return true
		end,
		regenerate = function(on_done)
			observed.regenerations = observed.regenerations + 1
			if on_done then on_done(true, "ready") end
			return true
		end,
		set_tap_action = function() error("the switch must not rewrite an assignment") end,
		set_hold_action = function() error("the switch must not rewrite an assignment") end,
		clear_all_bindings = function() error("the switch must not clear the bindings") end,
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
end

--- Finds the rendered switch row.
--- @param rows table Rendered submenu rows.
--- @return table|nil row
local function switch_row(rows)
	for _, row in ipairs(rows or {}) do
		if row.title == "menu.tapholds.on" or row.title == "menu.tapholds.off" then return row end
	end
	return nil
end

helpers.describe("the macOS Tap-Holds submenu draws its feature switch", function()
	helpers.it("renders the switch, checks the parent, and toggles it off then on", function()
		package.loaded["ui.menu.menu_tap_holds"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
		local observed = { enabled = true, switch_writes = {}, regenerations = 0 }
		local ctx = { karabiner = remap_double(observed), updateMenu = function() end }

		local built = menu.build(ctx)
		helpers.assert_eq(built.checked, true, "the parent row reports the switch")
		local row = switch_row(built.submenu)
		helpers.assert_true(row ~= nil, "the Tap-Holds submenu must draw its on/off row")
		helpers.assert_eq(row.title, "menu.tapholds.on")
		row.fn()
		helpers.assert_eq(observed.enabled, false)
		helpers.assert_eq(observed.regenerations, 1, "the switched rules must be redeployed")

		built = menu.build(ctx)
		helpers.assert_nil(built.checked)
		row = switch_row(built.submenu)
		helpers.assert_eq(row.title, "menu.tapholds.off")
		row.fn()
		helpers.assert_eq(observed.enabled, true, "re-enabling restores the feature")
		helpers.assert_eq(#observed.switch_writes, 2)
	end)
end)
