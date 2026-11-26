--- tests/unit/core/i18n/test_trigger_percent.lua

--- ==============================================================================
--- MODULE: Regression — locale.get ★ substitution with a "%" trigger char
--- DESCRIPTION:
--- The trigger character is user-configurable (M.set_trigger_char accepts any
--- single character). infra/locale.get() substitutes the "★" placeholder with the
--- live trigger via string.gsub(s, "★", trigger). string.gsub treats the
--- replacement string specially: a literal "%" must be escaped as "%%", otherwise
--- gsub raises "invalid use of '%' in replacement string". A user who picks "%"
--- as their magic key therefore crashes every menu build that renders a string
--- containing ★ (category.magic_key, dynamichotstrings.*, …).
---
--- This test sets the trigger provider to return "%" and asserts that get() does
--- NOT throw and performs the substitution literally. It FAILS before the fix
--- (gsub error) and PASSES once the replacement escapes "%".
--- ==============================================================================

local helpers = require("tests.helpers")
local describe, it = helpers.describe, helpers.it
local assert_true, assert_eq = helpers.assert_true, helpers.assert_eq

describe("locale.get — '%' trigger char does not break gsub", function()
	it("shows ★ with '%' beside it without raising", function()
		local locale = helpers.load_with_stubs("core.i18n.engine.locale")
		-- Force French (default) so the value for category.magic_key is loaded.
		locale.set_locale("fr")
		-- User has rebound the magic key to "%": the display must keep it literal.
		locale.set_display_provider(function(text, key)
			return require("hotstrings.engine.magic_key_display").display_text(text, "%", key)
		end)

		local ok, result = pcall(locale.get, "category.magic_key")
		assert_true(ok, "locale.get must not raise on a '%' trigger char (got: " .. tostring(result) .. ")")
		-- The ★ shows the literal "%" beside it (2026-11-21: « ★ (%) »).
		assert_eq(result, "Touche ★ (%) et expansion de texte", "★ should show the literal '%' beside it")
	end)
end)
