--- tests/unit/ui/test_tooltip_stacked_panel.lua

--- ==============================================================================
--- MODULE: Tooltip Stacked Panel — Outer-Box Rounding, Per-Row Colors (regression)
--- DESCRIPTION:
--- Locks down the multi-row (hotstring) tooltip: only the four OUTER box corners
--- round, every edge between rows is a straight line, and each row paints its own
--- category color. Rounding is built WITHOUT hs.canvas clipping — the first/last
--- rows draw a rounded base plus a same-color square "cap" that flattens the
--- inner (separator-side) corners; middle rows are plain squares.
---
--- ROOT CAUSE ENCODED — THREE bugs this design must never reintroduce:
---   1. ROUNDED CARDS PER ROW: a multi-row stack used to round every row, so the
---      corners between rows were rounded. Guard: middle rows are square and the
---      first/last rows flatten their inner corners (M._row_corner_plan).
---   2. COLOR BLEED ("vert rouge tronqué, petite partie verte"): a single panel in
---      the FIRST row's color, inset for differing rows, bled the panel color into
---      the last row's corner band. Guard: NO shared panel — every row paints its
---      own background, and each corner cap is the SAME color as its row.
---   3. SOLID RED TOOLTIP: a rounded action="clip" mask painted its default red
---      fill on a build that ignored the clip action, turning the whole tooltip
---      red. Guard: NO clip/resetClip element is ever emitted.
---
--- NOTE: the stub hs.canvas is a no-op mock, so the per-element rounding is applied
--- in render_stacked (not unit-testable directly); the rounding DECISION is pulled
--- into the pure M._row_corner_plan so the corner logic IS unit-tested here.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Force a fresh config load by clearing the config and the TOML reader cache so
-- that no stale cache-provider state from a prior test produces a partial parse
-- (e.g. missing the [typography] section that config.lua requires).
package.loaded["ui.tooltip.config"] = nil
package.loaded["toml_codec.reader"] = nil
package.loaded["infra.toml.reader"]   = nil

local Renderer = helpers.load_with_stubs("ui.tooltip.renderer")

helpers.describe("tooltip stacked panel: outer-box rounding, no clip", function()
	helpers.it("never emits a clip / resetClip element (the all-red tooltip cause)", function()
		for _, n in ipairs({ 1, 2, 3 }) do
			for _, el in ipairs(Renderer._build_stacked_elements(n)) do
				helpers.assert_true(el.action ~= "clip" and el.action ~= "resetClip",
					"no clip/resetClip action — its default red fill turned the tooltip solid red")
			end
		end
	end)

	helpers.it("has a uniform 4-slot row block + separators + border element count", function()
		for _, n in ipairs({ 1, 2, 3 }) do
			local els = Renderer._build_stacked_elements(n)
			-- 4*n per-row (bg base, cap, text, label) + (n-1) separators + 1 border = 5n
			helpers.assert_eq(#els, n * 5)
		end
	end)

	helpers.it("each row block is [rect bg][rect cap][text][text]", function()
		for _, n in ipairs({ 1, 2, 3 }) do
			local els = Renderer._build_stacked_elements(n)
			for i = 1, n do
				local base = (i - 1) * 4 + 1
				helpers.assert_eq(els[base].type, "rectangle")      -- background base
				helpers.assert_eq(els[base + 1].type, "rectangle")  -- corner cap
				helpers.assert_eq(els[base + 2].type, "text")       -- output text
				helpers.assert_eq(els[base + 3].type, "text")       -- trigger label
			end
		end
	end)

	helpers.it("ends with a rounded stroked border at index 5n", function()
		for _, n in ipairs({ 1, 2, 3 }) do
			local els = Renderer._build_stacked_elements(n)
			local last = els[#els]
			helpers.assert_eq(#els, n * 5)
			helpers.assert_eq(last.action, "strokeAndFill")
			helpers.assert_true(type(last.roundedRectRadii) == "table",
				"the border must be rounded to match the outer box corners")
		end
	end)
end)

helpers.describe("tooltip stacked panel: M._row_corner_plan rounds only the box", function()
	helpers.it("a single-row stack is one fully rounded box, no cap", function()
		local plan = Renderer._row_corner_plan(1, 1)
		helpers.assert_true(plan.rounded, "the sole row is the whole box → rounded")
		helpers.assert_eq(plan.cap, "none")
	end)

	helpers.it("the first row rounds the top and flattens its bottom corners", function()
		local plan = Renderer._row_corner_plan(1, 3)
		helpers.assert_true(plan.rounded)
		helpers.assert_eq(plan.cap, "bottom")
	end)

	helpers.it("the last row rounds the bottom and flattens its top corners", function()
		local plan = Renderer._row_corner_plan(3, 3)
		helpers.assert_true(plan.rounded)
		helpers.assert_eq(plan.cap, "top")
	end)

	helpers.it("middle rows are fully square with no cap (no inter-row rounding)", function()
		local plan = Renderer._row_corner_plan(2, 3)
		helpers.assert_true(not plan.rounded,
			"a middle row must be square so the corners between rows are straight")
		helpers.assert_eq(plan.cap, "none")
	end)
end)

helpers.describe("tooltip stacked panel: text measurement is memoized", function()
	-- minimumTextSize() is the dominant per-keystroke preview cost; the memo must
	-- only hit the ObjC call once per distinct (size_tag, text) pair.
	local function counting_canvas()
		local calls = { n = 0 }
		local canvas = {
			minimumTextSize = function(_self, _index, _styled)
				calls.n = calls.n + 1
				return { w = 10, h = 5 }
			end,
		}
		return canvas, calls
	end

	helpers.it("measures an identical (tag,text) pair only once", function()
		local canvas, calls = counting_canvas()
		local style = { font = { name = "x", size = 14 } }
		Renderer._measure_styled(canvas, 2, "bonjour", "main", style)
		Renderer._measure_styled(canvas, 2, "bonjour", "main", style)
		Renderer._measure_styled(canvas, 2, "bonjour", "main", style)
		helpers.assert_eq(calls.n, 1)  -- two later calls served from cache
	end)

	helpers.it("re-measures when the size tag differs (label vs row text)", function()
		local canvas, calls = counting_canvas()
		local style = { font = { name = "x", size = 14 } }
		Renderer._measure_styled(canvas, 2, "★", "main", style)
		Renderer._measure_styled(canvas, 2, "★", "hint", style)  -- different font size
		helpers.assert_eq(calls.n, 2)
	end)

	helpers.it("returns the measured size", function()
		local canvas = counting_canvas()
		local sz = Renderer._measure_styled(canvas, 2, "unique-token-xyz", "main", {})
		helpers.assert_eq(sz.w, 10)
		helpers.assert_eq(sz.h, 5)
	end)
end)




-- ==========================================================
-- ==========================================================
-- ======= 5/ M.render measures the combined footer once ====
-- ==========================================================
-- ==========================================================

--- ROOT CAUSE ENCODED: M.render computed `size_combined` inside the layout
--- DECISION block (does hint+info fit on one row?) and then DISCARDED it, only to
--- recompute the identical value ~25 lines later at the draw site. Nothing between
--- the two points changes element 3's text metrics, and is_combined_layout can
--- only be true if the first block ran — so the second call was pure waste,
--- doubling an ObjC text-layout call on every combined-layout render. This is the
--- same cost the stacked renderer already memoises.
---
--- NOTE: the other raw minimumTextSize calls in M.render are deliberately NOT
--- cached — prediction text is fresh on every render, so a cache would miss every
--- time and only add overhead. Only this duplicate was genuinely wasted work.

-- Distinctive markers so the combined footer measurement is identifiable purely
-- from the text handed to minimumTextSize (it contains BOTH halves).
local HINT_TEXT  = "HINTMARKER"
local INFO_TEXT  = "INFOMARKER"
local PREDS_TEXT = "PREDSMARKER"

-- Wide enough that the combined row always "fits" and the combined layout wins.
local FIXED_WIDTH_PX = 10000

--- Builds a styledtext double that survives concatenation, `#` and :setStyle(),
--- carrying its text along so the canvas double can report what was measured.
--- @return table An hs.styledtext replacement exposing `new`.
local function make_styledtext_stub()
	local mt = {}
	local function styled(text)
		return setmetatable({ text = text }, mt)
	end
	mt.__index = {
		-- render() re-centres the concatenated footer; the metrics are unaffected.
		setStyle = function(self) return self end,
	}
	mt.__concat = function(a, b)
		local at = (type(a) == "table" and a.text) or tostring(a)
		local bt = (type(b) == "table" and b.text) or tostring(b)
		return styled(at .. bt)
	end
	mt.__len = function(self) return #self.text end
	return { new = function(text, _style) return styled(text or "") end }, styled
end

--- Builds a canvas double that tallies every minimumTextSize call by measured text.
--- @return table canvas, table measurements Map of text -> call count.
local function make_counting_canvas()
	local measurements = {}
	local canvas = {
		minimumTextSize = function(_self, _index, styled_text)
			local text = (type(styled_text) == "table" and styled_text.text) or tostring(styled_text)
			measurements[text] = (measurements[text] or 0) + 1
			return { w = #text, h = 10 }
		end,
		frame = function() end,
		show  = function() end,
	}
	-- render() writes into elements 1..6 by index.
	for i = 1, 7 do canvas[i] = {} end
	return canvas, measurements
end

--- Returns the tally for the one measured string containing both footer halves.
--- @param measurements table Map of text -> call count.
--- @return integer count, string|nil the matched text
local function combined_footer_calls(measurements)
	for text, count in pairs(measurements) do
		if text:find(HINT_TEXT, 1, true) and text:find(INFO_TEXT, 1, true) then
			return count, text
		end
	end
	return 0, nil
end

--- Collects every string render() wrote into the canvas elements, so a test can
--- assert what was DRAWN rather than only what was measured.
--- @param canvas table The counting canvas double.
--- @return table Array of drawn strings.
local function drawn_texts(canvas)
	local out = {}
	for i = 1, 7 do
		local element = canvas[i]
		if type(element) == "table" then
			for _, value in pairs(element) do
				-- Styled text doubles carry their content on .text; plain strings
				-- are stored directly.
				local text = (type(value) == "table" and type(value.text) == "string" and value.text)
					or (type(value) == "string" and value)
					or nil
				if text then out[#out + 1] = text end
			end
		end
	end
	return out
end

helpers.describe("tooltip render: the combined footer is measured exactly once", function()
	helpers.it("does not measure the same combined row twice in one render", function()
		package.loaded["ui.tooltip.config"] = nil
		local styledtext_stub, styled = make_styledtext_stub()
		local R = helpers.load_with_stubs("ui.tooltip.renderer", { styledtext = styledtext_stub })

		local canvas, measurements = make_counting_canvas()
		R.canvas = canvas

		R.render(
			{
				preds   = styled(PREDS_TEXT),
				hint_st = styled(HINT_TEXT),
				info_st = styled(INFO_TEXT),
			},
			{ fixed_width = FIXED_WIDTH_PX, bg_color = { red = 0, green = 0, blue = 0 } },
			nil
		)

		local count, matched = combined_footer_calls(measurements)
		helpers.assert_not_nil(matched,
			"the combined hint+info footer must have been measured — otherwise this "
			.. "render never reached the combined layout and the test proves nothing")
		helpers.assert_eq(count, 1,
			"the combined footer must be measured ONCE per render; the layout decision "
			.. "and the draw site share one measurement rather than each paying for an "
			.. "ObjC text-layout call")

		-- Outcome, not just the tally. A render that measured the footer once and
		-- then drew nothing — or drew a different string — satisfies the count
		-- above while putting no footer on screen. Sharing a measurement is only
		-- an optimisation if the thing measured is also the thing rendered.
		local drawn = drawn_texts(canvas)
		local footer_on_canvas = false
		for _, text in ipairs(drawn) do
			if text:find(HINT_TEXT, 1, true) and text:find(INFO_TEXT, 1, true) then
				footer_on_canvas = true
				break
			end
		end
		helpers.assert_true(footer_on_canvas, string.format(
			"the measured combined footer must also reach the canvas. Asserting only the "
			.. "measurement count cannot tell a shared measurement apart from a render that "
			.. "measured and then bailed. Drawn: %s", table.concat(drawn, " | ")))
	end)
end)
