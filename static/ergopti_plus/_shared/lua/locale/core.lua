--- _shared/lua/locale/core.lua

--- ==============================================================================
--- MODULE: Locale Core (shared)
--- DESCRIPTION:
--- Pure logic for loading UI string translations from JSON locale files,
--- resolving translations through an active→en→fr fallback chain, and
--- substituting the ★ placeholder with the configured trigger character.
---
--- This module is driver-agnostic — the caller injects a JSON decoder, a path
--- resolver closure, and optional log functions via M.init(). The macOS driver
--- (macos/lib/locale.lua) injects hs.json.decode + Paths.shared; the Linux
--- driver (linux/lib/locale.lua) injects a vendored JSON decoder + a
--- debug.getinfo-based path walker. Both wrappers re-export the same public
--- surface so callers do not change.
---
--- FEATURES & RATIONALE:
--- 1. Single source: the two Lua locale modules were fork quasi-verbatim copies
---    (~160 lines each) differing only in JSON decoder + path resolution.
---    Merged here so any behaviour fix or ★-substitution tweak applies to both
---    drivers immediately.
--- 2. Lazy load: the file is read once on first get() call and cached.
--- 3. ★ substitution: the trigger-character placeholder is replaced at call time
---    via an injectable provider so the correct char is used even after rebinding.
--- 4. Fail-fast: invalid init args are logged (if log funcs are provided) and
---    the module stays uninitialised; get() returns "" until init succeeds.
--- ==============================================================================

local M = {}

-- Internal state — nil until M.init() succeeds.
local _state = nil




-- ========================================
-- ========================================
-- ======= 1/ Init & Guard ================
-- ========================================
-- ========================================

--- Initialises the locale module with driver-specific dependencies.
--- Must be called once before any other method. Idempotent — warns on
--- duplicate calls.
--- @param opts table
---   .json_decode          function (raw_json_string) → table (required)
---   .resolve_locale_path  function (code) → absolute_path_string | "" (required)
---   .log_debug            function|nil (fmt, ...)
---   .log_warn             function|nil (fmt, ...)
---   .log_error            function|nil (fmt, ...)
---   .read_file            function|nil  (path) → string|nil  Injected file reader for
---                         tests — when present, io.open is bypassed entirely.
---                         Return nil to signal a missing file.
---   .strip_bom            boolean  Strip UTF-8 BOM before JSON decode (default false)
function M.init(opts)
	if type(opts) ~= "table" then
		return
	end
	if _state then
		if opts.log_warn then
			opts.log_warn("locale", "M.init() called more than once — ignoring duplicate call.")
		end
		return
	end
	if type(opts.json_decode) ~= "function" then
		if opts.log_error then opts.log_error("locale", "M.init(): json_decode must be a function.") end
		return
	end
	if type(opts.resolve_locale_path) ~= "function" then
		if opts.log_error then opts.log_error("locale", "M.init(): resolve_locale_path must be a function.") end
		return
	end

	_state = {
		strings     = nil,
		strings_en  = nil,
		strings_fr  = nil,
		locale      = "fr",
		get_trigger = nil,
		json_decode         = opts.json_decode,
		resolve_locale_path = opts.resolve_locale_path,
		read_file  = type(opts.read_file) == "function" and opts.read_file or nil,
		strip_bom  = opts.strip_bom == true,
		log_debug  = type(opts.log_debug)  == "function" and opts.log_debug  or nil,
		log_warn   = type(opts.log_warn)   == "function" and opts.log_warn   or nil,
		log_error  = type(opts.log_error)  == "function" and opts.log_error  or nil,
	}
end

--- Guards public functions against being called before M.init().
--- @param func_name string Name of the calling function for the error log.
--- @return boolean False if not yet initialised.
local function require_init(func_name)
	if not _state then
		return false
	end
	return true
end




-- =====================================
-- =====================================
-- ======= 2/ Internal loader  =========
-- =====================================
-- =====================================

--- Loads a JSON locale file and returns a flat key→string table, or {}.
--- @param code string Locale code to load.
--- @return table
local function load_locale(code)
	local path = _state.resolve_locale_path(code)
	if path == "" then
		if _state.log_error then
			_state.log_error("locale", "locale_path('%s'): cannot resolve shared path.", code)
		end
		return {}
	end
	local raw
	if _state.read_file then
		raw = _state.read_file(path)
		if raw == nil then
			if _state.log_warn then
				_state.log_warn("locale", "Locale file not found: %s.", path)
			end
			return {}
		end
	else
		local fh = io.open(path, "r")
		if not fh then
			if _state.log_warn then
				_state.log_warn("locale", "Locale file not found: %s.", path)
			end
			return {}
		end
		raw = fh:read("*a")
		fh:close()
	end
	if _state.strip_bom and raw:sub(1, 3) == "\239\187\191" then
		raw = raw:sub(4)
	end
	local ok, data = pcall(_state.json_decode, raw)
	if ok and type(data) == "table" then
		local n = 0; for _ in pairs(data) do n = n + 1 end
		if _state.log_debug then
			_state.log_debug("locale", "Locale '%s' loaded (%d key(s)).", code, n)
		end
		return data
	end
	if _state.log_warn then
		_state.log_warn("locale", "Failed to decode locale '%s'.", code)
	end
	return {}
end

--- Ensures the active locale and both fallback locales are loaded.
local function ensure_loaded()
	if _state.strings then return end
	_state.strings = load_locale(_state.locale)
	if _state.locale ~= "en" then
		_state.strings_en = _state.strings_en or load_locale("en")
	else
		_state.strings_en = _state.strings
	end
	if _state.locale ~= "fr" then
		_state.strings_fr = _state.strings_fr or load_locale("fr")
	else
		_state.strings_fr = _state.strings
	end
end





-- ============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- ============================

--- Returns the translated string for the given dot-notation key,
--- with ★ substituted for the current trigger character.
--- Returns an empty string if the key is not found.
--- @param key string Dot-notation key.
--- @return string
function M.get(key)
	if not require_init("get") then return "" end
	ensure_loaded()
	local s = _state.strings[key]
	if type(s) ~= "string" or s == "" then
		s = _state.strings_en and _state.strings_en[key]
	end
	if type(s) ~= "string" or s == "" then
		s = _state.strings_fr and _state.strings_fr[key]
	end
	if type(s) ~= "string" then return "" end
	if _state.get_trigger then
		local ok, trigger = pcall(_state.get_trigger)
		if ok and type(trigger) == "string" and trigger ~= "" then
			s = (s:gsub("★", (trigger:gsub("%%", "%%%%"))))
		end
	end
	return s
end

--- Sets the trigger-character provider used for ★ substitution.
--- @param fn function A zero-argument function returning the trigger string.
function M.set_trigger_provider(fn)
	if not require_init("set_trigger_provider") then return end
	if type(fn) == "function" then
		_state.get_trigger = fn
	end
end

--- Switches the active locale and clears the string cache.
--- @param code string A locale code, e.g. "en".
function M.set_locale(code)
	if not require_init("set_locale") then return end
	if type(code) ~= "string" or code == "" then return end
	_state.locale     = code
	_state.strings    = nil
	if code == "en" then _state.strings_en = nil end
	if code == "fr" then _state.strings_fr = nil end
end

--- Returns all loaded strings as a flat table (for inspection/testing).
--- @return table
function M.all()
	if not require_init("all") then return {} end
	ensure_loaded()
	return _state.strings
end

--- Returns true if the module has been initialised (for testing).
--- @return boolean
function M.is_initialised()
	return _state ~= nil
end

return M
