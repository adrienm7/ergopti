--- tests/unit/modules/keymap/test_registry_section_delay_scoping.lua
--- Behavioral regression coverage for group-owned section delays.

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"modules.keymap.registry",
	"modules.keymap.registry_groups",
	"modules.keymap.registry_index",
	"modules.keymap.terminators",
	"modules.keymap.state",
	"modules.keymap.utils",
	"infra.toml.reader",
	"infra.timings",
	"modules.hotstrings.hotstrings_config",
}

local function group_data(trigger, delay)
	local meta = {}
	if delay ~= nil then meta.section_delays = { rolls = delay } end
	return {
		sections_order = { "rolls" },
		sections = {
			rolls = {
				[trigger] = { output = trigger:upper() },
			},
		},
		meta = meta,
	}
end

local function with_registry(data_by_path, callback)
	return helpers.with_fresh_modules(OWNED_MODULES, function()
		package.loaded["infra.toml.reader"] = {
			parse = function(path) return data_by_path[path], true end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = {
			get_user_override = function() return nil end,
		}
		local State = helpers.load_with_stubs("modules.keymap.state")
		package.loaded["infra.timings"] = {
			sec = function() return 0.01 end,
		}
		local Registry = require("modules.keymap.registry")
		local state = State.new(
			{ trigger_char = "★", expansion_delay = 0.4 },
			{ group_a = 0.4, group_b = 0.4 })
		helpers.assert_eq(Registry.init(state), true)
		return callback(state, Registry)
	end)
end

local function mapping_for(state, trigger)
	for _, mapping in ipairs(state.mappings) do
		if mapping.trigger == trigger then return mapping end
	end
	return nil
end

helpers.describe("Registry section-delay ownership", function()
	helpers.it("scopes colliding section names by group and prunes disabled owners", function()
		with_registry({
			["/virtual/group-b.toml"] = group_data("btrigger", 2.5),
			["/virtual/group-a.toml"] = group_data("atrigger", 0),
		}, function(state, Registry)
			helpers.assert_eq(Registry.load_toml("group_b", "/virtual/group-b.toml"), true)
			helpers.assert_eq(Registry.load_toml("group_a", "/virtual/group-a.toml"), true)

			local mapping_a = mapping_for(state, "atrigger")
			local mapping_b = mapping_for(state, "btrigger")
			helpers.assert_true(mapping_a ~= nil and mapping_b ~= nil,
				"both real registry mappings must be live before testing their delay policy")
			helpers.assert_eq(state.resolve_mapping_delay(mapping_a), 0,
				"group A must retain its always-active section delay")
			helpers.assert_eq(state.resolve_mapping_delay(mapping_b), 2.5,
				"group B must not inherit group A's colliding section name")
			helpers.assert_eq(state.WORD_TIMEOUT_SEC, 0,
				"an enabled always-active owner still requires an infinite word timeout")

			helpers.assert_eq(Registry.disable_group("group_a"), true)
			helpers.assert_nil(state.SECTION_DELAYS.group_a,
				"disabling a group must remove its complete section-delay ownership")
			helpers.assert_eq(state.resolve_mapping_delay(mapping_b), 2.5,
				"the remaining group must retain its own colliding section delay")
			helpers.assert_eq(state.WORD_TIMEOUT_SEC, 3.0,
				"the word timeout must be recomputed after the infinite owner is removed")

			helpers.assert_eq(Registry.enable_group("group_a"), true)
			local reloaded_a = mapping_for(state, "atrigger")
			helpers.assert_true(reloaded_a ~= nil, "re-enabling the group must restore its mappings")
			helpers.assert_eq(state.resolve_mapping_delay(reloaded_a), 0,
				"re-enabling the group must restore its own section-delay ownership")
			helpers.assert_eq(state.WORD_TIMEOUT_SEC, 0,
				"the restored always-active owner must restore the infinite timeout")
		end)
	end)

	helpers.it("replaces a group's delay set when the same file is reloaded", function()
		local data_by_path = {
			["/virtual/group-a.toml"] = group_data("atrigger", 0),
		}
		with_registry(data_by_path, function(state, Registry)
			helpers.assert_eq(Registry.load_toml("group_a", "/virtual/group-a.toml"), true)
			helpers.assert_eq(state.WORD_TIMEOUT_SEC, 0)

			data_by_path["/virtual/group-a.toml"] = group_data("atrigger", nil)
			helpers.assert_eq(Registry.reload_toml("group_a", "/virtual/group-a.toml"), true)

			local mapping = mapping_for(state, "atrigger")
			helpers.assert_true(mapping ~= nil, "the reloaded mapping must remain registered")
			local group_delays = state.SECTION_DELAYS.group_a or {}
			helpers.assert_nil(group_delays.rolls,
				"a removed source override must not survive a same-file reload")
			helpers.assert_eq(state.resolve_mapping_delay(mapping), 0.4,
				"the reloaded mapping must fall back to its group delay")
			helpers.assert_eq(state.WORD_TIMEOUT_SEC, 0.9,
				"the timeout must shrink after the removed infinite override")
		end)
	end)
end)
