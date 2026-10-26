--- _shared/lua/test/hotstring_override_parser_contract.lua

--- The shared override parser answers the same tree on every driver for the
--- vectors of _shared/tests/corpus/hotstrings/override_parse_vectors.json.
return function(helpers)
	local Json = require("json")
	local Overrides = require("hotstrings.overrides")
	local shared = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
		:match("^(.*)/lua/test/[^/]+$")
	assert(shared, "the shared tree must enclose this contract")
	local handle = assert(io.open(shared .. "/tests/corpus/hotstrings/override_parse_vectors.json", "rb"))
	local document = assert(Json.decode(handle:read("*a")))
	handle:close()
	assert(#document.vectors > 0, "the vector corpus must not be empty")

	--- Whether two trees hold the same keys and values.
	local function same(left, right)
		if type(left) ~= "table" or type(right) ~= "table" then return left == right end
		for key, value in pairs(left) do
			if not same(value, right[key]) then return false end
		end
		for key in pairs(right) do
			if left[key] == nil then return false end
		end
		return true
	end

	for _, vector in ipairs(document.vectors) do
		helpers.it("override vector: " .. vector.name, function()
			local ok, tree = pcall(Overrides.parse, vector.content, assert(Overrides.POLICIES[vector.policy], vector.policy))
			if vector.error then
				helpers.assert_eq(ok, false, "invalid TOML must raise")
			else
				assert(ok, tostring(tree))
				assert(same(tree, vector.expect), "the parsed tree differs from the vector")
			end
		end)
	end

	helpers.it("the reserved table name is the one the writers refuse", function()
		helpers.assert_eq(Overrides.RESERVED_TABLE, "__global__")
		helpers.assert_eq(Overrides.normalize_category("EXT.Demo"), "ext.demo")
		helpers.assert_eq(Overrides.normalize_category("a.b"), nil)
		helpers.assert_eq(Overrides.is_delay_offset(0 / 0), false)
		helpers.assert_eq(Overrides.is_delay(-1), false)
		helpers.assert_eq(pcall(Overrides.parse, "[a]\n"), false, "a missing key policy must be refused")
	end)
end
