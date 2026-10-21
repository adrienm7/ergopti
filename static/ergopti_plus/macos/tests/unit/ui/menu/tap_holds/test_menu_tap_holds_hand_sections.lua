--- tests/unit/ui/menu/tap_holds/test_menu_tap_holds_hand_sections.lua

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

	helpers.it("opens the shared picker from both slot rows and keeps the native delay tail (tap-hold-key-head)", function()
		with_head(nil, function(rows, observed)
			helpers.assert_eq(#rows, 6, "four shared head rows, native separator and delay")
			helpers.assert_eq(rows[1].title, "menu.tapholds.nothing_tap_hold")
			helpers.assert_eq(rows[2].title, "-")
			helpers.assert_eq(rows[3].title, "tap_hold.picker.tap")
			helpers.assert_eq(rows[4].title, "tap_hold.picker.hold")
			helpers.assert_type(rows[3].fn, "function", "the tap row is a command")
			helpers.assert_type(rows[4].fn, "function", "the hold row is a command")
			helpers.assert_nil(rows[3].menu, "the tap row builds no submenu of actions")
			helpers.assert_nil(rows[4].menu, "the hold row builds no submenu of actions")
			helpers.assert_eq(rows[5].title, "-")
			helpers.assert_eq(rows[6].title, "menu.tapholds.key_tap_delay")
			helpers.assert_eq(#observed.calls, 0)
		end)
	end)

	helpers.it("follows shared Tap/Hold order in the actual per-key provider (tap-hold-key-head)", function()
		with_head(function(head) head[3], head[5] = head[5], head[3] end, function(rows)
			helpers.assert_eq(rows[3].title, "tap_hold.picker.hold")
			helpers.assert_eq(rows[4].title, "tap_hold.picker.tap")
			helpers.assert_type(rows[3].fn, "function")
			helpers.assert_type(rows[4].fn, "function")
		end)
	end)

	helpers.it("reads a shared caption mutation without changing the native command (tap-hold-key-head)", function()
		with_head(function(head) head[3].i18n = "menu.shortcuts.title" end, function(rows)
			helpers.assert_eq(rows[3].title, "menu.shortcuts.title")
			helpers.assert_type(rows[3].fn, "function", "the tap command survives a caption change")
		end)
	end)

	helpers.it("honors declared platform hiding in the actual provider (tap-hold-key-head)", function()
		with_head(function(head) head[3].platforms = { "ahk", "linux" } end, function(rows)
			helpers.assert_eq(#rows, 5)
			helpers.assert_eq(rows[2].title, "-")
			helpers.assert_eq(rows[3].title, "tap_hold.picker.hold")
			helpers.assert_type(rows[3].fn, "function")
			helpers.assert_eq(rows[4].title, "-", "the native delay separator still follows the shared fragment")
		end)
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 3/ Shared Action Picker ==========
-- ==========================================
-- ==========================================

-- The catalogue the slot pickers read: a tap-only, two hold-and-tap and a
-- hold-only action, plus the catalogue's own "none".
local SLOT_CATALOGUE = {
	{ id = "none", label = "None", category = "Spécial", holdable = true, tappable = true },
	{ id = "escape", label = "Escape", category = "Navigation", holdable = false, tappable = true },
	{ id = "enter", label = "Enter", category = "Navigation" },
	{ id = "shift", label = "Shift", category = "Modifiers", holdable = true, tappable = false },
}

--- Drives the actual per-key rows with the shared picker window replaced by a
--- recorder of what it was opened with and of its confirmation callback.
--- @param body function Receives the key's rows, the observations and the rebuild.
local function with_slot_picker(body)
	return helpers.with_stub_scope({ "ui.menu.menu_tap_holds", "infra.manifest_menu", "infra.i18n",
		"infra.logger", "ui.menu.menu_utils", "ui.action_picker" }, function()
		local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
		local observed = { opened = {}, calls = {}, regenerations = 0, refreshes = 0,
			receipt = true, open_result = true }
		package.loaded["ui.action_picker"] = {
			open = function(opts, on_confirm)
				observed.opened[#observed.opened + 1] = { opts = opts, confirm = on_confirm }
				return observed.open_result
			end,
		}
		local native = remap_double()
		native.AVAILABLE_ACTIONS = SLOT_CATALOGUE
		native.get_tap_action = function(kid) return kid == "left_shift" and "escape" or "none" end
		native.get_hold_action = function(kid) return kid == "left_shift" and "shift" or "none" end
		local function setter(slot)
			return function(kid, aid)
				observed.calls[#observed.calls + 1] = { slot, kid, aid }
				if observed.receipt == "throws" then error("independent setter refusal", 0) end
				return observed.receipt
			end
		end
		native.set_tap_action = setter("tap")
		native.set_hold_action = setter("hold")
		native.regenerate = function() observed.regenerations = observed.regenerations + 1; return true end
		local built = menu.build({ karabiner = native,
			updateMenu = function() observed.refreshes = observed.refreshes + 1 end }).submenu
		local key = assert(built[key_index(built, "tap_hold.group.left_shift")])
		body(key.menu, observed, built)
	end)
end

helpers.describe("the macOS key slots open the shared action picker", function()
	helpers.it("opens the tap picker for the key's tap, its current action marked (tap-hold-action-picker)", function()
		with_slot_picker(function(rows, observed)
			helpers.assert_eq(#observed.opened, 0, "building the menu opens no window")
			helpers.assert_true(rows[3].fn(), "the click reports the opened picker")
			helpers.assert_eq(#observed.opened, 1)
			local opts = observed.opened[1].opts
			helpers.assert_eq(opts.presentation_id, "tap_hold_action", "the tap slot's shared title")
			helpers.assert_eq(opts.presentation_suffix, "tap_hold.group.left_shift", "the title names the key")
			helpers.assert_eq(opts.current, "escape", "the current tap is the picker's marked choice")
			helpers.assert_eq(opts.items, {
				{ type = "heading", level = 1, text = "Navigation" },
				{ type = "action", id = "escape", label = "Escape" },
				{ type = "action", id = "enter", label = "Enter" },
			}, "every tappable action under its category; the picker draws its own none")
			helpers.assert_eq(#observed.calls, 0, "opening the picker writes nothing")
		end)
	end)

	helpers.it("opens the hold picker for the key's hold with the holdable actions (tap-hold-action-picker)", function()
		with_slot_picker(function(rows, observed)
			helpers.assert_true(rows[4].fn())
			local opts = observed.opened[1].opts
			helpers.assert_eq(opts.presentation_id, "tap_hold_hold_action", "the hold slot's shared title")
			helpers.assert_eq(opts.presentation_suffix, "tap_hold.group.left_shift")
			helpers.assert_eq(opts.current, "shift")
			helpers.assert_eq(opts.items, {
				{ type = "heading", level = 1, text = "Modifiers" },
				{ type = "action", id = "shift", label = "Shift" },
			})
		end)
	end)

	helpers.it("persists a picked action through the key's own setter, then regenerates (tap-hold-action-picker)", function()
		with_slot_picker(function(rows, observed)
			rows[3].fn()
			rows[4].fn()
			local tap, hold = observed.opened[1].confirm, observed.opened[2].confirm
			helpers.assert_true(tap("enter"))
			helpers.assert_true(hold("shift"))
			helpers.assert_true(tap("none"), "the picker's own none clears the tap")
			helpers.assert_eq(observed.calls, { { "tap", "left_shift", "enter" },
				{ "hold", "left_shift", "shift" }, { "tap", "left_shift", "none" } })
			helpers.assert_eq(observed.regenerations, 3)
			helpers.assert_eq(observed.refreshes, 3)
		end)
	end)

	for _, receipt in ipairs({ { name = "false", value = false }, { name = "nil" },
		{ name = "truthy", value = "accepted" }, { name = "throwing", value = "throws" } }) do
		helpers.it("keeps the picker open on a " .. receipt.name .. " setter receipt (tap-hold-action-picker)", function()
			with_slot_picker(function(rows, observed)
				observed.receipt = receipt.value
				rows[3].fn()
				rows[4].fn()
				helpers.assert_eq(observed.opened[1].confirm("enter"), false, "a refusal keeps the picker retryable")
				helpers.assert_eq(observed.opened[2].confirm("shift"), false)
				helpers.assert_eq(observed.calls, { { "tap", "left_shift", "enter" }, { "hold", "left_shift", "shift" } })
				helpers.assert_eq(observed.regenerations, 0, "refused persistence cannot regenerate")
				helpers.assert_eq(observed.refreshes, 0)
			end)
		end)
	end

	helpers.it("refuses an action its slot does not offer (tap-hold-action-picker)", function()
		with_slot_picker(function(rows, observed)
			rows[3].fn()
			rows[4].fn()
			local tap, hold = observed.opened[1].confirm, observed.opened[2].confirm
			helpers.assert_eq(tap("shift"), false, "a hold-only modifier is no tap")
			helpers.assert_eq(hold("escape"), false, "a tap-only key is no hold")
			helpers.assert_eq(tap("unknown"), false)
			helpers.assert_eq(tap(nil), false)
			helpers.assert_eq(#observed.calls, 0, "nothing reaches the setters")
			helpers.assert_eq(observed.regenerations, 0)
		end)
	end)

	helpers.it("reports a picker that did not open (tap-hold-action-picker)", function()
		with_slot_picker(function(rows, observed)
			observed.open_result = false
			helpers.assert_eq(rows[3].fn(), false)
			helpers.assert_eq(rows[4].fn(), false)
		end)
	end)

	helpers.it("builds no submenu of actions under any key (tap-hold-action-picker)", function()
		with_slot_picker(function(_, observed, built)
			local labels = {}
			for _, action in ipairs(SLOT_CATALOGUE) do labels[action.label] = true end
			local function walk(rows)
				for _, row in ipairs(rows or {}) do
					helpers.assert_nil(labels[row.title], "an action row was built: " .. tostring(row.title))
					walk(row.menu)
				end
			end
			local keys = 0
			for _, row in ipairs(built) do
				if type(row.title) == "string" and row.title:match("^tap_hold%.group%.") then
					keys = keys + 1
					walk(row.menu)
				end
			end
			helpers.assert_eq(keys, #engine_keys(), "every key row was inspected")
			helpers.assert_eq(#observed.opened, 0)
		end)
	end)
end)

--- Drives the actual provider with only native ports controlled. Each build
--- rereads the native values; captured callbacks keep their original owners.
local function with_delay_native(body)
	return helpers.with_stub_scope({ "ui.menu.menu_tap_holds", "infra.manifest_menu",
		"infra.i18n", "infra.logger", "ui.menu.menu_utils" }, function()
		local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
		local native = remap_double()
		local observed = { value = 1500, receipt = true, calls = {}, refreshes = 0, regenerations = 0,
			dialog_ok = true, answer = { ["text returned"] = "375.8" } }
		native.get_tap_timeout = function(kid) return kid == "left_shift" and observed.value or nil end
		native.set_tap_timeout = function(kid, value)
			observed.calls[#observed.calls + 1] = { kid = kid, value = value }
			if observed.receipt == true then observed.value = value end
			return observed.receipt
		end
		native.regenerate = function() observed.regenerations = observed.regenerations + 1; return true end
		local original_dialog = hs.osascript.applescript
		hs.osascript.applescript = function(script)
			observed.script = script
			return observed.dialog_ok, observed.answer
		end
		local function rows()
			local built = menu.build({ karabiner = native,
				updateMenu = function() observed.refreshes = observed.refreshes + 1 end }).submenu
			local key = assert(built[key_index(built, "tap_hold.group.left_shift")])
			return key.menu
		end
		local ok, err = pcall(body, rows, observed, require("infra.manifest_menu"), native)
		hs.osascript.applescript = original_dialog
		if not ok then error(err, 0) end
	end)
end

helpers.describe("the complete macOS per-key delay declaration", function()
	helpers.it("uses native effective and global values with inherited reset state (tap-hold-key-delay)", function()
		with_delay_native(function(rows, observed)
			local i18n = require("infra.i18n")
			local original_get = i18n.get
			i18n.get = function(key)
				if key == "menu.tapholds.key_tap_delay" then return "Delay: %s" end
				if key == "menu.tapholds.key_tap_delay_use_global" then return "Global: %s" end
				return original_get(key)
			end
			local ok, err = pcall(function()
				local children = rows()
				helpers.assert_eq(#children, 6)
				helpers.assert_eq(children[5].title, "-")
				helpers.assert_eq(children[6].title, "Delay: 1,5 s", "existing native formatting survives")
				local reset = children[6].menu[2]
				helpers.assert_eq(reset.title, "Global: 200 ms")
				helpers.assert_eq(reset.checked == true, false)
				helpers.assert_eq(reset.disabled == true, false)
				helpers.assert_eq(reset.fn(), true, "durable reset and native regeneration are acknowledged")
				helpers.assert_eq(observed.calls, { { kid = "left_shift" } })
				helpers.assert_eq(observed.refreshes, 1)
				helpers.assert_eq(observed.regenerations, 1)
				children = rows()
				helpers.assert_eq(children[6].title, "Delay: 200 ms")
				reset = children[6].menu[2]
				helpers.assert_true(reset.checked)
				helpers.assert_true(reset.disabled)
				helpers.assert_eq(reset.fn(), false, "declared readiness refuses an inherited reset")
				helpers.assert_eq(#observed.calls, 1)
			end)
			i18n.get = original_get
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("reads actual delay order/caption declarations without losing native child owners (tap-hold-key-delay)", function()
		with_delay_native(function(rows, observed, manifest)
			local delay = manifest.get_array("tap_hold_key_delay_rows")
			local set, reset = delay[1], delay[2]
			local original_caption = set.i18n
			local ok, err = pcall(function()
				set.i18n = "menu.shortcuts.title"
				local children = rows()[6].menu
				helpers.assert_eq(children[1].title, "menu.shortcuts.title")
				helpers.assert_eq(children[1].fn(), true)
				helpers.assert_eq(observed.calls[1], { kid = "left_shift", value = 375 })
				delay[1], delay[2] = reset, set
				children = rows()[6].menu
				helpers.assert_eq(children[1].title, "menu.tapholds.key_tap_delay_use_global")
				helpers.assert_eq(children[2].title, "menu.shortcuts.title")
				helpers.assert_eq(children[1].fn(), true)
				helpers.assert_eq(observed.calls[2], { kid = "left_shift" })
			end)
			set.i18n = original_caption; delay[1], delay[2] = set, reset
			if not ok then error(err, 0) end
		end)
	end)

	for _, receipt in ipairs({ { name = "false", value = false }, { name = "nil" },
		{ name = "truthy", value = "accepted" } }) do
		helpers.it("retains actual delay " .. receipt.name .. " persistence refusal and retry (tap-hold-key-delay)", function()
			with_delay_native(function(rows, observed)
				local delay = rows()[6].menu
				observed.receipt = receipt.value
				helpers.assert_eq(delay[1].fn(), false)
				helpers.assert_eq(delay[2].fn(), false)
				helpers.assert_eq(observed.calls, { { kid = "left_shift", value = 375 }, { kid = "left_shift" } })
				helpers.assert_eq(observed.value, 1500)
				helpers.assert_eq(observed.regenerations, 0, "refused setter cannot regenerate")
				helpers.assert_eq(observed.refreshes, 0, "refused setter cannot acknowledge refresh")
				observed.receipt = true
				helpers.assert_eq(delay[1].fn(), true)
				helpers.assert_eq(observed.value, 375)
				helpers.assert_eq(delay[2].fn(), true)
				helpers.assert_nil(observed.value)
				helpers.assert_eq(observed.regenerations, 2)
				helpers.assert_eq(observed.refreshes, 2)
			end)
		end)
	end

	helpers.it("retains cancellation and invalid-value refusal before setters (tap-hold-key-delay)", function()
		with_delay_native(function(rows, observed)
			local callback = rows()[6].menu[1].fn
			observed.dialog_ok = false; callback()
			observed.dialog_ok, observed.answer = true, "bad native result"; callback()
			observed.answer = { ["text returned"] = "-1" }; callback()
			observed.answer = { ["text returned"] = "not a number" }; callback()
			helpers.assert_eq(#observed.calls, 0)
			helpers.assert_eq(observed.regenerations, 0)
			helpers.assert_eq(observed.refreshes, 0)
		end)
	end)
end)

helpers.describe("native per-key delay prompt refusal", function()
	for _, value in ipairs({ "0.25", "0", "-1", "1e309", "nan" }) do
		helpers.it("refuses " .. value .. " before a native override can be cleared (tap-hold-key-delay)", function()
			with_delay_native(function(rows, observed)
				observed.answer = { ["text returned"] = value }
				helpers.assert_eq(rows()[6].menu[1].fn(), false)
				helpers.assert_eq(#observed.calls, 0)
				helpers.assert_eq(observed.value, 1500)
				helpers.assert_eq(observed.regenerations, 0)
				helpers.assert_eq(observed.refreshes, 0)
			end)
		end)
	end
	helpers.it("refuses a throwing native dialog without publishing or regenerating (tap-hold-key-delay)", function()
		with_delay_native(function(rows, observed)
			hs.osascript.applescript = function() error("controlled native dialog refusal") end
			helpers.assert_eq(rows()[6].menu[1].fn(), false)
			helpers.assert_eq(#observed.calls, 0)
			helpers.assert_eq(observed.value, 1500)
			helpers.assert_eq(observed.regenerations, 0)
		end)
	end)
	helpers.it("retained custom command refuses a withdrawn native setter (tap-hold-key-delay)", function()
		with_delay_native(function(rows, observed, _, native)
			local callback = rows()[6].menu[1].fn
			local setter = native.set_tap_timeout
			native.set_tap_timeout = nil
			helpers.assert_eq(callback(), false)
			helpers.assert_eq(observed.value, 1500)
			helpers.assert_eq(observed.regenerations, 0)
			native.set_tap_timeout = setter
			helpers.assert_eq(callback(), true, "same retained command retries through the real setter")
			helpers.assert_eq(observed.value, 375)
			helpers.assert_eq(observed.regenerations, 1)
		end)
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 5/ Key-Combination Slots =========
-- ==========================================
-- ==========================================

-- The pair the combination tests drive: Left Shift held, then Right Shift.
local SHIFT_PAIR = { id = "shift_pair", label = "Shift pair", group = "Shift",
	from = { simultaneous = { { key_code = "left_shift" }, { key_code = "right_shift" } } } }

--- Drives the actual « Combinaisons de touches » group with the shared picker
--- window replaced by a recorder.
--- @param body function Receives the pair's slot rows and the observations.
local function with_pair_picker(body)
	return helpers.with_stub_scope({ "ui.menu.menu_tap_holds", "infra.manifest_menu", "infra.i18n",
		"infra.logger", "ui.menu.menu_utils", "ui.action_picker" }, function()
		local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
		local observed = { opened = {}, calls = {}, regenerations = 0, refreshes = 0, receipt = true }
		package.loaded["ui.action_picker"] = {
			open = function(opts, on_confirm)
				observed.opened[#observed.opened + 1] = { opts = opts, confirm = on_confirm }
				return true
			end,
		}
		local native = remap_double()
		native.AVAILABLE_ACTIONS = SLOT_CATALOGUE
		native.MOD_COMBOS = { SHIFT_PAIR }
		native.get_mod_combos_enabled = function() return true end
		native.get_combo_combo_action = function() return "enter" end
		native.get_combo_tap_action = function() return "escape" end
		native.get_combo_hold_action = function() return "shift" end
		for _, slot in ipairs({ "combo", "tap", "hold" }) do
			native["set_combo_" .. slot .. "_action"] = function(cid, aid)
				observed.calls[#observed.calls + 1] = { slot, cid, aid }
				if observed.receipt == "throws" then error("independent setter refusal", 0) end
				return observed.receipt
			end
		end
		native.regenerate = function() observed.regenerations = observed.regenerations + 1; return true end
		local rows = menu.build_key_combinations({ karabiner = native,
			updateMenu = function() observed.refreshes = observed.refreshes + 1 end })
		local function find(list)
			for _, row in ipairs(list or {}) do
				if type(row.title) == "string" and row.title:find("tap_hold.group.left_shift", 1, true) == 1 then
					return row
				end
				local nested = find(row.menu)
				if nested then return nested end
			end
		end
		local pair = assert(find(rows), "the Left Shift → Right Shift pair has a row")
		local slots = {}
		for _, row in ipairs(pair.menu) do
			if row.title == "menu.shortcuts.key_combinations_chord" then slots.chord = row end
			if row.title == "menu.shortcuts.key_combinations_hold_tap" then slots.tap = row end
			if row.title == "menu.shortcuts.key_combinations_hold_hold" then slots.hold = row end
		end
		body(slots, observed, pair)
	end)
end

-- The three slots, the shared picker presentation each opens, its current
-- action and the catalogue it lists.
local PAIR_SLOT_CASES = {
	{ slot = "chord", setter_slot = "combo", presentation = "key_combination_chord_action", current = "enter",
		items = { { type = "heading", level = 1, text = "Navigation" },
			{ type = "action", id = "escape", label = "Escape" }, { type = "action", id = "enter", label = "Enter" },
			{ type = "heading", level = 1, text = "Modifiers" }, { type = "action", id = "shift", label = "Shift" } },
		pick = "shift" },
	{ slot = "tap", setter_slot = "tap", presentation = "key_combination_tap_action", current = "escape",
		items = { { type = "heading", level = 1, text = "Navigation" },
			{ type = "action", id = "escape", label = "Escape" }, { type = "action", id = "enter", label = "Enter" } },
		pick = "enter", refused = "shift" },
	{ slot = "hold", setter_slot = "hold", presentation = "key_combination_hold_action", current = "shift",
		items = { { type = "heading", level = 1, text = "Modifiers" }, { type = "action", id = "shift", label = "Shift" } },
		pick = "shift", refused = "escape" },
}

helpers.describe("the macOS key-combination slots open the shared action picker", function()
	helpers.it("builds no submenu of actions under a pair (key-combination-action-picker)", function()
		with_pair_picker(function(slots, observed)
			for _, case in ipairs(PAIR_SLOT_CASES) do
				local row = slots[case.slot]
				helpers.assert_type(row, "table", case.slot .. " slot row")
				helpers.assert_type(row.fn, "function", case.slot .. " slot is a command")
				helpers.assert_nil(row.menu, case.slot .. " slot builds no submenu of actions")
			end
			helpers.assert_eq(#observed.opened, 0, "building the menu opens no window")
		end)
	end)

	for _, case in ipairs(PAIR_SLOT_CASES) do
		helpers.it("opens the " .. case.slot .. " picker and persists its pick (key-combination-action-picker)", function()
			with_pair_picker(function(slots, observed)
				helpers.assert_true(slots[case.slot].fn())
				local opts = observed.opened[1].opts
				helpers.assert_eq(opts.presentation_id, case.presentation)
				helpers.assert_eq(opts.presentation_suffix, "tap_hold.group.left_shift + tap_hold.group.right_shift",
					"the title names the pair")
				helpers.assert_eq(opts.current, case.current, "the current action is the marked choice")
				helpers.assert_eq(opts.items, case.items)
				helpers.assert_eq(#observed.calls, 0, "opening the picker writes nothing")
				local confirm = observed.opened[1].confirm
				if case.refused then
					helpers.assert_eq(confirm(case.refused), false, "the slot does not offer " .. case.refused)
					helpers.assert_eq(#observed.calls, 0)
				end
				helpers.assert_true(confirm(case.pick))
				helpers.assert_eq(observed.calls, { { case.setter_slot, "shift_pair", case.pick } })
				helpers.assert_eq(observed.regenerations, 1)
				helpers.assert_eq(observed.refreshes, 1)
			end)
		end)
	end

	for _, receipt in ipairs({ { name = "false", value = false }, { name = "nil" },
		{ name = "truthy", value = "accepted" }, { name = "throwing", value = "throws" } }) do
		helpers.it("keeps every pair picker open on a " .. receipt.name .. " setter receipt (key-combination-action-picker)", function()
			with_pair_picker(function(slots, observed)
				observed.receipt = receipt.value
				for index, case in ipairs(PAIR_SLOT_CASES) do
					slots[case.slot].fn()
					helpers.assert_eq(observed.opened[index].confirm(case.pick), false)
				end
				helpers.assert_eq(#observed.calls, 3, "each slot reached its own setter once")
				helpers.assert_eq(observed.regenerations, 0, "refused persistence cannot regenerate")
				helpers.assert_eq(observed.refreshes, 0)
			end)
		end)
	end
end)
