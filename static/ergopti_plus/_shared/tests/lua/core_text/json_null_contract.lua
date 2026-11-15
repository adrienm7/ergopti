--- _shared/tests/lua/core_text/json_null_contract.lua
--- What the shared JSON decoder gives for null, run by the macOS and Linux suites.
--- The default decode used `(val == NULL) and nil or val`, which always gives
--- val: every null became one shared empty table, in objects, in arrays and at
--- the root. Now a null member is absent, a null element leaves a hole at its
--- position and a null root gives nil; decode_lossless keeps its null token.
return function(helpers, Json)
	helpers.describe("shared JSON decoder: null", function()
		helpers.it("a null member is absent, its siblings kept (json-null)", function()
			local decoded = Json.decode('{"gone":null,"kept":1}')
			helpers.assert_eq(rawget(decoded, "gone"), nil)
			helpers.assert_eq(decoded.kept, 1)
			helpers.assert_eq(next(Json.decode('{"a":null,"b":null}')), nil)
		end)

		helpers.it("a null element leaves a hole and keeps the later positions (json-null)", function()
			local decoded = Json.decode('[1,null,3]')
			helpers.assert_eq(decoded[1], 1)
			helpers.assert_eq(rawget(decoded, 2), nil)
			helpers.assert_eq(decoded[3], 3)
			local leading = Json.decode('[null,{},[]]')
			helpers.assert_eq(rawget(leading, 1), nil)
			helpers.assert_eq(type(leading[2]), "table")
			helpers.assert_eq(type(leading[3]), "table")
		end)

		helpers.it("two nulls are never one shared table (json-null)", function()
			local decoded = Json.decode('{"list":[null,null],"value":null}')
			helpers.assert_eq(rawget(decoded, "value"), nil)
			helpers.assert_eq(rawget(decoded.list, 1), nil)
			helpers.assert_eq(rawget(decoded.list, 2), nil)
		end)

		helpers.it("a null root decodes to nil (json-null)", function()
			helpers.assert_eq(Json.decode("null"), nil)
			helpers.assert_eq(Json.decode("  null  "), nil)
		end)

		helpers.it("the lossless decode still keeps every null (json-null)", function()
			local decoded = Json.decode_lossless('{"error":null,"list":[1,null]}')
			helpers.assert_true(Json.is_null(decoded.error))
			helpers.assert_true(Json.is_null(decoded.list[2]))
			helpers.assert_eq(#decoded.list, 2)
			helpers.assert_true(Json.is_null(Json.decode_lossless("null")))
		end)
	end)
end
