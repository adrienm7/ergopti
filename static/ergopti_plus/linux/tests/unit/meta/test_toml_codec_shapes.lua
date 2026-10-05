--- tests/unit/meta/test_toml_codec_shapes.lua

--- ==============================================================================
--- MODULE: Canonical TOML Shape Receipts
--- DESCRIPTION:
--- Independent handwritten source controls verify optional array identity
--- evidence, including empty/nested arrays, without changing the default model
--- or the existing codec's default encoding contract.
--- ==============================================================================

local helpers = require("tests.helpers")
local Codec = require("toml_codec")

helpers.describe("canonical TOML optional shape receipts", function()
	helpers.it("retains exact nested and empty array identities separately from empty dictionaries", function()
		local source = 'empty = []\nmap = {}\nrows = [{ empty = [], map = {}, nested = [[], {}] }]\n'
			.. '[owned]\n"quoted.dot" = []\n[[records]]\nempty = []\n[[records]]\nmap = {}\n'
		local document, shapes = Codec.decode_with_shapes(source)
		helpers.assert_eq(document, Codec.decode(source), "the ordinary Lua value model is unchanged")
		helpers.assert_nil(getmetatable(document))
		for _, value in ipairs({ document.empty, document.rows, document.rows[1].empty,
			document.rows[1].nested, document.rows[1].nested[1], document.owned["quoted.dot"],
			document.records, document.records[1].empty }) do
			helpers.assert_eq(shapes.arrays[value], true, "each exact parsed array owns a receipt identity")
			helpers.assert_nil(getmetatable(value))
		end
		for _, value in ipairs({ document.map, document.rows[1], document.rows[1].map,
			document.rows[1].nested[2], document.records[1], document.records[2].map }) do
			helpers.assert_nil(shapes.arrays[value], "maps must not acquire array authority")
		end
		helpers.assert_eq(Codec.encode_value_with_shapes(document.empty, shapes), "[]")
		helpers.assert_eq(Codec.encode_value(document.empty), "{  }", "default encoder remains unchanged")
		helpers.assert_eq(Codec.encode_value_with_shapes(document.rows, shapes),
			'[{ empty = [], map = {  }, nested = [[], {  }] }]')
		local rendered = Codec.decode('rows = ' .. Codec.encode_value_with_shapes(document.rows, shapes))
		helpers.assert_eq(rendered.rows, document.rows)
	end)

	helpers.it("keeps multiline arrays and quoted array-looking strings distinct", function()
		local document, shapes = Codec.decode_with_shapes('value = [\n [],\n { empty = [] },\n]\ntext = "[]"\n')
		helpers.assert_eq(shapes.arrays[document.value], true)
		helpers.assert_eq(shapes.arrays[document.value[1]], true)
		helpers.assert_eq(shapes.arrays[document.value[2].empty], true)
		helpers.assert_nil(shapes.arrays[document.value[2]])
		helpers.assert_eq(document.text, "[]")
	end)

	helpers.it("exposes no partial receipt on malformed input and owns independent decode generations", function()
		for _, source in ipairs({ 'value = [', 'value = [{ empty = [] }, \"broken]', 'value = []\nvalue = {}\n' }) do
			local document, shapes = Codec.decode_with_shapes(source)
			helpers.assert_nil(document)
			helpers.assert_nil(shapes)
			helpers.assert_nil(Codec.decode(source))
		end
		local first, first_shapes = Codec.decode_with_shapes('value = []\n')
		local second, second_shapes = Codec.decode_with_shapes('value = []\n')
		helpers.assert_eq(first_shapes.arrays[first.value], true)
		helpers.assert_eq(second_shapes.arrays[second.value], true)
		helpers.assert_nil(first_shapes.arrays[second.value])
		helpers.assert_nil(second_shapes.arrays[first.value])
		helpers.assert_eq(Codec.decode_with_shapes(''), {})
	end)
	helpers.it("rejects mutations that would discard data through an array receipt", function()
		local document, shapes = Codec.decode_with_shapes('value = [1, 2]\n')
		document.value.named = "must not disappear"
		local named_error = helpers.assert_throws(function() Codec.encode_value_with_shapes(document.value, shapes) end)
		helpers.assert_true(tostring(named_error):find("TOML array receipt cannot discard named or invalid slots", 1, true) ~= nil)
		document.value.named = nil
		document.value[1] = nil
		local sparse_error = helpers.assert_throws(function() Codec.encode_value_with_shapes(document.value, shapes) end)
		helpers.assert_true(tostring(sparse_error):find("TOML array receipt requires dense slots", 1, true) ~= nil)
		document.value[1] = 1
		helpers.assert_eq(Codec.encode_value_with_shapes(document.value, shapes), "[1, 2]", "repaired same receipt remains retryable")
	end)

end)

local Loader = require("platform.remap.tap_hold_loader")
local DEFAULTS = require("infra.paths").shared("tap_hold/defaults.toml")


helpers.describe("tap-hold candidate shape ownership", function()
	helpers.it("refuses a foreign decoder receipt instead of blessing an empty array as a table", function()
		local first, receipt = Codec.decode_with_shapes('[tap_hold.keys]\ncaps_lock = []\n')
		local second = Codec.decode('[tap_hold.keys]\ncaps_lock = []\n')
		local owner_error = helpers.assert_throws(function() Loader.load_document(DEFAULTS, second, nil, "owned.toml", receipt) end)
		helpers.assert_true(tostring(owner_error):find("tap-hold shape receipt belongs to another document", 1, true) ~= nil)
		helpers.assert_nil(Loader.load_document(DEFAULTS, first, nil, "owned.toml", receipt).keys.caps_lock)
	end)
end)

helpers.describe("canonical optional numeric preservation", function()
	helpers.it("round-trips high-precision source numbers without changing default encoding", function()
		local document, receipt = Codec.decode_with_shapes('value = [1.2345678901234567, 0.12345678901234566, -1.23456789012345e-120, 9007199254740993]\n')
		local original_default = Codec.encode_value(document.value)
		local encoded = Codec.encode_value_with_shapes(document.value, receipt)
		local after = Codec.decode('value = ' .. encoded).value
		helpers.assert_eq(after, { 1.2345678901234567, 0.12345678901234566, -1.23456789012345e-120, 9007199254740993 })
		helpers.assert_eq(Codec.encode_value(document.value), original_default, "optional evidence does not mutate the default model")
	end)
end)

helpers.describe("canonical source-bound numeric tokens", function()
	helpers.it("retains unchanged raw numbers and refuses to reuse tokens after a field mutation", function()
		local source = 'maximum = 9223372036854775807\nfloat = 1.0\n'
			.. 'values = [9_223_372_036_854_775_807, 1.2345678901234567e+42, { tiny = -1.23456789012345e-120 }]\n'
		local document, receipt = Codec.decode_with_shapes(source)
		helpers.assert_eq(Codec.encode_value_with_shapes(document.maximum, receipt, document, "maximum"), "9223372036854775807")
		helpers.assert_eq(Codec.encode_value_with_shapes(document.float, receipt, document, "float"), "1.0")
		helpers.assert_eq(Codec.encode_value_with_shapes(document.values, receipt),
			"[9_223_372_036_854_775_807, 1.2345678901234567e+42, { tiny = -1.23456789012345e-120 }]")
		document.float = 2.5
		helpers.assert_eq(Codec.encode_value_with_shapes(document.float, receipt, document, "float"), "2.5", "changed field cannot borrow its old numeric token")
		local second, own = Codec.decode_with_shapes('maximum = 17\n')
		helpers.assert_eq(Codec.encode_value_with_shapes(second.maximum, receipt, second, "maximum"), "17", "foreign parent has no scalar token authority")
		helpers.assert_eq(Codec.encode_value_with_shapes(second.maximum, own, second, "maximum"), "17")
	end)
end)

helpers.describe("canonical special numeric source tokens", function()
	helpers.it("retains signed special-float source tokens through optional evidence", function()
		local document, receipt = Codec.decode_with_shapes('value = [+nan, -nan, +inf, -inf]\n')
		helpers.assert_eq(Codec.encode_value_with_shapes(document.value, receipt), "[+nan, -nan, +inf, -inf]")
	end)
end)

require("test.toml_document_shapes_contract")(helpers)
