--- tests/unit/menu/shortcuts/test_key_combination_pair_rows.lua

--- ==============================================================================
--- MODULE: Key Combination Pair Row Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/tap_hold/key_combination_pair_rows.json through
--- the shared summary the Linux menu draws its pair rows with: tap, hold and
--- chord in that order, the Windows layout (maintainer decision KCD-8).
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

helpers.describe("(kcd-8) shared key-combination pair rows", function()
	local CombinationLabels = require("tap_hold.engine.combination_labels")
	helpers.it("(kcd-8) orders and joins the slots the corpus names", function()
		local data = corpus()
		helpers.assert_eq(CombinationLabels.SLOT_ORDER, data.slot_order)
		helpers.assert_eq(CombinationLabels.SUMMARY_SEPARATOR, data.separator)
	end)
	helpers.it("(kcd-8) summarizes every corpus pair, chord included, as Windows does", function()
		local data = corpus()
		helpers.assert_eq(#data.summaries, 8, "the corpus covers every slot combination")
		for _, vector in ipairs(data.summaries) do
			helpers.assert_eq(CombinationLabels.summary(vector.labels, data.empty), vector.expected, vector.name)
		end
	end)
end)
