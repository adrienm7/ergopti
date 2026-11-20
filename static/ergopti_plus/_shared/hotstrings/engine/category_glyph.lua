--- _shared/hotstrings/engine/category_glyph.lua

--- ==============================================================================
--- MODULE: Hotstring Category Glyph (Shared)
--- DESCRIPTION:
--- Picks the small symbol a preview row shows in a framed badge at its far
--- left, the i18n key that names it for a screen reader, and the badge's size.
---
--- WHY A GLYPH:
--- The preview tints sit at one lightness, so a colour-blind reader cannot tell
--- the categories apart by tint. A shape can. The maintainer chose a glyph per
--- category over a text label on 2026-11-19 (docs/memory/maintainer-decisions.md).
---
--- THE PRECEDENCE, from strongest to weakest, as the tint's colour:
---   1. `glyph` / `glyph_name_key` in the category's own [_meta]
---   2. the per-category default of _shared/hotstrings/data/catalogue/defaults.toml
---      ([glyphs] personal for the user's own hotstrings)
---   3. the shared default of the same file ([glyphs] global_default)
--- The glyph and its name resolve independently: a category may declare its own
--- glyph and keep the default name.
---
--- WHY A DECLARED VALUE CAN BE REFUSED:
--- A user or extension TOML may declare anything. A glyph is one visible
--- character: whitespace, a control character or a word would break the row's
--- layout. A refused value falls to the next rung and is returned in `rejected`
--- so the driver logs it; it is never shown.
--- Mirrored by windows/hotstrings/engine/catalogue/category_glyph.ahk, both
--- pinned to _shared/tests/corpus/hotstrings/category_glyph_vectors.json.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Validation =======================
-- =============================================
-- =============================================

--- The code points of a UTF-8 string, or nil when it is not valid UTF-8.
--- @param text string
--- @return table|nil
local function codepoints(text)
	local out, index, length = {}, 1, #text
	while index <= length do
		local byte = text:byte(index)
		local size, value
		if byte < 0x80 then size, value = 1, byte
		elseif byte >= 0xC2 and byte <= 0xDF then size, value = 2, byte - 0xC0
		elseif byte >= 0xE0 and byte <= 0xEF then size, value = 3, byte - 0xE0
		elseif byte >= 0xF0 and byte <= 0xF4 then size, value = 4, byte - 0xF0
		else return nil end
		if index + size - 1 > length then return nil end
		for offset = 1, size - 1 do
			local continuation = text:byte(index + offset)
			if continuation < 0x80 or continuation > 0xBF then return nil end
			value = value * 64 + (continuation - 0x80)
		end
		local minimum = ({ 0, 0x80, 0x800, 0x10000 })[size]
		if value < minimum or value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF) then return nil end
		out[#out + 1] = value
		index = index + size
	end
	return out
end

--- Whether a value can be shown as a category glyph: at most max_codepoints
--- code points, none of them whitespace or a control character.
--- @param value any
--- @param max_codepoints integer defaults.toml [glyphs] max_codepoints.
--- @return boolean
function M.is_glyph(value, max_codepoints)
	if type(value) ~= "string" or value == "" then return false end
	assert(type(max_codepoints) == "number" and max_codepoints >= 1, "is_glyph needs [glyphs] max_codepoints")
	local points = codepoints(value)
	if not points or #points > max_codepoints then return false end
	for _, point in ipairs(points) do
		if point <= 0x20 or (point >= 0x7F and point <= 0xA0) or point == 0x2028 or point == 0x2029
			or (point >= 0x2000 and point <= 0x200A) or point == 0x3000 then
			return false
		end
	end
	return true
end

--- Whether a value can name a glyph: a dotted i18n key.
--- @param value any
--- @return boolean
function M.is_name_key(value)
	return type(value) == "string" and value:match("^[%w_]+%.[%w_.]+$") ~= nil
end




-- =============================================
-- =============================================
-- ======= 2/ The cascade ======================
-- =============================================
-- =============================================

--- Resolves the glyph of one category.
--- @param inputs table
---   meta              table|nil  [_meta] of the category's TOML (glyph, glyph_name_key).
---   category_glyph    string|nil Per-category default glyph (defaults.toml).
---   category_name_key string|nil Per-category default name key.
---   default_glyph     string     Shared default glyph.
---   default_name_key  string     Shared default name key.
---   max_codepoints    integer    defaults.toml [glyphs] max_codepoints.
--- @return table { glyph, name_key, rejected = { [field] = value } | nil }
function M.resolve(inputs)
	inputs = inputs or {}
	local meta = type(inputs.meta) == "table" and inputs.meta or {}
	local rejected = nil

	local function pick(field, valid, ...)
		local declared = meta[field]
		if declared ~= nil then
			if valid(declared) then return declared end
			rejected = rejected or {}
			rejected[field] = declared
		end
		for index = 1, select("#", ...) do
			local value = select(index, ...)
			if valid(value) then return value end
		end
		return nil
	end

	local max_codepoints = inputs.max_codepoints
	local function is_glyph(value) return M.is_glyph(value, max_codepoints) end
	local glyph = pick("glyph", is_glyph, inputs.category_glyph, inputs.default_glyph)
	local name_key = pick("glyph_name_key", M.is_name_key, inputs.category_name_key, inputs.default_name_key)
	return { glyph = glyph, name_key = name_key, rejected = rejected }
end





-- =============================================
-- =============================================
-- ======= 3/ The badge ========================
-- =============================================
-- =============================================

--- The chip a preview row draws its glyph in: the first cell of the row, at
--- its far left, before the output text, filled in the glyph grey with the glyph
--- knocked out in the row's tint. The chip says the glyph is an annotation, not
--- part of what the expansion types (the maintainer's request of 2026-11-19;
--- filled rather than framed since 2026-11-20, one control on Windows instead of
--- two). Every row of a stack shares one badge column, as
--- wide as its widest glyph, so the outputs stay aligned; a stack without a
--- glyph has no column and keeps the row it had before the glyphs.
--- @param glyph_w number Widest glyph of the stack, 0 when no row shows one.
--- @param glyph_h number Tallest glyph of the stack.
--- @param layout table { glyph_badge_pad_x, glyph_badge_pad_y, glyph_badge_gap },
---   the [layout] keys of _shared/core/ui/data/tooltip/constants.toml.
--- @return table { w, h, zone }: the chip's size, and how far right the
---   output text starts from the row's padding.
function M.badge_geometry(glyph_w, glyph_h, layout)
	if type(glyph_w) ~= "number" or glyph_w <= 0 then return { w = 0, h = 0, zone = 0 } end
	assert(type(layout) == "table", "badge_geometry needs the tooltip layout")
	local pad_y = assert(tonumber(layout.glyph_badge_pad_y), "glyph_badge_pad_y is required")
	local pad_x = assert(tonumber(layout.glyph_badge_pad_x), "glyph_badge_pad_x is required")
	local gap = assert(tonumber(layout.glyph_badge_gap), "glyph_badge_gap is required")
	local w = glyph_w + 2 * pad_x
	return { w = w, h = glyph_h + 2 * pad_y, zone = w + gap }
end

return M
