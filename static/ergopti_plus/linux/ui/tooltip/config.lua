--- ui/tooltip/config.lua

--- ==============================================================================
--- MODULE: Tooltip Style (Linux)
--- DESCRIPTION:
--- Reads _shared/modules/tooltip/constants.toml into the tables the renderer
--- draws with. It is the twin of macOS's ui/tooltip/config.lua and of the
--- Windows ui_style.ahk, and the three read the same file.
---
--- WHY FAIL-FAST AND NOT DEFAULTS:
--- A missing key here is a broken install, and the alternative is worse than an
--- error: a driver that substituted its own padding would draw a tooltip that
--- looks ALMOST like the other two, and "almost" is exactly the failure nobody
--- reports and nobody can diagnose from a screenshot. The other drivers already
--- raise; this one now does too.
---
--- FOLLOW THE TOML, NOT SPEC.md:
--- _shared/modules/tooltip/SPEC.md sources screen_margin from [positioning];
--- the TOML declares it under [layout]. The TOML is what every driver reads, so
--- it is what this module reads — and no gate pins the prose against the data,
--- so the drift is worth stating rather than silently working around.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Paths = require("infra.paths")
local TomlReader = require("toml_codec.reader")

local LOG = "ui.tooltip.config"

-- The suffix this driver's per-driver keys carry. macOS reads _hs, Windows _ahk.
local DRIVER_SUFFIX = "_linux"




-- =============================================
-- =============================================
-- ======= 1/ Reading the canon ================
-- =============================================
-- =============================================

--- The parsed sections, read once.
local _sections = nil

--- Loads the shared constants file, or raises.
--- @return table Section name → key → value.
local function sections()
	if _sections then return _sections end

	local path = Paths.shared("modules/tooltip/constants.toml")
	local parsed = TomlReader.parse(path)
	if type(parsed) ~= "table" or type(parsed.sections) ~= "table" then
		error("[tooltip.config] shared tooltip constants not readable: " .. tostring(path))
	end
	_sections = parsed.sections
	return _sections
end

--- One required key, or an error naming exactly what is missing.
--- @param section string
--- @param key string
--- @return any
local function require_key(section, key)
	local s = sections()[section]
	if type(s) ~= "table" or s[key] == nil then
		error(string.format("[tooltip.config] missing key [%s].%s in the shared tooltip constants",
			section, key))
	end
	return s[key]
end

--- A per-driver key, falling back to the shared one when the file declares only
--- a single value for every driver.
---
--- The fallback is NOT a default: it is the file saying "this value is the same
--- everywhere", which is true of the padding and the corner radius and false of
--- the fonts. A key that exists in neither form still raises.
--- @param section string
--- @param key string Base name, without the driver suffix.
--- @return any
local function require_driver_key(section, key)
	local s = sections()[section]
	if type(s) == "table" and s[key .. DRIVER_SUFFIX] ~= nil then
		return s[key .. DRIVER_SUFFIX]
	end
	return require_key(section, key)
end

--- Parses "#RRGGBB" into 0..1 components.
--- @param hex string
--- @return table { red, green, blue }
local function parse_hex(hex)
	local r, g, b = tostring(hex):match("^#(%x%x)(%x%x)(%x%x)$")
	if not r then
		error("[tooltip.config] not a #RRGGBB colour: " .. tostring(hex))
	end
	return {
		red   = tonumber(r, 16) / 255,
		green = tonumber(g, 16) / 255,
		blue  = tonumber(b, 16) / 255,
	}
end




-- =============================================
-- =============================================
-- ======= 2/ The style tables =================
-- =============================================
-- =============================================

--- Builds every style table the renderer needs. Raises on a missing key.
--- @return table
function M.load()
	local bg = parse_hex(require_key("colors", "bg_hex"))

	local style = {
		fonts = {
			main = require_driver_key("typography", "font_main"),
			bold = require_driver_key("typography", "font_bold"),
		},
		sizes = {
			main = require_driver_key("typography", "font_size_main"),
			hint = require_driver_key("typography", "font_size_hint"),
			info = require_driver_key("typography", "font_size_info"),
		},
		layout = {
			pad_x            = require_key("layout", "pad_x"),
			pad_y            = require_key("layout", "pad_y"),
			line_spacing     = require_key("layout", "line_spacing"),
			hint_spacing     = require_key("layout", "hint_spacing"),
			label_gap        = require_key("layout", "label_gap"),
			corner_radius    = require_key("layout", "corner_radius"),
			separator_height = require_key("layout", "separator_height"),
			-- SPEC.md files this under [positioning]; the TOML declares it under
			-- [layout] and the TOML is what every driver reads.
			screen_margin    = require_key("layout", "screen_margin"),
		},
		positioning = {
			caret_offset_x      = require_key("positioning", "caret_offset_x"),
			caret_offset_y      = require_key("positioning", "caret_offset_y"),
			window_offset_y     = require_key("positioning", "window_offset_y"),
			-- Named in full rather than composed from a suffix. A cross-driver gate
			-- records which driver reads which shared positioning constant, and it
			-- reads SOURCE — so a key assembled at runtime is a key that reach
			-- record cannot see, and the value would drop out of the ledger while
			-- still being used.
			window_bottom_inset = require_key("positioning", "window_bottom_inset_linux"),
			max_caret_height    = require_key("positioning", "max_caret_height"),
		},
		colors = {
			bg           = { red = bg.red, green = bg.green, blue = bg.blue },
			bg_alpha     = require_key("colors", "bg_alpha"),
			canvas_alpha = require_driver_key("colors", "canvas_alpha"),
			border_white = require_key("colors", "border_white"),
			border_alpha = require_driver_key("colors", "border_alpha"),
			sep_alpha    = require_driver_key("colors", "sep_alpha"),
		},
		tint = {
			lightness  = require_key("tint", "lightness"),
			saturation = require_key("tint", "saturation"),
		},
	}

	Logger.done(LOG, "Tooltip style loaded (pad %d/%d, radius %d, font %s %d).",
		style.layout.pad_x, style.layout.pad_y, style.layout.corner_radius,
		tostring(style.fonts.main), style.sizes.main)
	return style
end

--- Test seam: forgets the parsed file so a case can drive a different one.
function M._reset()
	_sections = nil
end

return M
