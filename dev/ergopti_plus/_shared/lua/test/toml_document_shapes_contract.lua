--- _shared/lua/test/toml_document_shapes_contract.lua

--- ==============================================================================
--- MODULE: Full-document TOML Source Receipts
--- DESCRIPTION:
--- Handwritten tokens distinguish numeric kinds and empty arrays across an
--- unrelated full-document edit. Optional receipts never change default APIs.
--- ==============================================================================

local math_type = math.type

return function(helpers)
	local Codec = require("toml_codec")
	helpers.describe("optional TOML document source receipts", function()
		helpers.it("keeps the default value model and encoder independent of source receipts", function()
			local source = 'float = 1.0\nempty = []\nmap = {}\n'
			local document, receipt = Codec.decode_with_shapes(source)
			helpers.assert_eq(document, { float = 1.0, empty = {}, map = {} })
			helpers.assert_eq(Codec.decode(source), document)
			helpers.assert_eq(Codec.encode_value(document.float), "1")
			helpers.assert_eq(Codec.encode_value(document.empty), "{  }")
			local before = Codec.encode(document)
			local encoded = Codec.encode_with_shapes(document, receipt)
			helpers.assert_contains(encoded, "float = 1.0")
			helpers.assert_contains(encoded, "empty = []")
			helpers.assert_contains(encoded, "[map]")
			helpers.assert_eq(Codec.encode(document), before)
		end)

		for _, token in ipairs({ "9_223_372_036_854_775_807", "1.2345678901234567", "1.0",
			"-0.0", "1.2345678901234567e+42", "-1.23456789012345e-120" }) do
			helpers.it("preserves an unchanged root numeric token: " .. token, function()
				local document, receipt = Codec.decode_with_shapes("future = " .. token .. "\n")
				document.owned = { timeout_ms = 1234 }
				local encoded = Codec.encode_with_shapes(document, receipt)
				helpers.assert_contains(encoded, "future = " .. token .. "\n")
				helpers.assert_eq(Codec.decode(encoded).owned, { timeout_ms = 1234 })
			end)
		end

		helpers.it("threads exact identities through nested maps and array dictionary members", function()
			local source = 'rows = [[], {}, { precise = 0.12345678901234566, empty = [] }, [1.0]]\n'
				.. '[future."with.dot"]\n"" = []\nnumber = 9_223_372_036_854_775_807\n'
			local document, receipt = Codec.decode_with_shapes(source)
			document.owned = true
			local encoded = Codec.encode_with_shapes(document, receipt)
			helpers.assert_contains(encoded, 'rows = [[], {  }, { empty = [], precise = 0.12345678901234566 }, [1.0]]')
			helpers.assert_contains(encoded, '[future."with.dot"]')
			helpers.assert_contains(encoded, '"" = []')
			helpers.assert_contains(encoded, 'number = 9_223_372_036_854_775_807')
			helpers.assert_eq(Codec.decode(encoded), {
				rows = { {}, {}, { precise = 0.12345678901234566, empty = {} }, { 1.0 } },
				future = { ["with.dot"] = { [""] = {}, number = 9223372036854775807 } }, owned = true,
			})
		end)

		helpers.it("does not reuse numeric authority after mutation", function()
			local document, receipt = Codec.decode_with_shapes('future = 1.0\n')
			document.future = 0.12345678901234566
			local encoded = Codec.encode_with_shapes(document, receipt)
			helpers.assert_eq(Codec.decode(encoded).future, 0.12345678901234566)
			helpers.assert_true(not encoded:find("future = 1.0", 1, true))
		end)

		for _, vector in ipairs({ { original = "-0.0", changed = "0.0" },
			{ original = "0.0", changed = "-0.0" } }) do
			helpers.it("retains signed-zero authority only for the same sign: " .. vector.original, function()
				local document, receipt = Codec.decode_with_shapes("future = " .. vector.original .. "\n")
				helpers.assert_contains(Codec.encode_with_shapes(document, receipt), "future = " .. vector.original .. "\n")
				helpers.assert_eq(Codec.encode_value_with_shapes(document.future, receipt, document, "future"), vector.original)
				document.future = tonumber(vector.changed)
				local encoded = Codec.encode_with_shapes(document, receipt)
				helpers.assert_contains(encoded, "future = " .. vector.changed .. "\n")
				helpers.assert_eq(1 / Codec.decode(encoded).future, 1 / tonumber(vector.changed))
				helpers.assert_eq(Codec.encode_value_with_shapes(document.future, receipt, document, "future"), vector.changed)
				if math_type then helpers.assert_eq(math_type(Codec.decode(encoded).future), "float") end
			end)
		end

		helpers.it("retains a fresh negative zero without changing default or integer encoding", function()
			local document, receipt = Codec.decode_with_shapes("future = 17\n")
			document.future, document.integer = tonumber("-0.0"), 0
			local encoded = Codec.encode_with_shapes(document, receipt)
			helpers.assert_contains(encoded, "future = -0.0\n")
			helpers.assert_contains(encoded, "integer = 0\n")
			helpers.assert_eq(Codec.encode_value(document.future), "0", "default numeric model stays unchanged")
			helpers.assert_eq(Codec.encode_value_with_shapes(document.future, receipt, document, "future"), "-0.0")
			if math_type then
				document.future = tonumber("0.0")
				helpers.assert_contains(Codec.encode_with_shapes(document, receipt), "future = 0.0\n")
			end
		end)

		helpers.it("keeps integer-zero ownership distinct from floating source receipts", function()
			for _, token in ipairs({ "0.0", "-0.0" }) do
				local document, receipt = Codec.decode_with_shapes("future = " .. token .. "\n")
				if math_type then
					document.future = 0
					helpers.assert_contains(Codec.encode_with_shapes(document, receipt), "future = 0\n")
					helpers.assert_eq(Codec.encode_value_with_shapes(document.future, receipt, document, "future"), "0")
					helpers.assert_eq(math_type(Codec.decode(Codec.encode_with_shapes(document, receipt)).future), "integer")
				end
				document.fresh_integer = 0
				helpers.assert_contains(Codec.encode_with_shapes(document, receipt), "fresh_integer = 0\n")
			end
			local document, receipt = Codec.decode_with_shapes("future = 0\n")
			if math_type then
				document.future = tonumber("0.0")
				helpers.assert_contains(Codec.encode_with_shapes(document, receipt), "future = 0.0\n")
				helpers.assert_eq(Codec.encode_value_with_shapes(document.future, receipt, document, "future"), "0.0")
			end
		end)

		helpers.it("refuses a document from a different read generation", function()
			local first, receipt = Codec.decode_with_shapes('empty = []\n')
			local second = Codec.decode('empty = []\n')
			local message = helpers.assert_throws(function() Codec.encode_with_shapes(second, receipt) end)
			helpers.assert_contains(tostring(message), "TOML shape receipt belongs to another document")
			helpers.assert_contains(Codec.encode_with_shapes(first, receipt), "empty = []")
		end)

		helpers.it("refuses named and sparse slots in source arrays instead of discarding them", function()
			local document, receipt = Codec.decode_with_shapes('empty = []\n')
			document.empty.future = "keep"
			local message = helpers.assert_throws(function() Codec.encode_with_shapes(document, receipt) end)
			helpers.assert_contains(tostring(message), "TOML array receipt cannot discard named or invalid slots")
			document.empty.future, document.empty[2] = nil, 17
			message = helpers.assert_throws(function() Codec.encode_with_shapes(document, receipt) end)
			helpers.assert_contains(tostring(message), "TOML array receipt requires dense slots")
			document.empty[2] = nil
			helpers.assert_contains(Codec.encode_with_shapes(document, receipt), "empty = []")
		end)

		for _, token in ipairs({ "1979-05-27", "07:32:00", "07:32:00.123456",
			"1979-05-27T07:32:00", "1979-05-27 07:32:00.123456",
			"1979-05-27T07:32:00Z", "1979-05-27t07:32:00z", "1979-05-27T07:32:00.123456-07:00" }) do
			helpers.it("retains an unchanged existing temporal fallback token: " .. token, function()
				local document, receipt = Codec.decode_with_shapes("future = " .. token .. "\n")
				helpers.assert_eq(document, { future = token }, "default temporal model stays a string")
				helpers.assert_eq(Codec.decode("future = " .. token), document)
				helpers.assert_eq(Codec.encode_value(document.future), '"' .. token .. '"')
				local encoded = Codec.encode_with_shapes(document, receipt)
				helpers.assert_contains(encoded, "future = " .. token .. "\n")
				helpers.assert_eq(Codec.encode_value_with_shapes(document.future, receipt, document, "future"), token)
			end)
		end

		helpers.it("keeps quoted temporal strings distinct and does not reuse changed fallback tokens", function()
			local document, receipt = Codec.decode_with_shapes('date = 1979-05-27\nquoted = "1979-05-27"\n')
			document.date = "changed"
			local encoded = Codec.encode_with_shapes(document, receipt)
			helpers.assert_contains(encoded, 'date = "changed"')
			helpers.assert_contains(encoded, 'quoted = "1979-05-27"')
		end)

		helpers.it("threads temporal receipts through inline records and arrays with exact owners", function()
			local document, receipt = Codec.decode_with_shapes('rows = [1979-05-27, { time = 07:32:00.123456 }]\n')
			local encoded = Codec.encode_with_shapes(document, receipt)
			helpers.assert_contains(encoded, 'rows = [1979-05-27, { time = 07:32:00.123456 }]')
			local second = Codec.decode('date = 1979-05-27\n')
			helpers.assert_eq(Codec.encode_value_with_shapes(second.date, receipt, second, "date"), '"1979-05-27"')
		end)
	end)
end
