--- ui/tooltip/config.lua

--- ==============================================================================
--- MODULE: Tooltip Configuration
--- DESCRIPTION:
--- Hammerspoon-side loader for the cross-driver tooltip visual constants.
--- The canonical source of truth is _shared/modules/tooltip/constants.toml — every
--- value exposed on M.* is read from that file at require-time. Missing file
--- or key → error (fail fast). No driver-side fallback values.
---
--- FEATURES & RATIONALE:
--- 1. Cross-driver parity: every constant here has a named equivalent in
---    constants.toml and in infra/ui_style.ahk (AHK side). Divergences between
---    the three files are bugs.
--- 2. No magic numbers: all tooltip renderer values originate here.
--- 3. Future-proof: a Linux or web driver reads constants.toml directly;
---    AHK and HS mirror it here as language-native tables for zero-cost access.
---
--- CROSS-REFERENCES (constants.toml key → Lua field):
---   [typography]  font_main_hs           → M.fonts.main
---   [typography]  font_bold_hs           → M.fonts.bold
---   [typography]  font_size_main_hs      → M.sizes.main
---   [typography]  font_size_hint_hs      → M.sizes.hint
---   [typography]  font_size_info_hs      → M.sizes.info
---   [layout]      pad_x                  → M.layout.pad_x
---   [layout]      pad_y                  → M.layout.pad_y
---   [layout]      line_spacing           → M.layout.line_spacing
---   [layout]      hint_spacing           → M.layout.hint_spacing
---   [layout]      corner_radius          → canvas element xRadius/yRadius
---   [layout]      screen_margin          → M.layout.screen_margin
---   [positioning] caret_offset_x         → M.layout.caret_offset_x
---   [positioning] caret_offset_y         → M.layout.caret_offset_y
---   [positioning] window_offset_y        → M.layout.window_offset_y
---   [positioning] window_bottom_inset_hs → M.layout.window_bottom_inset
---   [positioning] max_caret_height       → M.layout.max_caret_height
---   [colors]      bg_white / bg_alpha    → M.colors.bg / M.colors.bg_alpha
---   [colors]      sep_white / sep_alpha_hs → M.colors.sep
---   [tint]        lightness              → lightness constant in apply_tint()
---   [tint]        saturation             → saturation constant in apply_tint()
---   [timing]      hotstring_timeout_sec  → DEFAULT_TIMEOUT_SEC
---   [timing]      llm_timeout_sec        → DEFAULT_LLM_TIMEOUT_SEC
---   [timing]      timeout_decrement_sec  → TIMEOUT_DECREMENT_SEC
---   [timing]      timeout_floor_sec      → TIMEOUT_FLOOR_SEC
--- ==============================================================================

local M = {}
local Logger = require("infra.logger")
local LOG = "tooltip_config"

-- Populated strictly from _shared/modules/tooltip/constants.toml at require-time (fail fast).
M.fonts = {}
M.sizes = {}
M.layout = {}
M.colors = {}
M.tint_config = {}
M.llm_ui = {}

-- Tooltip durations (seconds). 0 means "infinite display". Set from TOML [timing].
local DEFAULT_TIMEOUT_SEC     = nil
local DEFAULT_LLM_TIMEOUT_SEC = nil
local TIMEOUT_FLOOR_SEC       = nil
local TIMEOUT_DECREMENT_SEC   = nil

M.settings = {
	timeout_sec          = 0,
	llm_timeout_sec      = 0,
	colorization_enabled = true
}

-- Accent colors per display context — loaded from TOML [accent_colors].
M.accent_colors = {}





-- ===================================
-- ===================================
-- ======= 1/ State Management =======
-- ===================================
-- ===================================

--- Safely sets the general tooltip timeout.
--- @param seconds number The duration in seconds. Uses 0 for infinite.
function M.set_timeout(seconds)
	local base_timeout = tonumber(seconds) or DEFAULT_TIMEOUT_SEC
	if base_timeout <= 0 then
		M.settings.timeout_sec = 0
		Logger.info(LOG, "Standard timeout disabled (infinite).")
	else
		M.settings.timeout_sec = math.max(TIMEOUT_FLOOR_SEC, base_timeout - TIMEOUT_DECREMENT_SEC)
	end
end

--- Safely sets the LLM specific tooltip timeout.
--- @param seconds number The duration in seconds. Uses 0 for infinite.
function M.set_llm_timeout(seconds)
	local base_timeout = tonumber(seconds) or DEFAULT_LLM_TIMEOUT_SEC
	if base_timeout <= 0 then
		M.settings.llm_timeout_sec = 0
		Logger.info(LOG, "LLM timeout disabled (infinite).")
	else
		M.settings.llm_timeout_sec = math.max(TIMEOUT_FLOOR_SEC, base_timeout - TIMEOUT_DECREMENT_SEC)
	end
end

--- Explicitly enables or disables colorization.
--- @param enabled boolean True to allow color, false to enforce gray.
function M.set_colorization_enabled(enabled)
	M.settings.colorization_enabled = (enabled == true)
	Logger.info(LOG, "Colorization explicitly set to: " .. tostring(M.settings.colorization_enabled) .. ".")
end

--- Applies a table of configuration parameters.
--- @param params table Configuration dictionary.
function M.setup(params)
	if type(params) ~= "table" then return end
	if params.hotstring_timeout then M.set_timeout(params.hotstring_timeout) end
	if params.llm_timeout then M.set_llm_timeout(params.llm_timeout) end
	if params.colorization_enabled ~= nil then M.set_colorization_enabled(params.colorization_enabled) end
end






-- ==========================================
-- ==========================================
-- ======= 2/ Accent Color Management =======
-- ==========================================
-- ==========================================

-- Maps tooltip-context keys to the hotstring category whose TOML metadata +
-- user override should drive their tint. Keys without an entry stay
-- governed by the legacy `M.accent_colors` table (`ai_loading`, `ai_prediction`).
local TINT_KEY_TO_CATEGORY = {
	hotstring_star        = "magickey",
	hotstring_autocorrect = "autocorrection",
	hotstring_personal    = "personal",
}

--- Parse a hex string ("#rrggbb" or "rrggbb") into an RGBA table the canvas
--- subsystem accepts. Returns nil for malformed input so callers can fall
--- back to the static accent_colors table.
--- @param hex string|nil
--- @return table|nil
local function parse_hex_color(hex)
	if type(hex) ~= "string" or hex == "" then return nil end
	if hex:sub(1, 1) == "#" then hex = hex:sub(2) end
	if #hex ~= 6 then return nil end
	local r = tonumber(hex:sub(1, 2), 16)
	local g = tonumber(hex:sub(3, 4), 16)
	local b = tonumber(hex:sub(5, 6), 16)
	if not (r and g and b) then return nil end
	return { red = r / 255, green = g / 255, blue = b / 255, alpha = 1.0 }
end

--- Returns the accent color for a display context, gated by the colorization setting.
--- Resolution order:
---   1. `hotstrings_config.resolve(category).color` for keys that map to a
---      hotstring category — this is the new authoritative source (TOML
---      metadata + shared user override file).
---   2. The legacy in-memory `M.accent_colors[key]` table for keys that do
---      not correspond to a hotstring category (`ai_*`).
--- Returns nil when colorization is disabled, the lookup fails, or the
--- key has no color defined.
--- @param key string The context key ("hotstring_star", "ai_loading", etc.).
--- @return table|nil The RGBA color table, or nil.
function M.tint(key)
	if not M.settings.colorization_enabled then return nil end

	local category = TINT_KEY_TO_CATEGORY[key]
	if category then
		local ok, hs_cfg = pcall(require, "modules.hotstrings.hotstrings_config")
		if ok and hs_cfg and type(hs_cfg.resolve) == "function" then
			local resolved = hs_cfg.resolve(category, nil)
			local rgba = resolved and parse_hex_color(resolved.color)
			if rgba then return rgba end
		end
	end

	return M.accent_colors[key]
end

--- Overrides the accent color for a given tooltip display context.
--- Pass nil as color to remove the tint for that context.
--- @param key string The accent color context key to override.
--- @param color table|nil The new RGBA color table, or nil.
function M.set_accent_color(key, color)
	M.accent_colors[key] = color
end





-- ==============================================================================
-- ==============================================================================
-- ======= 3/ Bootstrap: load from _shared/modules/tooltip/constants.toml =======
-- ==============================================================================
-- ==============================================================================

--- Reads _shared/modules/tooltip/constants.toml at require-time. Missing file, section,
--- or key → error (fail fast — no driver-side fallback values).
local function load_from_shared()
	local toml_reader = require("infra.toml.reader")

	-- Locate shared dir by walking up from this file:
	-- macos/ui/tooltip/config.lua → macos/ui/tooltip → macos/ui → macos → ergopti_plus → shared
	local shared_path = (function()
		local src = debug.getinfo(1, "S").source:gsub("^@", "")
		local dir = src:match("^(.*)[/\\][^/\\]+$") or src
		dir = dir:match("^(.*)[/\\][^/\\]+$") or dir
		dir = dir:match("^(.*)[/\\][^/\\]+$") or dir
		local ergopti_plus = dir:match("^(.*)[/\\][^/\\]+$") or dir
		return ergopti_plus .. "/_shared"
	end)()

	local toml_path = shared_path .. "/modules/tooltip/constants.toml"
	local c = toml_reader.parse(toml_path)
	-- Emptiness, not type, is the real signal: TomlReader.parse returns a
	-- well-formed but EMPTY result on both of its failure exits, so a type test can
	-- never fire and an unreadable file was reported further down as a missing
	-- [typography] section — sending the reader after a section that was never the
	-- problem. Mirrors the emptiness check landed in infra/timings.lua, and names the
	-- path so the message identifies the file that could not be read.
	if type(c) ~= "table" or type(c.sections) ~= "table" or next(c.sections) == nil then
		error("[tooltip/config] cannot read constants.toml (missing or empty): " .. tostring(toml_path))
	end

	local function require_key(section, key)
		local s = c.sections[section]
		if type(s) ~= "table" then
			error(string.format("[tooltip/config] missing section [%s] in constants.toml", section))
		end
		local v = s[key]
		if v == nil then
			error(string.format("[tooltip/config] missing key [%s].%s in constants.toml", section, key))
		end
		return v
	end

	local function optional_key(section, key)
		local s = c.sections[section]
		if type(s) ~= "table" then return nil end
		return s[key]
	end

	local function rgba_from_table(t, section, key)
		if type(t) ~= "table" then
			error(string.format("[tooltip/config] [%s].%s must be an RGBA table", section, key))
		end
		if t.red ~= nil or t.green ~= nil or t.blue ~= nil then
			return {
				red   = tonumber(t.red) or 0,
				green = tonumber(t.green) or 0,
				blue  = tonumber(t.blue) or 0,
				alpha = tonumber(t.alpha) or 1.0,
			}
		end
		if t.white ~= nil then
			return { white = tonumber(t.white) or 0, alpha = tonumber(t.alpha) or 1.0 }
		end
		error(string.format("[tooltip/config] [%s].%s must contain red/green/blue or white", section, key))
	end

	-- [typography]
	M.fonts.main = require_key("typography", "font_main_hs")
	M.fonts.bold = require_key("typography", "font_bold_hs")
	M.sizes.main = require_key("typography", "font_size_main_hs")
	M.sizes.hint = require_key("typography", "font_size_hint_hs")
	M.sizes.info = require_key("typography", "font_size_info_hs")
	M.sizes.gap  = require_key("llm_ui", "prediction_line_gap_hs")

	-- [layout]
	M.layout.pad_x         = require_key("layout", "pad_x")
	M.layout.pad_y         = require_key("layout", "pad_y")
	M.layout.line_spacing  = require_key("layout", "line_spacing")
	M.layout.hint_spacing  = require_key("layout", "hint_spacing")
	M.layout.screen_margin = require_key("layout", "screen_margin")
	M.layout.corner_radius = require_key("layout", "corner_radius")

	-- [positioning]
	M.layout.caret_offset_x      = require_key("positioning", "caret_offset_x")
	M.layout.caret_offset_y      = require_key("positioning", "caret_offset_y")
	M.layout.window_offset_y     = require_key("positioning", "window_offset_y")
	M.layout.window_bottom_inset = require_key("positioning", "window_bottom_inset_hs")
	M.layout.max_caret_height    = require_key("positioning", "max_caret_height")

	-- [colors]
	M.colors.bg       = { white = require_key("colors", "bg_white"), alpha = require_key("colors", "bg_alpha") }
	M.colors.bg_alpha = require_key("colors", "canvas_alpha_hs")
	M.colors.sep      = { white = require_key("colors", "sep_white"), alpha = require_key("colors", "sep_alpha_hs") }
	-- Border ring color, read from the shared source so the single AND stacked
	-- canvases (and the AHK driver via its own *_ahk alpha) round-trip the same
	-- look. border_alpha_hs is the canvas-tuned alpha; never hardcode it.
	M.colors.border   = { white = require_key("colors", "border_white"), alpha = require_key("colors", "border_alpha_hs") }
	M.colors.hint     = { white = require_key("colors", "hint_white"), alpha = require_key("colors", "hint_alpha") }
	M.colors.info_bar = { white = require_key("colors", "info_white"), alpha = require_key("colors", "info_alpha") }
	M.colors.invis    = { white = require_key("colors", "invis_white"), alpha = require_key("colors", "invis_alpha") }

	-- [llm_colors]
	M.colors.corr_sel   = rgba_from_table(require_key("llm_colors", "corr_sel"),   "llm_colors", "corr_sel")
	M.colors.nw_sel     = rgba_from_table(require_key("llm_colors", "nw_sel"),     "llm_colors", "nw_sel")
	M.colors.unsel_gray = rgba_from_table(require_key("llm_colors", "unsel_gray"), "llm_colors", "unsel_gray")
	M.colors.cursor     = rgba_from_table(require_key("llm_colors", "cursor"),     "llm_colors", "cursor")
	M.colors.cmd_sel    = rgba_from_table(require_key("llm_colors", "cmd_sel"),    "llm_colors", "cmd_sel")
	M.colors.cmd_dim    = rgba_from_table(require_key("llm_colors", "cmd_dim"),    "llm_colors", "cmd_dim")
	M.colors.loading    = rgba_from_table(require_key("llm_colors", "loading"),    "llm_colors", "loading")

	-- [accent_colors] — ai_prediction may be absent (no tint)
	M.accent_colors.hotstring_star        = rgba_from_table(require_key("accent_colors", "hotstring_star"),        "accent_colors", "hotstring_star")
	M.accent_colors.hotstring_autocorrect = rgba_from_table(require_key("accent_colors", "hotstring_autocorrect"), "accent_colors", "hotstring_autocorrect")
	M.accent_colors.hotstring_personal    = rgba_from_table(require_key("accent_colors", "hotstring_personal"),    "accent_colors", "hotstring_personal")
	M.accent_colors.ai_loading            = rgba_from_table(require_key("accent_colors", "ai_loading"),            "accent_colors", "ai_loading")
	M.accent_colors.ai_prediction         = optional_key("accent_colors", "ai_prediction")

	-- [llm_ui] — structural LLM tooltip chrome
	M.llm_ui = {
		active_prefix        = require_key("llm_ui", "active_prefix"),
		slot_placeholder     = require_key("llm_ui", "slot_placeholder"),
		inactive_align_char  = require_key("llm_ui", "inactive_align_char"),
		footer_space_divider = require_key("llm_ui", "footer_space_divider"),
		footer_combined_sep  = require_key("llm_ui", "footer_combined_separator"),
		shortcut_label_gap   = require_key("llm_ui", "shortcut_label_gap"),
		hint_accept_single   = require_key("llm_ui", "hint_accept_single"),
		hint_nav_left        = require_key("llm_ui", "hint_nav_left"),
		hint_nav_right       = require_key("llm_ui", "hint_nav_right"),
		hint_accept_center   = require_key("llm_ui", "hint_accept_center"),
		hint_arrow_left      = require_key("llm_ui", "hint_arrow_left"),
		hint_arrow_right     = require_key("llm_ui", "hint_arrow_right"),
		hint_or              = require_key("llm_ui", "hint_or"),
		hint_arrow_sep_left  = require_key("llm_ui", "hint_arrow_sep_left"),
		hint_arrow_sep_right = require_key("llm_ui", "hint_arrow_sep_right"),
	}

	-- [tint]
	M.tint_config.lightness  = require_key("tint", "lightness")
	M.tint_config.saturation = require_key("tint", "saturation")

	-- [timing]
	DEFAULT_TIMEOUT_SEC     = require_key("timing", "hotstring_timeout_sec")
	DEFAULT_LLM_TIMEOUT_SEC = require_key("timing", "llm_timeout_sec")
	TIMEOUT_DECREMENT_SEC   = require_key("timing", "timeout_decrement_sec")
	TIMEOUT_FLOOR_SEC       = require_key("timing", "timeout_floor_sec")
	M.timing = {
		timeout_decrement_sec = TIMEOUT_DECREMENT_SEC,
		timeout_floor_sec     = TIMEOUT_FLOOR_SEC,
	}
	M.settings.timeout_sec     = DEFAULT_TIMEOUT_SEC
	M.settings.llm_timeout_sec = DEFAULT_LLM_TIMEOUT_SEC

	Logger.done(LOG, "Shared tooltip constants loaded (pad_x=%d corner=%d tmo=%.1fs llm=%.1fs).",
		M.layout.pad_x, M.layout.corner_radius,
		M.settings.timeout_sec, M.settings.llm_timeout_sec)
end

load_from_shared()

return M
