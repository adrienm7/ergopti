--- ui/wpm/shared.lua

--- ==============================================================================
--- MODULE: WPM Shared UI Helpers
--- DESCRIPTION:
--- Centralizes reusable logic for WPM-related user interfaces.
---
--- FEATURES & RATIONALE:
--- 1. Source Resolution: Keeps menubar and floating widget synchronized.
--- 2. Unified Palette: Guarantees identical colors for each source type.
--- 3. Label Formatting: Provides consistent MPM text rendering utilities.
--- ==============================================================================

local M = {}
local hs = hs





-- =================================
-- =================================
-- ======= 1/ Color Mapping ========
-- =================================
-- =================================

local SOURCE_COLOR_HEX = {
	manual = "#007aff",
	hotstring = "#ff3b30",
	autocorrection = "#34c759",
	llm = "#af52de",
}




-- ======================================
-- ======================================
-- ======= 2/ Source Normalization ======
-- ======================================
-- ======================================

--- Resolves the active source in a rolling time window.
--- @param stats table Live stats payload from keylogger.
--- @param source_color_duration number Active source duration in seconds.
--- @param now_sec number|nil Current timestamp in seconds.
--- @return string Active source name or "none".
function M.get_active_source(stats, source_color_duration, now_sec)
	local source = "none"
	local source_time = 0

	if type(stats) == "table" then
		source = stats.source_variant or stats.source or "none"
		source_time = stats.source_time or 0
	end

	local now = now_sec or (hs.timer.absoluteTime() / 1000000000)
	local duration = type(source_color_duration) == "number" and source_color_duration or 1.0

	if source ~= "none" and (now - source_time) <= duration then
		return source
	end

	return "none"
end




-- =====================================
-- =====================================
-- ======= 3/ Shared UI Helpers ========
-- =====================================
-- =====================================

--- Returns the canonical UI color for a typing source.
--- @param source string Active source name.
--- @param alpha number|nil Opacity to apply.
--- @return table hs.color-compatible table.
function M.get_source_color(source, alpha)
	local resolved_source = source or "manual"
	if SOURCE_COLOR_HEX[resolved_source] == nil then
		resolved_source = "manual"
	end

	return {
		hex = SOURCE_COLOR_HEX[resolved_source],
		alpha = type(alpha) == "number" and alpha or 0.8,
	}
end

--- Formats the menubar label with optional non-breaking side spaces.
--- @param display_wpm number Integer MPM value.
--- @param with_nbsp_padding boolean Whether to add side padding.
--- @return string Formatted label.
function M.format_mpm_label(display_wpm, with_nbsp_padding)
	if with_nbsp_padding then
		return "\u{00A0}" .. tostring(display_wpm) .. " MPM\u{00A0}"
	end

	return string.format("%d MPM", display_wpm)
end

return M
