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
		helpers.assert_eq(row.label_color, chrome.colors.label_unselected)
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

helpers.describe("prediction shortcut column", function()
	helpers.it("keeps all ten bound digits outside the body and gray after modifier changes", function()
		local overlay, chrome = overlay_with_indent(0)
		local candidates = {}
		for index = 1, 10 do candidates[index] = { to_type = string.rep("M", index) } end
		for _, modifiers in ipairs(require("modules.llm.navigation_settings").options()) do
			local rows = overlay.build_rows(candidates, 3, { validation_modifiers = modifiers })
			local prefix = table.concat(modifiers, "+"):gsub("alt", "Alt"):gsub("ctrl", "Ctrl")
				:gsub("shift", "Shift"):gsub("cmd", "Super")
			for index = 1, 10 do
				local expected = (prefix ~= "" and prefix .. "+" or "") .. (index == 10 and "0" or index)
				helpers.assert_eq(rows[index].label, expected)
				helpers.assert_eq(rows[index].label_color, chrome.colors.label_unselected)
				helpers.assert_eq(rows[index].label_gap, chrome.column_gap)
				helpers.assert_eq(#rows[index].segments, 1, "shortcut must not be a body segment")
			end
		end
	end)

	helpers.it("reserves label separation and keeps different widths against the same edge", function()
		local column = require("tooltip.shortcut_column")
		helpers.assert_eq(column.width(37, 16, 12), 65)
		helpers.assert_eq(column.width(37, 0, 12), 37)
		helpers.assert_eq(column.left(65, 8), 57)
		helpers.assert_eq(column.left(65, 16), 49)
	end)
end)

helpers.describe("prediction column native adapter measurement", function()
	helpers.it("reserves the widest body and widest label even on different rows", function()
		local previous = package.loaded["adapters.graphics_renderer"]
		package.loaded["adapters.graphics_renderer"] = nil
		local ok, err = pcall(function()
			local renderer = require("adapters.graphics_renderer")
			renderer._set_binding_for_test({ Pango = { FontDescription = {
				from_string = function() return { set_size = function() end } end,
			} } })
			local text = ""
			local layout = { set_font_description = function() end,
				set_text = function(_, value) text = value end,
				get_pixel_size = function() return #text * 2, 10 end }
			local size = renderer.measure_rows({
				{ segments = {{ text = "longbody" }}, label = "1", label_gap = 12 },
				{ segments = {{ text = "x" }}, label = "Ctrl+Shift+0", label_gap = 12 },
			}, { fonts = { main = "sans", bold = "sans bold" }, sizes = { main = 14, hint = 11 },
				layout = { pad_x = 14, pad_y = 7, line_spacing = 2, label_gap = 9 } }, layout)
			-- Independent measured values: body16, label24, gap12, outer padding28.
			helpers.assert_eq(size.w, 80)
		end)
		package.loaded["adapters.graphics_renderer"] = previous
		if not ok then error(err, 0) end
	end)
end)
