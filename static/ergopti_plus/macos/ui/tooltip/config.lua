--- ui/tooltip/config.lua

--- ==============================================================================
--- MODULE: Tooltip Configuration
--- DESCRIPTION:
--- Hammerspoon-side mirror of the cross-driver tooltip visual constants.
--- The canonical source of truth is
--- static/ergopti_plus/shared/tooltip/constants.toml — every value declared here
--- MUST match the corresponding entry in that file. When constants.toml is
--- updated, this file must be updated to match.
---
--- FEATURES & RATIONALE:
--- 1. Cross-driver parity: every constant here has a named equivalent in
---    constants.toml and in lib/ui_style.ahk (AHK side). Divergences between
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
	bg         = { white = 0, alpha = 1.0 },
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

M.tint_config = {
	lightness  = 0.13,
	saturation = 0.85,
}

-- Default tooltip durations (seconds). 0 means "infinite display".
local DEFAULT_TIMEOUT_SEC     = 2.5
local DEFAULT_LLM_TIMEOUT_SEC = 12.0

-- Internal floor preserved when a positive timeout is requested. Any positive
-- caller-provided value is reduced by TIMEOUT_DECREMENT_SEC so back-to-back
-- tooltips do not visually overlap, but never below TIMEOUT_FLOOR_SEC.
local TIMEOUT_FLOOR_SEC     = 0.05
local TIMEOUT_DECREMENT_SEC = 0.2

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




-- =====================================================================
--- =====================================================================
-- ======= 3/ Bootstrap: load from shared/tooltip/constants.toml =======
--- =====================================================================
-- =====================================================================

--- Reads shared/tooltip/constants.toml at require-time and overwrites the
--- hardcoded defaults declared above so the Lua driver stays in sync with the
--- TOML single source of truth. Any read failure is logged at WARN and the
--- hardcoded defaults remain active — the tooltip is always functional.
local function load_from_shared()
	local ok_reader, toml_reader = pcall(require, "lib.toml_reader")
	if not ok_reader or not toml_reader then
		Logger.warn(LOG, "lib.toml_reader not available — tooltip constants using compile-time defaults.")
		return
	end

	-- Locate shared dir by walking up from this file:
	-- macos/ui/tooltip/config.lua → macos/ui/tooltip → macos/ui → macos → ergopti_plus → shared
	local ok_path, shared_path = pcall(function()
		local src = debug.getinfo(1, "S").source:gsub("^@", "")
		-- Strip 3 path components (config.lua, tooltip/, ui/) to reach macos/
		local dir = src:match("^(.*)[/\\][^/\\]+$") or src      -- tooltip/
		dir = dir:match("^(.*)[/\\][^/\\]+$") or dir            -- ui/
		dir = dir:match("^(.*)[/\\][^/\\]+$") or dir            -- macos/
		local ergopti_plus = dir:match("^(.*)[/\\][^/\\]+$") or dir -- ergopti_plus/
		return ergopti_plus .. "/shared"
	end)
	if not ok_path or not shared_path then
		error("[tooltip/config] Cannot resolve shared dir — tooltip constants not loaded.")
	end

	local toml_path = shared_path .. "/tooltip/constants.toml"
	local ok_c, c = pcall(toml_reader.parse, toml_path)
	if not ok_c or type(c) ~= "table" then
		error("[tooltip/config] shared/tooltip/constants.toml not readable: " .. tostring(c))
	end

	local function get(section, key, default)
		local s = c.sections[section]
		if type(s) ~= "table" then return default end
		local v = s[key]
		return (v ~= nil) and v or default
	end

	-- [typography]
	M.sizes.main = get("typography", "font_size_main_hs",  M.sizes.main)
	M.sizes.hint = get("typography", "font_size_hint_hs",  M.sizes.hint)
	M.sizes.info = get("typography", "font_size_info_hs",  M.sizes.info)

	-- [layout]
	M.layout.pad_x               = get("layout", "pad_x",             M.layout.pad_x)
	M.layout.pad_y               = get("layout", "pad_y",             M.layout.pad_y)
	M.layout.line_spacing        = get("layout", "line_spacing",       M.layout.line_spacing)
	M.layout.hint_spacing        = get("layout", "hint_spacing",       M.layout.hint_spacing)
	M.layout.screen_margin       = get("layout", "screen_margin",      M.layout.screen_margin)
	-- corner_radius passed directly as xRadius/yRadius on canvas element (no ×2)
	M.layout.corner_radius       = get("layout", "corner_radius",      M.layout.corner_radius)

	-- [positioning]
	M.layout.caret_offset_x      = get("positioning", "caret_offset_x",         M.layout.caret_offset_x)
	M.layout.caret_offset_y      = get("positioning", "caret_offset_y",         M.layout.caret_offset_y)
	M.layout.window_offset_y     = get("positioning", "window_offset_y",        M.layout.window_offset_y)
	M.layout.window_bottom_inset = get("positioning", "window_bottom_inset_hs", M.layout.window_bottom_inset)
	M.layout.max_caret_height    = get("positioning", "max_caret_height",       M.layout.max_caret_height)

	-- [colors]
	local bg_w = get("colors", "bg_white",    M.colors.bg.white)
	local bg_a = get("colors", "bg_alpha",    M.colors.bg.alpha)
	M.colors.bg       = { white = bg_w, alpha = bg_a }
	M.colors.bg_alpha = get("colors", "canvas_alpha_hs", M.colors.bg_alpha)

	-- [sep]
	local sep_w = get("colors", "sep_white",    M.colors.sep.white)
	local sep_a = get("colors", "sep_alpha_hs", M.colors.sep.alpha)
	M.colors.sep      = { white = sep_w, alpha = sep_a }

	-- [tint]
	M.tint_config = M.tint_config or {}
	M.tint_config.lightness  = get("tint", "lightness",  0)
	M.tint_config.saturation = get("tint", "saturation", 0)

	-- [timing]
	DEFAULT_TIMEOUT_SEC     = get("timing", "hotstring_timeout_sec", DEFAULT_TIMEOUT_SEC)
	DEFAULT_LLM_TIMEOUT_SEC = get("timing", "llm_timeout_sec",       DEFAULT_LLM_TIMEOUT_SEC)
	TIMEOUT_DECREMENT_SEC   = get("timing", "timeout_decrement_sec", TIMEOUT_DECREMENT_SEC)
	TIMEOUT_FLOOR_SEC       = get("timing", "timeout_floor_sec",     TIMEOUT_FLOOR_SEC)
	-- Re-apply to settings table so the live values reflect the TOML.
	M.settings.timeout_sec     = DEFAULT_TIMEOUT_SEC
	M.settings.llm_timeout_sec = DEFAULT_LLM_TIMEOUT_SEC

	Logger.done(LOG, "Shared tooltip constants loaded (pad_x=%d corner=%d tmo=%.1fs llm=%.1fs).",
		M.layout.pad_x, M.layout.corner_radius or 7,
		M.settings.timeout_sec, M.settings.llm_timeout_sec)
end

load_from_shared()

return M
