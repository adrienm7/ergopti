--- tests/unit/ui/menu/tap_holds/test_menu_tap_holds_owned_runtime.lua

--- ==============================================================================
--- MODULE: Tap-Holds Rows Of Ergopti's Own Karabiner Runtime
--- DESCRIPTION:
--- With Ergopti's own Karabiner runtime, the Tap-Holds submenu says what the
--- runtime did to the user's Mac: that their Karabiner-Elements is closed while
--- Ergopti runs and comes back on pause or quit, and why the runtime cannot run
--- when the one-driver-version rule of the VirtualHIDDevice blocks it.
---
--- ROOT CAUSE ENCODED: a user whose Karabiner disappeared while Ergopti ran, or
--- whose tap-holds stopped because of a driver conflict, had only the log to
--- learn why.
--- ==============================================================================

local helpers = require("tests.helpers")

local LABEL = "notify.karabiner.user_closed"

--- Loads the menu module over a fresh picker cache and a remap double.
--- @param integration_enabled boolean « Ergopti uses Karabiner ».
--- @param extra table|nil Facade fields added to the double.
--- @return table menu
--- @return table karabiner
local function menu_over_double(integration_enabled, extra)
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
		-- A left-hand key of the shared catalogue: its row sits right under the
		-- first hand header, where the hint belongs. Rows are labelled from the
		-- catalogue's label keys, not from this double's label.
		TAP_HOLD_KEYS = { { id = "tab", label = "Tab" } },
		MOD_COMBOS = { { id = "left_shift+right_shift", label = "Shift chord", group = "Shift",
			from = { simultaneous = { { key_code = "left_shift" }, { key_code = "right_shift" } } } } },
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
	for name, value in pairs(extra or {}) do karabiner[name] = value end
	return menu, karabiner
end

--- Builds the Tap-Holds submenu over a remap double.
--- @param integration_enabled boolean « Ergopti uses Karabiner ».
--- @param extra table|nil Facade fields added to the double.
--- @return table rows
local function tap_hold_rows(integration_enabled, extra)
	local menu, karabiner = menu_over_double(integration_enabled, extra)
	local built = menu.build({ karabiner = karabiner, updateMenu = function() end })
	helpers.assert_true(type(built) == "table" and type(built.submenu) == "table",
		"the Tap-Holds submenu must build")
	return built.submenu
end

--- Finds the closed-Karabiner row.
--- @param rows table Rendered submenu rows.
--- @return table|nil row
local function consent_row(rows)
	for _, row in ipairs(rows) do
		if row.title == LABEL then return row end
	end
	return nil
end

helpers.describe("Tap-Holds: Ergopti's own Karabiner runtime", function()
	helpers.it("says the user's Karabiner is closed only while Ergopti holds it closed", function()
		helpers.assert_nil(consent_row(tap_hold_rows(true)))
		helpers.assert_nil(consent_row(tap_hold_rows(true, { user_karabiner_closed = function() return false end })))
		local row = consent_row(tap_hold_rows(true, { user_karabiner_closed = function() return true end }))
		helpers.assert_true(row ~= nil, "the closed-Karabiner row must be drawn")
		helpers.assert_eq(row.disabled, true)
		helpers.assert_nil(row.fn)
	end)

	helpers.it("explains a VirtualHIDDevice block above the closed-Karabiner row and nothing otherwise", function()
		local function rows_for(status)
			return tap_hold_rows(true, {
				user_karabiner_closed = function() return true end,
				owned_runtime_status = function() return status end,
			})
		end
		local function find(rows, title)
			for index, row in ipairs(rows) do if row.title == title then return row, index end end
			return nil
		end
		local blocked = rows_for({ state = "unavailable", reason = "virtual_hid_incompatible" })
		local row, at = find(blocked, "menu.tapholds.vhid_incompatible")
		helpers.assert_true(row ~= nil, "the driver-version block must be explained")
		helpers.assert_eq(row.disabled, true)
		local _, consent_at = find(blocked, LABEL)
		helpers.assert_true(at < consent_at, "the explanation comes first")
		helpers.assert_true(find(rows_for({ state = "unavailable", reason = "virtual_hid_not_active" }),
			"menu.tapholds.vhid_not_active") ~= nil)
		for _, status in ipairs({ { state = "ready" }, { state = "unavailable", reason = "other_karabiner_running" } }) do
			local rows = rows_for(status)
			helpers.assert_nil(find(rows, "menu.tapholds.vhid_incompatible"))
			helpers.assert_nil(find(rows, "menu.tapholds.vhid_not_active"))
		end
	end)
end)
