--- tests/unit/lib/test_toml_multiline_first_line.lua

--- ==============================================================================
--- MODULE: TOML Multiline First-Line Preservation
--- DESCRIPTION:
--- Assignment whitespace normalization must not trim bytes inside open strings.
--- ==============================================================================

local helpers = require("tests.helpers")
local codec = require("toml_codec.codec")

helpers.describe("toml_codec: multiline first-line ownership", function()
	for _, quote in ipairs({ '"""', "'''" }) do
		for _, array in ipairs({ false, true }) do
			for body_index, body in ipairs({ "a \t \n b", "# content \t\nnext", " \t\nnext" }) do
				helpers.it("preserves first-line bytes for " .. quote .. " array=" .. tostring(array)
					.. " example=" .. body_index, function()
					local value = quote .. body .. quote
					if array then value = "[" .. value .. ", 2]" end
					local decoded = codec.decode("  value = " .. value .. " # outside\nnext = 3 # comment")
					helpers.assert_type(decoded, "table")
					helpers.assert_eq(array and decoded.value[1] or decoded.value, body)
					if array then helpers.assert_eq(decoded.value[2], 2) end
					helpers.assert_eq(decoded.next, 3)
				end)
			end
		end
	end

	helpers.it("still strips comments outside multiline array strings", function()
		local decoded = codec.decode('value = [ # opening\n 1, # first\n 2\n] # closing\nnext = "ok" # end')
		helpers.assert_type(decoded, "table")
		helpers.assert_eq(decoded.value, { 1, 2 })
		helpers.assert_eq(decoded.next, "ok")
	end)

	helpers.it("still trims a newline immediately after the opening delimiter", function()
		local decoded = codec.decode('value = """\ntext\n"""')
		helpers.assert_type(decoded, "table")
		helpers.assert_eq(decoded.value, "text\n")
	end)
end)
