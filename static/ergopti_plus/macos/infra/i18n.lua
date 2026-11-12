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
---    ``i18n_locale`` so it survives script reloads. A config.toml [script]
---    locale wins at start (infra.script_scope), so a change rewrites that row
---    first when the file holds one.
--- 3. Language selector: M.build_language_menu() returns a table of
---    hs.menubar or hs.menu items — one per supported locale — usable
---    directly inside builder.lua's global-actions section.
--- 4. Shared locale files: JSON files in static/locales/ are the single
---    source of truth shared with the AHK driver.
--- ==============================================================================

local M = {}
local _scope = require("scope_owner").new({ name = "infra.i18n", module = M })

local hs     = hs
local Logger = require("infra.logger")
local Storage = require("adapters.storage")
local TimerScheduler = require("adapters.timer_scheduler")
local _miss_warned = {}
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
local _locale_write_active = false
local _locale_rewrite_debt = nil
local _locale_storage_debt = nil
local _locale_storage_serial = 0

--- Pending reload timer — cancelled and replaced on every rapid locale switch
--- so only the last selection triggers a reload.
local _reload_timer = nil
local _reload_generation = 0
local _reload_deferred = nil

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
	-- Norwegian catalogues use "no", while the system identifies its two written forms.
	if lang == "nb" or lang == "nn" then lang = "no" end
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
	if _locale_write_active or _locale_rewrite_debt or _locale_storage_debt or not _scope.admit_change() then return false end
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
	if s ~= nil and s ~= "" then return s end
	-- A total miss (active locale, en and fr) shows the raw key: warned once
	-- per key, as on Windows, since every menu rebuild asks again.
	if not _miss_warned[key] then
		_miss_warned[key] = true
		Logger.warn(LOG, "No translation for '%s' in the active locale, en or fr — the raw key is displayed.",
			tostring(key))
	end
	return key
end

--- Whether a key has a translation, for a caller probing optional keys: unlike
--- get(), a miss decodes no fallback catalogue.
--- @param key string Dot-notation key.
--- @return boolean
function M.has(key)
	return locale_mod.has(key) == true
end

--- Returns the active locale code (e.g. ``"fr"``).

--- Returns a localised string with its {n} placeholders substituted.
---
--- The shared locale files use {1}, {2}, … — the AutoHotkey driver's logger
--- understands that syntax natively, macOS had no equivalent, and the two
--- onboarding call sites reached for string.format instead. string.format looks
--- for %s and leaves {1} untouched, so the privacy warning shown before enabling
--- the keystats displayed a literal "{1}" where the metrics path belongs — on
--- the one screen where the user most needs to see where their data will go.
--- @param key string Locale key.
--- @param ... any Values substituted for {1}, {2}, … in order.
--- @return string The localised, substituted string.
function M.format(key, ...)
	local text = M.get(key)
	if type(text) ~= "string" then return text end
	local args = table.pack(...)
	-- Substitution values are data, not templates: formatting a later argument
	-- must never rewrite a placeholder that appeared inside an earlier value.
	return (text:gsub("{([1-9]%d*)}", function(index)
		local position = tonumber(index)
		if position and position <= args.n then return tostring(args[position]) end
		return nil
	end))
end

--- @return string
function M.get_locale()
	return _locale
end

--- Rewrites config.toml's [script] locale when the file holds one: that row
--- wins at start, so leaving it would undo this change on the next reload.
--- @param code string Locale about to be saved.
--- @return boolean committed
local function rewrite_configured(code)
	local committed, detail, receipt = require("infra.script_scope").rewrite_configured_owned(
		require("config_keys").KEY.SCRIPT_LOCALE, code)
	_locale_rewrite_debt = receipt
	if committed ~= true then
		Logger.error(LOG, "Configured locale rewrite was refused: %s.", tostring(detail))
		return false
	end
	return true
end

--- Keeps the exact config inverse until restoration is confirmed by readback.
local function settle_locale_rewrite()
	if _locale_rewrite_debt == nil then return true end
	local ok, restored = pcall(require("infra.script_scope").restore_configured_rewrite, _locale_rewrite_debt)
	if not ok or restored ~= true then
		Logger.error(LOG, "Locale config rollback remains pending; another locale change is blocked.")
		return false
	end
	_locale_rewrite_debt = nil
	return true
end

--- Finishes the exact native cohort and conditionally removes its backup.
local function settle_locale_storage_inner(keep)
	local debt = _locale_storage_debt
	if debt == nil then return true end
	if debt.keep == nil then debt.keep = keep == true end
	if not rawequal(package.loaded["adapters.storage"], Storage) then return false end
	if debt.receipt and not debt.keep and not debt.restored then
		if Storage.restore_owned(debt.owner, debt.receipt) ~= true then return false end
		debt.restored = true
	end
	if not debt.released then
		if Storage.release_owned(debt.owner) ~= true then return false end
		debt.released = true
	end
	if debt.receipt and not debt.forgotten then
		if Storage.forget_owned(debt.owner, debt.receipt) ~= true then return false end
		debt.forgotten = true
	end
	if debt.backup_cleanup then
		if debt.backup_cleanup() ~= true then return false end
		debt.backup_cleanup = nil
	end
	if debt.backup_path then
		local content, status = debt.files.read_with_status(debt.backup_path)
		if status == "ok" then
			if content ~= debt.backup_bytes then return false end
			local removed, _, _, retry = debt.files.remove_if_unchanged(debt.backup_path,
				{ status = "ok", content = debt.backup_bytes })
			if removed ~= true then
				if type(retry) == "function" then debt.backup_cleanup = retry end
				return false
			end
		elseif status ~= "absent" then return false end
	end
	_locale_storage_debt = nil
	return true
end

local function settle_locale_storage(keep)
	local ok, settled = pcall(settle_locale_storage_inner, keep)
	return ok and settled == true
end

local function persist_selected_locale(code)
	local debt = _locale_storage_debt
	if not debt or debt.backup_path then return false end
	local path = require("infra.config_paths").get("ConfigTomlPath")
	if type(path) ~= "string" or path == "" then return false end
	_locale_storage_serial = _locale_storage_serial + 1
	debt.backup_path = path .. ".locale-" .. tostring(hs.timer.absoluteTime()) .. "-"
		.. tostring(_locale_storage_serial) .. ".settings"
	debt.files = require("adapters.file_system")
	debt.backup_bytes = require("json").encode({ format = "ergopti-owned-settings-v1", cells = debt.cells })
	if type(debt.backup_bytes) ~= "string" then return false end
	return Storage.publish_owned(debt.owner, debt.receipt,
		{ [SETTINGS_KEY] = { present = true, value = code } }, debt.backup_path, debt.files) == true
end

local function verify_configured_locale()
	local ok, verified = pcall(require("infra.script_scope").verify_configured_rewrite, _locale_rewrite_debt)
	return ok and verified == true
end

--- Arms one reload attempt. A delivered timer never reloads across an owned
--- locale write or retained storage cleanup; it retries after that work settles.
local function arm_locale_reload(generation, code)
	local handle
	local committed
	local predecessor = _reload_timer
	handle, committed = TimerScheduler.after(RELOAD_DEBOUNCE_SEC, function()
		if generation ~= _reload_generation or _reload_timer ~= handle then return end
		if _locale_write_active then
			_reload_deferred = { handle = handle, generation = generation, code = code }
			return
		end
		_locale_write_active = true
		local ready = settle_locale_storage(true) and _locale_rewrite_debt == nil
		_locale_write_active = false
		if handle.timer ~= nil and TimerScheduler.cancel(handle) ~= true then
			Logger.error(LOG, "Locale reload is blocked by retained timer cleanup.")
			return
		end
		if generation ~= _reload_generation or _reload_timer ~= handle then return end
		_reload_timer = nil
		if not ready then
			if not arm_locale_reload(generation, code) then
				Logger.error(LOG, "Locale reload retry could not be scheduled; cleanup remains pending.")
			end
			return
		end
		Logger.success(LOG, "Locale set to '%s' — reloading.", code)
		Logger.pcall(LOG, hs.reload)
	end)
	if generation ~= _reload_generation or _reload_timer ~= predecessor then
		if handle and handle.timer ~= nil and TimerScheduler.cancel(handle) ~= true then
			Logger.error(LOG, "Superseded locale reload timer retains native cleanup debt.")
		end
		return false
	end
	if handle and handle.timer ~= nil then _reload_timer = handle end
	if committed ~= true then
		if not handle or handle.timer == nil then _reload_timer = nil end
		return false
	end
	_reload_timer = handle
	return true
end

local function resume_deferred_reload()
	local pending = _reload_deferred
	_reload_deferred = nil
	if not pending or pending.generation ~= _reload_generation or _reload_timer ~= pending.handle then return end
	if pending.handle.timer ~= nil and TimerScheduler.cancel(pending.handle) ~= true then
		Logger.error(LOG, "Locale reload is blocked by retained timer cleanup.")
		return
	end
	if pending.generation ~= _reload_generation or _reload_timer ~= pending.handle then return end
	_reload_timer = nil
	if not arm_locale_reload(pending.generation, pending.code) then
		Logger.error(LOG, "Deferred locale reload could not be scheduled.")
	end
end

local function locale_transaction(action)
	if _locale_write_active then return false end
	_locale_write_active = true
	local ok, result = xpcall(function()
		if not settle_locale_storage(false) or not settle_locale_rewrite() then return false end
		local owner = {}
		if Storage.acquire_owned(owner, { SETTINGS_KEY }) ~= true then return false end
		_locale_storage_debt = { owner = owner }
		local receipt, cells = Storage.capture_owned(owner)
		if receipt == nil then return false end
		_locale_storage_debt.receipt, _locale_storage_debt.cells = receipt, cells
		return action()
	end, debug.traceback)
	if not ok or result ~= true then
		local storage_restored = settle_locale_storage(false)
		settle_locale_rewrite()
		if not storage_restored then Logger.error(LOG, "Locale settings rollback remains pending.") end
		if not ok then Logger.error(LOG, "Locale change raised; its config rollback was attempted.") end
		_locale_write_active = false
		resume_deferred_reload()
		return false
	end
	_locale_rewrite_debt = nil
	if not settle_locale_storage(true) then
		Logger.error(LOG, "Committed locale settings cleanup remains pending.")
	end
	_locale_write_active = false
	resume_deferred_reload()
	return true
end

--- Changes the active locale, persists it, and triggers a Hammerspoon reload
--- so all menus are rebuilt in the new language.
--- The reload is debounced: rapid successive calls cancel the pending reload
--- so only the last selected locale is applied, preventing stale reloads from
--- landing on an intermediate language when the user switches quickly.
--- Re-arms the reload an accepted earlier switch still owed after a refused
--- later switch cancelled it: refusing the later locale must not also drop the
--- reload that applies the accepted one.
--- @return boolean rearmed
local function restore_superseded_reload()
	if _reload_timer ~= nil then
		Logger.error(LOG, "The accepted locale reload waits behind retained timer cleanup.")
		return false
	end
	_reload_generation = _reload_generation + 1
	if not arm_locale_reload(_reload_generation, _locale) then
		Logger.error(LOG, "The accepted locale reload could not be rescheduled.")
		return false
	end
	return true
end

--- @param code string A known locale code.
local function set_locale_transaction(code)
	if not _scope.admit_change() then return false end
	if not is_known(code) then
		Logger.warn(LOG, "Unknown locale '%s' — ignoring.", code)
		return false
	end
	if code == _locale then return true end
	if not rewrite_configured(code) then return false end
	Logger.start(LOG, "Switching locale to '%s'…", code)
	-- Cancel any pending reload from a previous rapid switch. A committed one
	-- belongs to an accepted switch, so a refusal below hands it back.
	local superseded = false
	if _reload_timer then
		superseded = _reload_timer.committed == true
		if TimerScheduler.cancel(_reload_timer) ~= true then
			Logger.error(LOG, "Locale switch blocked by pending reload cleanup debt.")
			return false
		end
		_reload_timer = nil
	end

	local function refuse(message)
		Logger.error(LOG, message)
		if superseded then restore_superseded_reload() end
		return false
	end

	_reload_generation = _reload_generation + 1
	local generation = _reload_generation
	if not arm_locale_reload(generation, code) then
		return refuse("Locale switch reload timer was refused; locale remains unchanged.")
	end
	local reload_timer = _reload_timer

	local function retire_reload()
		_reload_generation = _reload_generation + 1
		if TimerScheduler.cancel(reload_timer) == true and _reload_timer == reload_timer then
			_reload_timer = nil
		end
	end

	local persisted = persist_selected_locale(code)
	if persisted ~= true then
		retire_reload()
		return refuse("Locale persistence failed; locale remains unchanged.")
	end
	if not verify_configured_locale() then
		retire_reload()
		return refuse("Configured locale changed before publication; locale remains unchanged.")
	end
	_locale = code
	return true
end

function M.set_locale(code)
	return locale_transaction(function() return set_locale_transaction(code) end)
end

--- Persists the locale to the settings store WITHOUT changing the in-memory
--- locale or scheduling a reload. The onboarding wizard needs this: it performs
--- its OWN single reload after writing config.toml, and set_locale()'s debounced
--- reload would race that. After the reload, M.init() reads this persisted value,
--- so the user's chosen language actually survives the wizard (set_locale_no_reload
--- only touches memory, which the reload discards).
--- @param code string A known locale code.
--- @return boolean committed True only when settings accepted the exact locale.
local function persist_locale_transaction(code)
	if not _scope.admit_change() then return false end
	if not is_known(code) then
		Logger.warn(LOG, "persist_locale: unknown locale '%s' — ignoring.", code)
		return false
	end
	if not rewrite_configured(code) then return false end
	local persisted = persist_selected_locale(code)
	if persisted ~= true then
		Logger.error(LOG, "Locale persistence without reload was refused; selection remains unsaved.")
		return false
	end
	if not verify_configured_locale() then
		Logger.error(LOG, "Configured locale changed before publication; selection was refused.")
		return false
	end
	Logger.debug(LOG, "Locale '%s' persisted to settings (no reload).", code)
	return true
end

function M.persist_locale(code)
	return locale_transaction(function() return persist_locale_transaction(code) end)
end

--- Adopts the saved locale when it changed after init(), without a reload.
--- config_overrides writes a config.toml [script] locale into the saved
--- setting once the config path is known, which is after init() ran; the
--- configured locale wins at start, so the menu must be built in it.
--- @return boolean adopted True when the active locale changed.
function M.adopt_saved_locale()
	if _locale_write_active or _locale_rewrite_debt or _locale_storage_debt or not _scope.admit_change() then return false end
	local saved = Storage.get(SETTINGS_KEY)
	if type(saved) ~= "string" or not is_known(saved) or saved == _locale then return false end
	_locale = saved
	if _locale_set_fn then _locale_set_fn(saved) end
	Logger.info(LOG, "Locale '%s' from config.toml wins at start.", saved)
	return true
end

--- Changes the active locale in memory only, without triggering a reload.
--- Used by the onboarding wizard so subsequent steps render in the new locale
--- without restarting the script mid-wizard.
--- @param code string A known locale code.
function M.set_locale_no_reload(code)
	if _locale_write_active or _locale_rewrite_debt or _locale_storage_debt or not _scope.admit_change() then return false end
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
	if _locale_write_active or _locale_rewrite_debt or _locale_storage_debt or not _scope.admit_change() then return false end
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
	if _locale_write_active or _locale_rewrite_debt or _locale_storage_debt then return false end
	if not rawequal(package.loaded["infra.locale"], locale_mod) then return false end
	if not (type(_locale_set_fn) == "function" and _reload_timer == nil) or not scope_known(_locale) or locale_mod.current_locale() ~= _locale then return false end
	local strings = locale_mod.all()
	return type(strings) == "table" and next(strings) ~= nil
end

--- Reads only the declared locale state this module owns; no persistence occurs here.
local function scope_state()
	return { locale = _locale, backend = locale_mod.current_locale(),
		setter = locale_mod.set_locale, getter = locale_mod.current_locale, loader = locale_mod.all, backend_parent = package.loaded["infra.locale"],
		core_parent = package.loaded["locale.core"], injector = _locale_set_fn, timer = _reload_timer, reload_generation = _reload_generation }
end

--- Publishes one locale through the injected backend setter, raising on refusal.
--- @param target table Declared locale fields to publish.
local function scope_publish(target)
	if _locale_set_fn(target.locale) == false then error("native locale injector refused") end
	local strings = locale_mod.all()
	if type(strings) ~= "table" or next(strings) == nil then error("native locale strings are unavailable") end
	_locale = target.locale
end

_scope.install({
	state = scope_state,
	identity = { "backend_parent", "core_parent" },
	stable = { "setter", "getter", "loader", "injector", "timer", "reload_generation" },
	published = { "locale", "backend" },
	ready = scope_ready,
	accept = function(value)
		if type(value) ~= "string" or not scope_known(value) then return nil end
		return { locale = value, backend = value }
	end,
	publish = scope_publish,
})

return M
