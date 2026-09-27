--- ui/wpm/shared.lua

--- ==============================================================================
--- MODULE: WPM Shared UI Helpers
--- DESCRIPTION:
--- Centralizes reusable logic for WPM-related user interfaces.
---
--- FEATURES & RATIONALE:
--- 1. Source Resolution: Keeps menubar and floating widget synchronized.
--- 2. Live Color Pipeline: The source_variant (= TOML group name) is passed
---    directly to hotstrings_config.resolve() so the widget color always matches
---    the group's _meta.color + any user override. "llm" and the canon's
---    [neutral_sources] take the canon's own colours.
--- 3. Nothing restated: every colour, the neutral sources and the label come
---    from _shared/modules/wpm_widget/constants.toml through the shared model
---    (_shared/lua/wpm_widget/model.lua), which the Linux driver runs too.
--- ==============================================================================

local M = {}
local hs = hs




-- =================================
-- =================================
-- ======= 1/ Color Mapping ========
-- =================================
-- =================================

local Logger = require("infra.logger")
local Paths = require("infra.paths")
local TomlCodec = require("toml_codec")
local WPMModel = require("wpm_widget.model")

local LOG = "wpm_shared"

-- The shared canon, read once. Its colours, its neutral sources and its
-- fallback accent used to be restated here as literals that had to be kept
-- "byte-identical" with the TOML by hand.
local _canon = nil

--- The shared canon, or nil (logged) when it cannot be read.
--- @return table|nil
function M.canon()
	if _canon then return _canon end
	local canon, err = WPMModel.load(Paths.shared("modules/wpm_widget/constants.toml"), TomlCodec.decode)
	if not canon then
		Logger.error(LOG, "The WPM canon is unusable (%s).", tostring(err))
		return nil
	end
	_canon = canon
	return _canon
end

--- A hotstring group's colour: its TOML _meta.color plus any user override.
--- @param group string
--- @return string|nil
function M.resolve_group_hex(group)
	local ok, hs_cfg = pcall(require, "modules.hotstrings.hotstrings_config")
	if not ok or not hs_cfg or type(hs_cfg.resolve) ~= "function" then return nil end
	local resolved = hs_cfg.resolve(group, nil)
	return resolved and resolved.color or nil
end

--- The unit under the number, in the user's language.
--- @return string
function M.unit_label()
	return require("infra.i18n").get("menu.metrics.wpm_unit")
end





--- =======================================
--- =======================================
--- ======= 2/ Source Normalization =======
--- =======================================
--- =======================================

--- Resolves the active source in a rolling time window.
--- @param stats table Live stats payload from keylogger.
--- @param source_color_duration number Active source duration in seconds.
--- @param now_sec number|nil Current timestamp in seconds.
--- @return string Active source name or "none".
function M.get_active_source(stats, source_color_duration, now_sec)
	local now = now_sec or (hs.timer.absoluteTime() / 1000000000)
	return WPMModel.active_source(stats, source_color_duration, now)
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
	local canon = M.canon()
	if not canon then return nil end
	return {
		hex   = WPMModel.source_hex(canon, source or "manual", M.resolve_group_hex),
		alpha = type(alpha) == "number" and alpha or 0.8,
	}
end

--- Formats the menubar label with optional non-breaking side spaces.
--- @param display_wpm number Integer MPM value.
--- @param with_nbsp_padding boolean Whether to add side padding.
--- @return string Formatted label.
function M.format_mpm_label(display_wpm, with_nbsp_padding)
	local label = WPMModel.readout_label(display_wpm, M.unit_label())
	if with_nbsp_padding then return "\u{00A0}" .. label .. "\u{00A0}" end
	return label
end

return M
