--- tests/unit/core/i18n/test_i18n.lua

--- ==============================================================================
--- MODULE: i18n Unit Tests
--- DESCRIPTION:
--- Behavioral tests for core/i18n/engine/i18n.lua — the iOS UI locale manager. Covers
--- system-locale detection, persistence via hs.settings, locale switching
--- (with debounced reload), language-menu building, locale sorting, and
--- the get() → lib.locale delegation with key fallback.
---
--- Before this file, core/i18n/engine/i18n.lua had zero test coverage — every function
--- (detect_system_locale, init, set_locale, build_language_menu_items, etc.)
--- was exercised only by manual end-to-end interaction. This test locks the
--- contract: supported-locale detection, persistence ordering, debounce
--- semantics, and the fallback-on-missing-key guarantee.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Stub menu.labels before anything requires it — decorate_section is a pure wrapper.
-- This module-scope stub is cleared at the end of the file (see the teardown block)
-- so it does not leak into later test files that require the REAL menu.labels
-- (test_log_level_emojis.lua and ui/menu/builder.lua both call log_level_emoji).
local _labels_called = {}
package.loaded["menu.engine.labels"] = {
	decorate_section = function(text)
		_labels_called[#_labels_called + 1] = text
		return "— " .. text .. " —"
	end,
}

-- Stub lib.locale so get() returns controlled values.
local _locale_store = {}
-- missing() is the shared core's answer to a miss: the raw key. Its
-- once-per-key warning is tested against the real core below.
package.loaded["core.i18n.engine.locale"] = {
	get = function(key) return _locale_store[key] end,
	missing = function(key) return key end,
}

-- Stub lib.logger (silent no-op).
package.loaded["infra.logger"] = helpers.make_logger_stub()

-- Save original hs.host.locale so we can override it per test.
local _orig_host_locale = hs.host.locale

local function set_system_locale(val)
	hs.host.locale = {
		current = function() return val end,
	}
end

local function clear_system_locale()
	hs.host.locale = nil
end

--- Load a fresh i18n module (wipes upvalues _locale, _reload_timer, etc.).
local function load_i18n()
	package.loaded["core.i18n.engine.i18n"] = nil
	return require("core.i18n.engine.i18n")
end

-- Save the original hs.reload so we can restore it if a test overrides it.
local _orig_hs_reload = hs.reload

-- Reset shared state between tests.
local function reset_state()
	-- Clear hs.settings store.
	for k in pairs(hs.settings.__store) do hs.settings.__store[k] = nil end
	-- Clear lib.locale store.
	for k in pairs(_locale_store) do _locale_store[k] = nil end
	-- Clear labels call log (nil out entries — closure captures original table).
	for i = #_labels_called, 1, -1 do _labels_called[i] = nil end
	-- Clear stale timers.
	for i = #hs.timer.__timers, 1, -1 do hs.timer.__timers[i] = nil end
	-- Restore hs.host.locale and hs.reload.
	hs.host.locale = _orig_host_locale
	hs.reload = _orig_hs_reload
end

--- Runs a scenario while the native settings writer refuses or raises.
--- @param mode string false|throw
--- @param scenario function
local function with_settings_refusal(mode, scenario)
	local original = hs.settings.set
	hs.settings.set = function()
		if mode == "throw" then error("injected locale persistence failure") end
		return false
	end
	local ok, err = xpcall(scenario, debug.traceback)
	hs.settings.set = original
	if not ok then error(err, 0) end
end

--- Reloads i18n with a deterministic transactional timer adapter.
--- @param failure string|nil settled|debt for the next acquisition.
--- @return table i18n
--- @return table controller
local function load_i18n_with_scheduler(failure)
	local controller = { failure = failure, cancel_refusals = failure == "debt" and 1 or 0, calls = {} }
	local scheduler = {}
	function scheduler.after(delay, callback)
		local handle = { timer = {}, committed = false, fired = false }
		controller.calls[#controller.calls + 1] = { delay = delay, callback = callback, handle = handle }
		local mode = controller.failure
		controller.failure = nil
		if mode == "settled" then
			handle.timer = nil
			handle.fired = true
			return handle, false
		elseif mode == "debt" then
			return handle, false
		end
		handle.committed = true
		return handle, true
	end
	function scheduler.cancel(handle)
		if controller.cancel_refusals > 0 then
			controller.cancel_refusals = controller.cancel_refusals - 1
			return false
		end
		handle.timer = nil
		handle.committed = false
		handle.fired = true
		return true
	end
	package.loaded["core.events.timer_scheduler"] = scheduler
	return load_i18n(), controller
end











-- ==========================================
-- ==========================================
-- ======= 1/ Pure getters (no state) =======
-- ==========================================
-- ==========================================


helpers.describe("i18n: pure getters", function()
	helpers.before_each(reset_state)

	helpers.it("locales() returns 21 supported locales", function()
		local i18n = load_i18n()
		local locs = i18n.locales()
		helpers.assert_eq(#locs, 21, "must have 21 supported locales")
		for _, loc in ipairs(locs) do
			helpers.assert_true(type(loc.code) == "string" and #loc.code == 2,
				"each locale must have a 2-letter code, got: " .. tostring(loc.code))
			helpers.assert_true(type(loc.flag) == "string" and #loc.flag > 0,
				"each locale must have a non-empty flag emoji")
			helpers.assert_true(type(loc.name) == "string" and #loc.name > 0,
				"each locale must have a non-empty name")
		end
	end)

	helpers.it("get_sorted_locales() returns a copy ordered by localized name", function()
		local i18n = load_i18n()
		local sorted = i18n.get_sorted_locales()
		helpers.assert_eq(#sorted, 21, "must return 21 entries")
		-- get_sorted_locales() sorts by localized name (a.name:lower() < b.name:lower()),
		-- NOT by locale code. Assert that invariant directly so the test does not
		-- depend on which specific locale sorts first/last under byte-wise lowercasing.
		for i = 1, #sorted - 1 do
			helpers.assert_true(sorted[i].name:lower() <= sorted[i + 1].name:lower(),
				"locales must be ordered by lowercased name (violated at index " .. i .. ")")
		end
		-- Verify it is a copy: modifying sorted does not affect the original
		sorted[1] = nil
		helpers.assert_eq(#i18n.locales(), 21, "original LOCALES must be unaffected by mutation of sorted copy")
	end)

	-- The row shape moved from title/fn to label/action on 2026-08-07: these rows
	-- are the `locales` list provider's answer, and the shared renderer reads the
	-- PROVIDER field names. They used to be built in the hs.menubar shape and
	-- translated one by one on the way into the provider — a conversion layer that
	-- existed only because the two halves of one path disagreed on the spelling.
	helpers.it("build_language_menu_items() returns provider rows with label/checked/action", function()
		local i18n = load_i18n()
		-- Default locale is "fr" — items should mark French as checked.
		local items = i18n.build_language_menu_items()
		helpers.assert_eq(#items, 21, "must return 21 menu items")
		local checked_count = 0
		for _, item in ipairs(items) do
			helpers.assert_true(type(item.label) == "string", "each row must have a label string")
			helpers.assert_true(item.title == nil,
				"`title` is the hs.menubar field: a row carrying it is dropped by the renderer, so the "
				.. "language menu would come out empty")
			helpers.assert_true(type(item.checked) == "boolean", "each row must have a checked boolean")
			helpers.assert_true(type(item.action) == "function", "each row must have an action")
			if item.checked then checked_count = checked_count + 1 end
		end
		helpers.assert_eq(checked_count, 1, "exactly one locale must be checked")
	end)
end)











-- ==========================================
-- ==========================================
-- ======= 2/ System locale detection =======
-- ==========================================
-- ==========================================


helpers.describe("i18n: detect_system_locale()", function()
	helpers.before_each(reset_state)

	helpers.it("returns known 2-letter prefix from e.g. fr_FR", function()
		set_system_locale("fr_FR")
		local i18n = load_i18n()
		helpers.assert_eq(i18n.detect_system_locale(), "fr",
			"fr_FR must resolve to 'fr'")
	end)

	helpers.it("chooses Norwegian for the system's Bokmål locale on first launch", function()
		set_system_locale("nb_NO")
		local i18n = load_i18n()
		i18n.init()
		helpers.assert_eq(i18n.get_locale(), "no")
	end)

	helpers.it("uses the Norwegian catalogue for the Nynorsk system locale", function()
		set_system_locale("nn_NO")
		local i18n = load_i18n()
		helpers.assert_eq(i18n.detect_system_locale(), "no")
	end)

	helpers.it("returns known 2-letter prefix from en_GB", function()
		set_system_locale("en_GB")
		local i18n = load_i18n()
		helpers.assert_eq(i18n.detect_system_locale(), "en",
			"en_GB must resolve to 'en'")
	end)

	helpers.it("returns known 2-letter prefix from zh_Hans_CN", function()
		set_system_locale("zh_Hans_CN")
		local i18n = load_i18n()
		helpers.assert_eq(i18n.detect_system_locale(), "zh",
			"zh_Hans_CN must resolve to 'zh'")
	end)

	helpers.it("falls back to 'en' for unsupported locale", function()
		set_system_locale("xx_YY")
		local i18n = load_i18n()
		helpers.assert_eq(i18n.detect_system_locale(), "en",
			"unsupported locale must fall back to 'en'")
	end)

	helpers.it("falls back to 'en' when hs.host.locale API is unavailable", function()
		clear_system_locale()
		local i18n = load_i18n()
		helpers.assert_eq(i18n.detect_system_locale(), "en",
			"missing hs.host.locale API must fall back to 'en'")
	end)

	helpers.it("falls back to 'en' when hs.host.locale.current() returns nil", function()
		hs.host.locale = { current = function() return nil end }
		local i18n = load_i18n()
		helpers.assert_eq(i18n.detect_system_locale(), "en",
			"nil return from current() must fall back to 'en'")
	end)

	helpers.it("falls back to 'en' when hs.host.locale.current() throws", function()
		hs.host.locale = { current = function() error("boom") end }
		local i18n = load_i18n()
		helpers.assert_eq(i18n.detect_system_locale(), "en",
			"throwing current() must fall back to 'en'")
	end)

	helpers.it("takes its fallback from the shared identifiers (i18n-system-fallback)", function()
		local identifiers = require("core.text.engine.identifiers")
		local saved = identifiers.locales.system_fallback
		identifiers.locales.system_fallback = "de"
		local ok, detail = pcall(function()
			local i18n = load_i18n()
			set_system_locale("xx_YY")
			helpers.assert_eq(i18n.detect_system_locale(), "de")
			clear_system_locale()
			helpers.assert_eq(i18n.detect_system_locale(), "de")
		end)
		identifiers.locales.system_fallback = saved
		assert(ok, detail)
	end)
end)











-- ==============================================
-- ==============================================
-- ======= 3/ Init (persistence + detect) =======
-- ==============================================
-- ==============================================


helpers.describe("i18n: init()", function()
	helpers.before_each(reset_state)

	helpers.it("reads persisted locale from hs.settings when valid", function()
		hs.settings.set("ergopti.i18n_locale", "de")
		set_system_locale("fr_FR")  -- would resolve to fr, but saved=de wins

		local i18n = load_i18n()
		-- Must inject the setter so _locale_set_fn exists.
		i18n.set_locale_injector(function(_) end)
		i18n.init()

		helpers.assert_eq(i18n.get_locale(), "de",
			"persisted 'de' must win over detected 'fr'")
	end)

	helpers.it("falls back to detect_system_locale when no saved locale", function()
		set_system_locale("ja_JP")

		local i18n = load_i18n()
		i18n.set_locale_injector(function(_) end)
		i18n.init()

		helpers.assert_eq(i18n.get_locale(), "ja",
			"must detect system locale when nothing is persisted")
	end)

	helpers.it("falls back to detect_system_locale when saved value is invalid", function()
		hs.settings.set("ergopti.i18n_locale", "xx")  -- unknown code
		set_system_locale("en_GB")

		local i18n = load_i18n()
		i18n.set_locale_injector(function(_) end)
		i18n.init()

		helpers.assert_eq(i18n.get_locale(), "en",
			"invalid saved locale must fall back to system detection")
	end)

	helpers.it("warns about a saved locale without a catalogue (i18n-unknown-saved)", function()
		hs.settings.set("ergopti.i18n_locale", "xx")
		set_system_locale("de_DE")
		local logger = package.loaded["infra.logger"]
		local warn, warnings = logger.warn, {}
		logger.warn = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end
		local ok, detail = pcall(function()
			local i18n = load_i18n()
			i18n.set_locale_injector(function(_) end)
			i18n.init()
		end)
		logger.warn = warn
		assert(ok, detail)
		helpers.assert_eq(warnings, { "Persisted locale 'xx' is unavailable — using the system locale 'de'." })
	end)
end)











-- ===================================
-- ===================================
-- ======= 4/ get() delegation =======
-- ===================================
-- ===================================


helpers.describe("i18n: get()", function()
	helpers.before_each(reset_state)

	helpers.it("returns the translated string from lib.locale", function()
		_locale_store["menu.global.reload"] = "Recharger"
		local i18n = load_i18n()
		helpers.assert_eq(i18n.get("menu.global.reload"), "Recharger",
			"get() must delegate to lib.locale")
	end)

	helpers.it("falls back to the raw key when translation is missing", function()
		local i18n = load_i18n()
		helpers.assert_eq(i18n.get("__missing_key__"), "__missing_key__",
			"missing translation must return the key itself")
	end)

	helpers.it("falls back to the raw key when translation is empty string", function()
		_locale_store["empty.key"] = ""
		local i18n = load_i18n()
		helpers.assert_eq(i18n.get("empty.key"), "empty.key",
			"empty translation must return the key itself")
	end)

	helpers.it("warns once per raw key shown, never for a probe (i18n-miss-warned)", function()
		local stub_locale, stub_core = package.loaded["core.i18n.engine.locale"], package.loaded["core.i18n.engine.core"]
		local logger = package.loaded["infra.logger"]
		local warn, warnings = logger.warn, {}
		logger.warn = function(_, message, key) warnings[#warnings + 1] = message:gsub("%%s", key or "") end
		package.loaded["core.i18n.engine.locale"] = nil
		local ok, detail = pcall(function()
			local locale = require("core.i18n.engine.locale")
			helpers.assert_eq(locale.has("__missing_key__"), false)
			helpers.assert_eq(#warnings, 0, "a probe is not a defect")
			helpers.assert_eq(locale.missing("__missing_key__"), "__missing_key__")
			locale.missing("__missing_key__")
			locale.missing("__other_missing__")
		end)
		logger.warn = warn
		package.loaded["core.i18n.engine.locale"], package.loaded["core.i18n.engine.core"] = stub_locale, stub_core
		assert(ok, detail)
		helpers.assert_eq(#warnings, 2, "each missing key is warned once")
		helpers.assert_true(warnings[1]:find("'__missing_key__'", 1, true) ~= nil)
		helpers.assert_true(warnings[2]:find("'__other_missing__'", 1, true) ~= nil)
	end)
end)











-- =================================================
-- =================================================
-- ======= 5/ Locale switching & persistence =======
-- =================================================
-- =================================================


helpers.describe("i18n: set_locale / persist_locale / set_locale_no_reload", function()
	helpers.before_each(reset_state)

	helpers.it("restores configured locale bytes when native persistence refuses", function()
		local path = os.tmpname()
		local original = '[script]\nlocale = "fr" # preserve comment\n'
		local file = assert(io.open(path, "wb")); file:write(original); file:close()
		local Paths = require("infra.config_paths")
		local prior = Paths.get
		local prior_scheduler = package.loaded["core.events.timer_scheduler"]
		Paths.get = function(key) if key == "ConfigTomlPath" then return path end return prior(key) end
		local ok, err = xpcall(function()
			local i18n = load_i18n_with_scheduler()
			with_settings_refusal("false", function() helpers.assert_eq(i18n.set_locale("de"), false) end)
			local read = assert(io.open(path, "rb")); local actual = read:read("*a"); read:close()
			helpers.assert_eq(actual, original, "a refused locale must not survive in config.toml")
		end, debug.traceback)
		Paths.get = prior; package.loaded["core.events.timer_scheduler"] = prior_scheduler; os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("restores configured locale bytes when reload scheduling refuses", function()
		local path = os.tmpname()
		local original = '[script]\nlocale = "fr" # existing\n'
		local file = assert(io.open(path, "wb")); file:write(original); file:close()
		local Paths = require("infra.config_paths")
		local prior, prior_scheduler = Paths.get, package.loaded["core.events.timer_scheduler"]
		Paths.get = function(key) if key == "ConfigTomlPath" then return path end return prior(key) end
		local ok, err = xpcall(function()
			local i18n = load_i18n_with_scheduler("settled")
			helpers.assert_eq(i18n.set_locale("de"), false)
			local read = assert(io.open(path, "rb")); local actual = read:read("*a"); read:close()
			helpers.assert_eq(actual, original)
			helpers.assert_nil(hs.settings.get("ergopti.i18n_locale"))
		end, debug.traceback)
		Paths.get = prior; package.loaded["core.events.timer_scheduler"] = prior_scheduler; os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("retains exact locale rollback debt without overwriting a concurrent file edit", function()
		local path = os.tmpname()
		local original = '[script]\nlocale = "fr" # original\n'
		local concurrent = '[script]\nlocale = "ja" # concurrent\n'
		local function write(value) local f = assert(io.open(path, "wb")); f:write(value); f:close() end
		local function read() local f = assert(io.open(path, "rb")); local value = f:read("*a"); f:close(); return value end
		write(original)
		local Paths, prior_scheduler = require("infra.config_paths"), package.loaded["core.events.timer_scheduler"]
		local prior_get, prior_set = Paths.get, hs.settings.set
		Paths.get = function(key) if key == "ConfigTomlPath" then return path end return prior_get(key) end
		local published
		hs.settings.set = function() published = read(); write(concurrent); return false end
		local ok, err = xpcall(function()
			local i18n = load_i18n_with_scheduler()
			helpers.assert_eq(i18n.persist_locale("de"), false)
			helpers.assert_eq(read(), concurrent, "rollback must not overwrite another writer")
			hs.settings.set = prior_set
			helpers.assert_eq(i18n.persist_locale("en"), false, "unsettled inverse blocks a new change")
			helpers.assert_eq(read(), concurrent)
			write(published)
			helpers.assert_true(i18n.persist_locale("en"), "retry restores the exact predecessor before continuing")
			helpers.assert_contains(read(), 'locale = "en"')
		end, debug.traceback)
		Paths.get, hs.settings.set = prior_get, prior_set
		package.loaded["core.events.timer_scheduler"] = prior_scheduler; os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("refuses a locale whose config is replaced during a successful native write", function()
		local path = os.tmpname()
		local original, concurrent = '[script]\nlocale = "fr"\n', '[script]\nlocale = "ja"\n'
		local function write(value) local f = assert(io.open(path, "wb")); f:write(value); f:close() end
		local function read() local f = assert(io.open(path, "rb")); local value = f:read("*a"); f:close(); return value end
		write(original)
		local Paths, prior_scheduler = require("infra.config_paths"), package.loaded["core.events.timer_scheduler"]
		local prior_get, prior_set = Paths.get, hs.settings.set
		Paths.get = function(key) if key == "ConfigTomlPath" then return path end return prior_get(key) end
		prior_set("ergopti.i18n_locale", "fr")
		hs.settings.set = function(key, value)
			local result = prior_set(key, value)
			if value == "de" then write(concurrent) end
			return result
		end
		local ok, err = xpcall(function()
			local i18n = load_i18n_with_scheduler()
			helpers.assert_eq(i18n.persist_locale("de"), false)
			helpers.assert_eq(read(), concurrent)
			helpers.assert_eq(hs.settings.get("ergopti.i18n_locale"), "fr")
		end, debug.traceback)
		Paths.get, hs.settings.set = prior_get, prior_set
		package.loaded["core.events.timer_scheduler"] = prior_scheduler; os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("checks the config snapshot even when no locale rewrite was needed", function()
		local path = os.tmpname()
		local original, concurrent = '[script]\nshow_error_dialog = true\n', '[script]\nlocale = "ja"\n'
		local function write(value) local f = assert(io.open(path, "wb")); f:write(value); f:close() end
		local function read() local f = assert(io.open(path, "rb")); local value = f:read("*a"); f:close(); return value end
		write(original)
		local Paths, prior_scheduler = require("infra.config_paths"), package.loaded["core.events.timer_scheduler"]
		local prior_get, prior_set = Paths.get, hs.settings.set
		Paths.get = function(key) if key == "ConfigTomlPath" then return path end return prior_get(key) end
		prior_set("ergopti.i18n_locale", "fr")
		hs.settings.set = function(key, value)
			local result = prior_set(key, value)
			if value == "de" then write(concurrent) end
			return result
		end
		local ok, err = xpcall(function()
			local i18n = load_i18n_with_scheduler()
			helpers.assert_eq(i18n.persist_locale("de"), false)
			helpers.assert_eq(read(), concurrent)
			helpers.assert_eq(hs.settings.get("ergopti.i18n_locale"), "fr")
		end, debug.traceback)
		Paths.get, hs.settings.set = prior_get, prior_set
		package.loaded["core.events.timer_scheduler"] = prior_scheduler; os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("restores a native locale setter that mutates then refuses", function()
		local path = os.tmpname()
		local original = '[script]\nlocale = "fr"\n'
		local file = assert(io.open(path, "wb")); file:write(original); file:close()
		local Paths, prior_scheduler = require("infra.config_paths"), package.loaded["core.events.timer_scheduler"]
		local prior_get, prior_set = Paths.get, hs.settings.set
		Paths.get = function(key) if key == "ConfigTomlPath" then return path end return prior_get(key) end
		prior_set("ergopti.i18n_locale", "fr")
		hs.settings.set = function(key, value)
			prior_set(key, value)
			if value == "de" then return false end
			return true
		end
		local ok, err = xpcall(function()
			local i18n = load_i18n_with_scheduler()
			helpers.assert_eq(i18n.persist_locale("de"), false)
			helpers.assert_eq(hs.settings.get("ergopti.i18n_locale"), "fr")
			local read = assert(io.open(path, "rb")); local actual = read:read("*a"); read:close()
			helpers.assert_eq(actual, original)
		end, debug.traceback)
		Paths.get, hs.settings.set = prior_get, prior_set
		package.loaded["core.events.timer_scheduler"] = prior_scheduler; os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("does not overwrite a concurrent native locale on rollback", function()
		local prior_set = hs.settings.set
		local prior_scheduler = package.loaded["core.events.timer_scheduler"]
		prior_set("ergopti.i18n_locale", "fr")
		hs.settings.set = function(key, value)
			if value == "de" then prior_set(key, "ja"); return false end
			return prior_set(key, value)
		end
		local ok, err = xpcall(function()
			local i18n = load_i18n_with_scheduler()
			helpers.assert_eq(i18n.persist_locale("de"), false)
			helpers.assert_eq(hs.settings.get("ergopti.i18n_locale"), "ja")
			hs.settings.set = prior_set
			helpers.assert_eq(i18n.persist_locale("en"), false)
			helpers.assert_eq(hs.settings.get("ergopti.i18n_locale"), "ja")
			prior_set("ergopti.i18n_locale", "fr")
			helpers.assert_true(i18n.persist_locale("en"))
		end, debug.traceback)
		hs.settings.set = prior_set; package.loaded["core.events.timer_scheduler"] = prior_scheduler
		if not ok then error(err, 0) end
	end)

	helpers.it("fences reentrant locale mutations during native publication", function()
		local prior_set = hs.settings.set
		local prior_scheduler = package.loaded["core.events.timer_scheduler"]
		local i18n = load_i18n_with_scheduler()
		local nested, competing
		hs.settings.set = function(key, value)
			nested = i18n.set_locale_no_reload("ja")
			competing = require("core.fs.adapters.storage").set("i18n_locale", "ja")
			return prior_set(key, value)
		end
		local ok, err = xpcall(function()
			helpers.assert_true(i18n.persist_locale("de"))
			helpers.assert_eq(nested, false)
			helpers.assert_eq(competing, false, "the exact alias is held during publication")
			helpers.assert_eq(i18n.get_locale(), "fr")
			helpers.assert_eq(hs.settings.get("ergopti.i18n_locale"), "de")
		end, debug.traceback)
		hs.settings.set = prior_set; package.loaded["core.events.timer_scheduler"] = prior_scheduler
		if not ok then error(err, 0) end
	end)

	helpers.it("holds the real storage cohort and removes its exact backup after commit", function()
		local path = os.tmpname()
		local file = assert(io.open(path, "wb")); file:write('[script]\nlocale = "fr"\n'); file:close()
		local Paths, prior_scheduler = require("infra.config_paths"), package.loaded["core.events.timer_scheduler"]
		local prior_get, prior_set = Paths.get, hs.settings.set
		local directory, base = path:match("^(.*)/([^/]+)$")
		local function backups()
			local result = {}
			for name in require("lfs").dir(directory) do
				if name:sub(1, #base + 8) == base .. ".locale-" then result[#result + 1] = directory .. "/" .. name end
			end
			return result
		end
		Paths.get = function(key) if key == "ConfigTomlPath" then return path end return prior_get(key) end
		local blocked, captured
		hs.settings.set = function(key, value)
			local matches = backups()
			if key == "ergopti.i18n_locale" and value == "de" then
				captured = #matches
				blocked = require("core.fs.adapters.storage").set("i18n_locale", "ja")
			end
			return prior_set(key, value)
		end
		local ok, err = xpcall(function()
			local i18n = load_i18n_with_scheduler()
			helpers.assert_true(i18n.persist_locale("de"))
			helpers.assert_eq(captured, 1, "backup must exist before native publication")
			helpers.assert_eq(blocked, false, "cooperating same-alias mutation must be fenced")
			helpers.assert_eq(#backups(), 0, "the committed exact backup must be removed")
		end, debug.traceback)
		Paths.get, hs.settings.set = prior_get, prior_set
		package.loaded["core.events.timer_scheduler"] = prior_scheduler
		for _, backup in ipairs(backups()) do os.remove(backup) end
		os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("retains an acquired alias when capture and initial release both refuse", function()
		local Storage = require("core.fs.adapters.storage")
		local prior_capture, prior_release = Storage.capture_owned, Storage.release_owned
		local prior_scheduler = package.loaded["core.events.timer_scheduler"]
		local releases = 0
		Storage.capture_owned = function() return nil end
		Storage.release_owned = function(owner)
			releases = releases + 1
			if releases == 1 then return false end
			return prior_release(owner)
		end
		local ok, err = xpcall(function()
			local i18n = load_i18n_with_scheduler()
			helpers.assert_eq(i18n.persist_locale("de"), false)
			helpers.assert_eq(Storage.set("i18n_locale", "ja"), false, "failed release keeps the same alias gated")
			Storage.capture_owned = prior_capture
			helpers.assert_true(i18n.persist_locale("en"), "the next request retries the retained release")
		end, debug.traceback)
		Storage.capture_owned, Storage.release_owned = prior_capture, prior_release
		package.loaded["core.events.timer_scheduler"] = prior_scheduler
		if not ok then error(err, 0) end
	end)

	helpers.it("does not rewrite config while another owner holds the locale alias", function()
		local path = os.tmpname()
		local original = '[script]\nlocale = "fr"\n'
		local file = assert(io.open(path, "wb")); file:write(original); file:close()
		local Paths, Storage = require("infra.config_paths"), require("core.fs.adapters.storage")
		local prior_get, prior_scheduler = Paths.get, package.loaded["core.events.timer_scheduler"]
		Paths.get = function(key) if key == "ConfigTomlPath" then return path end return prior_get(key) end
		local foreign = {}
		helpers.assert_true(Storage.acquire_owned(foreign, { "i18n_locale" }))
		local ok, err = xpcall(function()
			local i18n = load_i18n_with_scheduler()
			helpers.assert_eq(i18n.persist_locale("de"), false)
			local read = assert(io.open(path, "rb")); local actual = read:read("*a"); read:close()
			helpers.assert_eq(actual, original)
			helpers.assert_true(Storage.release_owned(foreign))
			helpers.assert_true(i18n.persist_locale("de"))
		end, debug.traceback)
		pcall(Storage.release_owned, foreign)
		Paths.get = prior_get; package.loaded["core.events.timer_scheduler"] = prior_scheduler; os.remove(path)
		if not ok then error(err, 0) end
	end)

	for _, boundary in ipairs({ "release", "forget", "backup" }) do
	helpers.it("waits for retained locale " .. boundary .. " cleanup before reloading", function()
		local Storage = require("core.fs.adapters.storage")
		local Files = require("core.fs.adapters.file_system")
		local prior_release, prior_forget, prior_remove = Storage.release_owned, Storage.forget_owned, Files.remove_if_unchanged
		local prior_scheduler, prior_reload = package.loaded["core.events.timer_scheduler"], hs.reload
		local refusals, reloads = 2, 0
		Storage.release_owned = function(owner)
			if boundary == "release" and refusals > 0 then refusals = refusals - 1; return false end
			return prior_release(owner)
		end
		Storage.forget_owned = function(owner, receipt)
			if boundary == "forget" and refusals > 0 then refusals = refusals - 1; return false end
			return prior_forget(owner, receipt)
		end
		Files.remove_if_unchanged = function(...)
			if boundary == "backup" and refusals > 0 then refusals = refusals - 1; return false end
			return prior_remove(...)
		end
		hs.reload = function() reloads = reloads + 1 end
		local ok, err = xpcall(function()
			local i18n, scheduler = load_i18n_with_scheduler()
			helpers.assert_true(i18n.set_locale("de"))
			local first = scheduler.calls[1]
			first.handle.timer = nil; first.callback()
			helpers.assert_eq(reloads, 0, "a held storage owner must survive timer delivery")
			helpers.assert_eq(#scheduler.calls, 2, "cleanup refusal schedules another exact check")
			local second = scheduler.calls[2]
			second.handle.timer = nil; second.callback()
			helpers.assert_eq(reloads, 1, "reload starts only after cleanup settles")
		end, debug.traceback)
		Storage.release_owned, Storage.forget_owned, Files.remove_if_unchanged = prior_release, prior_forget, prior_remove
		hs.reload = prior_reload
		package.loaded["core.events.timer_scheduler"] = prior_scheduler
		if not ok then error(err, 0) end
	end)
	end

	helpers.it("defers timer delivery during locale publication", function()
		local prior_set, prior_reload = hs.settings.set, hs.reload
		local prior_scheduler = package.loaded["core.events.timer_scheduler"]
		local reloads, scheduler = 0, nil
		hs.reload = function() reloads = reloads + 1 end
		hs.settings.set = function(key, value)
			local result = prior_set(key, value)
			if key == "ergopti.i18n_locale" and value == "de" then
				local timer = scheduler.calls[1]
				timer.handle.timer = nil; timer.callback()
				helpers.assert_eq(reloads, 0, "publication must unwind before reload")
			end
			return result
		end
		local ok, err = xpcall(function()
			local i18n
			i18n, scheduler = load_i18n_with_scheduler()
			helpers.assert_true(i18n.set_locale("de"))
			helpers.assert_eq(#scheduler.calls, 2)
			local retry = scheduler.calls[2]
			retry.handle.timer = nil; retry.callback()
			helpers.assert_eq(reloads, 1)
		end, debug.traceback)
		hs.settings.set, hs.reload = prior_set, prior_reload
		package.loaded["core.events.timer_scheduler"] = prior_scheduler
		if not ok then error(err, 0) end
	end)

	helpers.it("keeps the owner when a cleanup retry timer cannot be armed", function()
		local Storage = require("core.fs.adapters.storage")
		local prior_release, prior_reload = Storage.release_owned, hs.reload
		local prior_scheduler = package.loaded["core.events.timer_scheduler"]
		local refusals, reloads = 2, 0
		Storage.release_owned = function(owner)
			if refusals > 0 then refusals = refusals - 1; return false end
			return prior_release(owner)
		end
		hs.reload = function() reloads = reloads + 1 end
		local ok, err = xpcall(function()
			local i18n, scheduler = load_i18n_with_scheduler()
			helpers.assert_true(i18n.set_locale("de"))
			scheduler.failure = "settled"
			local timer = scheduler.calls[1]
			timer.handle.timer = nil; timer.callback()
			helpers.assert_eq(reloads, 0)
			helpers.assert_eq(Storage.set("i18n_locale", "ja"), false, "the unresolved alias remains owned")
			helpers.assert_true(i18n.persist_locale("de"), "a later request retries exact cleanup")
		end, debug.traceback)
		Storage.release_owned, hs.reload = prior_release, prior_reload
		package.loaded["core.events.timer_scheduler"] = prior_scheduler
		if not ok then error(err, 0) end
	end)

	helpers.it("defers timer delivery during committed storage cleanup", function()
		local Storage = require("core.fs.adapters.storage")
		local prior_release, prior_reload = Storage.release_owned, hs.reload
		local prior_scheduler = package.loaded["core.events.timer_scheduler"]
		local reloads, scheduler, delivered = 0, nil, false
		hs.reload = function() reloads = reloads + 1 end
		Storage.release_owned = function(owner)
			if not delivered then
				delivered = true
				local timer = scheduler.calls[1]
				timer.handle.timer = nil; timer.callback()
				helpers.assert_eq(reloads, 0, "cleanup must unwind before reload")
			end
			return prior_release(owner)
		end
		local ok, err = xpcall(function()
			local i18n
			i18n, scheduler = load_i18n_with_scheduler()
			helpers.assert_true(i18n.set_locale("de"))
			helpers.assert_eq(#scheduler.calls, 2)
			local retry = scheduler.calls[2]
			retry.handle.timer = nil; retry.callback()
			helpers.assert_eq(reloads, 1)
		end, debug.traceback)
		Storage.release_owned, hs.reload = prior_release, prior_reload
		package.loaded["core.events.timer_scheduler"] = prior_scheduler
		if not ok then error(err, 0) end
	end)

	helpers.it("fences reentrant locale changes during the timer's cleanup retry", function()
		local Storage = require("core.fs.adapters.storage")
		local prior_release, prior_reload = Storage.release_owned, hs.reload
		local prior_scheduler = package.loaded["core.events.timer_scheduler"]
		local calls, nested, i18n = 0, nil, nil
		hs.reload = function() end
		Storage.release_owned = function(owner)
			calls = calls + 1
			if calls == 1 then return false end
			if calls == 2 then nested = i18n.persist_locale("en") end
			return prior_release(owner)
		end
		local ok, err = xpcall(function()
			local scheduler
			i18n, scheduler = load_i18n_with_scheduler()
			helpers.assert_true(i18n.set_locale("de"))
			local timer = scheduler.calls[1]
			timer.handle.timer = nil; timer.callback()
			helpers.assert_eq(nested, false, "a cleanup callback cannot publish another locale")
			helpers.assert_eq(hs.settings.get("ergopti.i18n_locale"), "de")
		end, debug.traceback)
		Storage.release_owned, hs.reload = prior_release, prior_reload
		package.loaded["core.events.timer_scheduler"] = prior_scheduler
		if not ok then error(err, 0) end
	end)

	helpers.it("does not reload or discard a successor started during timer cancellation", function()
		local prior_scheduler, prior_reload = package.loaded["core.events.timer_scheduler"], hs.reload
		local reloads, nested = 0, nil
		hs.reload = function() reloads = reloads + 1 end
		local ok, err = xpcall(function()
			local i18n, scheduler = load_i18n_with_scheduler()
			helpers.assert_true(i18n.set_locale("de"))
			local timer_port = package.loaded["core.events.timer_scheduler"]
			local cancel, entered = timer_port.cancel, false
			timer_port.cancel = function(handle)
				if not entered then
					entered = true
					nested = i18n.set_locale("en")
				end
				return cancel(handle)
			end
			local first = scheduler.calls[1]
			first.callback()
			helpers.assert_true(nested)
			helpers.assert_eq(reloads, 0, "retired timer cannot reload over its successor")
			helpers.assert_eq(#scheduler.calls, 2)
			local successor = scheduler.calls[2]
			successor.handle.timer = nil; successor.callback()
			helpers.assert_eq(reloads, 1, "successor retains its own reload")
		end, debug.traceback)
		hs.reload = prior_reload; package.loaded["core.events.timer_scheduler"] = prior_scheduler
		if not ok then error(err, 0) end
	end)

	helpers.it("does not replace a successor started while a cleanup retry is armed", function()
		local Storage = require("core.fs.adapters.storage")
		local prior_release, prior_reload = Storage.release_owned, hs.reload
		local prior_scheduler = package.loaded["core.events.timer_scheduler"]
		local refusals, reloads = 2, 0
		Storage.release_owned = function(owner)
			if refusals > 0 then refusals = refusals - 1; return false end
			return prior_release(owner)
		end
		hs.reload = function() reloads = reloads + 1 end
		local ok, err = xpcall(function()
			local i18n, scheduler = load_i18n_with_scheduler()
			helpers.assert_true(i18n.set_locale("de"))
			local timer_port = package.loaded["core.events.timer_scheduler"]
			local after, entered = timer_port.after, false
			timer_port.after = function(delay, callback)
				local handle, accepted = after(delay, callback)
				if not entered then entered = true; helpers.assert_true(i18n.set_locale("en")) end
				return handle, accepted
			end
			local first = scheduler.calls[1]
			first.handle.timer = nil; first.callback()
			helpers.assert_eq(#scheduler.calls, 3)
			scheduler.calls[2].callback()
			helpers.assert_eq(reloads, 0, "superseded retry must not reload")
			local successor = scheduler.calls[3]
			successor.handle.timer = nil; successor.callback()
			helpers.assert_eq(reloads, 1, "successor must retain its own timer")
		end, debug.traceback)
		Storage.release_owned, hs.reload = prior_release, prior_reload
		package.loaded["core.events.timer_scheduler"] = prior_scheduler
		if not ok then error(err, 0) end
	end)

	-- MCF-001 timer-race subtype: a refused later switch cancelled the reload an
	-- accepted earlier switch still owed, so the accepted locale never loaded.
	for _, refusal in ipairs({ "timer", "settings" }) do
		helpers.it("(locale-superseded-reload) a " .. refusal .. " refusal hands the accepted reload back", function()
			local path = os.tmpname()
			local file = assert(io.open(path, "wb")); file:write('[script]\nlocale = "fr"\n'); file:close()
			local Paths = require("infra.config_paths")
			local prior_get, prior_reload = Paths.get, hs.reload
			local prior_scheduler = package.loaded["core.events.timer_scheduler"]
			local reloads = {}
			Paths.get = function(key) if key == "ConfigTomlPath" then return path end return prior_get(key) end
			hs.reload = function() reloads[#reloads + 1] = hs.settings.get("ergopti.i18n_locale") end
			local ok, err = xpcall(function()
				local i18n, scheduler = load_i18n_with_scheduler()
				helpers.assert_true(i18n.set_locale("de"))
				local accepted = assert(io.open(path, "rb")); local accepted_bytes = accepted:read("*a"); accepted:close()
				if refusal == "timer" then
					scheduler.failure = "settled"
					helpers.assert_eq(i18n.set_locale("en"), false)
				else
					with_settings_refusal("false", function() helpers.assert_eq(i18n.set_locale("en"), false) end)
				end
				local read = assert(io.open(path, "rb")); local actual = read:read("*a"); read:close()
				helpers.assert_eq(actual, accepted_bytes, "the refused locale must not survive in config.toml")
				helpers.assert_eq(i18n.get_locale(), "de")
				helpers.assert_eq(hs.settings.get("ergopti.i18n_locale"), "de")
				for _, call in ipairs(scheduler.calls) do
					if call.handle.committed and call.handle.timer ~= nil then
						call.handle.timer = nil; call.callback()
					end
				end
				helpers.assert_eq(reloads, { "de" }, "the accepted switch keeps exactly its own reload")
			end, debug.traceback)
			Paths.get, hs.reload = prior_get, prior_reload
			package.loaded["core.events.timer_scheduler"] = prior_scheduler; os.remove(path)
			if not ok then error(err, 0) end
		end)
	end

	helpers.it("retains rollback debt when the publisher claims success without restoring bytes", function()
		local path = os.tmpname()
		local original = '[script]\nlocale = "fr"\n'
		local file = assert(io.open(path, "wb")); file:write(original); file:close()
		local Paths, Writer = require("infra.config_paths"), require("core.text.engine.toml_codec.writer")
		local prior_get, prior_publish = Paths.get, Writer.publish_if_unchanged
		local prior_scheduler = package.loaded["core.events.timer_scheduler"]
		Paths.get = function(key) if key == "ConfigTomlPath" then return path end return prior_get(key) end
		Writer.publish_if_unchanged = function() return true end
		local ok, err = xpcall(function()
			local i18n = load_i18n_with_scheduler()
			with_settings_refusal("false", function() helpers.assert_eq(i18n.persist_locale("de"), false) end)
			local read = assert(io.open(path, "rb")); local actual = read:read("*a"); read:close()
			helpers.assert_contains(actual, 'locale = "de"')
			helpers.assert_eq(i18n.persist_locale("en"), false, "unverified restoration blocks new writes")
			Writer.publish_if_unchanged = prior_publish
			helpers.assert_true(i18n.persist_locale("en"))
		end, debug.traceback)
		Paths.get, Writer.publish_if_unchanged = prior_get, prior_publish
		package.loaded["core.events.timer_scheduler"] = prior_scheduler; os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("refuses locale publication when config rewrite readback is unchanged", function()
		local path = os.tmpname()
		local original = '[script]\nlocale = "fr"\n'
		local file = assert(io.open(path, "wb")); file:write(original); file:close()
		local Paths, Writer = require("infra.config_paths"), require("core.text.engine.toml_codec.writer")
		local prior_get, prior_batch = Paths.get, Writer.batch_write
		local prior_scheduler = package.loaded["core.events.timer_scheduler"]
		Paths.get = function(key) if key == "ConfigTomlPath" then return path end return prior_get(key) end
		Writer.batch_write = function() return true, nil, '[script]\nlocale = "de"\n' end
		local ok, err = xpcall(function()
			local i18n = load_i18n_with_scheduler()
			helpers.assert_eq(i18n.persist_locale("de"), false)
			helpers.assert_nil(hs.settings.get("ergopti.i18n_locale"))
			local read = assert(io.open(path, "rb")); local actual = read:read("*a"); read:close()
			helpers.assert_eq(actual, original)
		end, debug.traceback)
		Paths.get, Writer.batch_write = prior_get, prior_batch
		package.loaded["core.events.timer_scheduler"] = prior_scheduler; os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("set_locale() persists to hs.settings and schedules a debounced reload", function()
		-- Start with fr (default).
		local i18n = load_i18n()
		i18n.set_locale_injector(function(_) end)
		helpers.assert_eq(i18n.get_locale(), "fr")

		-- Record hs.reload calls.
		local reload_count = 0
		hs.reload = function() reload_count = reload_count + 1 end

		i18n.set_locale("de")
		helpers.assert_eq(i18n.get_locale(), "de",
			"in-memory locale must change immediately")
		helpers.assert_eq(hs.settings.get("ergopti.i18n_locale"), "de",
			"settings must be persisted immediately")
		helpers.assert_eq(reload_count, 0,
			"reload must NOT fire before the debounce timer")

		-- Fire the debounce timer.
		for _, t in ipairs(hs.timer.__timers) do
			if t.running and type(t.fn) == "function" then t:fire() end
		end
		helpers.assert_eq(reload_count, 1,
			"reload must fire after the debounce delay")
	end)

	helpers.it("set_locale() debounces rapid switches: cancels pending timer", function()
		local i18n = load_i18n()
		i18n.set_locale_injector(function(_) end)

		local reload_count = 0
		hs.reload = function() reload_count = reload_count + 1 end

		-- Rapid switches: de -> en -> ja
		i18n.set_locale("de")
		helpers.assert_eq(i18n.get_locale(), "de")
		i18n.set_locale("en")
		helpers.assert_eq(i18n.get_locale(), "en")
		i18n.set_locale("ja")
		helpers.assert_eq(i18n.get_locale(), "ja")

		-- Only ONE timer should have been created (the last one).
		local running = 0
		for _, t in ipairs(hs.timer.__timers) do
			if t.running then running = running + 1 end
		end
		helpers.assert_eq(running, 1,
			"rapid switches must debounce to a single pending timer")

		-- Fire it — only one reload.
		for _, t in ipairs(hs.timer.__timers) do
			if t.running and type(t.fn) == "function" then t:fire() end
		end
		helpers.assert_eq(reload_count, 1,
			"only one reload after rapid locale switches")
	end)

	helpers.it("set_locale() leaves memory and settings unchanged when reload scheduling refuses", function()
		local i18n = load_i18n_with_scheduler("settled")
		helpers.assert_eq(i18n.set_locale("de"), false)
		helpers.assert_eq(i18n.get_locale(), "fr")
		helpers.assert_nil(hs.settings.get("ergopti.i18n_locale"))
	end)

	helpers.it("set_locale() rejects native persistence false and throw outcomes", function()
		for _, mode in ipairs({ "false", "throw" }) do
			local i18n = load_i18n_with_scheduler()
			with_settings_refusal(mode, function()
				helpers.assert_eq(i18n.set_locale("de"), false)
			end)
			helpers.assert_eq(i18n.get_locale(), "fr")
			helpers.assert_nil(hs.settings.get("ergopti.i18n_locale"))
			reset_state()
		end
	end)

	helpers.it("set_locale() blocks a sibling while exact timer cleanup is pending", function()
		local i18n, controller = load_i18n_with_scheduler("debt")
		helpers.assert_eq(i18n.set_locale("de"), false)
		helpers.assert_eq(i18n.set_locale("en"), false)
		helpers.assert_eq(#controller.calls, 1)
		helpers.assert_eq(i18n.get_locale(), "fr")
		helpers.assert_nil(hs.settings.get("ergopti.i18n_locale"))

		helpers.assert_true(i18n.set_locale("en"))
		helpers.assert_eq(#controller.calls, 2)
		helpers.assert_eq(i18n.get_locale(), "en")
		helpers.assert_eq(hs.settings.get("ergopti.i18n_locale"), "en")
	end)

	helpers.it("set_locale() ignores unknown codes", function()
		local i18n = load_i18n()
		i18n.set_locale_injector(function(_) end)
		i18n.set_locale("xx")

		helpers.assert_eq(i18n.get_locale(), "fr",
			"unknown locale must not change in-memory state")
		helpers.assert_nil(hs.settings.get("ergopti.i18n_locale"),
			"unknown locale must not be persisted")
	end)

	helpers.it("set_locale() is a no-op when the same locale is already active", function()
		local i18n = load_i18n()
		i18n.set_locale_injector(function(_) end)
		i18n.set_locale("fr")  -- already the default

		helpers.assert_eq(i18n.get_locale(), "fr")
		helpers.assert_nil(hs.settings.get("ergopti.i18n_locale"),
			"same locale must not re-persist")
	end)

	helpers.it("persist_locale() writes to settings without changing in-memory locale", function()
		local i18n = load_i18n()
		i18n.set_locale_injector(function(_) end)
		helpers.assert_eq(i18n.get_locale(), "fr")

		helpers.assert_true(i18n.persist_locale("de"))
		helpers.assert_eq(i18n.get_locale(), "fr",
			"persist_locale must NOT change in-memory locale")
		helpers.assert_eq(hs.settings.get("ergopti.i18n_locale"), "de",
			"persist_locale must write to settings")
	end)

	helpers.it("persist_locale() reports native false and throw outcomes", function()
		for _, mode in ipairs({ "false", "throw" }) do
			local i18n = load_i18n()
			with_settings_refusal(mode, function()
				helpers.assert_eq(i18n.persist_locale("de"), false)
			end)
			helpers.assert_eq(i18n.get_locale(), "fr",
				"persistence refusal must not mutate the active locale")
			helpers.assert_nil(hs.settings.get("ergopti.i18n_locale"))
			reset_state()
		end
	end)

	helpers.it("persist_locale() ignores unknown codes", function()
		local i18n = load_i18n()
		i18n.set_locale_injector(function(_) end)
		helpers.assert_eq(i18n.persist_locale("xx"), false)
		helpers.assert_nil(hs.settings.get("ergopti.i18n_locale"),
			"unknown code must not be persisted")
	end)

	helpers.it("set_locale_no_reload() changes in-memory only", function()
		local i18n = load_i18n()
		local injected_code = nil
		i18n.set_locale_injector(function(code) injected_code = code end)

		i18n.set_locale_no_reload("de")
		helpers.assert_eq(i18n.get_locale(), "de",
			"in-memory locale must change")
		helpers.assert_nil(hs.settings.get("ergopti.i18n_locale"),
			"settings must NOT be touched")
		helpers.assert_eq(injected_code, "de",
			"locale injector must be called with the new code")
	end)

	helpers.it("set_locale_no_reload() ignores unknown codes", function()
		local i18n = load_i18n()
		i18n.set_locale_injector(function(_) end)
		i18n.set_locale_no_reload("xx")

		helpers.assert_eq(i18n.get_locale(), "fr",
			"unknown code must not change locale")
	end)
end)











-- ==================================
-- ==================================
-- ======= 6/ Locale injector =======
-- ==================================
-- ==================================


helpers.describe("i18n: set_locale_injector()", function()
	helpers.before_each(reset_state)

	helpers.it("stores the function so init() can push the active locale into lib.locale", function()
		local i18n = load_i18n()
		local received = nil
		i18n.set_locale_injector(function(code) received = code end)
		-- init() calls the injector with the active locale.
		set_system_locale("en_GB")
		i18n.init()
		helpers.assert_eq(received, "en",
			"init() must call the injector with the active locale")
	end)
end)











-- =====================================
-- =====================================
-- ======= 7/ Section decoration =======
-- =====================================
-- =====================================


helpers.describe("i18n: decorate_section / section", function()
	helpers.before_each(reset_state)

	helpers.it("decorate_section() delegates to menu.labels.decorate_section", function()
		local i18n = load_i18n()
		for i = #_labels_called, 1, -1 do _labels_called[i] = nil end
		local result = i18n.decorate_section("My Section")
		helpers.assert_eq(result, "— My Section —",
			"must return the decorated text")
		helpers.assert_eq(#_labels_called, 1)
		helpers.assert_eq(_labels_called[1], "My Section")
	end)

	helpers.it("section() translates then decorates", function()
		_locale_store["menu.global.title"] = "Titre"
		local i18n = load_i18n()
		for i = #_labels_called, 1, -1 do _labels_called[i] = nil end
		local result = i18n.section("menu.global.title")
		helpers.assert_eq(result, "— Titre —",
			"must translate and decorate")
		helpers.assert_eq(_labels_called[1], "Titre")
	end)
end)


-- Teardown — the runner requires each test file once, in sequence, running its
-- cases inline (helpers.describe/it execute immediately). Clearing the stubs this
-- file installed forces the NEXT file to load the genuine modules: menu.labels
-- (needed real by test_log_level_emojis.lua and ui/menu/builder.lua) and the
-- stub-wired lib.i18n / lib.locale pair must not leak either.
package.loaded["menu.engine.labels"] = nil
package.loaded["core.i18n.engine.locale"]  = nil
package.loaded["core.i18n.engine.i18n"]    = nil
