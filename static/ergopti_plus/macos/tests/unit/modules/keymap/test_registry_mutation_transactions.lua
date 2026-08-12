--- tests/unit/modules/keymap/test_registry_mutation_transactions.lua

--- ==============================================================================
--- MODULE: Registry Mutation Transactions
--- DESCRIPTION:
--- Proves that public group/section mutators return an exact boolean commitment
--- and restore both runtime mappings and persistent section settings when a
--- loader or post-load hook fails after mutation has begun.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Builds an initialized registry bound to a fresh in-memory Hammerspoon stub.
--- @return table state
--- @return table registry
local function fresh_registry()
	local registry = helpers.load_with_stubs("modules.keymap.registry")
	package.loaded["modules.keymap.state"] = nil
	local State = require("modules.keymap.state")
	local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
	registry.init(state)
	return state, registry
end


--- Registers one mapping owned by a programmatic group.
--- @param registry table
--- @param group_name string
--- @param trigger string
local function add_group_mapping(registry, group_name, trigger)
	registry.set_group_context(group_name)
	registry.add(trigger, trigger:upper(), { is_case_sensitive = true })
	registry.set_group_context(nil)
	registry.sort_mappings()
end


helpers.describe("registry mutations: exact commitment and rollback", function()
	helpers.it("exposes one caller-owned transaction across a registration batch", function()
		local state, registry = fresh_registry()
		local committed = registry.registry_transaction("test_batch", function()
			registry.register_lua_group("prospective", "Prospective", {})
			add_group_mapping(registry, "prospective", "partial")
			return false
		end)

		helpers.assert_eq(committed, false)
		helpers.assert_nil(state.groups.prospective,
			"the public transaction must restore group ownership")
		helpers.assert_eq(#state.mappings, 0,
			"the public transaction must restore every mapping in the batch")
	end)

	helpers.it("withholds private callback failures while preserving rollback visibility", function()
		local _, registry = fresh_registry()
		local Logger = require("infra.logger")
		local lines = {}
		local previous_level = Logger.current_level
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = tostring(line) end)
		local committed = registry.registry_transaction("private_registration", function()
			error("PRIVATE_REGISTRY_SENTINEL", 0)
		end)
		Logger.set_sink(nil)
		Logger.set_level(previous_level)

		helpers.assert_eq(committed, false)
		helpers.assert_true(#lines > 0, "the failed transaction must remain visible")
		local joined = table.concat(lines, "\n")
		helpers.assert_true(joined:find("private_registration", 1, true) ~= nil)
		helpers.assert_true(joined:find("PRIVATE_REGISTRY_SENTINEL", 1, true) == nil,
			"a callback handling personal mappings may carry PII in its error object")
	end)

	helpers.it("returns exact booleans for committed and impossible group states", function()
		local _, registry = fresh_registry()
		registry.register_lua_group("atomic", "Atomic", {})
		add_group_mapping(registry, "atomic", "alpha")

		helpers.assert_eq(registry.disable_group("atomic"), true)
		helpers.assert_eq(registry.disable_group("atomic"), true,
			"an idempotent request still fully satisfies the requested postcondition")
		registry.set_post_load_hook("atomic", function()
			add_group_mapping(registry, "atomic", "alpha")
		end)
		helpers.assert_eq(registry.enable_group("atomic"), true)
		helpers.assert_eq(registry.enable_group("atomic"), true)
		helpers.assert_eq(registry.disable_group("missing"), false)
		helpers.assert_eq(registry.enable_group("missing"), false)
	end)

	helpers.it("rolls back a programmatic enable when its post-load hook throws", function()
		local state, registry = fresh_registry()
		registry.register_lua_group("control", "Control", {})
		add_group_mapping(registry, "control", "omega")
		local control_mapping = state.mappings[1]
		registry.register_lua_group("hooked", "Hooked", {})
		add_group_mapping(registry, "hooked", "stable")
		helpers.assert_eq(registry.disable_group("hooked"), true)
		local seq_before = state.seq_counter

		registry.set_post_load_hook("hooked", function()
			registry.set_group_context("hooked")
			registry.add("partial", "PARTIAL", { is_case_sensitive = true })
			error("injected post-load failure")
		end)

		local ok, committed = pcall(registry.enable_group, "hooked")
		helpers.assert_true(ok, "a public mutator must convert a hook throw into false")
		helpers.assert_eq(committed, false)
		helpers.assert_eq(registry.is_group_enabled("hooked"), false)
		helpers.assert_eq(#state.mappings, 1,
			"the mapping registered before the hook throw must be removed")
		helpers.assert_eq(state.mappings[1], control_mapping,
			"a sibling group's corpus must retain its object identity")
		helpers.assert_eq(state.seq_counter, seq_before,
			"rollback must restore monotonic counters as well as visible mappings")
		helpers.assert_nil(state.current_group,
			"a throwing hook must not leak its group context into later registrations")
		helpers.assert_nil(registry.mappings_for_tail("l"),
			"tail indexes must not retain the hook's partial mapping")
		local control_bucket = registry.mappings_for_tail("a")
		helpers.assert_eq(control_bucket and control_bucket[1], control_mapping,
			"tail indexes must still point at the restored sibling corpus")
		local lookup_count = 0
		for _, mapping in pairs(state.mappings_lookup) do
			lookup_count = lookup_count + 1
			helpers.assert_eq(mapping, control_mapping,
				"the exact lookup must not retain the hook's partial mapping")
		end
		helpers.assert_eq(lookup_count, 1)
	end)

	helpers.it("restores settings and the live group when a section reload cannot parse", function()
		local state, registry = fresh_registry()
		registry.register_lua_group("broken", "Broken", { { name = "one" } })
		state.groups.broken.path = helpers.fixtures_dir() .. "invalid-hotstrings.toml"
		state.groups.broken.kind = "toml"
		add_group_mapping(registry, "broken", "stable")
		local mapping_before = state.mappings[1]
		local key = "hotstrings_section_broken_one"
		hs.settings.set(key, false)

		local previous_reader = package.loaded["infra.toml.reader"]
		package.loaded["infra.toml.reader"] = {
			parse = function() error("injected TOML parse failure") end,
		}
		local ok, committed = pcall(registry.enable_section, "broken", "one")
		package.loaded["infra.toml.reader"] = previous_reader

		helpers.assert_true(ok, "parse failure must be contained by the public mutator")
		helpers.assert_eq(committed, false)
		helpers.assert_eq(hs.settings.get(key), false,
			"the persisted section choice must roll back when its live reload fails")
		helpers.assert_eq(registry.is_group_enabled("broken"), true,
			"the group was enabled before the request and must remain enabled")
		helpers.assert_eq(#state.mappings, 1)
		helpers.assert_eq(state.mappings[1], mapping_before,
			"rollback must restore the exact previously-live mapping object")
	end)

	helpers.it("rolls back a throwing or ineffective settings write by read-back", function()
		for _, operation in ipairs({ "set", "clear" }) do
			for _, mode in ipairs({ "throw_after_write", "nil_noop", "false_noop" }) do
				local state, registry = fresh_registry()
				registry.register_lua_group("settings", "Settings", { { name = "one" } })
				add_group_mapping(registry, "settings", "stable")
				local mapping_before = state.mappings[1]
				local key = "hotstrings_section_settings_one"
				local real_set, real_clear = hs.settings.set, hs.settings.clear
				local previous
				if operation == "clear" then previous = false end
				if previous == false then real_set(key, false) else real_clear(key) end
				local real_operation = operation == "clear" and real_clear or real_set
				hs.settings[operation] = function(write_key, value)
					if mode == "throw_after_write" then
						real_operation(write_key, value)
						error("injected settings failure after write")
					end
					-- Return values are not commitments: set normally returns nil and
					-- clear may return false for an absent key. The no-op is detected
					-- only because the exact read-back still has the old value.
					if mode == "false_noop" then return false end
					return nil
				end

				local action = operation == "clear" and registry.enable_section or registry.disable_section
				local ok, committed = pcall(action, "settings", "one")
				hs.settings.set, hs.settings.clear = real_set, real_clear
				local label = operation .. "/" .. mode
				helpers.assert_true(ok, label .. " must be contained by the public mutator")
				helpers.assert_eq(committed, false, label .. " must not report commitment")
				helpers.assert_eq(hs.settings.get(key), previous,
					label .. " must restore the previous persistent value")
				helpers.assert_eq(registry.is_group_enabled("settings"), true)
				helpers.assert_eq(#state.mappings, 1)
				helpers.assert_eq(state.mappings[1], mapping_before)
				helpers.assert_true(registry.mappings_for_tail("e") ~= nil,
					label .. " must leave live indexes attached to the old corpus")
			end
		end
	end)

	helpers.it("does not register a Lua group whose file throws after a partial add", function()
		local state, registry = fresh_registry()
		local seq_before = state.seq_counter
		local fixture = helpers.fixtures_dir() .. "partial_hotstrings_failure.lua"
		local committed = registry.load_file("partial", fixture)
		helpers.assert_eq(committed, false)
		helpers.assert_nil(state.groups.partial)
		helpers.assert_eq(#state.mappings, 0)
		helpers.assert_eq(state.seq_counter, seq_before)
	end)
end)
