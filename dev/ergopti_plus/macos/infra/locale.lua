--- infra/locale.lua

--- ==============================================================================
--- MODULE: Locale (macOS)
--- DESCRIPTION:
--- Thin wrapper around _shared/lua/locale/core.lua. Injects macOS-specific
--- dependencies (hs.json.decode, Paths.shared, Logger) and re-exports the
--- shared surface. All locale logic lives in the shared module — this file
--- only wires the platform layer.
---
--- FEATURES & RATIONALE:
--- 1. Shared source: the same JSON files are consumed by all 3 drivers.
--- 2. Lazy load: the file is read once on first get() call and cached.
--- 3. ★ substitution: the trigger-character placeholder is replaced at
---    call time so the correct character is used even after rebinding.
--- ==============================================================================

local M = {}

local Logger  = require("infra.logger")
local Paths   = require("infra.paths")

-- Always start from a clean locale.core — tests may have left mock state
-- in the module cache (Core.init is idempotent and won't overwrite it).
package.loaded["locale.core"] = nil
local Core    = require("locale.core")

-- Wire the shared module at require-time so callers never call init().
Core.init({
	json_decode = hs.json.decode,
	resolve_locale_path = function(code)
		local path = Paths.shared("data/locales/" .. code .. ".json")
		if path and path ~= "" then
			-- Verify the file exists — fail-fast if not found
			local f = io.open(path, "r")
			if f then f:close(); return path end
		end
		Logger.error("locale", "locale_path('%s'): file not found.", code)
		return ""
	end,
	log_debug = function(section, fmt, ...) Logger.debug(section, fmt, ...) end,
	log_warn  = function(section, fmt, ...) Logger.warn(section, fmt, ...) end,
	log_error = function(section, fmt, ...) Logger.error(section, fmt, ...) end,
	strip_bom = false,  -- hs.json.decode handles BOM natively
})

-- Re-export the shared surface.
function M.get(key)                  return Core.get(key) end
function M.set_trigger_provider(fn)  Core.set_trigger_provider(fn) end
function M.set_locale(code)          Core.set_locale(code) end
function M.all()                     return Core.all() end

return M
