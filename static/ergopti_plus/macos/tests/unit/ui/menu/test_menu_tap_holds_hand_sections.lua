--- tests/unit/ui/menu/test_menu_tap_holds_hand_sections.lua

--- ==============================================================================
--- MODULE: The Tap-Holds Submenu Lists Its Keys By Hand
--- DESCRIPTION:
--- Renders the real macOS Tap-Holds submenu through the shared manifest over
--- every key the remap engine knows (platform/remap/data/tap_hold_keys.json)
--- and checks the hand sections the shared key catalogue decides.
---
--- ROOT CAUSE ENCODED:
--- the hand split read a `tap_hold_keys_catalog` manifest key that never
--- existed, so a built-in fallback always won, and that fallback said
--- `action = true` where `fn = true` was meant: Fn was listed under « Main
--- droite ». The rows also sat under a « — Tap / Hold — » header above the two
--- hand headers, with nothing between the last left key (Space) and the first
--- right key.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json    = require("json")




-- =====================================
-- =====================================
-- ======= 1/ Fixture ==================
-- =====================================
-- =====================================

--- The remap engine's real key list.
--- @return table
local function engine_keys()
	local fh = assert(io.open(helpers.driver_root() .. "platform/remap/data/tap_hold_keys.json", "r"))
	local keys = Json.decode(fh:read("*a"))
	fh:close()
	return keys
end

--- A remap double over the real key list, every slot unbound.
--- @return table
local function remap_double()
	return {
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200,
		DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "None", category = "Spécial", holdable = true, tappable = true },
		},
		TAP_HOLD_KEYS = engine_keys(),
		MOD_COMBOS = {},
		NON_CANONICAL_COMBOS = {},
		get_enabled = function() return true end,
		get_tap_holds_enabled = function() return true end,
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

--- Renders the submenu and returns its rows.
--- @return table rows
local function render()
	local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
	local built = menu.build({ karabiner = remap_double(), updateMenu = function() end })
	return built.submenu
end

--- Index of the first row whose title equals `title`.
--- @param rows table
--- @param title string
--- @return number|nil
local function index_of(rows, title)
	for index, row in ipairs(rows) do
		if row.title == title then return index end
	end
	return nil
end

--- Index of the key row named by a label key (titles read "<label>  :  …").
--- @param rows table
--- @param label_key string
--- @return number|nil
local function key_index(rows, label_key)
	local prefix = label_key .. "  :"
	for index, row in ipairs(rows) do
		if type(row.title) == "string" and row.title:sub(1, #prefix) == prefix then return index end
	end
	return nil
end




-- =====================================
-- =====================================
-- ======= 2/ Hand sections ============
-- =====================================
-- =====================================

helpers.describe("the macOS Tap-Holds submenu lists its keys by hand", function()
	helpers.it("puts Fn and Space under the left hand, a separator, then the right hand", function()
		local rows = render()
		local left = index_of(rows, "— menu.tapholds.left_hand_tap_hold —")
		local right = index_of(rows, "— menu.tapholds.right_hand_tap_hold —")
		helpers.assert_not_nil(left, "the « Main gauche (tap/hold) » header")
		helpers.assert_not_nil(right, "the « Main droite (tap/hold) » header")
		helpers.assert_true(left < right, "the left hand comes first")

		local fn = key_index(rows, "tap_hold.group.fn")
		local space = key_index(rows, "tap_hold.group.space")
		helpers.assert_not_nil(fn, "Fn has a row")
		helpers.assert_true(fn > left and fn < right, "Fn is a left-hand key")
		helpers.assert_not_nil(space, "Space has a row")
		helpers.assert_true(space > left and space < right, "Space is a left-hand key")

		-- Space ends the left hand; a separator follows it, then the right header
		-- and the first right-hand key.
		helpers.assert_eq(space, right - 2, "Space is the last left-hand row")
		helpers.assert_eq(rows[space + 1].title, "-", "a separator follows the last left-hand key")
		local first_right = key_index(rows, "tap_hold.group.right_command")
		helpers.assert_eq(first_right, right + 1, "Right Cmd is the first right-hand key")
		helpers.assert_not_nil(key_index(rows, "tap_hold.group.backspace"), "Backspace is listed")
		helpers.assert_true(key_index(rows, "tap_hold.group.backspace") > right,
			"Backspace is a right-hand key")
	end)

	helpers.it("lists every engine key exactly once, under the header of its hand", function()
		local rows = render()
		local keyed = 0
		for _, row in ipairs(rows) do
			if type(row.title) == "string" and row.title:match("^tap_hold%.group%.") then
				keyed = keyed + 1
			end
		end
		helpers.assert_eq(keyed, #engine_keys(), "one row per key the remap engine can bind")
	end)

	helpers.it("draws no « Tap / Hold » header of its own above the hands", function()
		for _, row in ipairs(render()) do
			local title = tostring(row.title)
			helpers.assert_nil(title:find("header_taps_holds", 1, true), "retired header: " .. title)
			helpers.assert_nil(title:find("menu.tapholds.left_hand —", 1, true), "retired header: " .. title)
		end
	end)
end)
