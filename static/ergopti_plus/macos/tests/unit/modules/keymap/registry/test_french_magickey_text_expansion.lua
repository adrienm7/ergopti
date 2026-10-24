--- tests/unit/modules/keymap/registry/test_french_magickey_text_expansion.lua

--- ==============================================================================
--- MODULE: French Magic Key Text Expansion Section (macOS)
--- DESCRIPTION:
--- hotstrings.french_magickey.text_expansion had no macOS test. Load the shipped
--- french/magickey.toml through the real registry and pin the toggle: the
--- section ships disabled, so none of its rules is live, and enabling it
--- publishes them with their shipped outputs.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"modules.keymap.registry",
	"modules.keymap.registry_groups",
	"modules.keymap.registry_index",
	"modules.keymap.terminators",
	"modules.keymap.state",
	"modules.keymap.utils",
	"infra.timings",
	"modules.hotstrings.hotstrings_config",
}

local function with_registry(callback)
	return helpers.with_fresh_modules(OWNED_MODULES, function()
		package.loaded["modules.hotstrings.hotstrings_config"] = { get_user_override = function() return nil end }
		local State = helpers.load_with_stubs("modules.keymap.state")
		package.loaded["infra.timings"] = { sec = function() return 0.01 end }
		local Registry = require("modules.keymap.registry")
		local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, { french_magickey = 0.4 })
		helpers.assert_eq(Registry.init(state), true)
		return callback(state, Registry)
	end)
end

local function outputs(state)
	local found = {}
	for _, mapping in ipairs(state.mappings) do
		if mapping.group == "french_magickey" then found[mapping.trigger] = assert(mapping.repl, "a live mapping carries its replacement") end
	end
	return found
end

helpers.describe("french_magickey text_expansion through the macOS registry (macos-text-expansion)", function()
	helpers.it("ships disabled and publishes its rules once enabled", function()
		with_registry(function(state, Registry)
			local path = assert(helpers.shared("modules/hotstrings/french/magickey.toml"))
			helpers.assert_eq(Registry.load_toml("french_magickey", path), true)
			helpers.assert_eq(Registry.is_section_enabled("french_magickey", "text_expansion"), false)
			helpers.assert_nil(outputs(state)["+m★"], "a disabled section publishes nothing")

			helpers.assert_true(Registry.enable_section("french_magickey", "text_expansion"))
			local live = outputs(state)
			helpers.assert_eq(live["+m★"], "meilleur")
			helpers.assert_eq(live["//★"], "rapport")

			helpers.assert_true(Registry.disable_section("french_magickey", "text_expansion"))
			helpers.assert_nil(outputs(state)["+m★"], "disabling it again retires its rules")
		end)
	end)
end)
