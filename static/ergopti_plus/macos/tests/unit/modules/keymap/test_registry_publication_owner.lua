--- tests/unit/modules/keymap/test_registry_publication_owner.lua

--- ==============================================================================
--- MODULE: Personal Registry Publication Ownership
--- DESCRIPTION:
--- Exercises real registry journals and strict derived-index restoration receipts.
--- A foreign mutation revokes inverse authority even when its visible value agrees.
--- ==============================================================================

local helpers = require("tests.helpers")

local function fixture(body)
	return helpers.with_stub_scope({ "adapters.storage", "modules.keymap.state", "modules.keymap.registry",
		"modules.keymap.registry_groups", "modules.keymap.registry_index" }, function()
		local registry = helpers.load_with_stubs("modules.keymap.registry")
		local state = require("modules.keymap.state").new({ trigger_char = "★", expansion_delay = 0.4 }, {})
		assert(registry.init(state))
		registry.register_lua_group("owner", "Owner", {})
		registry.set_group_context("owner")
		registry.add("original", "Original", { is_case_sensitive = true })
		registry.set_group_context(nil)
		registry.sort_mappings()
		local Groups = require("modules.keymap.registry_groups")
		local callbacks
		for index = 1, 40 do
			local name, value = debug.getupvalue(Groups.init, index)
			if not name then break end
			if name == "_callbacks" then callbacks = value; break end
		end
		assert(callbacks)
		body(state, registry, callbacks)
	end)
end

local function candidate(state, registry, owner, publisher)
	return owner.run(function()
		return registry.registry_transaction("personal_candidate", function()
			state.groups.owner.meta_description = "Candidate"
			state.mappings[1].repl = "Candidate"
			if owner.capture_current() ~= true then return false end
			return publisher()
		end)
	end)
end

helpers.describe("personal registry publication ownership", function()
	helpers.it("recognizes only an acknowledged private cloned inverse", function()
		fixture(function(state, registry)
			local original_group, original_mapping = state.groups.owner, state.mappings[1]
			local owner = assert(registry.capture_publication_owner())
			helpers.assert_eq(candidate(state, registry, owner, function() return false end), false)
			helpers.assert_eq(state.groups.owner.meta_description, "Owner")
			helpers.assert_eq(state.mappings[1].repl, "Original")
			helpers.assert_true(state.groups.owner ~= original_group, "only the journal admits its private clone")
			helpers.assert_eq(state.mappings[1], original_mapping)
			helpers.assert_eq(owner.current(), true)
			helpers.assert_nil(registry.capture_publication_owner(), "the inverse retains its cleanup owner")
			helpers.assert_eq(owner.retry_inverse(), true)
			helpers.assert_eq(owner.release(), true)
			local next_owner = assert(registry.capture_publication_owner())
			helpers.assert_eq(next_owner.current(), false)
			helpers.assert_eq(next_owner.release(), true)
		end)
	end)

	for _, refusal in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains inverse debt after a " .. refusal .. " derived-index acknowledgement", function()
			fixture(function(state, registry, callbacks)
				local owner = assert(registry.capture_publication_owner())
				local rebuild = callbacks.rebuild_lookup
				callbacks.rebuild_lookup = function()
					if refusal == "throw" then error("controlled rebuild refusal") end
					if refusal == "false" then return false end
					return nil
				end
				helpers.assert_eq(candidate(state, registry, owner, function() return false end), false)
				helpers.assert_eq(state.mappings[1].repl, "Original")
				helpers.assert_eq(owner.release(), false, "copied values do not acknowledge derived indexes")
				helpers.assert_nil(registry.capture_publication_owner())
				callbacks.rebuild_lookup = rebuild
				helpers.assert_eq(owner.retry_inverse(), true)
				helpers.assert_eq(owner.release(), true)
			end)
		end)
	end

	local mutations = {
		{ name = "same-value public gate acknowledgement", apply = function(_, registry)
			assert(registry.enable_group("owner") == true)
		end },
		{ name = "same-value public mutation", apply = function(state, registry)
			registry.set_group_context(state.current_group)
		end },
		{ name = "foreign mapping scalar", apply = function(state) state.mappings[1].repl = "Foreign" end },
		{ name = "foreign lifecycle generation", apply = function(state)
			state.lifecycle_generation = (state.lifecycle_generation or 0) + 1
		end },
		{ name = "foreign source identity", apply = function(state) state.groups.owner.source_path = "/foreign.toml" end },
		{ name = "foreign index generation", apply = function(_, _, callbacks) callbacks.rebuild_lookup() end },
	}
	for _, mutation in ipairs(mutations) do
		helpers.it("refuses inverse authority after " .. mutation.name, function()
			fixture(function(state, registry, callbacks)
				local owner = assert(registry.capture_publication_owner())
				helpers.assert_eq(candidate(state, registry, owner, function()
					mutation.apply(state, registry, callbacks)
					return false
				end), false)
				helpers.assert_eq(owner.current(), false)
				helpers.assert_eq(owner.retry_inverse(), false)
				helpers.assert_eq(owner.release(), false)
				helpers.assert_eq(state.groups.owner.meta_description, "Candidate", "foreign ownership prevents an inverse publication")
				helpers.assert_nil(registry.capture_publication_owner())
			end)
		end)
	end
end)
