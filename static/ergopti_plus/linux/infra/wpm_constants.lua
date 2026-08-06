--- infra/wpm_constants.lua

--- ==============================================================================
--- MODULE: WPM Widget Visual Constants (Linux binding)
--- DESCRIPTION:
--- Reads _shared/modules/wpm_widget/constants.toml — the cross-driver canon for
--- the WPM widget's geometry, colours and transparency.
---
--- WHY THIS READS THE FILE INSTEAD OF MIRRORING IT:
--- The canon's own header says "when a value changes here, the driver-side files
--- must be updated to match", and both existing drivers do exactly that: the AHK
--- `WPMWidgetConst` class and the Hammerspoon `CONFIG` table each restate every
--- entry by hand. Three hand-copies of one table is three chances for one to
--- drift, and the drift is invisible — a widget eight pixels too narrow on one
--- platform looks like a design choice.
---
--- This driver reads it. That is one fewer copy, and it costs a single file read
--- at startup for values that cannot change while the daemon runs.
---
--- FAIL-FAST, unlike the personal-info reader next door. A missing constant here
--- produces a widget with nil geometry, which draws nothing or draws wrong; there
--- is no safe degraded rendering to fall back to, and a widget that silently does
--- not appear is the defect this driver has already paid for twice.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Codec  = require("toml_codec")
local Paths  = require("infra.paths")

local LOG = "infra.wpm_constants"

-- Every key the widget reads, by section. Listed so a missing one is named at
-- load rather than discovered as a nil arithmetic error mid-draw.
local REQUIRED = {
	compact = {
		"width", "height", "height_number", "height_gap", "height_unit",
		"number_font_size", "unit_font_size", "padding_x", "unit_strip_darken_factor",
	},
	colors = { "bg_manual", "bg_ai", "bg_idle", "text_active", "text_idle" },
	transparency = { "alpha_active", "alpha_idle" },
}

local _constants = nil




-- =========================================
-- =========================================
-- ======= 1/ Loading ======================
-- =========================================
-- =========================================

--- Resolves the canon's absolute path through infra.paths.
---
--- Counting path components — three levels up, then "/_shared/…" — assumes the
--- checkout layout. A system package puts the driver flat in /usr/lib/ergopti,
--- where three up is /usr and nothing is found.
--- @return string|nil
local function resolve_path()
	return Paths.shared("modules/wpm_widget/constants.toml")
end

--- Loads and validates the canon, once.
--- @return table|nil The parsed table, or nil when it cannot be trusted.
function M.load()
	if _constants ~= nil then return _constants end

	local path = resolve_path()
	if not path then
		Logger.error(LOG, "Cannot resolve the shared WPM constants path — the widget cannot draw.")
		return nil
	end

	local fh = io.open(path, "r")
	if not fh then
		Logger.error(LOG, "Cannot open '%s' — the widget cannot draw.", path)
		return nil
	end
	local content = fh:read("*a")
	fh:close()

	local ok, parsed = pcall(Codec.decode, content)
	if not ok or type(parsed) ~= "table" then
		Logger.error(LOG, "Cannot parse '%s' — the widget cannot draw. (%s)", path, tostring(parsed))
		return nil
	end

	for section, keys in pairs(REQUIRED) do
		local table_ = parsed[section]
		if type(table_) ~= "table" then
			Logger.error(LOG, "The shared constants have no [%s] section — the widget cannot draw.", section)
			return nil
		end
		for _, key in ipairs(keys) do
			if table_[key] == nil then
				Logger.error(LOG, "The shared constants are missing %s.%s — the widget cannot draw.",
					section, key)
				return nil
			end
		end
	end

	_constants = parsed
	Logger.info(LOG, "WPM widget constants loaded from the shared canon.")
	return _constants
end

--- Drops the cache. Tests only.
function M._reset()
	_constants = nil
end

return M
