--- tests/unit/meta/test_json_unicode_round_trip.lua

--- ==============================================================================
--- MODULE: JSON Text Outside ASCII, Both Ways
--- DESCRIPTION:
--- Predictions are French, and servers written in Python escape every
--- non-ASCII character by default ("é"). The LLM bridge kept its own copy
--- of the decoder with string.char, which raises above 255 on LuaJIT: the
--- whole stream line holding "é" was dropped. Neither decoder joined a
--- surrogate pair, so an emoji became two invalid code points, and the encoder
--- sent other control characters raw, which a strict server rejects.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Bridge = helpers.load_module("infra.llm_bridge")

for _, codec in ipairs({
	{ name = "shared json", decode = Json.decode, encode = Json.encode },
	{ name = "llm bridge", decode = Bridge.json_decode, encode = Bridge.json_encode },
}) do
	helpers.describe(codec.name .. ": text outside ASCII", function()

		helpers.it("decodes an escaped accented letter", function()
			helpers.assert_eq(codec.decode('"caf\\u00e9 \\u2019"'), "café ’")
		end)

		helpers.it("joins a surrogate pair into one character", function()
			helpers.assert_eq(codec.decode('"\\ud83d\\ude00"'), "😀")
		end)

		helpers.it("replaces a lone surrogate instead of emitting invalid UTF-8", function()
			helpers.assert_eq(codec.decode('"a\\ud83db"'), "a\239\191\189b")
		end)

		helpers.it("keeps an escaped newline", function()
			helpers.assert_eq(codec.decode('"a\\u000ab"'), "a\nb")
		end)

		helpers.it("escapes every control character when encoding", function()
			local encoded = codec.encode("a\1b\8c\12d")
			helpers.assert_eq(encoded, '"a\\u0001b\\bc\\fd"')
			helpers.assert_eq(codec.decode(encoded), "a\1b\8c\12d")
		end)

		helpers.it("round-trips French text with raw UTF-8", function()
			local text = "Ça « marche » — déjà vu"
			helpers.assert_eq(codec.decode(codec.encode(text)), text)
		end)

	end)
end

helpers.describe("llm bridge: a streamed line with an escaped accent", function()
	helpers.it("is parsed, not dropped", function()
		helpers.assert_eq(Bridge.parse_stream_line('{"message":{"content":"\\u00e9t\\u00e9"},"done":false}'), "été")
	end)
end)
