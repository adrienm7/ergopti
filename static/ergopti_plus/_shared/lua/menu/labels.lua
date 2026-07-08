--- _shared/lua/menu/labels.lua

--- ==============================================================================
--- MODULE: Menu Label Formatters (shared)
--- DESCRIPTION:
--- Pure cross-driver formatters for menu item labels that were previously
--- duplicated between macOS (Lua) and Windows (AHK) with a divergent third
--- copy on Linux. These are trivial functions but they MUST stay identical
--- across all 3 drivers so the tray menu reads identically.
---
--- FEATURES & RATIONALE:
--- 1. log_level_emoji: maps a log severity name to its display emoji. The
---    macOS builder.lua and AHK menu_rebuild.ahk each had their own copy;
---    a third divergent copy existed in Linux menu_builder.lua.
--- 2. fmt_count: formats a large integer with space thousands separators
---    (French-style "1 234 567"). Duplicated as FmtCount in AHK
---    (menu_helpers.ahk) and fmt_grand in macOS (hotstring_counter.lua).
--- 3. decorate_section: wraps a section header label in "— … —" decoration
---    for disabled menu header items. Duplicated as MenuSectionTitle in AHK
---    (menu_helpers.ahk) and i18n.decorate_section in macOS (i18n.lua).
---
--- Windows cannot require Lua modules, so its AHK copies are kept in sync
--- via a JS drift gate (tools/test/test-section-decoration-parity.cjs).
--- ==============================================================================

local M = {}




-- ====================================================
-- ====================================================
-- ======= 1/ Log-Level Emoji Map =====================
-- ====================================================
-- ====================================================

--- Returns the display emoji for a log severity level name.
--- @param level string One of "DEBUG", "INFO", "WARNING", "ERROR".
--- @return string Emoji character.
function M.log_level_emoji(level)
	local emojis = { DEBUG = "🐛", INFO = "ℹ️", WARNING = "⚠️", ERROR = "❌" }
	return emojis[level] or "📝"
end




-- ====================================================
-- ====================================================
-- ======= 2/ Count Formatter =========================
-- ====================================================
-- ====================================================

--- Formats a large integer with space thousands separators.
--- e.g. 1234567 → "1 234 567".
--- @param n number The integer to format (rounded before formatting).
--- @return string Formatted string.
function M.fmt_count(n)
	local s = tostring(math.floor((n or 0) + 0.5))
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

--- Wraps a label in "— … —" decoration for disabled menu section headers.
--- @param text string The raw label text.
--- @return string Decorated label.
function M.decorate_section(text)
	return "— " .. text .. " —"
end

return M
