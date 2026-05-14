--- ui/wpm/shared.lua

--- ==============================================================================
--- MODULE: WPM Shared UI Helpers
--- DESCRIPTION:
--- Centralizes reusable logic for WPM-related user interfaces.
---
--- FEATURES & RATIONALE:
--- 1. Source Resolution: Keeps menubar and floating widget synchronized.
--- 2. Live Color Pipeline: Colors for hotstring sources are resolved from the
---    same TOML metadata + shared user-override file used by the tooltip system,
---    so any customization in the hotstrings config window is reflected here too.
---    Manual (blue) and AI (purple) use hardcoded fallbacks.
--- 3. Label Formatting: Provides consistent MPM text rendering utilities.
--- ==============================================================================

local M = {}
local hs = hs




-- =================================
-- =================================
-- ======= 1/ Color Mapping ========
-- =================================
-- =================================

-- Fallback hex colors used when no TOML/override color is available.
local COLOR_FALLBACK = {
	manual = "#007aff",
	llm    = "#af52de",
}

-- Maps a WPM source name to the hotstrings_config category whose TOML metadata
-- (+ user override) drives its color. Sources not listed here use COLOR_FALLBACK.
local SOURCE_TO_CATEGORY = {
	hotstring      = "magickey",
	autocorrection = "autocorrection",
}

--- Resolves the hex color string for a typing source.
--- Resolution order for hotstring/autocorrection:
---   1. hotstrings_config.resolve(category).color — TOML metadata + user override.
---   2. COLOR_FALLBACK[source] or "#007aff" when unconfigured or unknown.
--- For "manual" and "llm": COLOR_FALLBACK directly (no TOML source for these).
--- @param source string Source name ("manual", "hotstring", "autocorrection", "llm").
--- @return string Hex color string with leading "#".
local function resolve_source_hex(source)
	local category = SOURCE_TO_CATEGORY[source]
	if category then
		local ok, hs_cfg = pcall(require, "modules.hotstrings_config")
		if ok and hs_cfg and type(hs_cfg.resolve) == "function" then
			local resolved = hs_cfg.resolve(category, nil)
			if resolved and type(resolved.color) == "string" and resolved.color ~= "" then
				local c = resolved.color
				return c:sub(1, 1) == "#" and c or ("#" .. c)
			end
		end
	end
	return COLOR_FALLBACK[source] or "#007aff"
end




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
--- Color for "hotstring" and "autocorrection" is resolved live from the TOML
--- pipeline so user customizations are reflected without a restart.
--- @param source string Active source name.
--- @param alpha number|nil Opacity to apply.
--- @return table hs.color-compatible table.
function M.get_source_color(source, alpha)
	local hex = resolve_source_hex(source or "manual")

	return {
		hex   = hex,
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
