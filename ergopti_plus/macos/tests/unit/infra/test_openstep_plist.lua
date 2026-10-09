--- tests/unit/infra/test_openstep_plist.lua

--- ==============================================================================
--- MODULE: OpenStep Property List Reader Tests
--- DESCRIPTION:
--- The reader decodes what `defaults read DOMAIN KEY` prints, so the boot's
--- input-source probe needs no Python (hardening-h-no-rosetta): arrays and
--- dictionaries, bare and quoted strings, the escapes `defaults` emits, and a
--- refusal, never a partial value, for a malformed document.
--- ==============================================================================

local helpers = require("tests.helpers")

local function reader()
	package.loaded["infra.openstep_plist"] = nil
	return require("infra.openstep_plist")
end

helpers.describe("openstep-plist-reader", function()
	helpers.it("decodes the array of dictionaries `defaults read` prints", function()
		local plist = reader()
		local value = plist.decode(table.concat({
			"(",
			"        {",
			"        InputSourceKind = \"Keyboard Layout\";",
			"        \"KeyboardLayout ID\" = 252;",
			"        \"KeyboardLayout Name\" = ABC;",
			"    },",
			"        {",
			"        \"Bundle ID\" = \"com.apple.CharacterPaletteIM\";",
			"        InputSourceKind = \"Non Keyboard Input Method\";",
			"    }",
			")",
			"",
		}, "\n"))
		helpers.assert_true(plist.is_array(value))
		helpers.assert_eq(#value, 2)
		helpers.assert_eq(value[1]["KeyboardLayout Name"], "ABC")
		helpers.assert_eq(value[1]["KeyboardLayout ID"], "252")
		helpers.assert_eq(value[1].InputSourceKind, "Keyboard Layout")
		helpers.assert_eq(value[2]["Bundle ID"], "com.apple.CharacterPaletteIM")
		helpers.assert_true(not plist.is_array(value[1]), "a dictionary is not an array")
	end)

	helpers.it("decodes \\U code units, surrogate pairs, C escapes and octal bytes", function()
		local plist = reader()
		helpers.assert_eq(plist.decode('"Fran\\U00e7ais"'), "Français")
		helpers.assert_eq(plist.decode('"\\Ud83d\\Ude00"'), "😀")
		helpers.assert_eq(plist.decode('"a\\"b\\\\c\\nd\\te"'), 'a"b\\c\nd\te')
		helpers.assert_eq(plist.decode('"\\101\\102"'), "AB")
		helpers.assert_eq(plist.decode('"Français brut"'), "Français brut",
			"raw UTF-8 inside quotes passes through")
	end)

	helpers.it("accepts a trailing comma, negative bare numbers and empty containers", function()
		local plist = reader()
		local value = plist.decode("( -2, \"x\", )")
		helpers.assert_eq(#value, 2)
		helpers.assert_eq(value[1], "-2")
		helpers.assert_true(plist.is_array(plist.decode("()")))
		helpers.assert_true(not plist.is_array(plist.decode("{}")), "an empty dictionary is not an array")
		helpers.assert_eq(plist.decode("<0a41>"), "\nA")
	end)

	helpers.it("refuses a malformed document with the position of the fault", function()
		local plist = reader()
		for _, text in ipairs({
			"", "   ", "(", "( a b )", "{ a = b }", "{ a b; }", '"open', '"\\Ud83d"', '"\\Ude00x"',
			'"\\q"', '"\\200"', "(a) trailing", "<0a4>", "{ (a) = b; }", "@",
		}) do
			local value, err = plist.decode(text)
			helpers.assert_nil(value, "malformed document accepted: " .. text)
			helpers.assert_type(err, "string")
		end
		helpers.assert_nil(plist.decode(nil))
	end)
end)
