--- _shared/core/ui/engine/color_hex.lua

--- ==============================================================================
--- MODULE: Hex Color
--- DESCRIPTION:
--- Resolves CSS hexadecimal color forms to RGB for hue-based tooltip tinting.
--- Alpha is validated but does not alter the tint's configured opacity.
--- ==============================================================================

local M = {}

--- Parses a CSS hexadecimal color with an optional leading hash.
--- @param value any Color string.
--- @return table|nil rgb Normalized RGB channels, or nil for invalid input.
function M.parse(value)
	if type(value) ~= "string" then return nil end
	local hex = value:gsub("^#", "")
	local length = #hex
	if (length ~= 3 and length ~= 4 and length ~= 6 and length ~= 8)
		or hex:match("^[0-9a-fA-F]+$") == nil then return nil end
	if length == 3 or length == 4 then
		hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
	end
	return { red = tonumber(hex:sub(1, 2), 16) / 255,
		green = tonumber(hex:sub(3, 4), 16) / 255,
		blue = tonumber(hex:sub(5, 6), 16) / 255 }
end

return M
