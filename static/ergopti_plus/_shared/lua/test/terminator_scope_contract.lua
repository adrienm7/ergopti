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
