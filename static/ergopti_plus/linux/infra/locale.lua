--- infra/locale.lua

--- ==============================================================================
--- MODULE: Locale (Linux)
--- DESCRIPTION:
--- Thin wrapper around _shared/lua/locale/core.lua. Injects Linux-specific
--- dependencies (vendored JSON decoder, debug.getinfo-based path walker,
--- logger shim) and re-exports the shared surface. All locale logic lives in
--- the shared module — this file only wires the platform layer.
---
--- FEATURES & RATIONALE:
--- 1. Shared source: the same JSON files are consumed by all 3 drivers.
--- 2. Lazy load: the first successful read is cached; transient failures retry.
--- 3. ★ substitution: the trigger-character placeholder is replaced at
---    call time from an injectable provider.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

-- Always start from a clean locale.core — tests may have left mock state
-- in the module cache (Core.init is idempotent and won't overwrite it).
package.loaded["locale.core"] = nil
local Core   = require("locale.core")

-- Resolve the JSON decoder (pcall-guarded — falls back to load("return…")).
local function resolve_json_decoder()
	local ok_j, json_mod = pcall(require, "json")
	if ok_j and json_mod and type(json_mod.decode) == "function" then
		return json_mod.decode
	end
	-- Minimal fallback for trusted static data (strings only).
	return function(raw)
		local ok, val = pcall(function()
			return assert(load("return " .. raw))()
		end)
		if ok then return val end
	end
end

-- Resolves _shared/data/locales/<code>.json through infra/paths.lua, the one
-- resolver that knows both shipped layouts. This used to cut three levels off
-- this file's own chunk name, which is right only in the checkout and the
-- tarball: on the .deb and .rpm (/usr/lib/ergopti/infra/locale.lua) it named
-- /usr/lib/_shared, and from a relative launch ("./infra/locale.lua") it named
-- nothing. Either way every lookup returned its raw key, so the tray menu and
-- every notification read "menu.global.reload" instead of text.
local function resolve_locale_path(code)
	local ok, Paths = pcall(require, "infra.paths")
	if not ok or type(Paths.shared) ~= "function" then return "" end
	return Paths.shared("data/locales/" .. code .. ".json") or ""
end

-- Wire the shared module at require-time.
Core.init({
	json_decode = resolve_json_decoder(),
	resolve_locale_path = resolve_locale_path,
	log_debug = function(section, fmt, ...) Logger.debug(section, fmt, ...) end,
	log_warn  = function(section, fmt, ...) Logger.warn(section, fmt, ...) end,
	log_error = function(section, fmt, ...) Logger.error(section, fmt, ...) end,
})

-- Re-export the shared surface.
function M.get(key)                  return Core.get(key) end
function M.set_trigger_provider(fn)  Core.set_trigger_provider(fn) end
function M.set_locale(code)          Core.set_locale(code) end
function M.all()                     return Core.all() end

return M
