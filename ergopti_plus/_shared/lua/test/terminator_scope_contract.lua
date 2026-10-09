--- _shared/lua/test/terminator_scope_contract.lua

--- Runs the same delimiter restoration policy through both Lua drivers' leaf
--- planners. Expectations are explicit and independent of the production plan.
return function(helpers, select_leaves)
	local Scope = require("hotstrings.terminator_scope")
	select_leaves = select_leaves or Scope.builtin_state_leaves

	helpers.describe("shared delimiter scope behavior (hotstrings-delimiter-scope-parity)", function()
		helpers.it("inherits enabled and disabled defaults without owning personal entries", function()
			local defaults = Scope.defaults()
			helpers.assert_eq(defaults.space, true)
			helpers.assert_eq(defaults.slash, false)
			helpers.assert_eq(defaults.star, true)
			helpers.assert_true(next(defaults) ~= nil, "the catalogue must not be empty")
			defaults.space = false
			defaults.custom_personal = true
			helpers.assert_eq(Scope.defaults().space, true, "callers cannot mutate the source defaults")
			helpers.assert_nil(Scope.defaults().custom_personal)
		end)

		helpers.it("selects only shipped states in deterministic order and never rewrites the input", function()
			local document = { hotstrings = {
				terminator_states = { space = false, slash = true, ["custom_¤"] = false, retired = true },
				terminators = { { key = "custom_¤", char = "¤", label = "¤", consume = true } },
				unknown = "kept",
			} }
			local expected = {
				{ "hotstrings", "terminator_states", "slash" },
				{ "hotstrings", "terminator_states", "space" },
			}
			helpers.assert_eq(select_leaves(document), expected)
			helpers.assert_eq(document.hotstrings.terminator_states,
				{ space = false, slash = true, ["custom_¤"] = false, retired = true })
			helpers.assert_eq(document.hotstrings.terminators,
				{ { key = "custom_¤", char = "¤", label = "¤", consume = true } })
			helpers.assert_eq(document.hotstrings.unknown, "kept")
		end)

		helpers.it("replays independent personal preservation vectors without taking ownership", function()
			local shared = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
				:match("^(.*)/lua/test/[^/]+$")
			local path = assert(shared, "the shared tree encloses this contract")
				.. "/tests/corpus/hotstrings/terminator_restoration_vectors.json"
			local handle = assert(io.open(path, "rb"))
			local content = handle:read("*a")
			handle:close()
			local vectors = assert(require("json").decode(content))
			helpers.assert_eq(#vectors, 4, "all independent preservation vectors execute")
			for _, vector in ipairs(vectors) do
				local states = {}
				for key, value in pairs(vector.states) do states[key] = value end
				local expected_custom = assert(require("json").decode(require("json").encode(vector.custom)))
				local document = { hotstrings = {
					terminator_states = states, terminators = vector.custom, unknown = "kept",
				} }
				for _, leaf in ipairs(select_leaves(document)) do states[leaf[3]] = nil end
				helpers.assert_eq(states, vector.expected_personal, vector.id)
				helpers.assert_eq(document.hotstrings.terminators, expected_custom, vector.id)
				helpers.assert_eq(document.hotstrings.unknown, "kept", vector.id)
				local defaults = Scope.defaults()
				helpers.assert_eq(defaults.space, true, vector.id)
				helpers.assert_eq(defaults.slash, false, vector.id)
				helpers.assert_eq(defaults.star, true, vector.id)
			end
		end)

		helpers.it("leaves absent, malformed and personal-only state tables to their owners", function()
			for _, document in ipairs({ {}, { hotstrings = false }, { hotstrings = {} },
				{ hotstrings = { terminator_states = false } },
				{ hotstrings = { terminator_states = { "space", "slash" } } },
				{ hotstrings = { terminator_states = { custom_personal = false, retired = true } } },
			}) do
				helpers.assert_eq(select_leaves(document), {})
			end
		end)
	end)
end
