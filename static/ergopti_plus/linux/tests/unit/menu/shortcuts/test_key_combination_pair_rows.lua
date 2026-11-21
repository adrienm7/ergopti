--- tests/unit/menu/shortcuts/test_key_combination_pair_rows.lua

--- ==============================================================================
--- MODULE: Key Combination Pair Row Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/tap_hold/key_combination_pair_rows.json through
--- the shared pair-row helper the Linux menu draws its rows with: the Windows
--- summary, empty words and slot order (maintainer decision KCD-8).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the shared corpus through the driver's codec.
--- @return table
local function corpus()
	local path = require("core.fs.engine.paths").shared("tests/corpus/tap_hold/key_combination_pair_rows.json")
	local file = assert(io.open(path, "r"))
	local text = file:read("*a")
	file:close()
	return require("core.text.engine.json").decode(text)
end

--- A lookup that names its key, so the empty word is checked by its key.
--- @param key string
--- @return string
local function get(key) return "translated:" .. key end

helpers.describe("(kcd-8) shared key-combination pair rows", function()
	local PairRows = require("tap_hold.engine.key_combination_rows")
	helpers.it("(kcd-8) draws the slots and empty words the corpus names", function()
		local data = corpus()
		helpers.assert_eq(PairRows.SLOT_ORDER, data.slot_order)
		helpers.assert_eq(PairRows.EMPTY_ACTION_KEY, data.empty_action_key)
		helpers.assert_eq(PairRows.EMPTY_HOLD_KEY, data.empty_hold_key)
	end)
	helpers.it("(kcd-8) summarizes every corpus pair as Windows does", function()
		local data = corpus()
		helpers.assert_true(#data.summaries >= 4, "the corpus covers every slot combination")
		for _, vector in ipairs(data.summaries) do
			-- The decoder drops a null member: an empty slot reads as nil, and a
			-- null summary is the empty word.
			helpers.assert_eq(PairRows.summary(get, vector.tap, vector.hold), vector.summary or get(data.empty_action_key))
		end
	end)
	helpers.it("(kcd-8) names a pair row through common.label_value", function()
		local function locale(key) return key == "common.label_value" and "{1} : {2}" or get(key) end
		helpers.assert_eq(PairRows.pair_label(locale, "Tab", "Esc", "Copy", nil), "Tab + Esc : Copy")
		helpers.assert_eq(PairRows.pair_label(locale, "Tab", "Esc", nil, nil), "Tab + Esc : translated:dialog.action_picker.disabled")
	end)
end)
