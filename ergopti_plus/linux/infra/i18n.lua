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
--- 1. Storage-backed: the active locale is saved to ~/.config/ergopti_plus/
---    storage.json on every change and loaded on init.
--- 2. Locale discovery: list_locales() scans _shared/data/locales/ for
---    available .json files so the language menu is always up-to-date.
--- 3. Same surface as macOS: get(), get_locale(), set_locale().
--- 4. Trigger provider passthrough: delegates to locale.set_trigger_provider().
--- ==============================================================================

local M = {}
local _scope_busy = false
local _scope_owner, _scope_generation, _scope_receipts = nil, 0, setmetatable({}, { __mode = "k" })

local locale_mod = require("infra.locale")
local Logger     = require("logger.shim")
-- The shared section-header decoration, the same one macOS and AutoHotkey draw.
local Labels     = require("menu.labels")
local LOG        = "i18n"

local _locale    = "fr"   -- active locale code
local _storage   = nil    -- storage adapter (lazy-loaded)
local _available = {}     -- cached list of available locale codes


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
	local s = _get_storage()
	if not s or type(s.set) ~= "function" then return false end
	return s.set("locale", code) == true
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

	-- Through the shared resolver, not a per-file ".." count. This line used to
	-- walk "../../" from the driver root — one level too high — so `ls` found
	-- nothing, the scan collected zero codes, and the {"en","fr"} fallback below
	-- took over: the language menu offered 2 locales out of the 21 that ship.
	-- Nothing failed loudly; the menu simply had two rows.
	local Paths = require("infra.paths")
	local locales_dir = Paths.shared("data/locales")
	if not locales_dir then
		return { "en", "fr" }
	end

	local pipe = io.popen(string.format("ls '%s' 2>/dev/null", locales_dir:gsub("'", "'\\''")), "r")
	if not pipe then
		-- Fallback: try common codes.
		return { "en", "fr" }
	end

	for line in pipe:lines() do
		local code = line:match("^([%w_%-]+)%.json$")
		if code then
			-- Exclude non-language files (flags, readme, etc.)
			if not code:match("^_") and not code:match("^flags$") then
				codes[#codes + 1] = code
			end
		end
	end
	pipe:close()

	if #codes == 0 then codes = { "en", "fr" } end

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
	if _scope_owner ~= nil or _scope_busy then return false end
	_scope_generation = _scope_generation + 1
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
function M.persist_locale(code)
	if _scope_owner ~= nil or _scope_busy then return false end
	_scope_generation = _scope_generation + 1
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

	if not _save_locale(code) then
		Logger.error(LOG, "Locale '%s' was not persisted — nothing changed.", code)
		return false
	end
	_locale = code
	locale_mod.set_locale(code)
	Logger.info(LOG, "Locale set to '%s' (persisted).", code)
	return true
end

--- Switches to the given locale and persists a changed choice.
--- An unchanged menu selection preserves the legitimate absent-default no-op.
--- @param code string Locale code (must be in _available).
--- @return boolean True when the active locale needs no change or was persisted.
function M.set_locale(code)
	if _scope_owner ~= nil or _scope_busy then return false end
	_scope_generation = _scope_generation + 1
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
	if _scope_owner ~= nil or _scope_busy then return false end
	_scope_generation = _scope_generation + 1
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
	if not rawequal(package.loaded["infra.locale"], locale_mod) then return false end
	if not (type(_available) == "table" and #_available > 0) or not scope_known(_locale) or locale_mod.current_locale() ~= _locale then return false end
	local strings = locale_mod.all()
	return type(strings) == "table" and next(strings) ~= nil
end

--- Reads only the declared locale state this module owns; no persistence occurs here.
local function scope_state()
	return { module = package.loaded["infra.i18n"], locale = _locale, backend = locale_mod.current_locale(),
		setter = locale_mod.set_locale, getter = locale_mod.current_locale, loader = locale_mod.all, backend_parent = package.loaded["infra.locale"],
		core_parent = package.loaded["locale.core"] }
end

local function scope_equal(left, right)
	return rawequal(left.module, right.module) and left.locale == right.locale and left.backend == right.backend and left.setter == right.setter and left.getter == right.getter and left.loader == right.loader
		and rawequal(left.backend_parent, right.backend_parent) and rawequal(left.core_parent, right.core_parent)
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
		if locale_mod.set_locale(next_value.locale) == false then error("native translation backend refused") end
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
		and rawequal(current.backend_parent, data.before.backend_parent) and rawequal(current.core_parent, data.before.core_parent)
		and (current.locale == data.before.locale or current.locale == data.expected.locale)
		and (current.backend == data.before.backend or current.backend == data.expected.backend)) then return false end
	if not data.attempted or data.restored then return scope_equal(current, data.before) end
	local called = pcall(function()
		if locale_mod.set_locale(data.before.locale) == false then error("native translation backend restore refused") end
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
