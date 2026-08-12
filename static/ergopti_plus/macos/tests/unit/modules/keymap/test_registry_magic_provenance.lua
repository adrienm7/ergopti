--- tests/unit/modules/keymap/test_registry_magic_provenance.lua

--- ============================================================================
--- MODULE: Registry Magic Trigger Provenance
--- DESCRIPTION:
--- Proves that canonical magic ownership survives repeated key changes while a
--- literal trigger ending in a former key is never adopted and renamed.
--- ============================================================================

local helpers = require("tests.helpers")


local function fresh_registry(magic)
	local State = helpers.load_with_stubs("modules.keymap.state")
	local Registry = helpers.load_with_stubs("modules.keymap.registry")
	local state = State.new({ trigger_char = magic, expansion_delay = 0.4 }, {})
	state.magic_key = magic
	Registry.init(state)
	return Registry, state
end


helpers.describe("registry magic ownership is provenance, not a suffix guess", function()
	helpers.it("renames only the canonical family across two key changes", function()
		local Registry, state = fresh_registry("★")
		Registry.add("owned★", "OWNED", { is_case_sensitive = true })
		Registry.add("literal§", "LITERAL", { is_case_sensitive = true })
		Registry.update_trigger_char("§")
		Registry.update_trigger_char("µ")

		local by_replacement = {}
		for _, mapping in ipairs(state.mappings) do
			by_replacement[mapping.repl] = mapping
		end
		helpers.assert_eq(by_replacement.OWNED.trigger, "ownedµ")
		helpers.assert_true(by_replacement.OWNED.has_magic)
		helpers.assert_eq(by_replacement.LITERAL.trigger, "literal§",
			"a literal suffix matching the first custom key must not be adopted later")
		helpers.assert_eq(by_replacement.LITERAL.has_magic, false)
	end)

	helpers.it("accepts explicit provenance for already-substituted dynamic entries", function()
		local Registry, state = fresh_registry("§")
		Registry.add("06§", "PHONE", {
			is_case_sensitive = true,
			is_magic_trigger = true,
		})
		Registry.update_trigger_char("µ")
		helpers.assert_eq(state.mappings[1].trigger, "06µ")
		helpers.assert_true(state.mappings[1].has_magic)
	end)
end)
