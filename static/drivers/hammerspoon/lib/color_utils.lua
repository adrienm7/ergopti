-- lib/color_utils.lua

-- ===========================================================================
-- Color Utilities Module.
--
-- Provides reusable color helpers for UI modules, including hex parsing
-- and weighted blending against white.
-- ===========================================================================

local M = {}





-- ====================================
-- ====================================
-- ======= 1/ Color Conversions =======
-- ====================================
-- ====================================

--- Converts a #RRGGBB string to normalized RGB values.
--- @param hex string Hex color string
--- @return number|nil, number|nil, number|nil
function M.hex_to_rgb(hex)
	if type(hex) ~= "string" then return nil, nil, nil end
	local clean = hex:gsub("#", "")
	if #clean ~= 6 then return nil, nil, nil end

	local r = tonumber(clean:sub(1, 2), 16)
	local g = tonumber(clean:sub(3, 4), 16)
	local b = tonumber(clean:sub(5, 6), 16)
	if not r or not g or not b then return nil, nil, nil end

	return r / 255, g / 255, b / 255
end




-- ================================
-- ================================
-- ======= 2/ Color Mixing ========
-- ================================
-- ================================

--- Mixes a source hex color with white.
--- @param hex string Source color as #RRGGBB
--- @param color_ratio number Source ratio in [0, 1]
--- @param alpha number|nil Output alpha
--- @return table hs.color-compatible color
function M.mix_hex_with_white(hex, color_ratio, alpha)
	local ratio = math.min(1, math.max(0, color_ratio or 0.7))
	local white_ratio = 1 - ratio

	local r, g, b = M.hex_to_rgb(hex)
	if not r or not g or not b then
		return { white = 1, alpha = type(alpha) == "number" and alpha or 1 }
	end

	return {
		red = (r * ratio) + white_ratio,
		green = (g * ratio) + white_ratio,
		blue = (b * ratio) + white_ratio,
		alpha = type(alpha) == "number" and alpha or 1,
	}
end

return M
