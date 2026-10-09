--- tests/unit/infra/test_hs_json_stub_contract.lua

--- ==============================================================================
--- MODULE: Hammerspoon JSON Stub Control Escape Contract
--- DESCRIPTION:
--- Keeps independently authored JSON control bytes distinct from literal escape
--- examples when the native stub reads unchanged golden corpora.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("hs.json stub: control escape bytes", function()
	helpers.it("decodes backspace and form feed as independent byte expectations", function()
		local codec = dofile("tests/stubs/hs.lua").json
		local actual = codec.decode([=["Back\bform\f"]=])
		helpers.assert_eq(actual, "Back" .. string.char(8) .. "form" .. string.char(12))
	end)

	helpers.it("preserves escaped backslashes in literal control escape examples", function()
		local codec = dofile("tests/stubs/hs.lua").json
		local actual = codec.decode([=["Back\\bform\\f"]=])
		helpers.assert_eq(actual, [=[Back\bform\f]=])
	end)
end)


helpers.describe("hs.json stub: portable numeric interning", function()
	local function fresh_codec()
		return dofile("tests/stubs/hs.lua").json
	end
	helpers.it("decodes independently authored integral, fractional and exponent values", function()
		local decoded = fresh_codec().decode('{"version":1,"fraction":1.5,"exponent":1e2,"negative":-2}')
		helpers.assert_type(decoded, "table")
		helpers.assert_eq(decoded, { version = 1, fraction = 1.5, exponent = 100, negative = -2 })
	end)
	helpers.it("shares numerically equal JSON objects as LuaSkin does on both number models", function()
		local decoded = fresh_codec().decode('[{"value":1},{"value":1.0},{"value":1e0},{"value":1.5}]')
		helpers.assert_type(decoded, "table")
		helpers.assert_eq(#decoded, 4)
		helpers.assert_true(rawequal(decoded[1], decoded[2]), "1 and 1.0 compare equal")
		helpers.assert_true(rawequal(decoded[1], decoded[3]), "1 and 1e0 compare equal")
		helpers.assert_true(not rawequal(decoded[1], decoded[4]), "1.5 remains a distinct object")
	end)
	helpers.it("does not turn number arrays into equal-looking objects", function()
		local decoded = fresh_codec().decode('{"array":[1],"object":{"value":1},"twin":[1.0]}')
		helpers.assert_type(decoded, "table")
		helpers.assert_true(rawequal(decoded.array, decoded.twin), "equal native arrays share")
		helpers.assert_true(not rawequal(decoded.array, decoded.object), "array and object remain distinct")
	end)
	helpers.it("decodes a numeric record when distinct numeric-kind APIs are absent", function()
		local codec = fresh_codec()
		local prior_kind, prior_integer = math.type, math.tointeger
		math.type, math.tointeger = nil, nil
		local ok, decoded = pcall(codec.decode, '{"version":1}')
		math.type, math.tointeger = prior_kind, prior_integer
		helpers.assert_true(ok)
		helpers.assert_eq(decoded, { version = 1 })
	end)
end)
