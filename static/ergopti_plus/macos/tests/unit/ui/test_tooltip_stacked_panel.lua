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
package.loaded["lib.toml_reader"]   = nil

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
