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
--- 2. Lazy load: the file is read once on first get() call and cached.
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

-- Resolves the absolute path to _shared/data/locales/<code>.json by walking
-- up from this file's location (linux/infra/ → repo root → _shared/).
local function resolve_locale_path(code)
	local src = debug and debug.getinfo and debug.getinfo(1, "S")
	if src and src.source then
		local s = src.source
		if s:sub(1, 1) == "@" or s:sub(1, 1) == "=" then s = s:sub(2) end
		s = s:gsub("\\", "/")
		local root = s:match("^(.*)/[^/]+/[^/]+/[^/]+$")
		if root then
			return root .. "/_shared/data/locales/" .. code .. ".json"
		end
	end
	return ""
end

-- Wire the shared module at require-time.
Core.init({
	json_decode = resolve_json_decoder(),
	resolve_locale_path = resolve_locale_path,
	log_debug = function(section, fmt, ...) Logger.debug(section, fmt, ...) end,
	log_warn  = function(section, fmt, ...) Logger.warn(section, fmt, ...) end,
	log_error = function(section, fmt, ...) Logger.error(section, fmt, ...) end,
	strip_bom = true,  -- pure-Lua JSON decoder rejects UTF-8 BOM
})

-- Re-export the shared surface.
function M.get(key)                  return Core.get(key) end
function M.set_trigger_provider(fn)  Core.set_trigger_provider(fn) end
function M.set_locale(code)          Core.set_locale(code) end
function M.all()                     return Core.all() end

return M
