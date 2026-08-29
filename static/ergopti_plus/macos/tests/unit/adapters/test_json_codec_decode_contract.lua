--- tests/unit/adapters/test_json_codec_decode_contract.lua

--- ==============================================================================
--- MODULE: JsonCodec Decode Contract Tests
--- DESCRIPTION:
--- Exercises the production adapter against the native hs.json.decode result
--- shape, where both malformed JSON and a valid top-level null yield Lua nil.
--- ==============================================================================

local helpers = require("tests.helpers")

local logs = {}
local native_calls = {}
local logger = helpers.make_logger_stub()
logger.error = function(_, format_string, ...)
	logs[#logs + 1] = string.format(format_string, ...)
end

local previous_logger = package.loaded["infra.logger"]
package.loaded["infra.logger"] = logger
local JsonCodec = helpers.load_with_stubs("adapters.json_codec", {
	json = {
		encode = function() return "{}" end,
		decode = function(raw)
			native_calls[#native_calls + 1] = raw
			if raw == "false" then return false end
			if raw == "{\"ok\":true}" then return { ok = true } end
			if raw == "throw" then error("native decode raised") end
			return nil
		end,
	},
})
package.loaded["infra.logger"] = previous_logger

local function pack(...)
	return { n = select("#", ...), ... }
end

local function reset_observations()
	logs = {}
	native_calls = {}
end

helpers.describe("JsonCodec.decode result contract", function()
	helpers.it("preserves valid top-level null as a successful nil value", function()
		reset_observations()
		local result = pack(JsonCodec.decode(" \t null\r\n"))

		helpers.assert_eq(result.n, 2)
		helpers.assert_eq(result[1], nil)
		helpers.assert_eq(result[2], nil)
		helpers.assert_eq(#native_calls, 1)
		helpers.assert_eq(native_calls[1], " \t null\r\n")
		helpers.assert_eq(#logs, 0)
	end)

	helpers.it("preserves false and ordinary decoded values", function()
		reset_observations()
		local false_result = pack(JsonCodec.decode("false"))
		local object_result = pack(JsonCodec.decode("{\"ok\":true}"))

		helpers.assert_eq(false_result.n, 2)
		helpers.assert_eq(false_result[1], false)
		helpers.assert_eq(false_result[2], nil)
		helpers.assert_eq(object_result[1].ok, true)
		helpers.assert_eq(object_result[2], nil)
	end)

	helpers.it("reports a native nil for malformed JSON as a decode failure", function()
		reset_observations()
		local result = pack(JsonCodec.decode("{broken"))

		helpers.assert_eq(result.n, 2)
		helpers.assert_eq(result[1], nil)
		helpers.assert_eq(type(result[2]), "string")
		helpers.assert_true(result[2] ~= "", "malformed JSON must carry a diagnostic")
		helpers.assert_eq(#logs, 1)
		helpers.assert_true(not logs[1]:find("{broken", 1, true),
			"decode diagnostics must not expose response contents")
	end)

	helpers.it("accepts only RFC JSON whitespace around null", function()
		reset_observations()
		local _, err = JsonCodec.decode("\vnull")

		helpers.assert_eq(type(err), "string")
		helpers.assert_true(err ~= "", "vertical tab is not JSON whitespace")
		helpers.assert_eq(#logs, 1)
	end)

	helpers.it("contains native decoder exceptions", function()
		reset_observations()
		local value, err = JsonCodec.decode("throw")

		helpers.assert_eq(value, nil)
		helpers.assert_contains(err, "native decode raised")
		helpers.assert_eq(#logs, 1)
	end)
end)
