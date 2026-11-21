--- _shared/tests/lua/hotstrings/magic_key_contract.lua

--- Replays the magic key's layout default and display rules on both Lua
--- drivers. Windows replays the same corpus through the AHK twin
--- (windows/tests/unit/hotstrings/test_magic_key_rules.ahk) and the hotstring
--- editor through tools/test/test-magic-key-rules.cjs.
--- @param helpers table Driver test helpers.
--- @param json table Shared JSON codec.
--- @param shared_root string Absolute shared source directory.
return function(helpers, json, shared_root)
	local MagicKey = require("hotstrings.engine.magic_key")
	local function read(path)
		local handle = assert(io.open(shared_root .. path, "rb"))
		local text = handle:read("*a")
		handle:close()
		return json.decode(text)
	end
	local rules = MagicKey.new(read("/hotstrings/data/magic_key.json"))
	local corpus = read("/tests/corpus/hotstrings/magic_key_vectors.json")

	helpers.describe("magic key shared rules", function()
		for _, vector in ipairs(corpus.layout_default) do
			helpers.it("(magic-key-default) " .. vector.id, function()
				local magic, family = rules:layout_default(function(code) return vector.base[code] end, corpus.fallback)
				helpers.assert_eq(vector.expected, magic)
				-- A null family decodes to an absent member: the fallback.
				helpers.assert_eq(vector.family, family)
			end)
		end
		for _, vector in ipairs(corpus.display) do
			helpers.it("(magic-key-display) " .. vector.id, function()
				helpers.assert_eq(vector.expected, rules:display_text(vector.text, vector.char, vector.key))
			end)
		end
		helpers.it("(magic-key-display) a configured character is never shown alone", function()
			helpers.assert_eq("★ (ù)", rules:display("ù"))
			helpers.assert_eq("★", rules:display("★"))
		end)
		helpers.it("(magic-key-data) invalid data is refused", function()
			helpers.assert_throws(function() MagicKey.new({ marker = "★", display_format = "★", layout_families = {}, literal_marker_keys = {} }) end)
			helpers.assert_throws(function() MagicKey.new(nil) end)
		end)
	end)
end
