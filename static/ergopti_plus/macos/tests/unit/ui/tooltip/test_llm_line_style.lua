--- tests/unit/ui/tooltip/test_llm_line_style.lua

--- ==============================================================================
--- MODULE: What An AI Prediction Line Reads (macOS)
--- DESCRIPTION:
--- macOS is the reference for the prediction tooltip: on the selected line the
--- typed text is grey, the corrected part green and the continuation orange,
--- and the indentation setting places the cursor mark. That rule used to live
--- inside the canvas code, where no other driver could read it; it is now
--- _shared/lua/tooltip/llm_line.lua, shared with Linux and ported by Windows.
---
--- The first half replays the cross-driver corpus against the shared rule. The
--- second drives the real tooltip and records every styled piece it builds, so
--- the colours each role wears stay what they were before the extraction
--- (llm-line-style).
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.tooltip_watcher_fixture")

local corpus_path = helpers.shared("tests/corpus/tooltip/llm_line_vectors.json")

--- Reads the corpus, or raises: a missing cross-driver contract must fail.
--- @return table
local function read_corpus()
	local fh = assert(io.open(corpus_path, "r"), "cannot open corpus at " .. corpus_path)
	local raw = fh:read("*a")
	fh:close()
	return require("hs").json.decode(raw)
end

local corpus = read_corpus()
local LlmLine = require("tooltip.llm_line")

helpers.describe("AI prediction line: shared corpus (llm-line-style)", function()
	for _, vector in ipairs(corpus.prefixes) do
		helpers.it("(llm-line-style) prefix: " .. vector.id, function()
			local selected, unselected = LlmLine.prefixes(
				vector.indent, vector.line_count, corpus.mark, corpus.align)
			helpers.assert_eq(selected, vector.expected.selected, vector.id .. ": selected")
			helpers.assert_eq(unselected, vector.expected.unselected, vector.id .. ": unselected")
		end)
	end

	for _, vector in ipairs(corpus.segments) do
		helpers.it("(llm-line-style) segments: " .. vector.id, function()
			local segments = LlmLine.segments(vector.prediction, vector.selected)
			helpers.assert_eq(#segments, #vector.expected, vector.id .. ": piece count")
			for index, expected in ipairs(vector.expected) do
				local where = vector.id .. " #" .. index
				helpers.assert_eq(segments[index].text, expected.text, where .. ": text")
				helpers.assert_eq(segments[index].role, expected.role, where .. ": role")
				helpers.assert_eq(segments[index].bold, expected.bold, where .. ": bold")
			end
		end)
	end
end)

local CORRECTING = {
	chunks = { { type = "equal", text = "bonjou" }, { type = "insert", text = "r" } },
	nw = " le monde",
	has_corrections = true,
}

--- Renders one prediction through the real tooltip and returns every styled
--- piece it built, in order, as { text, color }.
--- @param fixture table Tooltip watcher fixture.
--- @param indent number The indentation setting.
--- @return table pieces, table config
local function styled_pieces(fixture, indent)
	local context = fixture.load_tooltip(support.CASES[1])
	local pieces = {}
	local real_new = hs.styledtext.new
	hs.styledtext.new = function(text, attributes)
		pieces[#pieces + 1] = { text = text, color = type(attributes) == "table" and attributes.color or nil }
		return real_new(text, attributes)
	end
	local ok, err = pcall(context.tooltip.show_predictions,
		{ CORRECTING, { chunks = {}, nw = "tout va bien" } }, 1, true, nil, "alt", indent)
	hs.styledtext.new = real_new
	assert(ok, err)
	return pieces, context.config
end

--- Whether a piece with this text was built in this colour.
--- @param pieces table
--- @param text string
--- @param color table
--- @return boolean
local function built(pieces, text, color)
	for _, piece in ipairs(pieces) do
		if piece.text == text and piece.color == color then return true end
	end
	return false
end

helpers.describe("tooltip_llm: the colours of a line (llm-line-style)", function()
	helpers.it("(llm-line-style) typed text is grey, the correction green, the next words orange", function()
		support.with_fixture(function(fixture)
			local pieces, config = styled_pieces(fixture, 0)
			helpers.assert_true(built(pieces, "bonjou", config.colors.unsel_gray), "typed text is grey")
			helpers.assert_true(built(pieces, "r", config.colors.corr_sel), "the correction is green")
			helpers.assert_true(built(pieces, " le monde", config.colors.nw_sel), "the next words are orange")
			helpers.assert_true(config.colors.corr_sel ~= config.colors.nw_sel,
				"the two accents must be different colours")
		end)
	end)

	helpers.it("(llm-line-style) the mark is drawn on the selected line and reserved, invisible, at -3", function()
		support.with_fixture(function(fixture)
			local pieces, config = styled_pieces(fixture, -3)
			helpers.assert_true(built(pieces, config.llm_ui.active_prefix, config.colors.cursor),
				"the selected line carries the mark")
			helpers.assert_true(built(pieces, config.llm_ui.active_prefix, config.colors.invis),
				"the other lines carry its width without drawing it")
		end)
	end)
end)
