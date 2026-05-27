--- lib/i18n.lua

--- ==============================================================================
--- MODULE: i18n (Internationalisation)
--- DESCRIPTION:
--- Manages the active UI locale for the Hammerspoon driver. Wraps lib/locale
--- to add locale switching, persistence via hs.settings, and a language
--- selector menu builder.
---
--- FEATURES & RATIONALE:
--- 1. Lazy Load: delegates file I/O to lib/locale; a locale switch clears
---    the locale cache so the next get() re-reads the new file.
--- 2. Persistence: the active locale code is written to hs.settings under
---    ``i18n_locale`` so it survives script reloads without touching any
---    TOML file.
--- 3. Language selector: M.build_language_menu() returns a table of
---    hs.menubar or hs.menu items — one per supported locale — usable
---    directly inside builder.lua's global-actions section.
--- 4. Shared locale files: JSON files in static/locales/ are the single
---    source of truth shared with the AHK driver.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")
local LOG    = "i18n"

local locale_mod = require("lib.locale")




-- ==========================================
--- =============================================
-- ======= 1/ Constants and module state =======
--- =============================================
-- ==========================================

--- Ordered list of supported locales.
local LOCALES = {
	{ code = "ar", flag = "🇸🇦", name = "العربية"    },
	{ code = "cs", flag = "🇨🇿", name = "Čeština"    },
	{ code = "da", flag = "🇩🇰", name = "Dansk"       },
	{ code = "de", flag = "🇩🇪", name = "Deutsch"     },
	{ code = "en", flag = "🇬🇧", name = "English"     },
	{ code = "es", flag = "🇪🇸", name = "Español"     },
	{ code = "fr", flag = "🇫🇷", name = "Français"    },
	{ code = "he", flag = "🇮🇱", name = "עברית"       },
	{ code = "hi", flag = "🇮🇳", name = "हिन्दी"      },
	{ code = "it", flag = "🇮🇹", name = "Italiano"    },
	{ code = "ja", flag = "🇯🇵", name = "日本語"       },
	{ code = "ko", flag = "🇰🇷", name = "한국어"       },
	{ code = "nl", flag = "🇳🇱", name = "Nederlands"  },
	{ code = "no", flag = "🇳🇴", name = "Norsk"        },
	{ code = "pl", flag = "🇵🇱", name = "Polski"       },
	{ code = "pt", flag = "🇧🇷", name = "Português"   },
	{ code = "ru", flag = "🇷🇺", name = "Русский"      },
	{ code = "sv", flag = "🇸🇪", name = "Svenska"      },
	{ code = "tr", flag = "🇹🇷", name = "Türkçe"       },
	{ code = "uk", flag = "🇺🇦", name = "Українська"   },
	{ code = "zh", flag = "🇨🇳", name = "中文"          },
}

--- hs.settings key used to persist the locale between reloads.
local SETTINGS_KEY = "i18n_locale"

--- Currently active locale code.
local _locale = "fr"




-- =====================================
--- ===================================
-- ======= 2/ Internal helpers =======
--- ===================================
-- =====================================

--- Returns true when code is a supported locale code.
local function is_known(code)
	for _, loc in ipairs(LOCALES) do
		if loc.code == code then return true end
	end
	return false
end

--- Pushes the active locale into lib/locale so get() resolves the right file.
--- lib/locale exposes no public setter for the locale code, so we access its
--- internals via a module-level upvalue injection pattern using an internal
--- function injected at require time.
local _locale_set_fn = nil  -- injected by init() below




-- =========================================
--- =============================
-- ======= 3/ Public API =======
--- =============================
-- =========================================

--- Detects the macOS system UI locale and returns the best matching supported
--- locale code.  Falls back to "en" when the system locale cannot be mapped.
--- Uses ``hs.host.locale.current()`` (Hammerspoon 0.9.93+); degrades gracefully
--- when the API is unavailable.
--- @return string A supported locale code, e.g. ``"fr"`` or ``"en"``.
function M.detect_system_locale()
	local raw = nil
	-- hs.host.locale.current() returns e.g. "fr_FR", "en_GB", "zh_Hans_CN"
	if hs.host and hs.host.locale and type(hs.host.locale.current) == "function" then
		local ok, val = pcall(hs.host.locale.current)
		if ok and type(val) == "string" then raw = val end
	end
	if not raw or raw == "" then
		Logger.debug(LOG, "detect_system_locale: API unavailable — falling back to 'en'.")
		return "en"
	end
	-- Try exact two-letter prefix first (e.g. "fr" from "fr_FR")
	local lang = raw:match("^([a-z][a-z])")
	if lang and is_known(lang) then
		Logger.debug(LOG, "detect_system_locale: '%s' → '%s'.", raw, lang)
		return lang
	end
	Logger.debug(LOG, "detect_system_locale: '%s' not in supported list — falling back to 'en'.", raw)
	return "en"
end

--- Initialises the i18n module. Reads the persisted locale from hs.settings;
--- if none is saved, detects the macOS system locale (fallback: "en").
--- Must be called once at boot before any menu is built.
function M.init()
	Logger.trace(LOG, "Initialising i18n…")
	local saved = hs.settings.get(SETTINGS_KEY)
	if type(saved) == "string" and is_known(saved) then
		_locale = saved
	else
		_locale = M.detect_system_locale()
	end
	-- Patch lib/locale so it loads the right file
	if _locale_set_fn then _locale_set_fn(_locale) end
	Logger.done(LOG, "i18n initialised (locale: '%s').", _locale)
end

--- Returns the translated string for the given dot-notation key.
--- Delegates to lib/locale.get() which handles ★ substitution and caching.
--- Falls back to the raw key name when the string is absent.
--- @param key string Dot-notation key, e.g. ``"menu.global.reload"``.
--- @return string
function M.get(key)
	local s = locale_mod.get(key)
	if s == nil or s == "" then return key end
	return s
end

--- Returns the active locale code (e.g. ``"fr"``).
--- @return string
function M.get_locale()
	return _locale
end

--- Changes the active locale, persists it, and triggers a Hammerspoon reload
--- so all menus are rebuilt in the new language.
--- @param code string A known locale code.
function M.set_locale(code)
	if not is_known(code) then
		Logger.warn(LOG, "Unknown locale '%s' — ignoring.", code)
		return
	end
	if code == _locale then return end
	Logger.start(LOG, "Switching locale to '%s'…", code)
	_locale = code
	hs.settings.set(SETTINGS_KEY, code)
	Logger.success(LOG, "Locale set to '%s' — reloading.", code)
	hs.reload()
end

--- Changes the active locale in memory only, without triggering a reload.
--- Used by the onboarding wizard so subsequent steps render in the new locale
--- without restarting the script mid-wizard.
--- @param code string A known locale code.
function M.set_locale_no_reload(code)
	if not is_known(code) then
		Logger.warn(LOG, "Unknown locale '%s' — ignoring.", code)
		return
	end
	_locale = code
	if _locale_set_fn then _locale_set_fn(code) end
end


--- Returns a shallow copy of LOCALES sorted alphabetically by name
--- (case-insensitive). Acts as the single source of truth for display
--- order across every surface that lists locales — the menubar language
--- submenu, the onboarding wizard's step 1 list, etc. — so they all
--- agree on row ordering regardless of the declaration order above.
---
--- Lua's ``string.lower`` only folds ASCII bytes, which is intentional
--- here: it keeps non-Latin script names (Cyrillic, Hebrew, Arabic,
--- Devanagari, CJK, Hangul) at the tail of the list per their natural
--- UTF-8 byte order, instead of intermixing them with Latin names.
--- @return table[] List of ``{code, flag, name}`` tables.
function M.get_sorted_locales()
	local sorted = {}
	for _, loc in ipairs(LOCALES) do sorted[#sorted + 1] = loc end
	table.sort(sorted, function(a, b) return a.name:lower() < b.name:lower() end)
	return sorted
end

--- Returns a list of hs.menu-compatible item tables for a language selector.
--- Each item has a title and an fn; the currently active locale gets a
--- checked = true flag. Pass this list directly into an hs.menubar submenu.
--- @return table[] List of menu item tables.
function M.build_language_menu_items()
	local items = {}
	for _, loc in ipairs(M.get_sorted_locales()) do
		local code = loc.code
		items[#items + 1] = {
			title   = loc.flag .. " " .. loc.name,
			checked = (code == _locale),
			fn      = function() M.set_locale(code) end,
		}
	end
	return items
end

--- Injects a locale setter into lib/locale so the active locale is applied
--- at module level. Called internally during init; exposed so init.lua can
--- wire the locale into lib/locale before any module calls locale.get().
--- @param fn function A function accepting a locale code string.
function M.set_locale_injector(fn)
	_locale_set_fn = fn
end

--- Returns the ordered list of supported locales (read-only view).
--- @return table[]
function M.locales()
	return LOCALES
end

--- Wraps a translated string in section-title dashes for disabled menu headers.
--- Use instead of embedding — directly in locale values.
--- @param key string i18n key to translate.
--- @return string Formatted as "— Value —".
function M.section(key)
	return "— " .. M.get(key) .. " —"
end

return M
