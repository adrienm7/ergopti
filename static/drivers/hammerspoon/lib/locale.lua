--- lib/locale.lua

--- ==============================================================================
--- MODULE: Locale
--- DESCRIPTION:
--- Loads UI string translations from a JSON locale file located at
--- ``static/locales/<locale>.json`` relative to the Hammerspoon config root.
--- Provides a single ``get(key)`` accessor so every module can retrieve a
--- translated description without knowing the locale or file path.
---
--- FEATURES & RATIONALE:
--- 1. Shared source: the same JSON files are consumed by the AHK driver, making
---    ``static/locales/`` the single source of truth for all UI descriptions
---    regardless of the underlying OS driver.
--- 2. Lazy load: the file is read once on first ``get()`` call and cached.
--- 3. ★ substitution: the trigger-character placeholder ``★`` is replaced at
---    call time so the correct character is used even if the user has rebound it.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")
local LOG    = "locale"

local _strings  = nil
local _locale   = "fr"
local _get_trigger = nil   -- injected by init.lua after keymap is ready




-- =====================================
-- =====================================
-- ======= 1/ Internal loader  =========
-- =====================================
-- =====================================

--- Resolves the absolute path to the locale JSON file.
--- @return string Absolute path to e.g. ``…/static/locales/fr.json``.
local function locale_path()
	-- hs.configdir points to ~/.hammerspoon; the repo root is two levels up
	-- (hammerspoon/ → static/ → repo root) then down to static/locales/.
	-- We walk up from hs.configdir until we find the locales/ directory.
	local cfg = hs.configdir or ""
	-- Expected layout: <repo>/static/drivers/hammerspoon/ → hs.configdir
	-- Walk up 3 levels: hammerspoon → drivers → static → repo root
	local repo_root = cfg:gsub("/static/drivers/hammerspoon$", "")
	                      :gsub("\\static\\drivers\\hammerspoon$", "")
	return repo_root .. "/static/locales/" .. _locale .. ".json"
end

--- Loads and caches the locale strings map.
local function ensure_loaded()
	if _strings then return end
	local path = locale_path()
	local ok, data = pcall(function()
		local f = io.open(path, "r")
		if not f then
			Logger.warn(LOG, "Locale file not found: '%s'.", path)
			return {}
		end
		local raw = f:read("*a")
		f:close()
		return hs.json.decode(raw) or {}
	end)
	if ok and type(data) == "table" then
		_strings = data
		Logger.debug(LOG, "Locale '%s' loaded (%d key(s)).", _locale, (function()
			local n = 0; for _ in pairs(data) do n = n + 1 end; return n
		end)())
	else
		Logger.warn(LOG, "Failed to load locale '%s': %s.", _locale, tostring(data))
		_strings = {}
	end
end




-- ============================
-- ============================
-- ======= 2/ Public API =======
-- ============================
-- ============================

--- Returns the translated string for the given dot-notation key,
--- with ``★`` substituted for the current trigger character.
--- Returns an empty string if the key is not found.
--- @param key string Dot-notation key, e.g. ``"dynamichotstrings.datefr"``.
--- @return string
function M.get(key)
	ensure_loaded()
	local s = _strings[key]
	if type(s) ~= "string" then return "" end
	if _get_trigger then
		local ok, trigger = pcall(_get_trigger)
		if ok and type(trigger) == "string" and trigger ~= "" then
			s = s:gsub("★", trigger)
		end
	end
	return s
end

--- Sets the trigger-character provider used for ``★`` substitution.
--- Call this once from init.lua after the keymap is ready.
--- @param fn function A zero-argument function returning the trigger string.
function M.set_trigger_provider(fn)
	if type(fn) == "function" then
		_get_trigger = fn
	end
end

--- Switches the active locale and clears the string cache so the next
--- ``get()`` call reloads the correct JSON file.
--- @param code string A locale code, e.g. ``"en"``.
function M.set_locale(code)
	if type(code) ~= "string" or code == "" then return end
	_locale  = code
	_strings = nil
end

--- Returns all loaded strings as a flat table (for inspection/testing).
--- @return table
function M.all()
	ensure_loaded()
	return _strings
end

return M
