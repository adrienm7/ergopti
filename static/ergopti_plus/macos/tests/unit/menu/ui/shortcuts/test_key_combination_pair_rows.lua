--- tests/unit/menu/ui/shortcuts/test_key_combination_pair_rows.lua

--- ==============================================================================
--- MODULE: Key-Combination Pair Rows Follow The Windows Layout
--- DESCRIPTION:
--- Maintainer decisions of 2026-11-21. KCD-8: every OS lays out the pair rows
--- the Windows way, one submenu per key held first, each pair's slots in the
--- order tap, hold, chord, and the chord in the pair's summary, replayed from
--- _shared/tests/corpus/tap_hold/key_combination_pair_rows.json. KCD-5: under
--- symmetry the macOS menu lists every ordered pair, tap and hold included, as
--- Windows and Linux do; only the chord row is shared between the two orders.
---
--- ROOT CAUSE ENCODED:
--- macOS drew a section header per first key with every pair beneath it,
--- ordered the slots chord, tap, hold, summarised a pair as « chord / tap /
--- hold » with every empty slot named, and hid the reverse-order pairs under
--- symmetry though the generator still applied their tap and hold.
--- ==============================================================================

local helpers = require("tests.helpers")

local CORPUS = "tests/corpus/tap_hold/key_combination_pair_rows.json"
local FORWARD, REVERSE = "lshift_rshift", "rshift_lshift"

--- Reads the shared pair-row vectors through the driver's codec.
--- @return table
local function corpus()
	local file = assert(io.open(helpers.shared(CORPUS), "r"))
	local text = file:read("*a")
	file:close()
	return require("core.fs.adapters.json_codec").decode(text)
end

--- A remap double holding both orders of one pair, with recorded writes.
--- @param slots table combo id -> { tap, hold, combo }.
--- @param symmetric boolean Chord symmetry.
--- @param writes table Mutable list of { setter, id, action }.
--- @return table
local function remap_double(slots, symmetric, writes)
	local function getter(field)
		return function(id) return (slots[id] or {})[field] or "none" end
	end
	local function setter(name, field)
		return function(id, action)
			writes[#writes + 1] = { setter = name, id = id, action = action }
			slots[id] = slots[id] or {}
			slots[id][field] = action
			return true
		end
	end
	return {
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200,
		DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "None", category = "Spécial", holdable = true, tappable = true },
			{ id = "copy", label = "Copy", short_label = "Copy", category = "Edit", tappable = true },
			{ id = "paste", label = "Paste", short_label = "Paste", category = "Edit", tappable = true },
			{ id = "ctrl", label = "Ctrl", short_label = "Ctrl", category = "Mod", holdable = true, tappable = false },
		},
		TAP_HOLD_KEYS = { { id = "left_shift", label = "Left Shift" } },
		MOD_COMBOS = {
			{ id = FORWARD, from = { simultaneous = { { key_code = "left_shift" }, { key_code = "right_shift" } } } },
			{ id = REVERSE, from = { simultaneous = { { key_code = "right_shift" }, { key_code = "left_shift" } } } },
		},
		NON_CANONICAL_COMBOS = { [REVERSE] = true },
		get_enabled = function() return true end,
		get_tap_holds_enabled = function() return true end,
		get_key_combinations_enabled = function() return true end,
		set_key_combinations_enabled = function() return true end,
		regenerate = function(on_done) if on_done then on_done(true, "ready") end return true end,
		get_combo_symmetric = function() return symmetric end,
		get_tap_action = function() return "none" end,
		get_hold_action = function() return "none" end,
		get_tap_timeout = function() return nil end,
		get_combo_tap_action = getter("tap"),
		get_combo_hold_action = getter("hold"),
		get_combo_combo_action = getter("combo"),
		set_combo_tap_action = setter("set_combo_tap_action", "tap"),
		set_combo_hold_action = setter("set_combo_hold_action", "hold"),
		set_combo_combo_action = setter("set_combo_combo_action", "combo"),
		get_tap_hold_timeout = function() return 200 end,
		get_sticky_timeout = function() return 1000 end,
		get_lone_modifier_tap_max_ms = function() return 1000 end,
		get_simultaneous_threshold = function() return 50 end,
	}
end

--- Builds the group with a recording action picker.
--- @param remap table Remap double.
--- @return table group Rendered rows.
--- @return table picks Mutable list of the pickers opened: { suffix, current, choose }.
local function build(remap)
	local picks = {}
	package.loaded["ui.action_picker"] = { open = function(spec, choose)
		picks[#picks + 1] = { suffix = spec.presentation_suffix, current = spec.current, choose = choose }
		return true
	end }
	local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
	menu._reset_picker_cache()
	return menu.build_key_combinations({ karabiner = remap, updateMenu = function() end }), picks
end

--- The rendered row whose title starts with `prefix`, depth first.
--- @param rows table
--- @param prefix string
--- @return table|nil
local function find(rows, prefix)
	for _, row in ipairs(rows or {}) do
		if type(row.title) == "string" and row.title:sub(1, #prefix) == prefix then return row end
		local found = find(row.menu, prefix)
		if found then return found end
	end
end

--- The slot rows of one rendered pair menu, without clear and separators.
--- @param pair table Rendered pair row.
--- @return table rows
local function slot_rows(pair)
	local rows = {}
	for _, row in ipairs(pair.menu or {}) do
		if type(row.title) == "string" and row.title:find("menu.shortcuts.key_combinations_", 1, true) == 1 then
			rows[#rows + 1] = row
		end
	end
	return rows
end

local PAIR = "key_name.left_shift + key_name.right_shift: "
local REVERSE_PAIR = "key_name.right_shift + key_name.left_shift: "

helpers.describe("the shared pair summary (kcd-8-pair-rows)", function()
	helpers.it("replays every summary vector of the shared corpus (kcd-8-pair-rows)", function()
		local policy = require("tap_hold.engine.combination_labels")
		local vectors = corpus()
		helpers.assert_eq(policy.SLOT_ORDER, vectors.slot_order, "one slot order on every OS")
		helpers.assert_eq(policy.SUMMARY_SEPARATOR, vectors.separator)
		helpers.assert_true(#vectors.summaries >= 8, "every slot combination is replayed")
		for _, vector in ipairs(vectors.summaries) do
			helpers.assert_eq(policy.summary(vector.labels, vectors.empty), vector.expected, vector.name)
		end
	end)
end)

helpers.describe("macOS pair rows follow the Windows layout (kcd-8-pair-rows)", function()
	helpers.it("groups the pairs in one submenu per key held first (kcd-8-pair-rows)", function()
		helpers.with_stub_scope({ "ui.menu.menu_tap_holds", "ui.action_picker" }, function()
			local group = build(remap_double({}, false, {}))
			local first = find(group, "key_name.left_shift")
			helpers.assert_not_nil(first, "the key held first has its own row")
			helpers.assert_eq(first.title, "key_name.left_shift", "the first key's row is its name alone")
			helpers.assert_type(first.menu, "table", "it opens a submenu")
			helpers.assert_true(first.menu[1].title:sub(1, #PAIR) == PAIR, "the pairs live in that submenu")
			helpers.assert_nil(find(group, "— key_name.left_shift —"), "no section header per first key")
		end)
	end)

	helpers.it("orders each pair's slots tap, hold, chord and names the chord in the summary (kcd-8-pair-rows)", function()
		helpers.with_stub_scope({ "ui.menu.menu_tap_holds", "ui.action_picker" }, function()
			local group = build(remap_double({ [FORWARD] = { tap = "copy", combo = "paste" } }, false, {}))
			local pair = find(group, PAIR)
			helpers.assert_eq(pair.title, PAIR .. "Copy / Paste", "assigned slots in tap, hold, chord order")
			local rows = slot_rows(pair)
			helpers.assert_eq(#rows, 3)
			helpers.assert_eq(rows[1].title, "menu.shortcuts.key_combinations_hold_tap", "tap first")
			helpers.assert_eq(rows[2].title, "menu.shortcuts.key_combinations_hold_hold", "hold second")
			helpers.assert_eq(rows[3].title, "menu.shortcuts.key_combinations_chord", "chord last")
			local empty = find(group, REVERSE_PAIR)
			helpers.assert_eq(empty.title, REVERSE_PAIR .. "dialog.action_picker.disabled",
				"an empty pair shows the Windows empty word")
		end)
	end)
end)

helpers.describe("symmetry lists every pair and shares only the chord (kcd-5-symmetric-pairs)", function()
	helpers.it("lists the reverse order with its own tap and the owner's chord (kcd-5-symmetric-pairs)", function()
		helpers.with_stub_scope({ "ui.menu.menu_tap_holds", "ui.action_picker" }, function()
			local slots = { [FORWARD] = { tap = "copy", combo = "paste" }, [REVERSE] = { hold = "ctrl" } }
			local group = build(remap_double(slots, true, {}))
			local reverse = find(group, REVERSE_PAIR)
			helpers.assert_not_nil(reverse, "the reverse order keeps its row under symmetry")
			helpers.assert_eq(reverse.title, REVERSE_PAIR .. "Ctrl / Paste",
				"its own hold, and the chord the owner order runs for both")
			helpers.assert_eq(find(group, PAIR).title, PAIR .. "Copy / Paste")
		end)
	end)

	helpers.it("writes a reverse pair's tap to itself and its chord to the owner (kcd-5-symmetric-pairs)", function()
		helpers.with_stub_scope({ "ui.menu.menu_tap_holds", "ui.action_picker" }, function()
			local writes = {}
			local group, picks = build(remap_double({}, true, writes))
			local rows = slot_rows(find(group, REVERSE_PAIR))
			rows[1].fn()
			picks[#picks].choose("copy")
			rows[3].fn()
			picks[#picks].choose("paste")
			helpers.assert_eq(writes[1], { setter = "set_combo_tap_action", id = REVERSE, action = "copy" })
			helpers.assert_eq(writes[2], { setter = "set_combo_combo_action", id = FORWARD, action = "paste" },
				"the shared chord row writes the owner order")
			helpers.assert_eq(picks[2].suffix, "key_name.right_shift + key_name.left_shift",
				"the picker names the pair the user opened")
		end)
	end)

	helpers.it("keeps each order's chord apart without symmetry (kcd-5-symmetric-pairs)", function()
		helpers.with_stub_scope({ "ui.menu.menu_tap_holds", "ui.action_picker" }, function()
			local writes = {}
			local group, picks = build(remap_double({ [FORWARD] = { combo = "paste" } }, false, writes))
			local reverse = find(group, REVERSE_PAIR)
			helpers.assert_eq(reverse.title, REVERSE_PAIR .. "dialog.action_picker.disabled")
			slot_rows(reverse)[3].fn()
			picks[#picks].choose("copy")
			helpers.assert_eq(writes[1], { setter = "set_combo_combo_action", id = REVERSE, action = "copy" })
		end)
	end)
end)
