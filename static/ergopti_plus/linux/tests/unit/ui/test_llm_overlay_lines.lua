--- tests/unit/ui/test_llm_overlay_lines.lua

--- ==============================================================================
--- MODULE: What An AI Prediction Line Reads (Linux)
--- DESCRIPTION:
--- The suggestion overlay drew each candidate's `to_type` as white text, with
--- no cursor mark, and read the indentation the other way round from macOS (a
--- negative value pushed the selected line). A line now reads as on macOS:
--- the mark in front of the selected line, the typed text grey, the corrected
--- part green and the continuation orange on it, grey on every other line.
---
--- The rule itself is _shared/lua/tooltip/llm_line.lua; the first half replays
--- the cross-driver corpus against it, the second drives the overlay's rows
--- (llm-line-style).
--- ==============================================================================

local helpers = require("tests.helpers")

local shared_root = helpers.driver_root() .. "/../_shared"
local corpus_path = shared_root .. "/tests/corpus/tooltip/llm_line_vectors.json"

--- Reads the corpus, or raises: a missing cross-driver contract must fail.
--- @return table
local function read_corpus()
	local fh = assert(io.open(corpus_path, "r"), "cannot open corpus at " .. corpus_path)
	local raw = fh:read("*a")
	fh:close()
	return require("json").decode(raw)
end

local corpus = read_corpus()
local LlmLine = require("tooltip.llm_line")

helpers.describe("AI prediction line: shared corpus (llm-line-style)", function()
	helpers.it("(llm-line-style) the corpus carries both families of vectors", function()
		helpers.assert_true(#corpus.prefixes > 0, "prefix vectors")
		helpers.assert_true(#corpus.segments > 0, "segment vectors")
	end)

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

--- Loads the overlay with the indentation the case asks for.
--- @param indent integer
--- @return table overlay, table chrome
local function overlay_with_indent(indent)
	local previous = package.loaded["modules.llm.display_settings"]
	package.loaded["modules.llm.display_settings"] = {
		get = function(name) return name == "pred_indent" and indent or false end,
	}
	package.loaded["ui.tooltip.llm"] = nil
	local overlay = require("ui.tooltip.llm")
	package.loaded["modules.llm.display_settings"] = previous
	package.loaded["ui.tooltip.llm"] = nil
	return overlay, require("ui.tooltip.config").llm_line()
end

local CORRECTING = {
	to_type = "r le monde",
	chunks = { { type = "equal", text = "bonjou" }, { type = "insert", text = "r" } },
	nw = " le monde",
	has_corrections = true,
}
local CONTINUING = { to_type = " tout va bien", chunks = {}, nw = " tout va bien" }

helpers.describe("AI overlay: a line reads as on macOS (llm-line-style)", function()
	helpers.it("(llm-line-style) the selected line is grey, green then orange, after the mark", function()
		local overlay, chrome = overlay_with_indent(0)
		local row = overlay.build_rows({ CORRECTING, CONTINUING }, 1, {})[1]
		helpers.assert_eq(row.prefix, chrome.mark)
		helpers.assert_eq(row.prefix_color, chrome.colors.cursor)
		helpers.assert_eq(row.segments[1].text, "bonjou")
		helpers.assert_eq(row.segments[1].color, chrome.colors.typed)
		helpers.assert_eq(row.segments[2].text, "r")
		helpers.assert_eq(row.segments[2].color, chrome.colors.corrected)
		helpers.assert_eq(row.segments[3].text, " le monde")
		helpers.assert_eq(row.segments[3].color, chrome.colors.next)
		helpers.assert_true(chrome.colors.corrected ~= chrome.colors.next,
			"the correction and the continuation must not share a colour")
	end)

	helpers.it("(llm-line-style) every other line is grey and draws no mark", function()
		local overlay, chrome = overlay_with_indent(0)
		local row = overlay.build_rows({ CORRECTING, CONTINUING }, 2, {})[1]
		helpers.assert_eq(row.prefix_color, nil)
		for index = 1, 3 do
			helpers.assert_eq(row.segments[index].color, chrome.colors.typed, "piece " .. index)
		end
		helpers.assert_eq(row.segments[4].color, chrome.colors.label_unselected)
	end)

	helpers.it("(llm-line-style) a plain continuation is orange, without its joining space", function()
		local overlay, chrome = overlay_with_indent(0)
		local row = overlay.build_rows({ CONTINUING }, 1, {})[1]
		helpers.assert_eq(row.segments[1].text, "tout va bien")
		helpers.assert_eq(row.segments[1].color, chrome.colors.next)
	end)

	helpers.it("(llm-line-style) text that is only typed is a continuation, or a correction of the selection", function()
		local overlay, chrome = overlay_with_indent(0)
		local rows = overlay.build_rows({ { to_type = "an answer", deletes = 0 } }, 1, {})
		helpers.assert_eq(rows[1].segments[1].color, chrome.colors.next)
		rows = overlay.build_rows(
			{ { to_type = "translated", deletes = 0, replaces_selection = true } }, 1, {})
		helpers.assert_eq(rows[1].segments[1].color, chrome.colors.corrected)
	end)

	helpers.it("(llm-line-style) -3 keeps every line aligned: the others carry the mark's width", function()
		local overlay, chrome = overlay_with_indent(-3)
		local rows = overlay.build_rows({ CORRECTING, CONTINUING }, 1, {})
		helpers.assert_eq(rows[1].prefix, chrome.mark)
		helpers.assert_eq(rows[2].prefix, chrome.mark)
		helpers.assert_eq(rows[2].prefix_color, nil)
	end)

	helpers.it("(llm-line-style) a negative indentation pushes the other lines, not the selected one", function()
		local overlay, chrome = overlay_with_indent(-2)
		local rows = overlay.build_rows({ CORRECTING, CONTINUING }, 1, {})
		helpers.assert_eq(rows[1].prefix, chrome.mark)
		helpers.assert_eq(rows[2].prefix, "  " .. chrome.align)
	end)
end)
