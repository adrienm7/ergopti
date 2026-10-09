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
		assert_hint_leads(rows, "tap_hold.group.tab")
	end)

	helpers.it("draws the hint above the greyed chord rows, in their Shortcuts group", function()
		assert_hint_leads(key_combination_rows(false), "tap_hold.group.left_shift + tap_hold.group.right_shift")
	end)

	helpers.it("draws no hint while the integration is on", function()
		for _, rows in ipairs({ tap_hold_rows(true), key_combination_rows(true) }) do
			for _, row in ipairs(rows) do
				helpers.assert_true(row.title ~= HINT, "an available engine needs no explanation")
			end
		end
	end)
end)

helpers.describe("the declared integration-off hint retains cached native children", function()
	helpers.it("reads the shared hint caption in key and chord providers (tap-hold-guidance)", function()
		local menu, native = menu_over_double(false)
		local row = require("infra.manifest_menu").get_array("tap_hold_karabiner_off_rows")[1]
		local previous = row.i18n
		local ok, err = pcall(function()
			row.i18n = "menu.shortcuts.title"
			local built = menu.build({ karabiner = native, updateMenu = function() end })
			local combinations = menu.build_key_combinations({ karabiner = native, updateMenu = function() end })
			local function check(rows, expected_count)
				local count = 0
				for _, item in ipairs(rows) do
					if item.title == "menu.shortcuts.title" then
						count = count + 1
						helpers.assert_true(item.disabled)
						helpers.assert_nil(item.fn)
					end
					helpers.assert_true(item.title ~= HINT)
				end
				helpers.assert_eq(count, expected_count, "one translated inert explanation per native provider")
			end
			check(built.submenu, 1); check(combinations, 2)
		end)
		row.i18n = previous
		if not ok then error(err, 0) end
	end)

	helpers.it("hides only the declared hint without mutating cached greyed key rows (tap-hold-guidance)", function()
		local menu, native = menu_over_double(false)
		local row = require("infra.manifest_menu").get_array("tap_hold_karabiner_off_rows")[1]
		local previous = row.platforms
		local ctx = { karabiner = native, updateMenu = function() end }
		local before = menu.build(ctx).submenu
		local ok, err = pcall(function()
			row.platforms = { "ahk", "linux" }
			local hidden = menu.build(ctx).submenu
			helpers.assert_eq(#hidden, #before - 1, "platform policy removes the hint, not key data")
			local keys_before, keys_after = {}, {}
			for _, item in ipairs(before) do
				if type(item.title) == "string" and item.title:match("^tap_hold%.group%.") then keys_before[#keys_before + 1] = item end
			end
			for _, item in ipairs(hidden) do
				helpers.assert_true(item.title ~= HINT)
				if type(item.title) == "string" and item.title:match("^tap_hold%.group%.") then
					helpers.assert_true(item.disabled)
					keys_after[#keys_after + 1] = item
				end
			end
			helpers.assert_true(#keys_before > 0, "real catalogue rows must survive")
			helpers.assert_eq(keys_after, keys_before, "cached native row data remains exact")
		end)
		row.platforms = previous
		if not ok then error(err, 0) end
	end)
end)
