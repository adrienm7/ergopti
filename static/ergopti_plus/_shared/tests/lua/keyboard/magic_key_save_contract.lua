--- _shared/tests/lua/keyboard/magic_key_save_contract.lua

--- Replays the modifiers + magic key save rule on both Lua drivers. Windows
--- replays the same corpus through the AHK twin
--- (windows/tests/unit/modules/shortcuts/test_magic_key_save.ahk).
--- @param helpers table Driver test helpers.
--- @param json table Shared JSON codec.
--- @param shared_root string Absolute shared source directory.
return function(helpers, json, shared_root)
	local Policy = require("shortcuts.engine.magic_key_save_core")
	local handle = assert(io.open(shared_root .. "/tests/corpus/shortcuts/magic_key_save_vectors.json", "rb"))
	local corpus = json.decode(handle:read("*a"))
	handle:close()

	helpers.describe("modifiers + magic key save shared rule", function()
		helpers.it("(magic-key-save) the corpus sends S", function()
			helpers.assert_eq(corpus.save_key, Policy.SAVE_KEY)
		end)
		for _, vector in ipairs(corpus.vectors) do
			helpers.it("(magic-key-save) " .. vector.id, function()
				local input = { os = vector.os, held = vector.held }
				for gate, value in pairs(corpus.gates) do input[gate] = value end
				for gate, value in pairs(vector.gates or {}) do input[gate] = value end
				local decision = Policy.resolve(input)
				helpers.assert_eq(decision.action, vector.expected.action)
				helpers.assert_eq(decision.reason, vector.expected.reason)
				helpers.assert_eq(decision.sends, vector.expected.sends)
			end)
		end
		helpers.it("(magic-key-save) a modifier the OS lacks is refused", function()
			helpers.assert_throws(function() Policy.decide("windows", { "altgr" }) end)
			helpers.assert_throws(function() Policy.decide("beos", { "ctrl" }) end)
		end)
	end)
end
