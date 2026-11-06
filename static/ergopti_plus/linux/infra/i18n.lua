--- infra/i18n.lua

--- ==============================================================================
--- MODULE: i18n — Internationalisation (Linux)
--- DESCRIPTION:
--- i18n wrapper over infra/locale with XDG-persistent locale storage. The macOS
--- i18n module handles hs.settings persistence and system-locale detection;
--- the Linux equivalent uses the storage adapter for persistence and defaults
--- to "fr" (matching the macOS default) when no preference is saved.
---
--- FEATURES & RATIONALE:
--- 1. Storage-backed: the active locale is saved to ~/.config/ergopti/
---    storage.json on every change and loaded on init.
--- 2. Locale discovery: list_locales() scans _shared/data/locales/ for
---    available .json files so the language menu is always up-to-date.
--- 3. Same surface as macOS: get(), get_locale(), set_locale().
--- 4. Trigger provider passthrough: delegates to locale.set_trigger_provider().
--- ==============================================================================

local M = {}
local _scope = require("scope_owner").new({ name = "infra.i18n", module = M })

local locale_mod = require("infra.locale")
local Logger     = require("logger.shim")
-- The shared section-header decoration, the same one macOS and AutoHotkey draw.
local Labels     = require("menu.labels")
local NativeDirectory = require("infra.native_directory")
local LOG        = "i18n"

local _locale    = "fr"   -- active locale code
local _storage   = nil    -- storage adapter (lazy-loaded)
local _available = {}     -- cached list of available locale codes
local _locale_busy, _locale_config_debt, _locale_storage_debt, _locale_backend_debt = false, nil, nil, nil
local _locale_backup_serial = 0


-- =========================================
-- =========================================
-- ======= 1/ Storage Helpers ==============
-- =========================================
-- =========================================

--- Loads the storage adapter once.
--- @return table|nil
local function _get_storage()
	if _storage then return _storage end
	local ok, mod = pcall(require, "adapters.storage")
	if ok then _storage = mod end
	return _storage
end

--- Loads the persisted locale preference, or returns the default.
--- @return string
local function _load_persisted_locale()
	local s = _get_storage()
	if not s then return "fr" end
	local saved = s.get("locale")
	if type(saved) == "string" and saved ~= "" then
		return saved
	end
	return "fr"
end

--- Persists the current locale so it survives restarts.
--- @param code string Locale code.
--- @return boolean True only after durable storage confirms the write.
local function _save_locale(code)
	local debt = _locale_storage_debt
	if not debt or debt.backup then return false end
	if type(debt.storage.path) ~= "function" then return false end
	local store_path = debt.storage.path()
	if type(store_path) ~= "string" or store_path == "" then return false end
	_locale_backup_serial = _locale_backup_serial + 1
	debt.backup = store_path .. ".locale-" .. tostring(os.time()) .. "-" .. tostring(_locale_backup_serial) .. ".settings"
	return debt.storage.publish_owned(debt.owner, debt.receipt,
		{ locale = { present = true, value = code } }, debt.backup, require("adapters.file_system")) == true
end

--- Settles retained native ownership without deleting the durable backup.
local function settle_locale_storage(keep)
	local debt = _locale_storage_debt
	if not debt then return true end
	if debt.keep == nil then debt.keep = keep == true end
	if not rawequal(package.loaded["adapters.storage"], debt.storage) then return false end
	if debt.receipt and not debt.keep and not debt.restored then
		if debt.storage.restore_owned(debt.owner, debt.receipt) ~= true then return false end
		debt.restored = true
	end
	if not debt.released then
		if debt.storage.release_owned(debt.owner) ~= true then return false end
		debt.released = true
	end
	if debt.receipt and not debt.forgotten then
		if debt.storage.forget_owned(debt.owner, debt.receipt) ~= true then return false end
		debt.forgotten = true
	end
	_locale_storage_debt = nil
	return true
end

local function settle_locale_config()
	if not _locale_config_debt then return true end
	if require("infra.script_scope").restore_configured_rewrite(_locale_config_debt) ~= true then return false end
	_locale_config_debt = nil
	return true
end

local function settle_locale_backend()
	local debt = _locale_backend_debt
	if not debt then return true end
	local current = locale_mod.current_locale()
	if current ~= debt.before then
		if current ~= debt.after then return false end
		local ok = pcall(locale_mod.set_locale, debt.before)
		if not ok or locale_mod.current_locale() ~= debt.before then return false end
	end
	_locale_backend_debt = nil
	return true
end

local function locale_transaction(action)
	if _locale_busy then return false end
	_locale_busy = true
	local ok, committed = xpcall(function()
		if not settle_locale_backend() or not settle_locale_storage(false) or not settle_locale_config() then return false end
		local storage = _get_storage()
		if not storage or type(storage.acquire_owned) ~= "function" then return false end
		local owner = {}
		if storage.acquire_owned(owner, { "locale" }) ~= true then return false end
		_locale_storage_debt = { owner = owner, storage = storage }
		local receipt = storage.capture_owned(owner)
		if not receipt then return false end
		_locale_storage_debt.receipt = receipt
		_locale_storage_debt.config_path = require("infra.config_paths").config("config.toml")
		if type(_locale_storage_debt.config_path) ~= "string" then return false end
		return action()
	end, debug.traceback)
	if not ok or committed ~= true then
		local backend_ok, storage_ok, config_ok = pcall(settle_locale_backend), pcall(settle_locale_storage, false), pcall(settle_locale_config)
		if not backend_ok or not storage_ok or not config_ok or _locale_backend_debt or _locale_storage_debt or _locale_config_debt then
			Logger.error(LOG, "Locale rollback remains pending; another change is blocked.")
		end
		_locale_busy = false
		return false
	end
	_locale_config_debt, _locale_backend_debt = nil, nil
	local cleaned, settled = pcall(settle_locale_storage, true)
	if not cleaned or settled ~= true then Logger.error(LOG, "Committed locale storage cleanup remains pending.") end
	_locale_busy = false
	return true
end


-- =========================================
-- =========================================
-- ======= 2/ Locale Discovery =============
-- =========================================
-- =========================================

--- Reads the canonical language order shared with the other drivers and the
--- site (_shared/data/locale_order.json) and returns a {code -> rank} map, or
--- nil if it can't be read/decoded — the caller then falls back to code order.
--- @param data_dir string Absolute path to the _shared/data directory.
--- @return table|nil Map of locale code to 1-based rank.
local function _load_order(data_dir)
	local ok_j, json_mod = pcall(require, "json")
	if not ok_j or type(json_mod) ~= "table" or type(json_mod.decode) ~= "function" then
		return nil
	end
	local f = io.open(data_dir .. "/locale_order.json", "r")
	if not f then return nil end
	local raw = f:read("*a")
	f:close()
	local ok, doc = pcall(json_mod.decode, raw)
	if not ok or type(doc) ~= "table" or type(doc.order) ~= "table" then return nil end
	local rank = {}
	for i, code in ipairs(doc.order) do rank[code] = i end
	return rank
end

--- Scans _shared/data/locales/ for available .json files and returns the
--- basename (without extension) as locale codes, in the canonical shared
--- display order (falling back to code order if the order file is unreadable).
--- @return table Array of locale code strings (e.g. {"en", "fr"}).
local function _scan_locales()
	local codes = {}

	local Paths = require("infra.paths")
	local locales_dir = Paths.shared("data/locales")
	assert(locales_dir, "i18n: shared locale directory is unavailable")
	-- Availability is established only by a complete native enumeration. Shell
	-- lines can invent names from legal LF bytes or publish failed partial output.
	local entries, err = NativeDirectory.entries(locales_dir)
	if not entries then
		local reason = string.format("Locale directory '%s' could not be enumerated: %s", locales_dir, tostring(err))
		Logger.error(LOG, "%s.", reason)
		error(reason, 0)
	end
	for _, entry in ipairs(entries) do
		local code = entry.name:match("^([%w_%-]+)%.json$")
		if code and not code:match("^_") and not code:match("^flags$") then
			local kind = entry.kind
			if kind == "link" then
				local path = NativeDirectory.join(locales_dir, entry.name)
				local detail, refusal
				kind, detail, refusal = NativeDirectory.target_kind(path)
				if kind == nil and refusal ~= "ENOENT" then
					local reason = string.format("Locale path '%s' could not be inspected: %s", path, tostring(detail))
					Logger.error(LOG, "%s.", reason)
					error(reason, 0)
				end
			end
			if kind == "file" then codes[#codes + 1] = code end
		end
	end
	assert(#codes > 0, "i18n: no locale files are available in " .. locales_dir)

	-- Order by the canonical shared list; codes absent from it fall to the end
	-- alphabetically, so a newly added locale still appears before it is listed.
	-- Same resolver: this line carried the same wrong depth, so the canonical
	-- display order never loaded either and the two surviving locales sorted
	-- alphabetically instead.
	local rank = _load_order(Paths.shared("data"))
	if rank then
		table.sort(codes, function(a, b)
			local ra, rb = rank[a] or math.huge, rank[b] or math.huge
			if ra ~= rb then return ra < rb end
			return a < b
		end)
	else
		table.sort(codes)
	end
	return codes
end


-- =========================================
-- =========================================
-- ======= 3/ Initialisation ===============
-- =========================================
-- =========================================

--- Initialises the i18n module: loads the persisted locale and applies it.
--- Must be called once at daemon startup. Idempotent.
function M.init()
	if _locale_busy or _locale_config_debt or _locale_storage_debt or _locale_backend_debt or not _scope.admit_change() then return false end
	if _available and #_available > 0 then
		-- Already initialised — skip.
		return
	end

	-- Discover available locales.
	_available = _scan_locales()
	Logger.info(LOG, "Available locales: %s.", table.concat(_available, ", "))

	-- Load and apply the persisted preference.
	local saved = _load_persisted_locale()
	local found = false
	for _, code in ipairs(_available) do
		if code == saved then found = true; break end
	end
	if found then
		_locale = saved
		locale_mod.set_locale(saved)
	else
		Logger.warn(LOG, "Persisted locale '%s' is unavailable — using 'fr'.", tostring(saved))
		_locale = "fr"
		locale_mod.set_locale("fr")
	end

	Logger.info(LOG, "i18n initialised (locale=%s, %d available).", _locale, #_available)
end


-- =========================================
-- =========================================
-- ======= 4/ Public API ===================
-- =========================================
-- =========================================

--- Returns the translated string for the given key.
--- @param key string Dot-notation key (e.g. "menu.global.reload").
--- @return string Translated string, or the raw key on miss.
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

--- Persists an explicit wizard selection before adopting its locale.
--- Unlike the ordinary menu setter, a same-locale choice needs a storage ACK.
--- @param code string Locale code (must be in _available).
--- @return boolean True only after storage confirms the explicit selection.
local function persist_locale_transaction(code)
	if not _scope.admit_change() then return false end
	if type(code) ~= "string" or code == "" then return false end

	-- Verify the locale is available.
	local found = false
	for _, c in ipairs(_available) do
		if c == code then found = true; break end
	end
	if not found then
		Logger.warn(LOG, "set_locale('%s'): locale not available — ignored.", code)
		return false
	end

	-- config.toml's [script] locale wins at start: rewrite it first.
	local scope = require("infra.script_scope")
	if require("infra.config_paths").config("config.toml") ~= _locale_storage_debt.config_path then return false end
	local rewritten, _, receipt = scope.rewrite_configured_owned(require("config_keys").KEY.SCRIPT_LOCALE, code)
	_locale_config_debt = receipt
	if rewritten ~= true or not _save_locale(code)
		or require("infra.config_paths").config("config.toml") ~= _locale_storage_debt.config_path
		or scope.verify_configured_rewrite(receipt) ~= true then
		Logger.error(LOG, "Locale '%s' was not persisted — nothing changed.", code)
		return false
	end
	_locale_backend_debt = { before = locale_mod.current_locale(), after = code }
	local applied, accepted = pcall(locale_mod.set_locale, code)
	if not applied or accepted == false or locale_mod.current_locale() ~= code then return false end
	_locale = code
	Logger.info(LOG, "Locale set to '%s' (persisted).", code)
	return true
end

function M.persist_locale(code)
	return locale_transaction(function() return persist_locale_transaction(code) end)
end

--- Switches to the given locale and persists a changed choice.
--- An unchanged menu selection preserves the legitimate absent-default no-op.
--- @param code string Locale code (must be in _available).
--- @return boolean True when the active locale needs no change or was persisted.
function M.set_locale(code)
	if _locale_busy or _locale_config_debt or _locale_storage_debt or _locale_backend_debt then
		return M.persist_locale(code)
	end
	if not _scope.admit_change() then return false end
	if code == _locale then return true end
	return M.persist_locale(code)
end

--- Returns the list of available locale codes for the language menu.
--- Lazily calls init() on first access so callers don't need to remember.
--- @return table Array of code strings (e.g. {"de", "en", "fr", "es"}).
function M.list_locales()
	if not _available or #_available == 0 then
		M.init()
	end
	return _available
end

--- Sets the trigger-character provider used for ★ substitution in locale strings.
--- Delegates to infra/locale.set_trigger_provider.
--- @param fn function Zero-argument function returning the trigger character string.
function M.set_trigger_provider(fn)
	locale_mod.set_trigger_provider(fn)
end

--- Returns a human-readable display name for a locale code.
--- @param code string Locale code (e.g. "en", "fr").
--- @return string Display name (e.g. "English", "Français").
function M.display_name(code)
	-- From the generated table rather than a map written out here. The
	-- hand-written one carried 16 of the 21 shipped locales, and the lookup ends
	-- in `or code` — so da, no, cs, he and hi rendered in the language menu as
	-- those bare two-letter codes, sitting between "Nederlands" and "Русский",
	-- while the other sixteen showed their native names. Nothing failed; five
	-- rows just looked like a bug nobody had filed.
	local ok, table_mod = pcall(require, "_generated.locale_table")
	if not ok or type(table_mod) ~= "table" then
		Logger.error(LOG, "display_name(): _generated/locale_table.lua is missing — "
			.. "language names fall back to raw codes. Run `npm run codegen:locale-tables`.")
		return code
	end
	for _, entry in ipairs(table_mod) do
		if entry.code == code then return entry.name end
	end
	return code
end

--- Passthrough for macOS API parity.
--- @param fn function|nil
function M.set_locale_injector(fn)
	if _locale_busy or _locale_config_debt or _locale_storage_debt or _locale_backend_debt or not _scope.admit_change() then return false end
	-- On Linux, persistence is handled by storage.lua (see _save_locale).
	-- Kept for API parity with macOS.
end




-- ===================================
-- ===== 9) Section Header Labels ====
-- ===================================

--- Wraps a section-header label in its "— … —" decoration.
---
--- The decoration itself is shared with macOS and AutoHotkey (menu/labels.lua),
--- for the reason that module's own header gives: three drivers drew the same
--- header three ways. This driver simply had no caller for it until the shared
--- menu renderer arrived, which resolves every `section_header` row through it.
--- @param text string
--- @return string
function M.decorate_section(text)
	return Labels.decorate_section(text)
end

--- Resolves a key and decorates it as a section header. The renderer's
--- `section_header` rows call exactly this, on every Lua driver.
--- @param key string
--- @return string
function M.section(key)
	return M.decorate_section(M.get(key))
end

local function scope_known(value)
	if type(value) ~= "string" then return false end
	for _, code in ipairs(_available or {}) do if code == value then return true end end
	return false
end

local function scope_ready()
	if _locale_busy or _locale_config_debt or _locale_storage_debt or _locale_backend_debt then return false end
	if not rawequal(package.loaded["infra.locale"], locale_mod) then return false end
	if not (type(_available) == "table" and #_available > 0) or not scope_known(_locale) or locale_mod.current_locale() ~= _locale then return false end
	local strings = locale_mod.all()
	return type(strings) == "table" and next(strings) ~= nil
end

--- Reads only the declared locale state this module owns; no persistence occurs here.
local function scope_state()
	return { locale = _locale, backend = locale_mod.current_locale(),
		setter = locale_mod.set_locale, getter = locale_mod.current_locale, loader = locale_mod.all, backend_parent = package.loaded["infra.locale"],
		core_parent = package.loaded["locale.core"] }
end

--- Publishes one locale through the translation backend, raising on refusal.
--- @param target table Declared locale fields to publish.
local function scope_publish(target)
	if locale_mod.set_locale(target.locale) == false then error("native translation backend refused") end
	local strings = locale_mod.all()
	if type(strings) ~= "table" or next(strings) == nil then error("native locale strings are unavailable") end
	_locale = target.locale
end

_scope.install({
	state = scope_state,
	identity = { "backend_parent", "core_parent" },
	stable = { "setter", "getter", "loader" },
	published = { "locale", "backend" },
	ready = scope_ready,
	accept = function(value)
		if type(value) ~= "string" or not scope_known(value) then return nil end
		return { locale = value, backend = value }
	end,
	publish = scope_publish,
})

return M
