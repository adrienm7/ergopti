--- _shared/lua/tooltip/layout.lua

--- ==============================================================================
--- MODULE: Tooltip Layout (Shared)
--- DESCRIPTION:
--- Where the preview tooltip goes, given an anchor and the screen it must stay
--- inside. Pure: the only OS-derived inputs are the arguments.
---
--- WHY IT IS SHARED AND WHY IT IS PURE:
--- _shared/modules/tooltip/layout.js is the reference implementation and
--- _shared/tests/corpus/tooltip/layout_vectors.json is its output. Every driver
--- has to agree with those vectors, and the only way to check that is to be able
--- to CALL the maths with a synthetic screen frame. On macOS this arithmetic
--- used to be inline in the render path, so the corpus test replayed a CLONE of
--- it defined inside the test file — while its docstring claimed to catch "any
--- divergence in clamping or positioning". It pinned the clone.
---
--- THE THREE ANCHOR KINDS, AND WHY THEY DIFFER:
---   caret     — the insertion point. The tooltip goes below and to the RIGHT,
---               because a tooltip centred on the caret covers the word being
---               typed, which is the word it is previewing.
---   input_box — an element with known bounds and no caret. Centred under it,
---               and flipped ABOVE when it would fall off the bottom.
---   nil       — nothing could be resolved. Centre-bottom of the screen, which
---               is visible without claiming to point at anything.
--- Clamping is last and unconditional: a tooltip half off-screen is worse than
--- one in the wrong place, because the user cannot read it at all.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Position resolution ==============
-- =============================================
-- =============================================

--- Places the tooltip, then clamps it into the frame.
---
--- @param anchor table|nil { type = "caret"|"input_box"|…, x, y, w, h }.
---   nil means nothing could be resolved.
--- @param canvas table { w, h } Tooltip size in layout units.
--- @param screen_frame table { x, y, w, h } The frame to place and clamp within.
--- @param opts table Geometry, from _shared/modules/tooltip/constants.toml:
---   caret_offset_x, caret_offset_y, window_offset_y, screen_margin.
--- @return table { x, y } The clamped top-left corner.
function M.compute_position(anchor, canvas, screen_frame, opts)
	local width, height = canvas.w, canvas.h
	local x, y

	-- "Has coordinates", not "is truthy". A JSON decoder represents null as a
	-- sentinel rather than nil, so a corpus vector with `"anchor": null` arrives
	-- as a truthy value with no x — and a truthiness test would take the caret
	-- branch and do arithmetic on nothing.
	local has_anchor = type(anchor) == "table" and type(anchor.x) == "number"

	if has_anchor then
		if anchor.type == "caret" then
			-- Below and to the right: a tooltip centred on the caret covers the
			-- word it is previewing.
			x = anchor.x + opts.caret_offset_x
			y = anchor.y + (anchor.h or 0) + opts.caret_offset_y
		else
			x = anchor.x - width / 2
			y = anchor.y + opts.window_offset_y
			-- Flip above the anchor rather than let the clamp shove it back up
			-- over the element: clamping would cover the thing being annotated.
			if y + height > screen_frame.y + screen_frame.h then
				y = anchor.y - height - opts.window_offset_y
			end
		end
	else
		x = screen_frame.x + (screen_frame.w - width) / 2
		y = screen_frame.y + screen_frame.h - height - opts.window_offset_y
	end

	local margin = opts.screen_margin
	return {
		x = math.max(screen_frame.x + margin,
			math.min(x, screen_frame.x + screen_frame.w - width - margin)),
		y = math.max(screen_frame.y + margin,
			math.min(y, screen_frame.y + screen_frame.h - height - margin)),
	}
end

return M
