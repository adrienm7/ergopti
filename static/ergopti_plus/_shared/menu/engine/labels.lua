--- _shared/menu/engine/labels.lua

--- ==============================================================================
--- MODULE: Menu Label Formatters (shared)
--- DESCRIPTION:
--- Pure cross-driver formatters for menu item labels that were previously
--- duplicated between macOS (Lua) and Windows (AHK) with a divergent third
--- copy on Linux. These are trivial functions but they MUST stay identical
--- across all 3 drivers so the tray menu reads identically.
---
--- FEATURES & RATIONALE:
--- 1. fmt_count: formats a large integer with space thousands separators
---    (French-style "1 234 567"). Duplicated as FmtCount in AHK
---    (menu_helpers.ahk) and fmt_grand in macOS (hotstring_counter.lua).
--- 2. decorate_section: frames a section header title for disabled menu
---    header rows. The frame is data, _shared/menu/data/section_header.json,
---    generated into menu.section_header_data here and into the constants
---    MenuSectionTitle (windows/menu/engine/helpers.ahk) reads, so one edit
---    restyles every header of the three drivers.
---
--- Windows cannot require Lua modules; a JS drift gate keeps its formatters
--- in step (tools/test/test-section-decoration-parity.cjs).
--- ==============================================================================

local SectionHeader = require("menu.engine.section_header_data")

local M = {}





--- Formats a large integer with space thousands separators.
--- e.g. 1234567 → "1 234 567".
--- @param n number The integer to format (rounded before formatting).
--- @return string Formatted string.
function M.fmt_count(n)
	-- tonumber() coercion, not just `or 0`: the two macOS menu copies this
	-- function replaced accepted a numeric string, and several call sites read
	-- their count out of a table whose value may have come back as text. Without
	-- it, folding those copies in here would turn a working label into an
	-- arithmetic error on a string.
	local s = tostring(math.floor((tonumber(n) or 0) + 0.5))
	local r = ""
	for i = 1, #s do
		if i > 1 and (#s - i + 1) % 3 == 0 then r = r .. " " end
		r = r .. s:sub(i, i)
	end
	return r
end




-- ====================================================
-- ====================================================
-- ======= 3/ Section Header Decoration ===============
-- ====================================================
-- ====================================================

--- Frames a title as a disabled menu section header, in the shared format.
--- @param text string The translated title, in the case its locale writes it.
--- @return string The header label.
function M.decorate_section(text)
	return SectionHeader.prefix .. text .. SectionHeader.suffix
end

return M
