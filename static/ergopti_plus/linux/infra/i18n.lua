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
local function _save_locale(code)
	local s = _get_storage()
	if s then s.set("locale", code) end
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
	if _available and #_available > 0 then
		-- Already initialised — skip.
		return
	end

	-- Discover available locales.
	_available = _scan_locales()
	Logger.info(LOG, "Available locales: %s.", table.concat(_available, ", "))

	-- Load and apply the persisted preference.
	local saved = _load_persisted_locale()
	M.set_locale(saved)

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

--- Switches to the given locale and persists the choice.
--- @param code string Locale code (must be in _available).
function M.set_locale(code)
	if type(code) ~= "string" or code == "" then return end
	if code == _locale then return end

	-- Verify the locale is available.
	local found = false
	for _, c in ipairs(_available) do
		if c == code then found = true; break end
	end
	if not found then
		Logger.warn(LOG, "set_locale('%s'): locale not available — ignored.", code)
		return
	end

	_locale = code
	locale_mod.set_locale(code)
	_save_locale(code)
	Logger.info(LOG, "Locale set to '%s' (persisted).", code)
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

return M
