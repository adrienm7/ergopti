--- tests/unit/lib/test_toml_inline_object_roundtrip.lua

--- ==============================================================================
--- MODULE: TOML Dictionary Array Member Regressions
--- DESCRIPTION:
--- Preserves every field of dictionary members without changing section output.
--- ==============================================================================

local helpers = require("tests.helpers")
local codec = require("toml_codec")
local cases = {
	{ name = "distinct objects", value = { items = {
		{ name = "first", enabled = false, count = 0 },
		{ name = "second", enabled = true, count = 2 },
	} } },
	{ name = "nested dictionaries and arrays", value = { items = {
		{ config = { tuning = { value = 1.25 } }, tags = { "one", "two" }, children = { { id = "child" } } },
	} } },
	{ name = "quoted keys and delimiter data", value = { items = {
		{ ["space key"] = "a,b#c{d}", ["dot.key"] = "line\nnext", ["accenté"] = "tab\tend", ['quote"key'] = 'quote"\\end' },
	} } },
	{ name = "empty object members", value = { items = { {}, { child = {} } } } },
	{ name = "scalar arrays", value = { values = { 1, false, "literal" } } },
	{ name = "ordinary sections", value = { settings = { name = "section", nested = { enabled = true } } } },
}

helpers.describe("TOML dictionary array members", function()
	for _, case in ipairs(cases) do
		helpers.it("(toml-inline-object) preserves " .. case.name, function()
			local encoded = codec.encode(case.value)
			local decoded = codec.decode(encoded)
			helpers.assert_eq(decoded, case.value, "all keys and independently typed values must survive")
			if case.name == "ordinary sections" then
				helpers.assert_true(encoded:find("[settings]", 1, true) ~= nil)
				helpers.assert_true(encoded:find("[settings.nested]", 1, true) ~= nil)
			end
		end)
	end
	helpers.it("(toml-inline-object) orders keys independently of insertion order", function()
		local first, second = {}, {}
		first.z, first.a = 2, 1
		second.a, second.z = 1, 2
		local encoded = codec.encode({ items = { first } })
		helpers.assert_eq(encoded, codec.encode({ items = { second } }))
		helpers.assert_true(encoded:find("{ a = 1, z = 2 }", 1, true) ~= nil,
			"determinism must preserve the object, not compare two empty maps")
	end)
end)
