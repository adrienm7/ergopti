--- tests/unit/lib/test_config_overrides_inline_comments.lua

--- ==============================================================================
--- MODULE: Config Overrides — Inline Comment Stripping Regression Test
--- DESCRIPTION:
--- Regression test asserting that TOML inline comments (everything from the
--- first unquoted `#` to end of line) are stripped from values before coercion.
--- Before the fix, `log_level = "DEBUG" # this is a comment` would coerce to
--- the raw string `"DEBUG" # this is a comment` instead of `"DEBUG"`. This test
--- encodes that exact failure mode so the bug can never silently return.
---
--- FEATURES & RATIONALE:
--- 1. Isolated Store: Overrides hs.settings with an in-memory table so that
---    every call to hs.settings.set() from M.apply() is fully observable
---    without touching the canonical shared stub.
--- 2. Both Value Types: Covers string values (quoted) and numeric values to
---    confirm that comment stripping happens before type coercion in both cases.
--- 3. Canonical Restore: The canonical hs.settings reference is restored after
---    the suite so no state leaks into subsequent test files.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Override hs.settings with a local in-memory store so we can inspect exactly
-- what M.apply() passed to hs.settings.set without touching the canonical stub.
-- The canonical SETTINGS_STORE is restored at the end of this file.
local stored = {}
_G.hs = _G.hs or {}
local _ORIGINAL_SETTINGS = _G.hs.settings
local test_settings = {
	set = function(key, value) stored[key] = value end,
	get = function(key) return stored[key] end,
}

package.loaded["adapters.storage"] = nil
local Overrides = helpers.load_with_stubs("infra.config_overrides", {settings = test_settings})
-- helpers.load_with_stubs calls __reset() which reinstalls the canonical
-- hs.settings stub; re-apply the inspectable override so the suites below
-- still write into the local `stored` table.
_G.hs.settings = test_settings





-- ================================================================
-- ================================================================
-- ======= 1/ Inline Comment Stripping ([features] section) =======
-- ================================================================
-- ================================================================

helpers.describe("config_overrides.apply — inline comment stripping", function()

	-- Helper: write content to a temp file, run apply(), then clean up
	local function with_tmp(content, fn)
		local path = os.tmpname()
		local fh = io.open(path, "w")
		fh:write(content)
		fh:close()
		fn(path)
		os.remove(path)
	end

	helpers.it("strips an inline comment from a quoted string value in [features]", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end

		-- The raw line is: log_level = "DEBUG" # this is a comment
		-- After stripping the inline comment the value must coerce to "DEBUG",
		-- not to the raw string `"DEBUG" # this is a comment`.
		with_tmp('[features]\nlog_level = "DEBUG" # this is a comment\n', function(path)
			local applied = Overrides.apply(path)

			helpers.assert_true(applied >= 1, "applied count")
			helpers.assert_eq(stored["ergopti.log_level"], "DEBUG", "log_level after comment strip")
		end)
	end)


	helpers.it("strips an inline comment from a numeric value in [features]", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end

		-- The raw line is: some_value = 42 # numeric comment
		-- After stripping, the value string is "42" which must coerce to the
		-- number 42, not to the string "42 # numeric comment".
		with_tmp('[features]\nsome_value = 42 # numeric comment\n', function(path)
			local applied = Overrides.apply(path)

			helpers.assert_true(applied >= 1, "applied count")
			helpers.assert_eq(stored["ergopti.some_value"], 42, "some_value after comment strip")
		end)
	end)


	helpers.it("strips inline comments in [script] section as well", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end

		with_tmp('[script]\nLogLevel = "INFO" # developer note\n', function(path)
			local applied = Overrides.apply(path)

			helpers.assert_true(applied >= 1, "applied count")
			-- LogLevel maps to the canonical ergopti.log_level key (F-M4); the comment
			-- must still be stripped from the value.
			helpers.assert_eq(stored["ergopti.log_level"], "INFO", "LogLevel after comment strip")
		end)
	end)


	helpers.it("handles a value with no inline comment unchanged", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end

		-- Sanity-check: plain values (no comment) must still coerce correctly
		with_tmp('[features]\nlog_level = "WARN"\n', function(path)
			local applied = Overrides.apply(path)

			helpers.assert_true(applied >= 1, "applied count")
			helpers.assert_eq(stored["ergopti.log_level"], "WARN", "log_level without comment")
		end)
	end)


	helpers.it("handles a standalone comment line without counting it as an override", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end

		-- A line that is only a comment must be silently skipped; the count
		-- must reflect only the real key=value entries.
		with_tmp('[features]\n# full-line comment\nlog_level = "DEBUG"\n', function(path)
			local applied = Overrides.apply(path)

			helpers.assert_eq(applied, 1, "only the real entry is counted")
			helpers.assert_eq(stored["ergopti.log_level"], "DEBUG", "log_level set correctly")
		end)
	end)


	helpers.it("does NOT strip a # that appears inside a quoted string value", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end

		-- M-08 (quote-aware regex): the old pattern `#.*$` would strip the # inside
		-- the quoted value as well. The fix uses `#[^"]*$` which stops at a `"`.
		-- `key = "has#hash" # trailing comment` must coerce to the string `has#hash`,
		-- not to the truncated `has`.
		with_tmp('[features]\nlog_level = "has#hash" # trailing comment\n', function(path)
			local applied = Overrides.apply(path)

			helpers.assert_true(applied >= 1, "applied count")
			helpers.assert_eq(stored["ergopti.log_level"], "has#hash",
				"# inside quoted value must be preserved; only the trailing comment is stripped")
		end)
	end)


	helpers.it("does NOT truncate a value containing an escaped double-quote (F-MED-23)", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end

		-- F-MED-23: the quote-aware fast-path regex `'^"[^"]*"'` is not escape-aware
		-- and stops at the FIRST literal `"` — including one preceded by a backslash.
		-- Before the fix, `key = "a \"quoted\" word"  # comment` truncated the
		-- extracted value to `"a \"` (silently dropping the rest of the value AND
		-- the genuine trailing comment) and coerced to the mangled string `a \`.
		-- The fix walks the string honouring `\"` escapes so the full value round-
		-- trips and the trailing comment is still stripped correctly.
		with_tmp('[features]\nkey = "a \\"quoted\\" word"  # comment\n', function(path)
			local applied = Overrides.apply(path)

			helpers.assert_true(applied >= 1, "applied count")
			helpers.assert_eq(stored["ergopti.key"], 'a "quoted" word',
				"escaped quotes inside the value must round-trip and the trailing comment must be stripped")
		end)
	end)

	helpers.it("never executes table-looking text inside a multiline string", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end

		with_tmp([==[[llm]
app_profile_overrides = """
[features]
llm.enabled = false
"""
]==], function(path)
			local applied = Overrides.apply(path)
			helpers.assert_eq(applied, 0,
				"only the owned [script]/[features] tables may publish settings")
			helpers.assert_nil(stored["ergopti.llm.enabled"],
				"a header and assignment inside a string are inert user data")
		end)
	end)

end)


package.loaded["adapters.storage"] = nil
package.loaded["infra.config_overrides"] = nil
if _ORIGINAL_SETTINGS then _G.hs.settings = _ORIGINAL_SETTINGS end
