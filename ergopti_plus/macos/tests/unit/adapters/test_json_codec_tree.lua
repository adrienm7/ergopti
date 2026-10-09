--- tests/unit/adapters/test_json_codec_tree.lua

--- ==============================================================================
--- MODULE: JsonCodec Returns A Tree
--- DESCRIPTION:
--- hs.json.decode converts through LuaSkin, which looks up the objects it
--- already pushed by isEqual: (Skin.m, pushNSObject:withOptions:
--- alreadySeenObjects:): every array or object equal to one met earlier in the
--- same document comes back as that same Lua table. JsonCodec.decode must hand
--- its callers a tree, where editing one value never edits another.
---
--- ROOT CAUSES ENCODED:
--- 1. dev.148 refused every Karabiner deploy on a Mac with « generated rule 1
---    manipulator 3 has inconsistent managed conditions »: CapsWord's 30
---    identical conditions lists were one table, and each manipulator's
---    generation gate was appended to all of them (json-shared-tables).
--- 2. The test stub of hs.json.decode built a fresh table for every value, so
---    no test could see it. The stub now shares equal values as LuaSkin does,
---    and the first case below keeps it that way.
--- ==============================================================================

local helpers = require("tests.helpers")

local DOCUMENT = '{"first": [{"name": "capsword", "value": 1}], "second": [{"name": "capsword", "value": 1}],'
	.. ' "empty_list": [], "empty_object": {}, "other_empty_list": []}'

helpers.with_fresh_modules({ "adapters.json_codec", "infra.logger" }, function()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	local JsonCodec = require("adapters.json_codec")

	--- Whether a table is reachable twice from a decoded value.
	--- @param value any Decoded value.
	--- @param seen table|nil Tables already visited.
	--- @return boolean shared
	local function has_shared_table(value, seen)
		if type(value) ~= "table" then return false end
		seen = seen or {}
		if seen[value] then return true end
		seen[value] = true
		for _, nested in pairs(value) do
			if has_shared_table(nested, seen) then return true end
		end
		return false
	end

	helpers.describe("JsonCodec.decode returns a tree (json-shared-tables)", function()
		helpers.it("the hs.json.decode stub shares equal values as LuaSkin does (json-shared-tables)", function()
			local decoded = hs.json.decode(DOCUMENT)
			helpers.assert_true(rawequal(decoded.first, decoded.second),
				"two equal arrays of one document are one table under Hammerspoon")
			helpers.assert_true(rawequal(decoded.empty_list, decoded.other_empty_list),
				"two empty arrays are equal NSArrays, hence one table")
			helpers.assert_true(not rawequal(decoded.empty_list, decoded.empty_object),
				"an empty array and an empty object are not equal")
		end)

		helpers.it("decode() gives every value its own tables (json-shared-tables)", function()
			local decoded, err = JsonCodec.decode(DOCUMENT)
			helpers.assert_eq(err, nil)
			helpers.assert_true(not has_shared_table(decoded), "no table is reachable twice")
			decoded.first[#decoded.first + 1] = { name = "gate", value = 1 }
			decoded.first[1].value = 0
			helpers.assert_eq(#decoded.second, 1, "appending to one list leaves its equal twin alone")
			helpers.assert_eq(decoded.second[1].value, 1, "editing one entry leaves its equal twin alone")
			decoded.empty_list[1] = "x"
			helpers.assert_eq(#decoded.other_empty_list, 0, "the two empty arrays are distinct")
		end)
	end)
end)
