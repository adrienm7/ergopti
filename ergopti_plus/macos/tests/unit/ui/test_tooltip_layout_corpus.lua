--- tests/unit/ui/test_tooltip_layout_corpus.lua

--- ==============================================================================
--- MODULE: Tooltip Layout Corpus Consumer (macOS)
--- DESCRIPTION:
--- Loads the cross-driver tooltip layout corpus from
--- _shared/tests/corpus/tooltip/layout_vectors.json and replays each
--- position-resolution vector through the RENDERER's own positioning function,
--- asserting the output matches the expected golden values.
---
--- ROOT CAUSE ENCODED:
--- This file used to define its own CONSTANTS, clamp_to_screen and
--- resolve_position — a complete clone of the maths — and replay the corpus
--- against that, while this docstring claimed the test pinned the math "so any
--- divergence in clamping or positioning is caught immediately". It pinned the
--- clone. The renderer could have drifted arbitrarily and all six vectors would
--- still have passed, because nothing here ever loaded it.
---
--- The maths was inline inside M.render(), tangled with hs.window and hs.screen
--- calls, which is why it had not been extracted. It is now
--- renderer.compute_position(anchor, canvas, screen_frame): the anchor and the
--- frame are its only OS-derived inputs, so passing them in makes the rest pure
--- and lets the corpus's synthetic screenFrame drive the real code.
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

-- The renderer is the implementation under test. Loading it here is the whole
-- point: the clone that used to sit at this spot — its own CONSTANTS,
-- clamp_to_screen and resolve_position — made every assertion below a statement
-- about the test file rather than about the driver.
local renderer = helpers.load_with_stubs("ui.tooltip.renderer")




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
			local result = renderer.compute_position(vec.anchor, vec.canvasSize, vec.screenFrame)
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
	-- Driven through a CARET anchor, whose x is used directly (plus the offset),
	-- so the clamp is what decides the result. The window branch centres the
	-- tooltip on the anchor first, which would obscure what is being tested.
	helpers.it("clamps to the right margin", function()
		local screen = { x = 0, y = 0, w = 1000, h = 800 }
		local canvas = { w = 200, h = 100 }
		-- 900 + caret_offset_x is past the edge; maxX = 1000 - 200 - 5 = 795.
		local r = renderer.compute_position({ type = "caret", x = 900, y = 10, h = 0 }, canvas, screen)
		helpers.assert_eq(r.x, 795, "x clamped to maxX")
	end)

	helpers.it("clamps to the left margin", function()
		local screen = { x = 0, y = 0, w = 1000, h = 800 }
		local canvas = { w = 200, h = 100 }
		local r = renderer.compute_position({ type = "caret", x = -300, y = 10, h = 0 }, canvas, screen)
		helpers.assert_eq(r.x, 5, "x clamped to margin (5)")
	end)

	helpers.it("resolve_position with null anchor centres bottom", function()
		local screen = { x = 0, y = 0, w = 1920, h = 1080 }
		local canvas = { w = 300, h = 80 }
		local r = renderer.compute_position(nil, canvas, screen)
		helpers.assert_eq(r.x, 810, "centred x")
		helpers.assert_eq(r.y, 995, "bottom y")
	end)

	-- A non-caret anchor is treated as a window anchor: centred on the anchor,
	-- offset below it.
	--
	-- This test previously asserted that an unknown type falls back to
	-- centre-bottom, which is what the shared JS does — and what the CLONE this
	-- file used to replay did. The renderer does not: it branches on
	-- `type == "caret"` and treats everything else as a window anchor. That
	-- divergence from the spec sat here undetected precisely because the test
	-- exercised the clone.
	--
	-- It is latent, not live. resolve_anchor() produces only "caret",
	-- "input_box", "window" or nil, and for all four the renderer agrees with
	-- the shared implementation. Adding an unknown-type branch would be a dead
	-- one, so the behaviour is pinned as it is rather than "fixed".
	helpers.it("treats a non-caret anchor as a window anchor", function()
		local screen = { x = 0, y = 0, w = 1920, h = 1080 }
		local canvas = { w = 300, h = 80 }
		local r = renderer.compute_position({ type = "window", x = 960, y = 500, h = 0 }, canvas, screen)
		helpers.assert_eq(r.x, 810, "centred horizontally on the anchor (960 - 300/2)")
		helpers.assert_eq(r.y, 505, "offset below the anchor by window_offset_y")
	end)
end)
