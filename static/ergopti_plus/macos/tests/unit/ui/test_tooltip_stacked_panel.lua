--- tests/unit/ui/test_tooltip_stacked_panel.lua

--- ==============================================================================
--- MODULE: Tooltip Stacked Panel — Rounded Clip Mask + Per-Row Colors (regression)
--- DESCRIPTION:
--- Locks down the element structure of the multi-row (hotstring) tooltip: a
--- rounded action="clip" mask (element 1) defines the rounded clipping region,
--- every per-row background is a SQUARE fill clipped to that region (so each row
--- carries its own category color while the outer corners round and the edges
--- between rows stay straight), clipping is reset before the border, and the
--- border is the rounded stroke on top.
---
--- ROOT CAUSE ENCODED — TWO distinct bugs this structure must never reintroduce:
---   1. SOLID RED TOOLTIP: an early rounded action="clip" element with no fill
---      rendered as its DEFAULT red fill on a build that ignored the clip action,
---      painting the whole tooltip red. Guard: the clip element's fillColor is
---      transparent (alpha 0), so an unsupported clip degrades to invisible.
---   2. COLOR BLEED ("vert rouge tronqué, petite partie verte"): a later no-clip
---      attempt painted ONE panel rectangle in the FIRST row's color and inset
---      differing rows by the corner radius — so the last row's corner band bled
---      the panel color and the inset truncated the fills. Guard: there is NO
---      single panel fill; every row paints its own full-height square background.
--- These assertions fail if the clip mask is dropped, its fill turns opaque, a
--- per-row background regains rounding, or a row stops painting its own color.
---
--- NOTE: the stub hs.canvas is a no-op mock, so the element STRUCTURE (not the
--- rendered pixels) is what is testable; M._build_stacked_elements is pure for
--- exactly this reason.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Force a fresh config load by clearing the config and the TOML reader cache so
-- that no stale cache-provider state from a prior test produces a partial parse
-- (e.g. missing the [typography] section that config.lua requires).
package.loaded["ui.tooltip.config"] = nil
package.loaded["toml_codec.reader"] = nil
package.loaded["lib.toml_reader"]   = nil

local Renderer = helpers.load_with_stubs("ui.tooltip.renderer")

helpers.describe("tooltip stacked panel: rounded clip mask, per-row colors", function()
	helpers.it("element 1 is a rounded clip mask with a TRANSPARENT fill", function()
		local els = Renderer._build_stacked_elements(1)
		helpers.assert_eq(els[1].type, "rectangle")
		helpers.assert_eq(els[1].action, "clip")
		helpers.assert_true(type(els[1].roundedRectRadii) == "table"
			and (els[1].roundedRectRadii.xRadius or 0) > 0,
			"the clip mask must be rounded so the outer corners round")
		-- The transparent fill is the guard against the historical all-red tooltip:
		-- a build that ignores the clip action must paint nothing, not red.
		helpers.assert_true(type(els[1].fillColor) == "table" and els[1].fillColor.alpha == 0,
			"the clip mask fill must be transparent (alpha 0) so an unsupported clip never paints red")
	end)

	helpers.it("emits exactly one clip and one resetClip, in that order", function()
		for _, n in ipairs({ 1, 2, 3 }) do
			local els = Renderer._build_stacked_elements(n)
			local clip_idx, reset_idx
			for i, el in ipairs(els) do
				if el.action == "clip" then
					helpers.assert_true(clip_idx == nil, "only one clip mask is allowed")
					clip_idx = i
				elseif el.action == "resetClip" then
					helpers.assert_true(reset_idx == nil, "only one resetClip is allowed")
					reset_idx = i
				end
			end
			helpers.assert_eq(clip_idx, 1)  -- the clip mask leads the stack
			helpers.assert_true(reset_idx ~= nil and reset_idx == n * 4 + 1,
				"resetClip must sit just before the border so its stroke is not clipped")
		end
	end)

	helpers.it("has the clip + rows + separators + resetClip + border element count", function()
		for _, n in ipairs({ 1, 2, 3 }) do
			local els = Renderer._build_stacked_elements(n)
			-- 1 clip + 3*n per-row + (n-1) separators + 1 resetClip + 1 border = 4n + 2
			helpers.assert_eq(#els, n * 4 + 2)
		end
	end)

	helpers.it("ends with a rounded stroked border AFTER the resetClip", function()
		local els = Renderer._build_stacked_elements(2)
		local last = els[#els]
		helpers.assert_eq(last.action, "strokeAndFill")
		helpers.assert_true(type(last.roundedRectRadii) == "table",
			"the border must be rounded to match the clip mask")
		helpers.assert_eq(els[#els - 1].action, "resetClip")
	end)

	helpers.it("every per-row background is a fill (no single panel paints the rows)", function()
		-- The no-clip bleed bug skipped rows that matched a shared panel color; here
		-- there is no panel, so each row MUST paint its own background unconditionally.
		for _, n in ipairs({ 1, 2, 3 }) do
			local els = Renderer._build_stacked_elements(n)
			for i = 1, n do
				helpers.assert_eq(els[(i - 1) * 3 + 2].action, "fill")
			end
		end
	end)

	helpers.it("per-row backgrounds are SQUARE (straight edges between rows)", function()
		-- The user-facing contract: a multi-row stack is ONE rounded box with straight
		-- separators, never a rounded card per row. Only the clip mask (element 1) and
		-- the outer border may round; every per-row background must be square.
		for _, n in ipairs({ 2, 3 }) do
			local els = Renderer._build_stacked_elements(n)
			for i = 1, n do
				local bg = els[(i - 1) * 3 + 2]
				helpers.assert_true(bg.roundedRectRadii == nil,
					"row " .. i .. "/" .. n .. " background must be square (no roundedRectRadii) "
						.. "so the edges between rows are straight lines")
			end
		end
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
