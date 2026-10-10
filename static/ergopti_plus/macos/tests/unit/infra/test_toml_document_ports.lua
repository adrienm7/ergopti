--- tests/unit/infra/test_toml_document_ports.lua

--- ==============================================================================
--- MODULE: Original TOML Document Constructor Ports
--- DESCRIPTION:
--- Fixed whole-document port identity and independent source-kind expectations.
--- ==============================================================================

local helpers = require("tests.helpers")
local codec = require("toml_codec.codec")
helpers.describe("original TOML document port tuple", function()
helpers.it("original document constructor tuple", function()
	local owner, decoder, encoder, shaped = codec.document_ports()
	assert(owner == codec and decoder == codec.decode_with_shapes and encoder == codec.encode and shaped == codec.encode_with_shapes)
end)
helpers.it("mutable role alias cannot alter retained constructor tuple", function()
	local owner, decoder, encoder, shaped = codec.document_ports()
	codec.encode = codec.encode_value; codec.encode_with_shapes = codec.encode_value_with_shapes
	local ok, err = pcall(function()
		local current, same_decoder, same_encoder, same_shaped = codec.document_ports()
		assert(current == owner and same_decoder == decoder and same_encoder == encoder and same_shaped == shaped)
		assert(same_encoder ~= codec.encode and same_shaped ~= codec.encode_with_shapes)
	end)
	codec.encode, codec.encode_with_shapes = encoder, shaped
	if not ok then error(err, 0) end
end)
helpers.it("original document ports retain independent typed source", function()
	local owner, decoder, encoder, shaped = codec.document_ports()
	local document, shapes = decoder('[karabiner]\nruntime = "owned"\n[future]\nempty = []\nkind = 1.0\ninteger = 9_223_372_036_854_775_807\n')
	assert(document and shapes)
	document.karabiner.runtime = nil
	local bytes = shaped(document, shapes)
	assert(bytes:find('empty = []', 1, true) and bytes:find('kind = 1.0', 1, true) and bytes:find('integer = 9_223_372_036_854_775_807', 1, true))
	local roundtrip = decoder(bytes)
	assert(type(roundtrip.future) == 'table' and roundtrip.future.integer == 9223372036854775807)
	assert(encoder({ future = { answer = 42 } }):find('[future]', 1, true))
end)
end)
