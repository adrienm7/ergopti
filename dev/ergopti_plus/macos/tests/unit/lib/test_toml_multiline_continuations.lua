--- tests/unit/lib/test_toml_multiline_continuations.lua

--- ==============================================================================
--- MODULE: TOML Multiline Continuation Regression Tests
--- DESCRIPTION:
--- Preserve source escape ownership while trimming line-ending continuations.
--- ==============================================================================

local helpers = require("tests.helpers")
local codec = require("toml_codec.codec")

helpers.describe("toml_codec: multiline continuation escape ownership", function()
	for count = 1, 4 do
		for _, padding in ipairs({ "", " \t" }) do
			helpers.it("preserves " .. count .. " backslashes with padding length " .. #padding, function()
				local source = 'value = """\na' .. string.rep("\\", count) .. padding .. '\n \tb"""'
				local expected = "a" .. string.rep("\\", math.floor(count / 2))
				if count % 2 == 0 then expected = expected .. padding .. "\n \t" end
				local decoded = codec.decode(source)
				helpers.assert_type(decoded, "table")
				helpers.assert_eq(decoded.value, expected .. "b")
			end)
		end
	end

	helpers.it("trims blank lines through the closing delimiter", function()
		local decoded = codec.decode('value = """\na\\ \t\n \n\t"""')
		helpers.assert_type(decoded, "table")
		helpers.assert_eq(decoded.value, "a")
	end)

	helpers.it("does not manufacture an escape across a continuation", function()
		local decoded = codec.decode('value = """a\\\\\\\n n"""')
		helpers.assert_type(decoded, "table")
		helpers.assert_eq(decoded.value, "a\\n")
	end)

	helpers.it("normalizes CRLF before collapsing padded continuations", function()
		local decoded = codec.decode('value = """\r\na\\ \t\r\n \tb"""')
		helpers.assert_type(decoded, "table")
		helpers.assert_eq(decoded.value, "ab")
	end)

	helpers.it("still rejects unknown escapes and backslashes without a newline", function()
		helpers.assert_nil(codec.decode('value = """a\\q"""'))
		helpers.assert_nil(codec.decode('value = """a\\ \tb"""'))
	end)

	helpers.it("does not collapse literal multiline content", function()
		local body = "a\\ \n b"
		local decoded = codec.decode("value = '''\n" .. body .. "'''")
		helpers.assert_type(decoded, "table")
		helpers.assert_eq(decoded.value, body)
	end)
end)
