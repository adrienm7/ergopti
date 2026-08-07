--- tests/unit/ui/menu/test_karabiner_timeout_regenerates.lua

--- ==============================================================================
--- MODULE: Karabiner Delay Pickers — Regeneration on Commit (regression)
--- DESCRIPTION:
--- Locks down that the two free-text delay pickers in the Karabiner submenu — the
--- global tap/hold timeout and the sticky-modifier timeout — regenerate
--- karabiner.json after writing the new value.
---
--- ROOT CAUSE ENCODED: both setters (karabiner.set_tap_hold_timeout /
--- set_sticky_timeout) end at Config.save_user_config with NO regenerate() of
--- their own, and these two menu items were the only ones in the submenu that did
--- not compensate at the call site. The menu label therefore updated instantly
--- while typing kept using the OLD threshold until some unrelated later click
--- happened to regenerate — so the user attributed the change to the wrong action.
--- The lie was silent precisely because the refreshed label IS the confirmation
--- signal. Asserting on regenerate (not on the label) pins the real defect.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Menu titles are produced by string.format(i18n.get(key), delay); the test i18n
-- stub echoes the key back and neither key carries a format specifier, so the
-- rendered title is the bare key — that is how the two items are located below.
local TAP_HOLD_ITEM_TITLE = "menu.karabiner.tap_hold_title"
local STICKY_ITEM_TITLE   = "menu.karabiner.sticky_title"

-- Value typed into the AppleScript prompt. Any positive integer differing from
-- the stubbed current timeouts works; the setters are spies, not validators.
local TYPED_DELAY_MS = "350"





-- ==========================================
-- ==========================================
-- ======= 1/ Karabiner Module Double =======
-- ==========================================
-- ==========================================

--- Builds the minimal karabiner surface M.build() touches, with spies on the two
--- setters under test and on regenerate.
--- @return table The module double (spy counters live under the `_calls` field).
local function make_karabiner()
	local calls = { regenerate = 0, set_tap_hold = 0, set_sticky = 0 }
	return {
		_calls = calls,
		DEFAULT_TAP_HOLD_TIMEOUT_MS       = 200,
		DEFAULT_STICKY_TIMEOUT_MS         = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "Aucune", category = "Special", holdable = true, tappable = true },
		},
		TAP_HOLD_KEYS        = { { id = "left_shift", label = "Maj G" } },
		MOD_COMBOS           = { { id = "esc_tab", label = "Esc+Tab", group = "Esc" } },
		NON_CANONICAL_COMBOS = {},
		get_enabled            = function() return true end,
		set_enabled            = function() end,
		get_combo_symmetric    = function() return false end,
		set_combo_symmetric    = function() end,
		get_tap_action         = function() return "none" end,
		get_hold_action        = function() return "none" end,
		get_tap_timeout        = function() return nil end,
		set_tap_timeout        = function() end,
		get_combo_combo_action = function() return "none" end,
		get_combo_tap_action   = function() return "none" end,
		get_combo_hold_action  = function() return "none" end,
		get_tap_hold_timeout   = function() return 200 end,
		get_sticky_timeout     = function() return 1000 end,
		get_simultaneous_threshold = function() return 50 end,
		set_simultaneous_threshold = function() end,
		open_gui               = function() end,
		-- STATEFUL, not counting. The real contract is that karabiner.json ends up
		-- carrying the value the user just typed, and that holds only because the
		-- setter mutates _state BEFORE regenerate() reads it. Counters share no
		-- state, so their assertions are invariant under swapping the two calls —
		-- a mutant that regenerates from the PRE-EDIT value keeps them green.
		-- Recording what regenerate() OBSERVES makes the order load-bearing.
		set_tap_hold_timeout   = function(ms)
			calls.set_tap_hold = calls.set_tap_hold + 1
			calls.tap_hold_value = ms
		end,
		set_sticky_timeout     = function(ms)
			calls.set_sticky = calls.set_sticky + 1
			calls.sticky_value = ms
		end,
		regenerate             = function()
			calls.regenerate = calls.regenerate + 1
			-- Snapshot what a real generator would read at this instant.
			calls.deployed_tap_hold = calls.tap_hold_value
			calls.deployed_sticky   = calls.sticky_value
		end,
	}
end

--- Finds a submenu entry by its rendered title.
--- @param item table The built Karabiner menu item.
--- @param title string Title to match exactly.
--- @return table|nil The matching submenu entry.
--- Finds a row by its label, in either dialect.
---
--- This menu's rows became provider DATA on 2026-08-07 — `label` / `action`
--- instead of `title` / `fn` — so the renderer materialises them rather than
--- receiving a finished tree. What this test pins is unchanged: the delay rows
--- exist and committing one regenerates karabiner.json. Reading both spellings
--- keeps it pinned through the conversion instead of pinning the spelling.
--- @param item table The built menu entry.
--- @param label string The row label to find.
--- @return table|nil
local function find_item(item, label)
	for _, entry in ipairs(item.menu or item.items or {}) do
		if entry.title == label or entry.label == label then return entry end
	end
	return nil
end

--- The callback a row carries, in either dialect.
--- @param row table
--- @return function|nil
local function row_action(row)
	if type(row) ~= "table" then return nil end
	return row.fn or row.action
end

--- Builds the Karabiner menu with a fresh double and an AppleScript stub that
--- always answers TYPED_DELAY_MS, so a picker's fn runs its full commit path.
--- @return table menu_item, table karabiner_double
local function build_menu()
	local karabiner = make_karabiner()
	local menu_karabiner = helpers.load_with_stubs("ui.menu.menu_remap", {
		osascript = {
			applescript = function(_script)
				return true, { ["text returned"] = TYPED_DELAY_MS }
			end,
		},
	})
	local item = menu_karabiner.build({ karabiner = karabiner, updateMenu = function() end })
	return item, karabiner
end





-- ==============================================
-- ==============================================
-- ======= 2/ Regeneration Contract Tests =======
-- ==============================================
-- ==============================================

helpers.describe("karabiner delay pickers push the new value to the keyboard", function()
	helpers.it("regenerates karabiner.json after the tap/hold delay is committed", function()
		local item, karabiner = build_menu()
		local delay_item = find_item(item, TAP_HOLD_ITEM_TITLE)
		helpers.assert_not_nil(delay_item, "the tap/hold delay item must exist in the submenu")
		helpers.assert_type(row_action(delay_item), "function")

		row_action(delay_item)()

		helpers.assert_eq(karabiner._calls.set_tap_hold, 1, "the setter must run")
		helpers.assert_true(karabiner._calls.regenerate >= 1,
			"set_tap_hold_timeout never regenerates on its own, so the menu item must — "
			.. "otherwise typing keeps the OLD threshold while the label claims the new one")
		-- The ORDER is the actual guarantee: regenerate() must observe the value the
		-- setter just stored. Asserting only the two call counts passes just as
		-- happily when the deploy runs FIRST and ships the pre-edit threshold.
		helpers.assert_eq(karabiner._calls.deployed_tap_hold, karabiner._calls.tap_hold_value,
			"regenerate() must run AFTER the setter, so the deployed config carries the "
			.. "value the user just committed rather than the previous one")
	end)

	helpers.it("regenerates karabiner.json after the sticky delay is committed", function()
		local item, karabiner = build_menu()
		local sticky_item = find_item(item, STICKY_ITEM_TITLE)
		helpers.assert_not_nil(sticky_item, "the sticky delay item must exist in the submenu")
		helpers.assert_type(row_action(sticky_item), "function")

		row_action(sticky_item)()

		helpers.assert_eq(karabiner._calls.set_sticky, 1, "the setter must run")
		helpers.assert_true(karabiner._calls.regenerate >= 1,
			"set_sticky_timeout never regenerates on its own, so the menu item must — "
			.. "otherwise the new value only reaches the keyboard on a later unrelated click")
	end)

	-- A rejected / cancelled dialog must not touch karabiner.json: regenerating on
	-- a no-op write would rewrite the file on every dismissed prompt.
	helpers.it("does not regenerate when the user cancels the dialog", function()
		local karabiner = make_karabiner()
		local menu_karabiner = helpers.load_with_stubs("ui.menu.menu_remap", {
			osascript = { applescript = function(_script) return false, nil end },
		})
		local item = menu_karabiner.build({ karabiner = karabiner, updateMenu = function() end })

		find_item(item, TAP_HOLD_ITEM_TITLE).fn()
		find_item(item, STICKY_ITEM_TITLE).fn()

		helpers.assert_eq(karabiner._calls.regenerate, 0,
			"a cancelled prompt writes nothing, so it must not regenerate either")
	end)
end)
