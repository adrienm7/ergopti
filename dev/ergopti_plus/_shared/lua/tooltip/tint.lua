--- _shared/lua/tooltip/tint.lua

--- ==============================================================================
--- MODULE: Tooltip Tint (Shared)
--- DESCRIPTION:
--- Turns a category's accent colour into the dark background the preview is
--- drawn on: keep the hue, replace the lightness and saturation.
---
--- WHY NOT JUST DARKEN THE ACCENT:
--- Accents differ wildly in lightness — a yellow and a navy at the same
--- saturation are nowhere near each other — so darkening each one by a fixed
--- amount produces panels of visibly different brightness sitting next to each
--- other in the same list. Taking the HUE and imposing one lightness and one
--- saturation is what makes every category recognisable and every panel equally
--- readable. The two numbers live in _shared/modules/tooltip/constants.toml.
---
--- WHY AN ACHROMATIC ACCENT FALLS BACK:
--- Grey has no hue. Running it through the conversion produces a hue of zero,
--- which is red — so a category with a neutral accent would get a red panel.
--- The reference implementation (mixTint in tint.js) checks the same delta.
--- ==============================================================================

local M = {}

-- Below this chroma the colour has no meaningful hue and the conversion would
-- invent one. Matches the JS reference exactly, because the two are pinned to
-- the same vectors.
local ACHROMATIC_DELTA = 0.0001




-- =============================================
-- =============================================
-- ======= 1/ Hue extraction ===================
-- =============================================
-- =============================================

--- The hue of an RGB colour, normalised to 0..1, or nil when achromatic.
--- @param r number 0..1
--- @param g number 0..1
--- @param b number 0..1
--- @return number|nil
function M.hue_of(r, g, b)
	local max_c = math.max(r, g, b)
	local min_c = math.min(r, g, b)
	local delta = max_c - min_c
	if delta < ACHROMATIC_DELTA then return nil end

	local hue
	if max_c == r then
		hue = ((g - b) / delta) % 6
	elseif max_c == g then
		hue = (b - r) / delta + 2
	else
		hue = (r - g) / delta + 4
	end
	return hue / 6
end




-- =============================================
-- =============================================
-- ======= 2/ The tint =========================
-- =============================================
-- =============================================

--- Builds the background colour for a requested accent.
---
--- @param requested table|nil { red, green, blue } in 0..1, or nil.
--- @param opts table
---   lightness number   Imposed L, from [tint].lightness.
---   saturation number  Imposed S, from [tint].saturation.
---   alpha number       Alpha of the result.
---   neutral table      The colour to use when there is no hue to keep.
--- @return table { red, green, blue, alpha }
function M.mix(requested, opts)
	if type(requested) ~= "table" then return opts.neutral end

	local r = math.max(0, math.min(1, requested.red or 0))
	local g = math.max(0, math.min(1, requested.green or 0))
	local b = math.max(0, math.min(1, requested.blue or 0))

	local hue = M.hue_of(r, g, b)
	if not hue then return opts.neutral end

	local lightness, saturation = opts.lightness, opts.saturation
	local c = (1 - math.abs(2 * lightness - 1)) * saturation
	local x = c * (1 - math.abs((hue * 6) % 2 - 1))
	local m = lightness - c / 2
	local h6 = hue * 6

	local nr, ng, nb
	if h6 < 1 then nr, ng, nb = c, x, 0
	elseif h6 < 2 then nr, ng, nb = x, c, 0
	elseif h6 < 3 then nr, ng, nb = 0, c, x
	elseif h6 < 4 then nr, ng, nb = 0, x, c
	elseif h6 < 5 then nr, ng, nb = x, 0, c
	else nr, ng, nb = c, 0, x
	end

	return {
		red   = math.max(0, math.min(1, nr + m)),
		green = math.max(0, math.min(1, ng + m)),
		blue  = math.max(0, math.min(1, nb + m)),
		alpha = opts.alpha,
	}
end

return M
