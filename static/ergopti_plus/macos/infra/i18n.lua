--- infra/i18n.lua

--- ==============================================================================
--- MODULE: i18n (Internationalisation)
--- DESCRIPTION:
--- Manages the active UI locale for the Hammerspoon driver. Wraps infra/locale
--- to add locale switching, persistence via hs.settings, and a language
--- selector menu builder.
---
--- FEATURES & RATIONALE:
--- 1. Lazy Load: delegates file I/O to infra/locale; a locale switch clears
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
local Logger = require("infra.logger")
local LOG    = "i18n"

local locale_mod = require("infra.locale")
local Labels     = require("menu.labels")





-- =============================================
-- =============================================
-- ======= 1/ Constants and module state =======
-- =============================================
-- =============================================

--- Ordered list of supported locales, in the canonical language-menu order.
---
--- Generated, not written here: the order comes from
--- _shared/data/locale_order.json and the native names from
--- _shared/data/locale_names.json. Three hand-maintained copies is how the Linux
--- table came to hold 16 of the 21 shipped locales, its five missing rows
--- rendering in the menu as bare two-letter codes. Do not re-sort at runtime.
local LOCALES = require("_generated.locale_table")

--- hs.settings key used to persist the locale between reloads.
local SETTINGS_KEY = "i18n_locale"

--- Currently active locale code.
local _locale = "fr"

--- Pending reload timer — cancelled and replaced on every rapid locale switch
--- so only the last selection triggers a reload.
local _reload_timer = nil

--- Delay before reloading after a locale change (seconds).
local RELOAD_DEBOUNCE_SEC = 0.15





-- ===================================
-- ===================================
-- ======= 2/ Internal helpers =======
-- ===================================
-- ===================================

--- Returns true when code is a supported locale code.
local function is_known(code)
	for _, loc in ipairs(LOCALES) do
		if loc.code == code then return true end
	end
	return false
end

--- Pushes the active locale into infra/locale so get() resolves the right file.
--- infra/locale exposes no public setter for the locale code, so we access its
--- internals via a module-level upvalue injection pattern using an internal
--- function injected at require time.
local _locale_set_fn = nil  -- injected by init() below





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

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
	-- Patch infra/locale so it loads the right file
	if _locale_set_fn then _locale_set_fn(_locale) end
	Logger.done(LOG, "i18n initialised (locale: '%s').", _locale)
end

--- Returns the translated string for the given dot-notation key.
--- Delegates to infra/locale.get() which handles ★ substitution and caching.
--- Falls back to the raw key name when the string is absent.
--- @param key string Dot-notation key, e.g. ``"menu.global.reload"``.
--- @return string
function M.get(key)
	local s = locale_mod.get(key)
	if s == nil or s == "" then return key end
	return s
end

--- Returns the active locale code (e.g. ``"fr"``).

--- Returns a localised string with its {n} placeholders substituted.
---
--- The shared locale files use {1}, {2}, … — the AutoHotkey driver's logger
--- understands that syntax natively, macOS had no equivalent, and the two
--- onboarding call sites reached for string.format instead. string.format looks
--- for %s and leaves {1} untouched, so the privacy warning shown before enabling
--- the keylogger displayed a literal "{1}" where the metrics path belongs — on
--- the one screen where the user most needs to see where their data will go.
--- @param key string Locale key.
--- @param ... any Values substituted for {1}, {2}, … in order.
--- @return string The localised, substituted string.
function M.format(key, ...)
	local text = M.get(key)
	if type(text) ~= "string" then return text end
	local args = table.pack(...)
	for n = 1, args.n do
		local value = tostring(args[n])
		-- The replacement is outside-world data (a filesystem path), and a "%" in
		-- a gsub replacement raises. Escape it rather than trusting the input.
		value = value:gsub("%%", "%%%%")
		text = text:gsub("{" .. n .. "}", value)
	end
	return text
end

--- @return string
function M.get_locale()
	return _locale
end

--- Changes the active locale, persists it, and triggers a Hammerspoon reload
--- so all menus are rebuilt in the new language.
--- The reload is debounced: rapid successive calls cancel the pending reload
--- so only the last selected locale is applied, preventing stale reloads from
--- landing on an intermediate language when the user switches quickly.
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
	-- Cancel any pending reload from a previous rapid switch
	if _reload_timer then
		_reload_timer:stop()
		_reload_timer = nil
	end
	_reload_timer = hs.timer.doAfter(RELOAD_DEBOUNCE_SEC, function()
		_reload_timer = nil
		Logger.success(LOG, "Locale set to '%s' — reloading.", code)
		hs.reload()
	end)
end

--- Persists the locale to the settings store WITHOUT changing the in-memory
--- locale or scheduling a reload. The onboarding wizard needs this: it performs
--- its OWN single reload after writing config.toml, and set_locale()'s debounced
--- reload would race that. After the reload, M.init() reads this persisted value,
--- so the user's chosen language actually survives the wizard (set_locale_no_reload
--- only touches memory, which the reload discards).
--- @param code string A known locale code.
function M.persist_locale(code)
	if not is_known(code) then
		Logger.warn(LOG, "persist_locale: unknown locale '%s' — ignoring.", code)
		return
	end
	hs.settings.set(SETTINGS_KEY, code)
	Logger.debug(LOG, "Locale '%s' persisted to settings (no reload).", code)
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


--- Returns a shallow copy of LOCALES in canonical display order. LOCALES is
--- already declared in that order (single-sourced from
--- _shared/data/locale_order.json and pinned by the parity test), so this
--- simply hands back a copy — every surface that lists locales (menubar
--- language submenu, onboarding step 1, …) shares the one order and can
--- never desync. The canonical order keeps Latin-script names first and the
--- non-Latin scripts (Cyrillic, Hebrew, Arabic, Devanagari, CJK, Hangul) at
--- the tail, matching their natural UTF-8 byte order.
--- @return table[] List of ``{code, flag, name}`` tables.
function M.get_sorted_locales()
	local copy = {}
	for _, loc in ipairs(LOCALES) do copy[#copy + 1] = loc end
	return copy
end

--- Returns the locale rows for the language selector, as PROVIDER data.
---
--- `label` / `action`, not `title` / `fn`: these rows are the `locales` list the
--- shared renderer materialises, and it reads the provider field names. They were
--- built in the hs.menubar shape and translated one by one on the way into the
--- provider, which is a conversion layer that exists only because two halves of
--- one path disagreed about the spelling.
--- @return table[] List of provider rows.
function M.build_language_menu_items()
	local items = {}
	for _, loc in ipairs(M.get_sorted_locales()) do
		local code = loc.code
		items[#items + 1] = {
			label   = loc.flag .. " " .. loc.name,
			checked = (code == _locale),
			action  = function() M.set_locale(code) end,
		}
	end
	return items
end

--- Injects a locale setter into infra/locale so the active locale is applied
--- at module level. Called internally during init; exposed so init.lua can
--- wire the locale into infra/locale before any module calls locale.get().
--- @param fn function A function accepting a locale code string.
function M.set_locale_injector(fn)
	_locale_set_fn = fn
end

--- Returns the ordered list of supported locales (read-only view).
--- @return table[]
function M.locales()
	return LOCALES
end

--- Wraps already-translated text in the section-title dashes used for disabled
--- menu headers. THE single source of the "— … —" decoration on macOS — AHK's
--- MenuSectionTitle (infra/menu_helpers.ahk) mirrors it. Every menu builder must
--- route through this (or M.section) instead of inlining the dashes, so the
--- decoration can never silently drift between the ~10 macOS menu sites or the
--- two drivers. Guarded by test-section-decoration-parity.cjs.
--- @param text string Already-localized label.
--- @return string Formatted as "— text —".
function M.decorate_section(text)
	return Labels.decorate_section(text)
end

--- Wraps a translated string in section-title dashes for disabled menu headers.
--- Use instead of embedding — directly in locale values.
--- @param key string i18n key to translate.
--- @return string Formatted as "— Value —".
function M.section(key)
	return M.decorate_section(M.get(key))
end

return M
