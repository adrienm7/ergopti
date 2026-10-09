--- tests/unit/modules/dynamic_hotstrings/test_toml_unescape_order.lua

--- ==============================================================================
--- MODULE: TOML Basic-String Unescape Ordering
--- DESCRIPTION:
--- Verifies the shared decoder distinguishes an escaped backslash followed by
--- "n" from a newline escape. The former chained-gsub implementations in the
--- personal-info and hotstrings-config readers corrupted that exact boundary.
--- Their public persistence round-trips are covered by the sibling transaction
--- tests; this module pins the canonical decoding primitive they now consume.
--- ==============================================================================

local helpers = require("tests.helpers")
local BasicString = require("toml_codec.basic_string")

helpers.describe("TOML basic-string decoder: one left-to-right pass", function()
	helpers.it("keeps an escaped backslash followed by n as two literal bytes", function()
		helpers.assert_eq(BasicString.unescape_body("\\\\n"), "\\n",
			"\\\\n represents a literal backslash followed by n")
	end)

	helpers.it("decodes one newline escape without reinterpreting its result", function()
		helpers.assert_eq(BasicString.unescape_body("\\n"), "\n")
		helpers.assert_eq(BasicString.unescape_body("\\u0001"), string.char(1),
			"Unicode escapes must decode without a sentinel collision")
	end)

	helpers.it("rejects malformed escapes instead of preserving ambiguous bytes", function()
		helpers.assert_nil(BasicString.unescape_body("\\q"))
		helpers.assert_nil(BasicString.unescape_body("\\u001"))
	end)

	helpers.it("keeps the same scalar contract through the LuaJIT UTF-8 shim", function()
		local original_utf8 = _G.utf8
		local original_module = package.loaded["toml_codec.basic_string"]
		local ok, err = xpcall(function()
			_G.utf8 = nil
			package.loaded["toml_codec.basic_string"] = nil
			local compat_codec = require("toml_codec.basic_string")
			helpers.assert_eq(compat_codec.unescape_body("\\u0001"), string.char(1))
			helpers.assert_eq(compat_codec.unescape_body("\\U0001F600"),
				string.char(0xF0, 0x9F, 0x98, 0x80))
			helpers.assert_nil(compat_codec.unescape_body("\\uD800"))
		end, debug.traceback)
		_G.utf8 = original_utf8
		package.loaded["toml_codec.basic_string"] = original_module
		if not ok then error(err, 0) end
	end)
end)
