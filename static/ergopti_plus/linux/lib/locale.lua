--- linux/lib/locale.lua

--- ==============================================================================
--- MODULE: Locale (Linux)
--- DESCRIPTION:
--- Loads UI string translations from the shared locale JSON files at
--- ``_shared/data/locales/<code>.json``. Mirrors ``macos/lib/locale.lua``:
--- same surface (M.get, M.set_locale, all), same ★ substitution, same
--- en→fr fallback chain. The macOS driver resolves paths via Paths.shared()
--- and uses hs.json.decode; the Linux driver resolves by walking up from
--- this file's own location and uses a pcall-guarded JSON decoder.
---
--- FEATURES & RATIONALE:
--- 1. Shared source: the same JSON files are consumed by all 3 drivers.
--- 2. Lazy load: the file is read once on first get() call and cached.
--- 3. ★ substitution: the trigger-character placeholder is replaced at
---    call time from an injectable provider.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG    = "locale"

local _strings     = nil   -- active locale strings
local _strings_en  = nil   -- English fallback strings
local _strings_fr  = nil   -- French second-fallback strings
local _locale      = "fr"
local _get_trigger = nil   -- injected by init after keymap is ready

-- Resolve the JSON decoder (pcall-guarded — falls back to load("return…")).
local _json_decode = nil
local function _resolve_decoder()
	if _json_decode then return end
	local ok_j, json_mod = pcall(require, "json")
	if ok_j and json_mod and type(json_mod.decode) == "function" then
		_json_decode = json_mod.decode
		return
	end
	-- Minimal fallback for trusted static data (strings only, no booleans/null).
	_json_decode = function(raw)
		local ok, val = pcall(function()
			return assert(load("return " .. raw))()
		end)
		if ok then return val end
	end
end


-- =====================================
-- =====================================
-- ======= 1/ Internal loader  =========
-- =====================================
-- =====================================

--- Resolves the absolute path to _shared/data/locales/<code>.json by walking
--- up from this file's location (linux/lib/ → repo root → _shared/).
--- @param code string Locale code, e.g. "fr".
--- @return string Absolute path, or empty string on failure.
local function locale_path(code)
	local src = debug and debug.getinfo and debug.getinfo(1, "S")
	if src and src.source then
		local s = src.source
		-- Strip leading '@' (LuaJIT) or '=' (Lua 5.4 chunk marker)
		if s:sub(1, 1) == "@" or s:sub(1, 1) == "=" then s = s:sub(2) end
		s = s:gsub("\\", "/")
		-- s is .../ergopti_plus/linux/lib/locale.lua — walk up 3 levels to .../ergopti_plus/
		local root = s:match("^(.*)/[^/]+/[^/]+/[^/]+$")  -- strips /linux/lib/locale.lua
		if root then
			return root .. "/_shared/data/locales/" .. code .. ".json"
		end
	end
	return ""
end

--- Loads a JSON locale file and returns a flat key→string table, or {}.
--- @param code string Locale code to load.
--- @return table
local function load_locale(code)
	_resolve_decoder()
	local path = locale_path(code)
	if path == "" then
		Logger.error(LOG, "locale_path('%s'): cannot resolve shared path.", code)
		return {}
	end
	local fh = io.open(path, "r")
	if not fh then
		Logger.warn(LOG, "Locale file not found: %s.", path)
		return {}
	end
	local raw = fh:read("*a")
	fh:close()
	-- Strip UTF-8 BOM (EF BB BF) — the pure-Lua JSON decoder rejects it
	if raw:sub(1, 3) == "\239\187\191" then raw = raw:sub(4) end
	if _json_decode then
		local ok, data = pcall(_json_decode, raw)
		if ok and type(data) == "table" then
			local n = 0; for _ in pairs(data) do n = n + 1 end
			Logger.debug(LOG, "Locale '%s' loaded (%d key(s)).", code, n)
			return data
		end
	end
	Logger.warn(LOG, "Failed to decode locale '%s'.", code)
	return {}
end

--- Ensures the active locale and both fallback locales are loaded.
local function ensure_loaded()
	if _strings then return end
	_strings = load_locale(_locale)
	if _locale ~= "en" then
		_strings_en = _strings_en or load_locale("en")
	else
		_strings_en = _strings
	end
	if _locale ~= "fr" then
		_strings_fr = _strings_fr or load_locale("fr")
	else
		_strings_fr = _strings
	end
end


-- ============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- ============================

--- Returns the translated string for the given dot-notation key,
--- with ★ substituted for the current trigger character.
--- Returns an empty string if the key is not found.
--- @param key string Dot-notation key.
--- @return string
function M.get(key)
	ensure_loaded()
	local s = _strings[key]
	if type(s) ~= "string" or s == "" then
		s = _strings_en and _strings_en[key]
	end
	if type(s) ~= "string" or s == "" then
		s = _strings_fr and _strings_fr[key]
	end
	if type(s) ~= "string" then return "" end
	if _get_trigger then
		local ok, trigger = pcall(_get_trigger)
		if ok and type(trigger) == "string" and trigger ~= "" then
			s = (s:gsub("★", (trigger:gsub("%%", "%%%%"))))
		end
	end
	return s
end

--- Sets the trigger-character provider used for ★ substitution.
--- @param fn function A zero-argument function returning the trigger string.
function M.set_trigger_provider(fn)
	if type(fn) == "function" then
		_get_trigger = fn
	end
end

--- Switches the active locale and clears the string cache.
--- @param code string A locale code, e.g. "en".
function M.set_locale(code)
	if type(code) ~= "string" or code == "" then return end
	_locale     = code
	_strings    = nil
	if code == "en" then _strings_en = nil end
	if code == "fr" then _strings_fr = nil end
end

--- Returns all loaded strings as a flat table (for inspection/testing).
--- @return table
function M.all()
	ensure_loaded()
	return _strings
end

return M
