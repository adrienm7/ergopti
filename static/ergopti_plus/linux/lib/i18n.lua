--- linux/lib/i18n.lua

--- ==============================================================================
--- MODULE: i18n — Internationalisation (Linux)
--- DESCRIPTION:
--- Minimal i18n wrapper over lib/locale. The macOS i18n module handles
--- hs.settings persistence, system-locale detection, locale-sorted menus, and
--- debounced reloads. On Linux these are either not yet implemented (tray menu
--- is a stub) or not applicable (no hs.settings). This wrapper provides the
--- same surface (get, get_locale, set_locale) so future Linux UI code can
--- call i18n.get(key) without driver-specific paths.
---
--- FEATURES & RATIONALE:
--- 1. Thin: delegates everything to lib/locale.
--- 2. Same surface as macOS: get(), get_locale(), set_locale().
--- 3. Default locale: "fr" (matching the macOS default); can be changed via
---    set_locale() at any time.
--- ==============================================================================

local M = {}

local locale_mod = require("lib.locale")
local Logger     = require("logger.shim")
local LOG        = "i18n"

local _locale = "fr"


-- =============================
-- =============================
-- ======= Public API ==========
-- =============================
-- =============================

--- Returns the translated string for the given dot-notation key.
--- Delegates to lib/locale.get(). Falls back to the raw key name.
--- @param key string Dot-notation key, e.g. "menu.global.reload".
--- @return string
function M.get(key)
	local s = locale_mod.get(key)
	if s == nil or s == "" then return key end
	return s
end

--- Returns the active locale code (e.g. "fr").
--- @return string
function M.get_locale()
	return _locale
end

--- Changes the active locale. The next get() call reads the new file.
--- @param code string A locale code, e.g. "en".
function M.set_locale(code)
	if type(code) ~= "string" or code == "" then return end
	if code == _locale then return end
	_locale = code
	locale_mod.set_locale(code)
	Logger.info(LOG, "Locale set to '%s'.", code)
end

--- Injects a locale setter into lib/locale (for init-time wiring).
--- @param fn function A function accepting a locale code string.
function M.set_locale_injector(fn)
	-- The macOS version uses this to wire hs.settings persistence.
	-- On Linux the locale module handles its own state; kept for API parity.
end

return M
