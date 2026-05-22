--- ui/tooltip/config.lua

--- ==============================================================================
--- MODULE: Tooltip Configuration
--- DESCRIPTION:
--- Centralizes all configuration, styling parameters, layout offsets, and 
--- constants for the tooltip UI.
---
--- FEATURES & RATIONALE:
--- 1. Single Source of Truth: Prevents magic numbers in UI code.
--- 2. Infinite Support: Values <= 0 seamlessly translate to infinite displays.
--- ==============================================================================

local M = {}
local Logger = require("lib.logger")
local LOG = "tooltip_config"

M.fonts = { main = ".AppleSystemUIFont", bold = ".AppleSystemUIFontBold" }
M.sizes = { main = 14, hint = 11, info = 10, gap = 3 }

M.layout = {
	pad_x               = 14,
	pad_y               = 7,
	line_spacing        = 8,
	hint_spacing        = 4,
	caret_offset_x      = 15,
	caret_offset_y      = 18,
	window_offset_y     = 5,
	window_bottom_inset = 40,
	screen_margin       = 5,
	max_caret_height    = 80
}

M.colors = {
	bg         = { white = 0.10, alpha = 1.0 },
	bg_alpha   = 0.97,
	corr_sel   = { red = 0.25, green = 0.90, blue = 0.40, alpha = 1.0 },
	nw_sel     = { red = 1.00, green = 0.62, blue = 0.10, alpha = 1.0 },
	unsel_gray = { white = 0.50, alpha = 1.0 },
	cursor     = { red = 0.98, green = 0.88, blue = 0.22, alpha = 1.0 },
	cmd_sel    = { red = 0.95, green = 0.58, blue = 0.08, alpha = 0.75 },
	cmd_dim    = { white = 0.45, alpha = 1.0 },
	hint       = { white = 0.40, alpha = 1.0 },
	info_bar   = { white = 0.30, alpha = 1.0 },
	sep        = { white = 1.00, alpha = 0.09 },
	invis      = { white = 0.00, alpha = 0.00 },
	loading    = { red = 0.94, green = 0.78, blue = 0.28, alpha = 1.0 }
}

-- Default tooltip durations (seconds). 0 means "infinite display".
local DEFAULT_TIMEOUT_SEC     = 2.5
local DEFAULT_LLM_TIMEOUT_SEC = 12.0

-- Internal floor preserved when a positive timeout is requested. Any positive
-- caller-provided value is reduced by TIMEOUT_DECREMENT_SEC so back-to-back
-- tooltips do not visually overlap, but never below TIMEOUT_FLOOR_SEC.
local TIMEOUT_FLOOR_SEC     = 0.05
local TIMEOUT_DECREMENT_SEC = 0.1

M.settings = {
	timeout_sec          = DEFAULT_TIMEOUT_SEC,
	llm_timeout_sec      = DEFAULT_LLM_TIMEOUT_SEC,
	colorization_enabled = true
}

-- Default background tint for each tooltip display context.
-- A nil value means no tint (the tooltip uses the standard dark background).
local DEFAULT_ACCENT_COLORS = {
	hotstring_star        = { red = 1.00, green = 0.00, blue = 0.00, alpha = 1.0 },
	hotstring_autocorrect = { red = 0.00, green = 0.80, blue = 0.00, alpha = 1.0 },
	hotstring_personal    = { red = 0.20, green = 0.55, blue = 1.00, alpha = 1.0 },
	ai_loading            = { red = 0.68, green = 0.38, blue = 1.00, alpha = 1.0 },
	ai_prediction         = nil,
}

-- Active accent colors — initialized from defaults, overridable at runtime via set_accent_color()
M.accent_colors = {}
for key, color in pairs(DEFAULT_ACCENT_COLORS) do
	M.accent_colors[key] = color
end





-- ===================================
--- ===================================
-- ======= 1/ State Management =======
--- ===================================
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
--- ==========================================
-- ======= 2/ Accent Color Management =======
--- ==========================================
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
		local ok, hs_cfg = pcall(require, "modules.hotstrings_config")
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

return M
