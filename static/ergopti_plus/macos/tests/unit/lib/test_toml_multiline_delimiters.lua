--- tests/unit/lib/test_toml_multiline_delimiters.lua

--- ==============================================================================
--- MODULE: TOML Multiline Delimiter Ownership
--- DESCRIPTION:
--- The first lexical closing run ends a value; content quotes in four/five-quote
--- endings must not reopen a string or conceal following container delimiters.
--- ==============================================================================

local helpers = require("tests.helpers")
local codec = require("toml_codec.codec")
local scanner = require("toml_codec.record_scanner")

helpers.describe("toml_codec: multiline delimiter boundaries", function()
	for _, char in ipairs({ '"', "'" }) do
		local triple = string.rep(char, 3)
		for count = 3, 5 do
			helpers.it("keeps empty-body closure " .. count .. char, function()
				local decoded = codec.decode("value = " .. triple .. string.rep(char, count))
				helpers.assert_type(decoded, "table")
				helpers.assert_eq(decoded.value, string.rep(char, count - 3))
			end)
			for _, array in ipairs({ false, true }) do
				for _, multiline in ipairs({ false, true }) do
					helpers.it("keeps " .. count .. char .. " array=" .. tostring(array)
						.. " multiline=" .. tostring(multiline), function()
						local body = multiline and "a\nb" or "a"
						local value = triple .. body .. string.rep(char, count)
						if array then value = "[" .. value .. ", 2]" end
						local decoded = codec.decode("value = " .. value .. " # comment\nnext = 3")
						helpers.assert_type(decoded, "table")
						helpers.assert_eq(array and decoded.value[1] or decoded.value,
							body .. string.rep(char, count - 3))
						if array then helpers.assert_eq(decoded.value[2], 2) end
						helpers.assert_eq(decoded.next, 3)
					end)
				end
			end
		end

		for _, array in ipairs({ false, true }) do
			helpers.it("rejects trailing tokens for " .. char .. " array=" .. tostring(array), function()
				local value = triple .. "a" .. triple .. " junk " .. triple .. "b" .. triple
				if array then value = "[" .. value .. "]" end
				helpers.assert_nil(codec.decode("value = " .. value))
			end)
		end

		helpers.it("rejects oversized closing runs for " .. char, function()
			helpers.assert_nil(codec.decode("value = " .. triple .. "a" .. string.rep(char, 6)))
		end)

		for count = 4, 5 do
			helpers.it("settles record depth after " .. count .. char, function()
				local depth, quote = scanner.advance("a" .. string.rep(char, count) .. "] # ignored [", 1, triple)
				helpers.assert_eq(depth, 0)
				helpers.assert_nil(quote)
			end)
		end
	end

	helpers.it("retains escaped quotes inside a basic multiline string", function()
		local decoded = codec.decode('value = """a""\\"b"""')
		helpers.assert_type(decoded, "table")
		helpers.assert_eq(decoded.value, 'a"""b')
	end)

	helpers.it("permits a content triple formed only by continuation removal", function()
		local decoded = codec.decode('value = """a""\\\n "b"""')
		helpers.assert_type(decoded, "table")
		helpers.assert_eq(decoded.value, 'a"""b')
	end)
end)
