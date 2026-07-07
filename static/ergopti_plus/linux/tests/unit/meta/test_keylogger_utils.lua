--- linux/tests/unit/meta/test_keylogger_utils.lua

local helpers = require("tests.helpers")

helpers.describe("_shared/lua/keylogger/utils.lua", function()
	helpers.it("module loads without error", function()
		local ok, mod = pcall(require, "keylogger.utils")
		helpers.assert_true(ok, "require('keylogger.utils') should succeed")
		helpers.assert_true(type(mod) == "table", "should return a table")
		helpers.assert_true(type(mod.gc) == "function", "should expose gc()")
		helpers.assert_true(type(mod.char_class) == "function", "should expose char_class()")
		helpers.assert_true(type(mod.pop_utf8) == "function", "should expose pop_utf8()")
	end)

	local K = require("keylogger.utils")

	helpers.describe("gc (get-or-create)", function()
		helpers.it("creates sub-table when key is absent", function()
			local t = {}
			local sub = K.gc(t, "new_key", { value = 42 })
			helpers.assert_true(type(sub) == "table", "returns a table")
			helpers.assert_eq(sub.value, 42, "default value is set")
			helpers.assert_eq(t["new_key"], sub, "parent references sub-table")
		end)

		helpers.it("returns existing sub-table on second call", function()
			local t = {}
			local a = K.gc(t, "k", { count = 1 })
			local b = K.gc(t, "k", { count = 2 })
			helpers.assert_eq(a.count, 1, "first call sets value")
			helpers.assert_eq(b.count, 1, "second call does NOT overwrite")
			helpers.assert_eq(a, b, "same table reference")
		end)

		helpers.it("uses empty table when no default given", function()
			local t = {}
			local sub = K.gc(t, "k")
			helpers.assert_true(type(sub) == "table", "returns a table")
			helpers.assert_eq(next(sub), nil, "empty table")
		end)
	end)

	helpers.describe("char_class", function()
		helpers.it("classifies space characters", function()
			helpers.assert_eq(K.char_class(" "), "space")
			helpers.assert_eq(K.char_class("\t"), "space")
			helpers.assert_eq(K.char_class("\n"), "space")
		end)

		helpers.it("classifies digits", function()
			helpers.assert_eq(K.char_class("0"), "digit")
			helpers.assert_eq(K.char_class("5"), "digit")
			helpers.assert_eq(K.char_class("9"), "digit")
		end)

		helpers.it("classifies ASCII letters", function()
			helpers.assert_eq(K.char_class("a"), "letter")
			helpers.assert_eq(K.char_class("Z"), "letter")
		end)

		helpers.it("classifies Latin-1 accented letters as letter", function()
			helpers.assert_eq(K.char_class("é"), "letter")
			helpers.assert_eq(K.char_class("è"), "letter")
		end)

		helpers.it("classifies punctuation", function()
			helpers.assert_eq(K.char_class("."), "punct")
			helpers.assert_eq(K.char_class(","), "punct")
			helpers.assert_eq(K.char_class("!"), "punct")
		end)

		helpers.it("classifies bracket keys as other", function()
			helpers.assert_eq(K.char_class("[BS]"), "other")
			helpers.assert_eq(K.char_class("[UP]"), "other")
		end)

		helpers.it("handles nil/empty gracefully", function()
			helpers.assert_eq(K.char_class(nil), "other")
			helpers.assert_eq(K.char_class(""), "other")
		end)
	end)

	helpers.describe("pop_utf8", function()
		helpers.it("removes last ASCII character", function()
			helpers.assert_eq(K.pop_utf8("hello"), "hell")
		end)

		helpers.it("removes last multi-byte character", function()
			helpers.assert_eq(K.pop_utf8("hé"), "h")
		end)

		helpers.it("handles empty string", function()
			helpers.assert_eq(K.pop_utf8(""), "")
		end)

		helpers.it("handles nil", function()
			helpers.assert_eq(K.pop_utf8(nil), "")
		end)

		helpers.it("handles single character", function()
			helpers.assert_eq(K.pop_utf8("a"), "")
		end)
	end)
end)
