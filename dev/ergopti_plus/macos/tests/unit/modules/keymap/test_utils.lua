--- tests/unit/modules/keymap/test_utils.lua

--- ==============================================================================
--- MODULE: keymap.utils Unit Tests
--- DESCRIPTION:
--- Validates the pure helpers used by the keymap engine:
--- replacement-token parsing, plain-text projection, paste/keystroke decision,
--- and the prediction overlap solver.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local KU = helpers.load_with_stubs("modules.keymap.utils")




-- =====================================
-- =====================================
-- ======= 1/ tokens_from_repl ==========
-- =====================================
-- =====================================

helpers.describe("KU.tokens_from_repl", function()
	helpers.it("returns text token for plain string", function()
		local t = KU.tokens_from_repl("Hello")
		helpers.assert_eq(#t, 1)
		helpers.assert_eq(t[1].kind, "text")
		helpers.assert_eq(t[1].value, "Hello")
	end)

	helpers.it("recognizes {Enter} as a key token", function()
		local t = KU.tokens_from_repl("a{Enter}b")
		helpers.assert_eq(#t, 3)
		helpers.assert_eq(t[2].kind, "key")
		helpers.assert_eq(t[2].value, "return")
	end)

	helpers.it("recognizes {Tab} as a key token", function()
		local t = KU.tokens_from_repl("{Tab}")
		helpers.assert_eq(#t, 1)
		helpers.assert_eq(t[1].kind, "key")
		helpers.assert_eq(t[1].value, "tab")
	end)

	helpers.it("matches placeholders case-insensitively", function()
		local t = KU.tokens_from_repl("{enter}")
		helpers.assert_eq(t[1].kind, "key")
		helpers.assert_eq(t[1].value, "return")
	end)

	helpers.it("treats unknown placeholders as literal text", function()
		local t = KU.tokens_from_repl("{Unknown}")
		helpers.assert_eq(t[1].kind, "text")
		helpers.assert_eq(t[1].value, "{Unknown}")
	end)

	helpers.it("splits literal newlines into key tokens", function()
		local t = KU.tokens_from_repl("a\nb")
		-- Expected: text "a", key "return", text "b"
		helpers.assert_eq(#t, 3)
		helpers.assert_eq(t[2].kind, "key")
		helpers.assert_eq(t[2].value, "return")
	end)

	helpers.it("returns empty list for non-string input", function()
		helpers.assert_eq(KU.tokens_from_repl(nil), {})
		helpers.assert_eq(KU.tokens_from_repl(42), {})
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ plain_text ===============
-- =====================================
-- =====================================

helpers.describe("KU.plain_text", function()
	helpers.it("concatenates only text tokens", function()
		local tokens = {
			{ kind = "text", value = "a" },
			{ kind = "key",  value = "return" },
			{ kind = "text", value = "b" },
		}
		helpers.assert_eq(KU.plain_text(tokens), "ab")
	end)

	helpers.it("returns empty for non-table input", function()
		helpers.assert_eq(KU.plain_text(nil), "")
		helpers.assert_eq(KU.plain_text("oops"), "")
	end)

	helpers.it("returns empty when no text tokens", function()
		helpers.assert_eq(KU.plain_text({ { kind = "key", value = "tab" } }), "")
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ should_paste =============
-- =====================================
-- =====================================

helpers.describe("KU.should_paste", function()
	helpers.it("returns false for short ASCII strings", function()
		helpers.assert_eq(KU.should_paste("Hello"), false)
	end)

	helpers.it("returns true for strings >50 chars", function()
		local s = string.rep("x", 60)
		helpers.assert_eq(KU.should_paste(s), true)
	end)

	helpers.it("returns true for strings with high unicode (>0xFFFF)", function()
		helpers.assert_eq(KU.should_paste("hi 🎉"), true)
	end)

	helpers.it("returns false for non-string input", function()
		helpers.assert_eq(KU.should_paste(nil), false)
		helpers.assert_eq(KU.should_paste(42), false)
	end)

	helpers.it("returns false for short BMP (multi-byte but <= 0xFFFF)", function()
		helpers.assert_eq(KU.should_paste("café"), false)
	end)
end)




-- =====================================
-- =====================================
-- ======= 4/ resolve_prediction_overlap
-- =====================================
-- =====================================

helpers.describe("KU.resolve_prediction_overlap", function()
	helpers.it("returns originals when prediction is empty", function()
		local d, t = KU.resolve_prediction_overlap("buf", 3, "")
		helpers.assert_eq(d, 3)
		helpers.assert_eq(t, "")
	end)

	helpers.it("preserves originals when buffer is empty", function()
		local d, t = KU.resolve_prediction_overlap("", 0, "hello")
		helpers.assert_eq(d, 0)
		helpers.assert_eq(t, "hello")
	end)

	helpers.it("detects overlap and converts to delete + retype", function()
		-- Buffer ends with "tex"; prediction "texte" overlaps by 3 chars
		local d, t = KU.resolve_prediction_overlap("Je tex", 0, "texte")
		helpers.assert_eq(d, 3)
		helpers.assert_eq(t, "texte")
	end)

	helpers.it("strips double-space when buffer ends with whitespace", function()
		local d, t = KU.resolve_prediction_overlap("Hello ", 0, " world")
		helpers.assert_eq(d, 0)
		helpers.assert_eq(t, "world")
	end)

	helpers.it("strips leading space after a hyphen (compound word)", function()
		local d, t = KU.resolve_prediction_overlap("anti-", 0, " spam")
		helpers.assert_eq(d, 0)
		-- After hyphen no separator: leading space stripped
		helpers.assert_eq(t, "spam")
	end)

	helpers.it("preserves original when no overlap is found", function()
		local d, t = KU.resolve_prediction_overlap("Hello", 2, "world")
		helpers.assert_eq(d, 2)
		helpers.assert_eq(t, "world")
	end)

	helpers.it("is accent-insensitive for overlap detection", function()
		-- Buffer ends with "été" (with accents), prediction "ete continues" matches
		local d, t = KU.resolve_prediction_overlap("c'était l'été", 0, "ete continue")
		helpers.assert_true(d >= 1)
	end)
end)
