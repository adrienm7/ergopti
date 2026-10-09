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
local _scope_busy = false
local _scope_owner, _scope_generation, _scope_receipts = nil, 0, setmetatable({}, { __mode = "k" })

local hs     = hs
local Logger = require("infra.logger")
local Storage = require("adapters.storage")
local TimerScheduler = require("adapters.timer_scheduler")
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
local _reload_generation = 0

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
	if _scope_owner ~= nil or _scope_busy then return false end
	_scope_generation = _scope_generation + 1
	Logger.trace(LOG, "Initialising i18n…")
	local saved = Storage.get(SETTINGS_KEY)
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
	if _scope_owner ~= nil or _scope_busy then return false end
	_scope_generation = _scope_generation + 1
	if not is_known(code) then
		Logger.warn(LOG, "Unknown locale '%s' — ignoring.", code)
		return false
	end
	if code == _locale then return true end
	Logger.start(LOG, "Switching locale to '%s'…", code)
	-- Cancel any pending reload from a previous rapid switch
	if _reload_timer then
		if TimerScheduler.cancel(_reload_timer) ~= true then
			Logger.error(LOG, "Locale switch blocked by pending reload cleanup debt.")
			return false
		end
		_reload_timer = nil
	end

	_reload_generation = _reload_generation + 1
	local generation = _reload_generation
	local reload_timer
	local committed
	reload_timer, committed = TimerScheduler.after(RELOAD_DEBOUNCE_SEC, function()
		if generation ~= _reload_generation or _reload_timer ~= reload_timer then return end
		if reload_timer.timer == nil then _reload_timer = nil end
		Logger.success(LOG, "Locale set to '%s' — reloading.", code)
		Logger.pcall(LOG, hs.reload)
	end)
	if reload_timer and reload_timer.timer ~= nil then _reload_timer = reload_timer end
	if committed ~= true then
		if not reload_timer or reload_timer.timer == nil then _reload_timer = nil end
		Logger.error(LOG, "Locale switch reload timer was refused; locale remains unchanged.")
		return false
	end
	_reload_timer = reload_timer

	local persisted = Storage.set(SETTINGS_KEY, code)
	if persisted ~= true then
		_reload_generation = _reload_generation + 1
		TimerScheduler.cancel(reload_timer)
		Logger.error(LOG, "Locale persistence failed; locale remains unchanged.")
		return false
	end
	_locale = code
	return true
end

--- Persists the locale to the settings store WITHOUT changing the in-memory
--- locale or scheduling a reload. The onboarding wizard needs this: it performs
--- its OWN single reload after writing config.toml, and set_locale()'s debounced
--- reload would race that. After the reload, M.init() reads this persisted value,
--- so the user's chosen language actually survives the wizard (set_locale_no_reload
--- only touches memory, which the reload discards).
--- @param code string A known locale code.
--- @return boolean committed True only when settings accepted the exact locale.
function M.persist_locale(code)
	if _scope_owner ~= nil or _scope_busy then return false end
	_scope_generation = _scope_generation + 1
	if not is_known(code) then
		Logger.warn(LOG, "persist_locale: unknown locale '%s' — ignoring.", code)
		return false
	end
	local persisted = Storage.set(SETTINGS_KEY, code)
	if persisted ~= true then
		Logger.error(LOG, "Locale persistence without reload was refused; selection remains unsaved.")
		return false
	end
	Logger.debug(LOG, "Locale '%s' persisted to settings (no reload).", code)
	return true
end

--- Changes the active locale in memory only, without triggering a reload.
--- Used by the onboarding wizard so subsequent steps render in the new locale
--- without restarting the script mid-wizard.
--- @param code string A known locale code.
function M.set_locale_no_reload(code)
	if _scope_owner ~= nil or _scope_busy then return false end
	_scope_generation = _scope_generation + 1
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
	if _scope_owner ~= nil or _scope_busy then return false end
	_scope_generation = _scope_generation + 1
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

local function scope_known(value)
	return is_known(value)
end

local function scope_ready()
	if not rawequal(package.loaded["infra.locale"], locale_mod) then return false end
	if not (type(_locale_set_fn) == "function" and _reload_timer == nil) or not scope_known(_locale) or locale_mod.current_locale() ~= _locale then return false end
	local strings = locale_mod.all()
	return type(strings) == "table" and next(strings) ~= nil
end

--- Reads only the declared locale state this module owns; no persistence occurs here.
local function scope_state()
	return { module = package.loaded["infra.i18n"], locale = _locale, backend = locale_mod.current_locale(),
		setter = locale_mod.set_locale, getter = locale_mod.current_locale, loader = locale_mod.all, backend_parent = package.loaded["infra.locale"],
		core_parent = package.loaded["locale.core"], injector = _locale_set_fn, timer = _reload_timer, reload_generation = _reload_generation }
end

local function scope_equal(left, right)
	return rawequal(left.module, right.module) and left.locale == right.locale and left.backend == right.backend and left.setter == right.setter and left.getter == right.getter and left.loader == right.loader
		and rawequal(left.backend_parent, right.backend_parent) and rawequal(left.core_parent, right.core_parent) and left.injector == right.injector and left.timer == right.timer and left.reload_generation == right.reload_generation
end

--- Acquires the declared runtime field for one primary transaction token.
--- @param owner table Exact token; pending() describes primary compensation only.
--- @return boolean acquired
local function scope_acquire_impl(owner)
	if type(owner) ~= "table" or type(owner.pending) ~= "function" or _scope_owner ~= nil
		or not rawequal(package.loaded["infra.i18n"], M) then return false end
	if not scope_ready() or not rawequal(package.loaded["infra.i18n"], M) then return false end
	_scope_owner = owner
	return true
end

function M.scope_acquire(owner)
	if _scope_busy then return false end
	_scope_busy = true
	local called, acquired = pcall(scope_acquire_impl, owner)
	_scope_busy = false
	return called and acquired == true
end

--- Releases the admission gate while retaining opaque inverse receipts.
--- @param owner table Exact token.
--- @return boolean released
function M.scope_release(owner)
	if _scope_busy or not rawequal(_scope_owner, owner) or owner.pending() ~= false then return false end
	_scope_owner = nil
	return true
end

--- Captures an opaque, source-bound runtime inverse under the native claim.
--- @param owner table Exact token.
--- @return table|nil receipt
local function scope_capture_impl(owner)
	if not rawequal(_scope_owner, owner) or not rawequal(package.loaded["infra.i18n"], M) then return nil end
	local generation = _scope_generation
	local receipt, before = {}, scope_state()
	if not rawequal(_scope_owner, owner) or not rawequal(package.loaded["infra.i18n"], M) or _scope_generation ~= generation then return nil end
	_scope_receipts[receipt] = { owner = owner, before = before, expected = before, generation = _scope_generation }
	return receipt
end

function M.scope_capture(owner)
	if _scope_busy then return nil end
	_scope_busy = true
	local called, result = pcall(scope_capture_impl, owner)
	_scope_busy = false
	if not called then return nil end
	return result
end

--- Applies one canonical value after proving the captured runtime still owns it.
--- @param owner table Exact token.
--- @param receipt table Native opaque receipt.
--- @param value string Available canonical locale.
--- @return boolean applied
local function scope_apply_impl(owner, receipt, value)
	local data = _scope_receipts[receipt]
	if not rawequal(_scope_owner, owner) or not data or not rawequal(data.owner, owner) or data.forgotten or data.attempted
		or data.generation ~= _scope_generation or not scope_equal(scope_state(), data.expected)
		or not rawequal(package.loaded["infra.i18n"], M) then return false end
	if type(value) ~= "string" or not scope_known(value) then return false end
	local next_value = {}
	for key, child in pairs(data.before) do next_value[key] = child end
	next_value.locale, next_value.backend = value, value
	_scope_generation = _scope_generation + 1
	data.generation, data.expected, data.attempted = _scope_generation, next_value, true
	local called = pcall(function()
		if _locale_set_fn(next_value.locale) == false then error("native locale injector refused") end
		local strings = locale_mod.all()
		if type(strings) ~= "table" or next(strings) == nil then error("native locale strings are unavailable") end
		_locale = next_value.locale
	end)
	local observed = scope_state()
	return called and scope_equal(observed, next_value) and rawequal(_scope_owner, owner)
		and rawequal(package.loaded["infra.i18n"], M) and data.generation == _scope_generation
end

function M.scope_apply(owner, receipt, value)
	if _scope_busy then return false end
	_scope_busy = true
	local called, result = pcall(scope_apply_impl, owner, receipt, value)
	_scope_busy = false
	if not called then return false end
	return result
end

--- Restores only this receipt's acknowledged or interrupted scalar publication.
--- @param owner table Exact token.
--- @param receipt table Native opaque receipt.
--- @return boolean restored
local function scope_restore_impl(owner, receipt)
	local data = _scope_receipts[receipt]
	if not rawequal(_scope_owner, owner) or not data or not rawequal(data.owner, owner) or data.forgotten or data.generation ~= _scope_generation then return false end
	local current = scope_state()
	if not rawequal(current.module, M) or not rawequal(package.loaded["infra.i18n"], M) or not (rawequal(current.module, data.before.module) and current.setter == data.before.setter and current.getter == data.before.getter and current.loader == data.before.loader
		and rawequal(current.backend_parent, data.before.backend_parent) and rawequal(current.core_parent, data.before.core_parent) and current.injector == data.before.injector and current.timer == data.before.timer and current.reload_generation == data.before.reload_generation
		and (current.locale == data.before.locale or current.locale == data.expected.locale)
		and (current.backend == data.before.backend or current.backend == data.expected.backend)) then return false end
	if not data.attempted or data.restored then return scope_equal(current, data.before) end
	local called = pcall(function()
		if _locale_set_fn(data.before.locale) == false then error("native locale injector restore refused") end
		local strings = locale_mod.all()
		if type(strings) ~= "table" or next(strings) == nil then error("native locale strings are unavailable") end
		_locale = data.before.locale
	end)
	local observed = scope_state()
	if not called or not scope_equal(observed, data.before) or not rawequal(_scope_owner, owner)
		or not rawequal(package.loaded["infra.i18n"], M) or data.generation ~= _scope_generation then return false end
	_scope_generation = _scope_generation + 1
	data.generation, data.expected, data.restored = _scope_generation, data.before, true
	return true
end

function M.scope_restore(owner, receipt)
	if _scope_busy then return false end
	_scope_busy = true
	local called, result = pcall(scope_restore_impl, owner, receipt)
	_scope_busy = false
	if not called then return false end
	return result
end

--- Forgets only a finalized inverse, without changing live native state.
--- @param owner table Exact primary token.
--- @param receipt table Native opaque receipt.
--- @return boolean forgotten
function M.scope_forget(owner, receipt)
	local data = _scope_receipts[receipt]
	if _scope_busy or rawequal(_scope_owner, owner) or not data or not rawequal(data.owner, owner) or owner.pending() ~= false then return false end
	if data.forgotten then return true end
	data.before, data.expected, data.generation = nil, nil, nil
	data.forgotten = true
	return true
end

return M
