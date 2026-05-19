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

local _strings     = nil   -- active locale strings
local _strings_en  = nil   -- English fallback strings
local _strings_fr  = nil   -- French second-fallback strings
local _locale      = "fr"
local _get_trigger = nil   -- injected by init.lua after keymap is ready




-- =====================================
-- =====================================
-- ======= 1/ Internal loader  =========
-- =====================================
-- =====================================

--- Resolves the absolute path to a locale JSON file.
--- @param code string Locale code, e.g. ``"fr"``.
--- @return string Absolute path to the JSON file.
local function locale_path(code)
	local cfg = hs.configdir or ""
	-- Strip any trailing slash so the pattern anchor $ works reliably
	cfg = cfg:gsub("[/\\]+$", "")
	-- Walk up the directory tree looking for a static/locales/ sibling at each
	-- level. This is resilient to symlinks, realpath resolution, and any path
	-- prefix differences between dev and packaged .app builds where hs.configdir
	-- may not end with the expected /static/drivers/hammerspoon suffix.
	local function find_locales_root(dir)
		local max_steps = 8
		local current = dir
		for _ = 1, max_steps do
			local candidate = current .. "/static/locales"
			local ok, attr = pcall(hs.fs.attributes, candidate)
			if ok and type(attr) == "table" and attr.mode == "directory" then
				return current
			end
			-- Move one level up
			local parent = current:match("^(.*)[/\\][^/\\]+$")
			if not parent or parent == current then break end
			current = parent
		end
		return nil
	end

	local root = find_locales_root(cfg)
	if not root then
		Logger.warn(LOG, "locale_path: could not find static/locales/ walking up from '%s'.", cfg)
		-- Last-resort: try stripping the known suffix pattern
		root = cfg:gsub("[/\\]static[/\\]drivers[/\\]hammerspoon$", "")
		if root == cfg then
			Logger.error(LOG, "locale_path: giving up — path resolution failed for '%s'.", cfg)
		end
	end
	return root .. "/static/locales/" .. code .. ".json"
end

--- Loads a JSON locale file and returns a flat key→string table, or {}.
--- @param code string Locale code to load.
--- @return table
local function load_locale(code)
	local path = locale_path(code)
	local ok, data = pcall(function()
		local f = io.open(path, "r")
		if not f then
			Logger.error(LOG, "Locale file not found: '%s' (hs.configdir='%s').", path, hs.configdir or "nil")
			return {}
		end
		local raw = f:read("*a")
		f:close()
		return hs.json.decode(raw) or {}
	end)
	if ok and type(data) == "table" then
		Logger.debug(LOG, "Locale '%s' loaded (%d key(s)).", code, (function()
			local n = 0; for _ in pairs(data) do n = n + 1 end; return n
		end)())
		return data
	end
	Logger.warn(LOG, "Failed to load locale '%s': %s.", code, tostring(data))
	return {}
end

--- Ensures the active locale and both fallback locales are loaded.
local function ensure_loaded()
	if _strings then return end
	_strings = load_locale(_locale)
	-- Pre-load fallbacks so missing keys degrade gracefully
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
	-- Resolve with fallback chain: active locale → English → French
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
	_locale     = code
	_strings    = nil
	-- Reset en/fr caches only if they were the previously active locale
	-- (they stay loaded across locale switches to avoid redundant re-reads)
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
