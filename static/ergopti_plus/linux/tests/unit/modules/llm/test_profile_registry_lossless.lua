--- tests/unit/modules/llm/test_profile_registry_lossless.lua

local helpers = require("tests.helpers")
local Json = require("json")
local Base64 = require("compat.base64")
local Registry = require("modules.llm.profile_registry_codec")

helpers.describe("lossless profile JSON", function()
	helpers.it("preserves opaque null objects and arrays through the actual registry envelope", function()
		local raw = '[null,{},[],{"a":null,"b":[],"c":[{},null,[]]}]'
		local records = Registry.decode("v1:" .. Base64.encode(raw))
		helpers.assert_eq(Base64.decode(Registry.encode(records):sub(4)), raw)
	end)

	helpers.it("preserves unknown nested data when another profile is appended", function()
		local raw = '[{"future":{"a":null,"b":[],"c":{}},"id":"future_profile"}]'
		local records = Registry.decode("v1:" .. Base64.encode(raw))
		records[#records + 1] = { id = "user_new", label = "New", system_single = "Continue", batch = false }
		local stored = Registry.decode(Registry.encode(records))
		helpers.assert_eq(Json.encode(stored[1]), raw:sub(2, -2))
		helpers.assert_eq(stored[2].id, "user_new")
	end)

	helpers.it("distinguishes null empty object and empty array at every nesting level", function()
		local records = Json.decode_lossless('[null,{},[],[null,{},[]]]')
		helpers.assert_true(Json.is_array(records))
		helpers.assert_true(Json.is_null(records[1]))
		helpers.assert_eq(Json.is_array(records[2]), false)
		helpers.assert_true(Json.is_array(records[3]))
		helpers.assert_true(Json.is_null(records[4][1]))
		helpers.assert_eq(Json.encode(records), '[null,{},[],[null,{},[]]]')
	end)

	helpers.it("constructs detached dense arrays including the empty known-field value", function()
		local source = { "STOP", "END" }
		local array = Json.array(source)
		source[1] = "changed"
		helpers.assert_eq(Json.encode(array), '["STOP","END"]')
		helpers.assert_true(Json.is_array(array))
		helpers.assert_eq(Json.encode(Json.array({})), '[]')
		helpers.assert_eq(Json.encode({}), '{}')
	end)

	helpers.it("refuses holes maps and null as constructed arrays", function()
		local hole = { "first", "second", "third" }; hole[2] = nil
		for _, value in ipairs({ hole, { name = "map" }, Json.decode_lossless("null"), "array" }) do
			local failure = helpers.assert_throws(function() Json.array(value) end)
			helpers.assert_contains(failure, "JSON arrays require dense numeric values")
		end
	end)

	helpers.it("does not turn a mutated tagged array into an object or silently truncate it", function()
		local hole = Json.array({ "first", "second", "third" }); hole[2] = nil
		local map = Json.array({}); map.name = "foreign"
		helpers.assert_nil(Json.encode(hole))
		helpers.assert_nil(Json.encode(map))
	end)

	helpers.it("keeps the neutral registry sparse and still rejects invalid envelope shapes", function()
		helpers.assert_eq(Registry.encode(Registry.decode("")), "")
		helpers.assert_eq(Registry.encode(Registry.decode("v1:" .. Base64.encode("[]"))), "")
		for _, row in ipairs({
			{ "v2:W10=", "unknown user profile registry version" },
			{ "v1:!!!!", "invalid user profile base64 envelope" },
			{ "v1:" .. Base64.encode("null"), "user profile JSON must be an array" },
			{ "v1:" .. Base64.encode("{}"), "user profile JSON must be an array" },
			{ "v1:" .. Base64.encode("[null,]"), "user profile registry must be an array" },
			{ "v1:" .. Base64.encode("[{}]garbage"), "user profile registry must be an array" },
		}) do
			local failure = helpers.assert_throws(function() Registry.decode(row[1]) end, row[1])
			helpers.assert_contains(failure, row[2])
		end
	end)

	helpers.it("refuses malformed input in the explicit lossless decoder", function()
		for _, raw in ipairs({ "", "[", "[1,]", '{"a":}', '["\\q"]', '["raw\nnewline"]',
			'[01]', '[1.]', '[1e]', '[1e9999]', '["\\uD800"]', '{"a":1,"a":2}' }) do
			helpers.assert_nil(Json.decode_lossless(raw), raw)
		end
	end)

	helpers.it("round trips valid Unicode escapes booleans numbers and escaped controls", function()
		local decoded = Json.decode_lossless('["caf\\u00e9 \\ud83d\\ude00",false,true,-1.5e2,"\\n"]')
		helpers.assert_eq(decoded[1], "café 😀")
		helpers.assert_eq(Json.encode(decoded), '["café 😀",false,true,-150,"\\n"]')
	end)

	helpers.it("preserves the default decoder and untagged encoder contract", function()
		helpers.assert_eq(Json.encode(Json.decode('[null,{},[]]')), '[{},{},{}]')
		helpers.assert_eq(Json.encode(Json.decode('null')), '{}')
		helpers.assert_eq(Json.decode('"\\q"'), 'q')
		helpers.assert_eq(Json.decode('"\\ud800"'), '\239\191\189')
		helpers.assert_eq(Json.encode({ "one", "two" }), '["one","two"]')
		helpers.assert_eq(Json.encode({}), '{}')
		helpers.assert_nil(Json.decode('[1,]'))
	end)
end)
