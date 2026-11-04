--- _shared/lua/menu/separators.lua

--- ==============================================================================
--- MODULE: Menu Separator Rules
--- DESCRIPTION:
--- The one rule that decides which separator rows of a built menu are drawn: a
--- separator is kept only between two real rows, so none leads, none trails and
--- none follows another one. The renderer applies it to every menu it returns,
--- submenus included, because list providers and dynamic handlers bring
--- separators of their own that can land next to a manifest `---`.
---
--- Pure data in, same data out: no logger, no platform, no manifest. The rule
--- is pinned by `tests/corpus/menus/separator_normalization_vectors.json`, which
--- both Lua drivers replay; the Windows twin (`manifest_menu.ahk`) replays the
--- same vectors when its port lands.
--- ==============================================================================

local M = {}

M.SEPARATOR_TITLE = "-"





-- ====================================
-- ====================================
-- ======= 1/ Rule ====================
-- ====================================
-- ====================================

--- Returns true when a menu item table is a separator.
--- @param entry any
--- @return boolean
function M.is_separator(entry)
	return type(entry) == "table" and entry.title == M.SEPARATOR_TITLE
end

--- Drops every separator that would not sit between two real rows, in place.
---
--- Submenus are normalised too, since a provider nests rows freely.
--- @param items table Array of menu item tables; `{ title = "-" }` is a separator.
--- @return table The same array.
function M.normalize(items)
	local kept = {}
	for _, entry in ipairs(items) do
		if M.is_separator(entry) then
			if #kept > 0 and not M.is_separator(kept[#kept]) then kept[#kept + 1] = entry end
		else
			if type(entry) == "table" and type(entry.menu) == "table" then
				M.normalize(entry.menu)
			end
			kept[#kept + 1] = entry
		end
	end
	while M.is_separator(kept[#kept]) do kept[#kept] = nil end
	for i = 1, math.max(#items, #kept) do items[i] = kept[i] end
	return items
end

return M
