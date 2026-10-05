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

--- Runs the actual per-key menu and shared renderer with a controlled native port.
--- @param configured boolean Whether the selected key has a tap assignment.
--- @param body function Receives menu finder, observed native calls and declaration.
local function with_native_key_menu(configured, body)
	return helpers.with_stub_scope({ "ui.menu.menu_tap_holds", "infra.manifest_menu",
		"infra.i18n", "infra.logger", "ui.menu.menu_utils" }, function()
		local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
		local observed = { calls = {}, refreshes = 0, receipt = true }
		local native = remap_double()
		native.get_tap_action = function(kid) return configured and kid == "left_shift" and "copy" or "none" end
		native.clear_tap_hold_binding = function(kid, on_done)
			observed.calls[#observed.calls + 1] = kid
			on_done(observed.receipt == true, "controlled-terminal", 1)
			return observed.receipt
		end
		local function rows()
			return menu.build({ karabiner = native,
				updateMenu = function() observed.refreshes = observed.refreshes + 1 end }).submenu
		end
		local function first()
			local prefix = require("infra.i18n").get("tap_hold.group.left_shift") .. "  :"
			for _, row in ipairs(rows()) do
				if type(row.title) == "string" and row.title:sub(1, #prefix) == prefix then
					return row.menu[1], row.menu
				end
			end
		end
		body(first, observed, require("infra.manifest_menu").get_array("tap_hold_key_native_commands"))
	end)
end

helpers.describe("the declared per-key native command", function()
	for _, configured in ipairs({ true, false }) do
		helpers.it("keeps configured=" .. tostring(configured) .. " availability (tap-hold-key-native)", function()
			with_native_key_menu(configured, function(first, observed)
				local row, children = first()
				helpers.assert_type(row, "table")
				helpers.assert_eq(row.title, "menu.tapholds.nothing_tap_hold")
				helpers.assert_eq(row.disabled == true, not configured)
				helpers.assert_eq(children[2].title, "-", "the original following separator stays native")
				helpers.assert_eq(#observed.calls, 0, "constructing the row is inert")
				if configured then
					helpers.assert_eq(row.fn(), true)
					helpers.assert_eq(observed.calls, { "left_shift" })
				else
					helpers.assert_eq(row.fn(), false)
					helpers.assert_eq(#observed.calls, 0)
				end
			end)
		end)
	end

	helpers.it("reads its actual shared caption and retains the native command (tap-hold-key-native)", function()
		with_native_key_menu(true, function(first, observed, declaration)
			helpers.assert_eq(#declaration, 2, "both platform caption variants are declared")
			local row = declaration[2]
			helpers.assert_eq(row.id, "tap_hold_key_no_action")
			local previous = row.i18n
			row.i18n = "menu.shortcuts.title"
			local ok, err = pcall(function()
				local selected = first()
				helpers.assert_eq(selected.title, "menu.shortcuts.title")
				helpers.assert_eq(selected.fn(), true)
				helpers.assert_eq(observed.calls, { "left_shift" })
			end)
			row.i18n = previous
			if not ok then error(err, 0) end
		end)
	end)

	for _, receipt in ipairs({ { name = "false", value = false }, { name = "nil" },
		{ name = "truthy", value = "accepted" } }) do
		helpers.it("retains its native " .. receipt.name .. " refusal and retry (tap-hold-key-native)", function()
			with_native_key_menu(true, function(first, observed)
				local held = first().fn
				observed.receipt = receipt.value
				helpers.assert_eq(held(), false)
				helpers.assert_eq(observed.calls, { "left_shift" })
				observed.receipt = true
				helpers.assert_eq(held(), true)
				helpers.assert_eq(observed.calls, { "left_shift", "left_shift" })
			end)
		end)
	end
end)

helpers.describe("the declared complete per-key head", function()
	local function with_head(mutate, body)
		with_native_key_menu(true, function(first, observed)
			local head = require("infra.manifest_menu").get_array("tap_hold_key_head")
			local saved = {}
			for index, row in ipairs(head) do
				saved[index] = {}
				for key, value in pairs(row) do saved[index][key] = value end
			end
			local ok, err = pcall(function()
				if mutate then mutate(head) end
				local _, children = first()
				body(children, observed)
			end)
			for index = #head, 1, -1 do head[index] = nil end
			for index, row in ipairs(saved) do head[index] = row end
			if not ok then error(err, 0) end
		end)
	end

	helpers.it("retains both picker subtrees and the native delay tail (tap-hold-key-head)", function()
		with_head(nil, function(rows, observed)
			helpers.assert_eq(#rows, 6, "four shared head rows, native separator and delay")
			helpers.assert_eq(rows[1].title, "menu.tapholds.nothing_tap_hold")
			helpers.assert_eq(rows[2].title, "-")
			helpers.assert_eq(rows[3].title, "menu.tapholds.tap_arrow")
			helpers.assert_eq(rows[4].title, "menu.tapholds.hold_arrow")
			helpers.assert_type(rows[3].menu, "table")
			helpers.assert_type(rows[4].menu, "table")
			helpers.assert_nil(rows[3].fn, "macOS tap still opens a submenu")
			helpers.assert_eq(rows[5].title, "-")
			helpers.assert_eq(rows[6].title, "menu.tapholds.key_tap_delay")
			helpers.assert_eq(#observed.calls, 0)
		end)
	end)

	helpers.it("follows shared Tap/Hold order in the actual per-key provider (tap-hold-key-head)", function()
		with_head(function(head) head[4], head[6] = head[6], head[4] end, function(rows)
			helpers.assert_eq(rows[3].title, "menu.tapholds.hold_arrow")
			helpers.assert_eq(rows[4].title, "menu.tapholds.tap_arrow")
			helpers.assert_type(rows[3].menu, "table")
			helpers.assert_type(rows[4].menu, "table")
		end)
	end)

	helpers.it("reads a shared caption mutation without changing the native subtree (tap-hold-key-head)", function()
		with_head(function(head) head[4].i18n = "menu.tapholds.hold_arrow" end, function(rows)
			helpers.assert_eq(rows[3].title, "menu.tapholds.hold_arrow")
			helpers.assert_type(rows[3].menu, "table")
			helpers.assert_true(#rows[3].menu > 0, "the original action picker payload survives")
		end)
	end)

	helpers.it("honors declared platform hiding in the actual provider (tap-hold-key-head)", function()
		with_head(function(head) head[4].platforms = { "ahk", "linux" } end, function(rows)
			helpers.assert_eq(#rows, 5)
			helpers.assert_eq(rows[2].title, "-")
			helpers.assert_eq(rows[3].title, "menu.tapholds.hold_arrow")
			helpers.assert_type(rows[3].menu, "table")
			helpers.assert_eq(rows[4].title, "-", "the native delay separator still follows the shared fragment")
		end)
	end)
end)

helpers.describe("declared head retains the macOS picker mutation owners", function()
	for _, receipt in ipairs({ { name = "true", value = true }, { name = "false", value = false },
		{ name = "nil" }, { name = "truthy", value = "accepted" } }) do
		helpers.it("keeps native " .. receipt.name .. " setter receipts for both slots (tap-hold-key-head)", function()
			helpers.with_stub_scope({ "ui.menu.menu_tap_holds", "infra.manifest_menu", "infra.i18n",
				"infra.logger", "ui.menu.menu_utils" }, function()
				local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
				local native, calls, regenerations, refreshes = remap_double(), {}, 0, 0
				native.set_tap_action = function(kid, aid) calls[#calls + 1] = { "tap", kid, aid }; return receipt.value end
				native.set_hold_action = function(kid, aid) calls[#calls + 1] = { "hold", kid, aid }; return receipt.value end
				native.regenerate = function() regenerations = regenerations + 1; return true end
				local built = menu.build({ karabiner = native, updateMenu = function() refreshes = refreshes + 1 end }).submenu
				local key = assert(built[key_index(built, "tap_hold.group.left_shift")])
				helpers.assert_type(key.menu[3].menu[1].fn, "function")
				helpers.assert_type(key.menu[4].menu[1].fn, "function")
				helpers.assert_eq(key.menu[3].menu[1].fn(), receipt.value == true)
				helpers.assert_eq(key.menu[4].menu[1].fn(), receipt.value == true)
				helpers.assert_eq(calls, { { "tap", "left_shift", "none" }, { "hold", "left_shift", "none" } })
				helpers.assert_eq(regenerations, receipt.value == true and 2 or 0, "refused persistence cannot regenerate")
				helpers.assert_eq(refreshes, receipt.value == true and 2 or 0)
			end)
		end)
	end
end)
