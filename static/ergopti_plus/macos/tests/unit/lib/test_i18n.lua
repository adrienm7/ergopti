--- tests/unit/lib/test_i18n.lua

--- ==============================================================================
--- MODULE: i18n Unit Tests
--- DESCRIPTION:
--- Behavioral tests for infra/i18n.lua — the iOS UI locale manager. Covers
--- system-locale detection, persistence via hs.settings, locale switching
--- (with debounced reload), language-menu building, locale sorting, and
--- the get() → lib.locale delegation with key fallback.
---
--- Before this file, infra/i18n.lua had zero test coverage — every function
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
package.loaded["menu.labels"] = {
	decorate_section = function(text)
		_labels_called[#_labels_called + 1] = text
		return "— " .. text .. " —"
	end,
}

-- Stub lib.locale so get() returns controlled values.
local _locale_store = {}
package.loaded["infra.locale"] = {
	get = function(key) return _locale_store[key] end,
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
	package.loaded["infra.i18n"] = nil
	return require("infra.i18n")
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
end)











-- ==============================================
-- ==============================================
-- ======= 3/ Init (persistence + detect) =======
-- ==============================================
-- ==============================================


helpers.describe("i18n: init()", function()
	helpers.before_each(reset_state)

	helpers.it("reads persisted locale from hs.settings when valid", function()
		hs.settings.set("i18n_locale", "de")
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
		hs.settings.set("i18n_locale", "xx")  -- unknown code
		set_system_locale("en_GB")

		local i18n = load_i18n()
		i18n.set_locale_injector(function(_) end)
		i18n.init()

		helpers.assert_eq(i18n.get_locale(), "en",
			"invalid saved locale must fall back to system detection")
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
end)











-- =================================================
-- =================================================
-- ======= 5/ Locale switching & persistence =======
-- =================================================
-- =================================================


helpers.describe("i18n: set_locale / persist_locale / set_locale_no_reload", function()
	helpers.before_each(reset_state)

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
		helpers.assert_eq(hs.settings.get("i18n_locale"), "de",
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

	helpers.it("set_locale() ignores unknown codes", function()
		local i18n = load_i18n()
		i18n.set_locale_injector(function(_) end)
		i18n.set_locale("xx")

		helpers.assert_eq(i18n.get_locale(), "fr",
			"unknown locale must not change in-memory state")
		helpers.assert_nil(hs.settings.get("i18n_locale"),
			"unknown locale must not be persisted")
	end)

	helpers.it("set_locale() is a no-op when the same locale is already active", function()
		local i18n = load_i18n()
		i18n.set_locale_injector(function(_) end)
		i18n.set_locale("fr")  -- already the default

		helpers.assert_eq(i18n.get_locale(), "fr")
		helpers.assert_nil(hs.settings.get("i18n_locale"),
			"same locale must not re-persist")
	end)

	helpers.it("persist_locale() writes to settings without changing in-memory locale", function()
		local i18n = load_i18n()
		i18n.set_locale_injector(function(_) end)
		helpers.assert_eq(i18n.get_locale(), "fr")

		i18n.persist_locale("de")
		helpers.assert_eq(i18n.get_locale(), "fr",
			"persist_locale must NOT change in-memory locale")
		helpers.assert_eq(hs.settings.get("i18n_locale"), "de",
			"persist_locale must write to settings")
	end)

	helpers.it("persist_locale() ignores unknown codes", function()
		local i18n = load_i18n()
		i18n.set_locale_injector(function(_) end)
		i18n.persist_locale("xx")
		helpers.assert_nil(hs.settings.get("i18n_locale"),
			"unknown code must not be persisted")
	end)

	helpers.it("set_locale_no_reload() changes in-memory only", function()
		local i18n = load_i18n()
		local injected_code = nil
		i18n.set_locale_injector(function(code) injected_code = code end)

		i18n.set_locale_no_reload("de")
		helpers.assert_eq(i18n.get_locale(), "de",
			"in-memory locale must change")
		helpers.assert_nil(hs.settings.get("i18n_locale"),
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
package.loaded["menu.labels"] = nil
package.loaded["infra.locale"]  = nil
package.loaded["infra.i18n"]    = nil
