-- static/ergopti_plus/macos/tests/unit/infra/toml/test_toml_codec_decode_memo.lua

--- ==============================================================================
--- MODULE: TOML Codec Decode Memo Tests
--- DESCRIPTION:
--- One preferences save decoded the same config.toml text 17 times, about
--- 100 ms of a 246 ms save under Lua 5.4 (measured). decode_with_shapes now
--- keeps the newest decoded texts and hands every caller a private deep copy.
--- These cases pin both halves: the repeated text is not parsed again, and no
--- caller can observe or corrupt another caller's document or receipts.
--- ==============================================================================

local helpers = require("tests.helpers")

local SOURCE = '[owner]\ncount = 1_000\nnames = ["a", "b"]\nnested = { list = [] }\n'

--- Counts key-path parses while one callback runs; every decoded assignment
--- line parses its key, so a real decode can never report zero.
--- @param callback function Work to observe.
--- @return number parses Key-path parses performed by the callback.
local function count_key_parses(callback)
	local KeyPath = require("toml_codec.key_path")
	local original = KeyPath.parse
	local parses = 0
	KeyPath.parse = function(...)
		parses = parses + 1
		return original(...)
	end
	local ok, failure = pcall(callback)
	KeyPath.parse = original
	if not ok then error(failure, 0) end
	return parses
end

helpers.describe("TOML codec decode memo", function()
	helpers.it("does not parse a text it decoded a moment ago", function()
		local Codec = require("toml_codec.codec")
		local text = SOURCE .. "# memo probe " .. tostring(os.clock()) .. "\n"
		helpers.assert_true(count_key_parses(function() Codec.decode_with_shapes(text) end) > 0,
			"the first decode of a text must parse it")
		helpers.assert_eq(count_key_parses(function() Codec.decode_with_shapes(text) end), 0,
			"the repeated text must be served from the memo")
	end)

	helpers.it("hands every caller an independent document bound to its own receipts", function()
		local Codec = require("toml_codec.codec")
		local first, first_shapes = Codec.decode_with_shapes(SOURCE)
		first.owner.names[1] = "mutated"
		first.owner.count = 7
		local second, second_shapes = Codec.decode_with_shapes(SOURCE)
		helpers.assert_true(second ~= first, "each caller receives its own document")
		helpers.assert_eq(second.owner.names[1], "a")
		helpers.assert_eq(second.owner.count, 1000)
		helpers.assert_true(second_shapes.document == second, "receipts name the returned document")
		helpers.assert_eq(second_shapes.arrays[second.owner.names], true)
		helpers.assert_eq(second_shapes.arrays[second.owner.nested.list], true)
		helpers.assert_nil(second_shapes.arrays[first.owner.names], "receipts never name another caller's tables")
		helpers.assert_nil(first_shapes.arrays[second.owner.names])
		helpers.assert_true(Codec.encode_with_shapes(second, second_shapes):find("count = 1_000", 1, true) ~= nil,
			"the copied numeric receipt still restores the source token")
	end)

	helpers.it("keeps refusing a malformed text and still decodes texts evicted from the memo", function()
		local Codec = require("toml_codec.codec")
		for _ = 1, 2 do
			local document, shapes = Codec.decode_with_shapes("[owner]\nvalue = 1\nvalue = 2\n")
			helpers.assert_nil(document)
			helpers.assert_nil(shapes)
		end
		for round = 1, 2 do
			for index = 1, 6 do
				local document = Codec.decode_with_shapes("[t]\nvalue = " .. index .. "\n")
				helpers.assert_eq(document.t.value, index, "text " .. index .. " in round " .. round)
			end
		end
	end)
end)
