--- tests/unit/ui/test_webview_pages_carry_their_strings.lua

--- ==============================================================================
--- MODULE: Every Shared Page Carries Its Strings
--- DESCRIPTION:
--- What a macOS webview page receives as text, and when.
---
--- THE DEFECT THIS PINS:
--- An inline page cannot fetch its file:// locale, so the host injected the
--- active locale (all()) once the page had loaded. The diagnostics page and the
--- error window then raced their own failed fetch, which replaced the injected
--- strings with nothing: every dynamic label showed its raw key. all() also
--- held the active locale alone, so any key that locale lacked would show raw
--- even without the race, with no English to fall back on.
---
--- The page now carries the whole catalogue in its boot script, active locale
--- over English over French, before any of its scripts run; the build is cached
--- per locale because the strings are part of the page.
--- ==============================================================================

local helpers = require("tests.helpers")
local describe, it = helpers.describe, helpers.it
local assert_true, assert_eq = helpers.assert_true, helpers.assert_eq





-- ================================
-- ================================
-- ======= 1/ The Catalogue =======
-- ================================
-- ================================

describe("locale catalogue: active over English over French", function()
	it("fills what the active locale lacks from English, then French (catalogue-en-fallback)", function()
		local saved_core = package.loaded["locale.core"]
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		package.loaded["locale.core"] = saved_core

		local files = {
			fr = '{"a":"A-fr","b":"B-fr","c":"C-fr"}',
			en = '{"a":"A-en","b":"B-en","d":""}',
			de = '{"a":"A-de","b":""}',
		}
		Core.init({
			json_decode = require("json").decode,
			resolve_locale_path = function(code) return code end,
			read_file = function(path) return files[path] end,
		})
		Core.set_locale("de")

		assert_true(type(Core.catalogue) == "function",
			"locale core must expose catalogue(): all() holds the active locale only")
		local catalogue = Core.catalogue()
		assert_eq(catalogue.a, "A-de", "the active locale wins")
		assert_eq(catalogue.b, "B-en", "an empty active translation falls back to English, as get() does")
		assert_eq(catalogue.c, "C-fr", "a key English lacks falls back to French")
		assert_eq(catalogue.d, "", "a key every locale leaves empty stays empty rather than missing")
	end)

	it("is re-exported by infra.locale", function()
		local locale = helpers.load_with_stubs("infra.locale")
		assert_true(type(locale.catalogue) == "function", "infra.locale must re-export catalogue()")
	end)
end)





-- =================================================
-- =================================================
-- ======= 2/ The Page Carries the Catalogue =======
-- =================================================
-- =================================================

--- Writes a throwaway page and returns its directory (with trailing slash).
--- @return string dir, string name
local function fixture()
	local dir = (os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp")
		:gsub("\\", "/"):gsub("/$", "") .. "/"
	local name = "ergopti_strings_probe.html"
	local fh = assert(io.open(dir .. name, "w"))
	fh:write('<!DOCTYPE html><html><head><title data-i18n="probe.title"></title></head>'
		.. '<body><script>window.page_ran = true;</script></body></html>')
	fh:close()
	return dir, name
end

--- Builds the fixture page with a stubbed locale and catalogue.
--- @param locale string Active locale code.
--- @param catalogue table Strings infra.locale.catalogue() returns.
--- @return string html, table errors
local function build(locale, catalogue)
	local saved_locale, saved_i18n = package.loaded["infra.locale"], package.loaded["infra.i18n"]
	package.loaded["infra.locale"] = { catalogue = function() return catalogue end }
	package.loaded["infra.i18n"] = { get_locale = function() return locale end }
	local builder = require("ui.ui_builder")
	local logger = require("infra.logger")
	local original = logger.error
	local errors = {}
	logger.error = function(_tag, fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		errors[#errors + 1] = ok and line or tostring(fmt)
	end
	local dir, name = fixture()
	local ok_build, html = pcall(builder.build_injected_html, dir, name)
	logger.error = original
	package.loaded["infra.locale"], package.loaded["infra.i18n"] = saved_locale, saved_i18n
	return ok_build and html or "", errors
end

describe("ui_builder: a page is built with its strings", function()
	it("seeds window._i18n_strings before any page script runs (page-carries-strings)", function()
		package.loaded["ui.ui_builder"] = nil
		local html, errors = build("fr", { ["probe.title"] = "Diagnostic" })
		assert_eq(#errors, 0, "a complete catalogue builds without errors: " .. table.concat(errors, " | "))
		local seed_at = html:find("window._i18n_strings=", 1, true)
		local page_at = html:find("window.page_ran", 1, true)
		assert_true(seed_at ~= nil, "the page must carry its strings: an inline page cannot fetch them")
		assert_true(page_at ~= nil and seed_at < page_at, "the strings must precede every page script")
		assert_true(html:find('"probe.title":"Diagnostic"', 1, true) ~= nil, "the seed holds the catalogue")
	end)

	it("cannot let a translation end the boot script early (seed-script-safe)", function()
		package.loaded["ui.ui_builder"] = nil
		local html = build("fr", { ["probe.title"] = "a </script><script>alert(1)</script>" })
		assert_true(html:find("</script><script>alert", 1, true) == nil,
			"a '<' inside a translation must be escaped in the seed")
		assert_true(html:find("a \\u003c/script>", 1, true) ~= nil, "the '<' is written as \\u003c")
	end)

	it("serves a page built for one locale only to that locale (cache-per-locale)", function()
		package.loaded["ui.ui_builder"] = nil
		local french = build("fr", { ["probe.title"] = "Bonjour" })
		local english = build("en", { ["probe.title"] = "Hello" })
		assert_true(french:find("Bonjour", 1, true) ~= nil, "the French build carries French")
		assert_true(english:find("Hello", 1, true) ~= nil,
			"a language switch must not serve the page built for the previous language")
		assert_true(english:find('_i18n_locale="en"', 1, true) ~= nil, "the page names the new locale")
	end)

	it("says so when it has no strings to seed (seed-unavailable-is-loud)", function()
		package.loaded["ui.ui_builder"] = nil
		local html, errors = build("fr", {})
		assert_true(html:find("window._i18n_strings=", 1, true) == nil, "nothing is seeded from nothing")
		assert_eq(#errors, 1, "an empty catalogue is logged once as an ERROR")
	end)
end)
