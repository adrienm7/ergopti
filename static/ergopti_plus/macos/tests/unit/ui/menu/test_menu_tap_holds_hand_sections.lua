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

local helpers, runtime_inputs = require("tests.support.remap_menu_runtime_inputs").bind(require("tests.helpers"))
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
		get_runtime = runtime_inputs.get_runtime,
		shared_runtime_selected = runtime_inputs.shared_runtime_selected,
		runtime_unavailable_reason = runtime_inputs.runtime_unavailable_reason,
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
-- ======= 5/ Complete Action Picker Frame ==
-- ==========================================
-- ==========================================

--- Finds the real private picker through the public builder's closure graph.
--- No production export, replicated picker or source-text evaluator is introduced.
--- @param fn function Actual native public builder.
--- @param visited table|nil Function identities already inspected.
--- @return function|nil picker
local function native_tap_hold_picker(fn, visited)
	visited = visited or {}
	if visited[fn] then return nil end
	visited[fn] = true
	for index = 1, math.huge do
		local name, value = debug.getupvalue(fn, index)
		if name == nil then break end
		if name == "build_action_picker" and type(value) == "function" then return value end
		if type(value) == "function" then
			local found = native_tap_hold_picker(value, visited)
			if found then return found end
		end
	end
	return nil
end

--- Owns the actual local picker and records catalogue, grouping and mutation reads.
--- @param body function Receives actual picker, effects and renderer.
local function with_action_picker_frame(body)
	return helpers.with_stub_scope({ "ui.menu.menu_tap_holds", "infra.manifest_menu",
		"menu.renderer", "infra.i18n", "infra.logger", "ui.menu.menu_utils" }, function()
		local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
		local picker = native_tap_hold_picker(menu.build)
		helpers.assert_type(picker, "function", "the actual public builder must reach its native picker")
		local effects = { catalogue_reads = 0, grouped_reads = 0, setters = {}, regenerations = 0,
			refreshes = 0, receipt = true, actions = {} }
		local native = setmetatable({
			get_runtime = runtime_inputs.get_runtime,
			shared_runtime_selected = runtime_inputs.shared_runtime_selected,
			runtime_unavailable_reason = runtime_inputs.runtime_unavailable_reason,
			regenerate = function() effects.regenerations = effects.regenerations + 1; return true end,
		}, {
			__index = function(_, key)
				if key == "AVAILABLE_ACTIONS" then
					effects.catalogue_reads = effects.catalogue_reads + 1
					if effects.on_catalogue_read then effects.on_catalogue_read() end
					return effects.actions
				end
			end,
		})
		local utils = require("ui.menu.menu_utils")
		local actual_grouped_picker = utils.build_action_picker
		utils.build_action_picker = function(...)
			effects.grouped_reads = effects.grouped_reads + 1
			return actual_grouped_picker(...)
		end
		local function build(actions, current, slot)
			effects.actions = actions
			return picker(native, function(id)
				effects.setters[#effects.setters + 1] = id
				if effects.receipt == "throws" then error("independent picker mutation refusal", 0) end
				return effects.receipt
			end, current, function() effects.refreshes = effects.refreshes + 1 end, slot)
		end
		return body(build, effects, require("infra.manifest_menu"), utils)
	end)
end

--- Returns original dynamic source captions and separator markers in their order.
--- @param rows table Actual provider data.
--- @return table labels
local function picker_frame_labels(rows)
	local labels = {}
	for _, row in ipairs(rows) do labels[#labels + 1] = row.separator and "-" or row.label end
	return labels
end

helpers.describe("complete native Tap-Hold action picker frame", function()
	helpers.it("keeps independently specified Special, grouped and boundary order", function()
		with_action_picker_frame(function(build, effects)
			local special = { id = "none", label = "Independent None", category = "Spécial", holdable = true, tappable = true }
			local grouped = { id = "escape", label = "Independent Escape", category = "Navigation", holdable = true, tappable = true }
			local cases = {
				{ actions = { grouped, special }, expected = { special.label, "-", "— Navigation —", grouped.label } },
				{ actions = { special }, expected = { special.label } },
				{ actions = { grouped }, expected = { "— Navigation —", grouped.label } },
				{ actions = {}, expected = {} },
			}
			for _, case in ipairs(cases) do
				local rows = build(case.actions, "none", "tap")
				helpers.assert_eq(picker_frame_labels(rows), case.expected,
					"the boundary occurs only when both native sections contribute")
			end
			helpers.assert_true(effects.catalogue_reads > 0, "the positive source counter is armed")
			helpers.assert_true(effects.grouped_reads > 0, "the real grouping helper remains in use")
			helpers.assert_eq(effects.setters, {}, "construction does not mutate native assignments")
			helpers.assert_eq(effects.regenerations, 0)
			helpers.assert_eq(effects.refreshes, 0)
		end)
	end)

	helpers.it("retains actual tap, hold and combination filtering and checked choices", function()
		with_action_picker_frame(function(build)
			local actions = {
				{ id = "shift", label = "Shift", category = "Modifiers", holdable = true, tappable = false },
				{ id = "none", label = "None", category = "Spécial", holdable = true, tappable = true },
				{ id = "escape", label = "Escape", category = "Navigation", holdable = false, tappable = true },
				{ id = "capsword", label = "CapsWord", category = "Spécial", holdable = false, tappable = true },
			}
			local cases = {
				{ slot = "tap", current = "escape", expected = { "None", "CapsWord", "-", "— Navigation —", "Escape" } },
				{ slot = "hold", current = "shift", expected = { "None", "-", "— Modifiers —", "Shift" } },
				{ slot = "combo", current = "capsword", expected = { "None", "CapsWord", "-", "— Modifiers —", "Shift", "— Navigation —", "Escape" } },
			}
			for _, case in ipairs(cases) do
				local rows = build(actions, case.current, case.slot)
				helpers.assert_eq(picker_frame_labels(rows), case.expected)
				local checked = {}
				for _, row in ipairs(rows) do
					if row.checked then checked[#checked + 1] = row.label end
				end
				local expected = { tap = "Escape", hold = "Shift", combo = "CapsWord" }
				helpers.assert_eq(checked, { expected[case.slot] }, "exactly the actual current choice remains checked")
			end
		end)
	end)

	helpers.it("preserves literal native setter acknowledgements for both selection branches", function()
		with_action_picker_frame(function(build, effects)
			local rows = build({
				{ id = "none", label = "None", category = "Spécial", holdable = true, tappable = true },
				{ id = "escape", label = "Escape", category = "Navigation", holdable = true, tappable = true },
			}, "none", "tap")
			local actions = { { row = rows[1], id = "none" }, { row = rows[4], id = "escape" } }
			for _, branch in ipairs(actions) do
				for _, receipt in ipairs({ { value = false }, {}, { value = "accepted" }, { value = "throws" } }) do
					effects.receipt = receipt.value
					local before = effects.regenerations
					local refreshes = effects.refreshes
					helpers.assert_eq(branch.row.action(), false)
					helpers.assert_eq(effects.setters[#effects.setters], branch.id)
					helpers.assert_eq(effects.regenerations, before, "a refusal cannot regenerate")
					helpers.assert_eq(effects.refreshes, refreshes, "a refusal cannot acknowledge a refresh")
				end
				effects.receipt = true
				local before = effects.regenerations
				local refreshes = effects.refreshes
				helpers.assert_eq(branch.row.action(), true)
				helpers.assert_eq(effects.setters[#effects.setters], branch.id)
				helpers.assert_eq(effects.regenerations, before + 1)
				helpers.assert_eq(effects.refreshes, refreshes + 1)
			end
		end)
	end)

	for _, control in ipairs({ "missing", "withdrawn", "missing_boundary", "malformed" }) do
		helpers.it("refuses " .. control .. " declarations before catalogue or grouping reads", function()
			with_action_picker_frame(function(build, effects, renderer)
				local root = renderer.get_root()
				if control == "missing" then root.tap_hold_action_picker_frame = nil
				elseif control == "withdrawn" then root.tap_hold_action_picker_frame = {}
				elseif control == "missing_boundary" then root.tap_hold_action_picker_boundary = {}
				else root.tap_hold_action_picker_frame[1].type = "unrecognized" end
				local rows = build({ { id = "none", label = "None", category = "Spécial" } }, "none", "tap")
				helpers.assert_eq(effects.catalogue_reads, 0, "invalid presentation refuses before real catalogue reads")
				helpers.assert_eq(effects.grouped_reads, 0, "invalid presentation refuses before real grouping")
				helpers.assert_nil(rows, "an incomplete picker cannot publish partial choices")
				helpers.assert_eq(effects.setters, {})
				helpers.assert_eq(effects.regenerations, 0)
			end)
		end)
	end

	for _, control in ipairs({ "missing", "non_boolean", "raises" }) do
		helpers.it("refuses " .. control .. " boundary predicates before native source reads", function()
			with_action_picker_frame(function(build, effects, renderer)
				local actual_template_rows = renderer.template_rows
				renderer.template_rows = function(key, commands, getters, children)
					if key == "tap_hold_action_picker_frame" then
						if control == "missing" then getters.tap_hold_picker_has_boundary = nil
						elseif control == "non_boolean" then getters.tap_hold_picker_has_boundary = function() return 1 end
						else getters.tap_hold_picker_has_boundary = function() error("independent picker boundary refusal", 0) end end
					end
					return actual_template_rows(key, commands, getters, children)
				end
				local rows = build({ { id = "none", label = "None", category = "Spécial" } }, "none", "tap")
				helpers.assert_eq(effects.catalogue_reads, 0)
				helpers.assert_eq(effects.grouped_reads, 0)
				helpers.assert_nil(rows)
				helpers.assert_eq(effects.setters, {})
			end)
		end)
	end

	helpers.it("refuses publication if a previously admitted native read withdraws the boundary", function()
		with_action_picker_frame(function(build, effects, renderer)
			effects.on_catalogue_read = function() renderer.get_root().tap_hold_action_picker_boundary = {} end
			local rows = build({
				{ id = "none", label = "None", category = "Spécial", holdable = true },
				{ id = "escape", label = "Escape", category = "Navigation", holdable = true },
			}, "none", "tap")
			helpers.assert_eq(effects.catalogue_reads, 1, "an admitted native read cannot be retroactively undone")
			helpers.assert_nil(rows, "subsequent declaration withdrawal refuses final publication")
			helpers.assert_eq(effects.setters, {})
			helpers.assert_eq(effects.regenerations, 0)
		end)
	end)
end)
