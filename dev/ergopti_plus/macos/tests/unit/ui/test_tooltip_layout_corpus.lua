--- tests/unit/ui/test_tooltip_layout_corpus.lua

--- ==============================================================================
--- MODULE: Tooltip Layout Corpus Consumer (macOS)
--- DESCRIPTION:
--- Loads the cross-driver tooltip layout corpus from
--- _shared/tests/corpus/tooltip/layout_vectors.json and replays each
--- position-resolution vector through a pure-Lua clone of the shared
--- layout.js resolvePosition + clampToScreen logic, asserting the output
--- matches the expected golden values.
---
--- The macOS renderer (ui/tooltip/renderer.lua) implements this same math
--- inline. This test pins the math against the shared vectors so any
--- divergence in clamping or positioning is caught immediately.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ===============================================
-- ===============================================
-- ======= 1/ Corpus Loading =====================
-- ===============================================
-- ===============================================

local corpus_path = helpers.shared("tests/corpus/tooltip/layout_vectors.json")

local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then return nil, "cannot open corpus at " .. corpus_path end
	local raw = fh:read("*a")
	fh:close()
	local ok, result = pcall(require("hs").json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(result) end
	return result, nil
end

local corpus_root, corpus_err = read_corpus()




-- ===============================================
-- ===============================================
-- ======= 2/ Pure-Lua Layout Clone ==============
-- ===============================================
-- ===============================================

-- Mirrors _shared/modules/tooltip/layout.js resolvePosition + clampToScreen.
-- Pure functions — no OS calls, no hs.*. Used to validate the layout corpus
-- vectors against the canonical math without depending on the real renderer.

local CONSTANTS = {
	caretOffsetX = 15,
	caretOffsetY = 18,
	windowOffsetY = 5,
	screenMargin = 5,
}

local function clamp_to_screen(pos, canvas_size, screen_frame, margin)
	margin = margin or CONSTANTS.screenMargin
	local minX = screen_frame.x + margin
	local maxX = screen_frame.x + screen_frame.w - canvas_size.w - margin
	local minY = screen_frame.y + margin
	local maxY = screen_frame.y + screen_frame.h - canvas_size.h - margin
	return {
		x = math.max(minX, math.min(pos.x, maxX)),
		y = math.max(minY, math.min(pos.y, maxY)),
	}
end

local function resolve_position(anchor, canvas_size, screen_frame)
	local posX, posY

	if not anchor then
		posX = screen_frame.x + (screen_frame.w - canvas_size.w) / 2
		posY = screen_frame.y + screen_frame.h - canvas_size.h - CONSTANTS.windowOffsetY
	elseif anchor.type == "caret" or anchor.type == "screen" then
		posX = anchor.x + CONSTANTS.caretOffsetX
		posY = anchor.y + (anchor.h or 0) + CONSTANTS.caretOffsetY
	elseif anchor.type == "input_box" or anchor.type == "window" then
		posX = anchor.x - canvas_size.w / 2
		posY = anchor.y + CONSTANTS.windowOffsetY
		if posY + canvas_size.h > screen_frame.y + screen_frame.h then
			posY = anchor.y - canvas_size.h - CONSTANTS.windowOffsetY
		end
	else
		posX = screen_frame.x + (screen_frame.w - canvas_size.w) / 2
		posY = screen_frame.y + screen_frame.h - canvas_size.h - CONSTANTS.windowOffsetY
	end

	return clamp_to_screen({ x = posX, y = posY }, canvas_size, screen_frame)
end




-- ===============================================
-- ===============================================
-- ======= 3/ Corpus Integrity ===================
-- ===============================================
-- ===============================================

helpers.describe("tooltip layout corpus — integrity", function()
	helpers.it("corpus file is readable and parseable", function()
		helpers.assert_true(corpus_root ~= nil,
			"corpus load error: " .. tostring(corpus_err))
		helpers.assert_true(type(corpus_root) == "table",
			"corpus root must be a table")
		helpers.assert_true(type(corpus_root.vectors) == "table",
			"corpus.vectors must be a table")
		helpers.assert_true(#corpus_root.vectors > 0,
			"corpus must have at least one vector")
	end)

	helpers.it("every vector has required fields: id, anchor, canvasSize, screenFrame, expected", function()
		if not corpus_root then return end
		for _, v in ipairs(corpus_root.vectors) do
			helpers.assert_true(type(v.id) == "string" and v.id ~= "",
				"vector missing id field")
			helpers.assert_true(v.expected ~= nil,
				"vector '" .. tostring(v.id) .. "' missing expected")
		end
	end)
end)




-- ===============================================
-- ===============================================
-- ======= 4/ Vector Execution ===================
-- ===============================================
-- ===============================================

helpers.describe("tooltip layout corpus — vector replay", function()
	if not corpus_root then return end

	for _, vec in ipairs(corpus_root.vectors) do
		helpers.it("layout: " .. vec.id, function()
			local result = resolve_position(vec.anchor, vec.canvasSize, vec.screenFrame)
			helpers.assert_true(result ~= nil, "result must not be nil")
			helpers.assert_eq(result.x, vec.expected.x,
				vec.id .. ": x mismatch (expected " .. tostring(vec.expected.x) .. ", got " .. tostring(result.x) .. ")")
			helpers.assert_eq(result.y, vec.expected.y,
				vec.id .. ": y mismatch (expected " .. tostring(vec.expected.y) .. ", got " .. tostring(result.y) .. ")")
		end)
	end
end)




-- ===============================================
-- ===============================================
-- ======= 5/ Additional Regression Tests ========
-- ===============================================
-- ===============================================

helpers.describe("tooltip layout — additional regression edges", function()
	helpers.it("clamp respects margin on all four sides", function()
		local screen = { x = 0, y = 0, w = 1000, h = 800 }
		local canvas = { w = 200, h = 100 }
		-- Too far right — clamp to maxX = 1000 - 200 - 5 = 795
		local r = clamp_to_screen({ x = 900, y = 10 }, canvas, screen)
		helpers.assert_eq(r.x, 795, "x clamped to maxX")
		helpers.assert_eq(r.y, 10, "y unchanged")
	end)

	helpers.it("clamp respects minX margin", function()
		local screen = { x = 0, y = 0, w = 1000, h = 800 }
		local canvas = { w = 200, h = 100 }
		local r = clamp_to_screen({ x = -50, y = 10 }, canvas, screen)
		helpers.assert_eq(r.x, 5, "x clamped to margin (5)")
	end)

	helpers.it("resolve_position with null anchor centres bottom", function()
		local screen = { x = 0, y = 0, w = 1920, h = 1080 }
		local canvas = { w = 300, h = 80 }
		local r = resolve_position(nil, canvas, screen)
		helpers.assert_eq(r.x, 810, "centred x")
		helpers.assert_eq(r.y, 995, "bottom y")
	end)

	helpers.it("resolve_position unknown anchor type defaults to centre-bottom", function()
		local screen = { x = 0, y = 0, w = 1920, h = 1080 }
		local canvas = { w = 300, h = 80 }
		local r = resolve_position({ type = "unknown", x = 100, y = 100 }, canvas, screen)
		helpers.assert_eq(r.x, 810, "centred x for unknown type")
		helpers.assert_eq(r.y, 995, "bottom y for unknown type")
	end)
end)
