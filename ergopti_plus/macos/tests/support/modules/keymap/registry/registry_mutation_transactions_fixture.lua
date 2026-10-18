--- tests/support/modules/keymap/registry/registry_mutation_transactions_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_registry_mutation_transactions
--- DESCRIPTION:
--- Prelude shared by the test_registry_mutation_transactions_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")
local CaptionFixture = require("tests.support.personal_menu_caption_fixture")

--- Models the empty boot directory catalogue in registry-only menu fixtures.
--- The actual registry/persistence owners stay live; importing the boot loader
--- would construct an unrelated keymap against the already initialized registry.
--- @param callback function Actual menu transaction and its assertions.
--- @return ... Callback results.
local function with_menu_diagnostics(callback)
	return helpers.with_stub_scope({ "infra.personal_hotstrings" }, function()
		package.loaded["infra.personal_hotstrings"] = {
			unavailable_directories = function() return {} end,
		}
		return callback()
	end)
end


--- Builds an initialized registry bound to a fresh in-memory Hammerspoon stub.
--- @return table state
--- @return table registry
local function fresh_registry()
	package.loaded["adapters.storage"] = nil
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



local function dynamic_personal_scope_fixture(enabled, outcome, absent)
	local Custom = helpers.load_with_stubs("ui.menu.menu_hotstrings_custom")
	local registry_state, registry = fresh_registry()
	package.loaded["modules.dynamic_hotstrings"] = nil
	package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
	local personal = require("modules.dynamic_hotstrings")
	personal.set_enabled(not enabled)
	local original_set = personal.set_enabled
	local module_calls = {}
	personal.set_enabled = function(value)
		module_calls[#module_calls + 1] = value
		return original_set(value)
	end
	local names = { "datelongfr", "datefr", "date", "phoneprefixes", "ssnprefixes", "ibanprefixes" }
	local sections = {}
	for _, name in ipairs(names) do sections[#sections + 1] = { name = name } end
	sections[#sections + 1] = { name = "-" }
	sections[#sections + 1] = { name = "textexpansionpersonalinformation", is_module_placeholder = true }
	registry.register_lua_group("dynamichotstrings", "Dynamic", sections)
	registry.register_lua_group("spare", "Spare", {})
	add_group_mapping(registry, "spare", "untouched")
	local spare_mapping = registry_state.mappings[1]
	for _, name in ipairs(names) do
		hs.settings.set("ergopti.hotstrings_section_dynamichotstrings_" .. name, not enabled)
	end
	registry.set_post_load_hook("dynamichotstrings", function()
		for _, name in ipairs(names) do
			if registry.is_section_enabled("dynamichotstrings", name) then add_group_mapping(registry, "dynamichotstrings", name) end
		end
	end)
	if enabled then
		registry.disable_group("dynamichotstrings")
	else
		for _, name in ipairs(names) do add_group_mapping(registry, "dynamichotstrings", name) end
	end
	local original_mappings = {}
	for _, mapping in ipairs(registry_state.mappings) do original_mappings[#original_mappings + 1] = mapping end
	local menu_state = { hotstrings = { dynamichotstrings = not enabled, spare = true },
		keymap = false, personal_info = not enabled, trigger_char = "★" }
	if absent then menu_state.personal_info = nil end
	local original = "[hotstrings]\nenabled = false\n[hotstrings.modules]\npersonal_info = "
		.. tostring(not enabled) .. "\nfuture_module = { retained = 17 }\n"
	local files = { config = original }
	package.loaded["adapters.file_system"] = {
		read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
		write_if_unchanged = function(path, content, expected)
			if files.refuse or expected.status ~= (files[path] and "ok" or "absent")
				or (expected.status == "ok" and expected.content ~= files[path]) then return false end
			files[path] = content; return true
		end,
	}
	package.loaded["infra.preferences"] = nil
	local preferences = require("infra.preferences")
	preferences.load("config")
	local shared = assert(require("toml_codec").decode(require("tests.support.source_file").read(
		helpers.driver_root() .. "../_shared/modules/hotstrings/_index.toml")))
	local observations, starts, updates, saves = {}, 0, 0, 0
	registry.start = function() starts = starts + 1; return true end
	local ctx = { state = menu_state, paused = true, keymap = registry, personal_info = personal,
		module_sections = shared.modules, updateMenu = function() updates = updates + 1 end }
	ctx.save_prefs = function()
		saves = saves + 1
		observations[#observations + 1] = { personal.is_enabled(), menu_state.personal_info,
			registry.is_group_enabled("dynamichotstrings") }
		if outcome == "false" then return false end
		if outcome == "nil" then return nil end
		if outcome == "throw" then error("owned canonical save refusal") end
		return preferences.save("config", menu_state, { "dynamichotstrings.toml", "spare.toml" }, { keymap = registry })
	end
	local action = Custom.category_scope_fn(ctx, { "dynamichotstrings" }, enabled)
	return { action = action, ctx = ctx, personal = personal, registry = registry, state = registry_state,
		preferences = preferences, files = files, original = original, names = names, module_calls = module_calls,
		observations = observations, spare_mapping = spare_mapping, original_mappings = original_mappings, original_enabled = not enabled,
		counts = function() return starts, updates, saves end }
end

local function assert_dynamic_personal_scope(f, desired)
	helpers.assert_eq(f.personal.is_enabled(), desired, "the actual external module shares the selected target")
	helpers.assert_eq(f.registry.is_group_enabled("dynamichotstrings"), desired)
	for _, name in ipairs(f.names) do
		helpers.assert_eq(hs.settings.get("ergopti.hotstrings_section_dynamichotstrings_" .. name), desired)
	end
	helpers.assert_eq(f.registry.is_group_enabled("spare"), true)
	local retained = false
	for _, mapping in ipairs(f.state.mappings) do if mapping == f.spare_mapping then retained = true end end
	helpers.assert_true(retained, "the unrelated group's exact mapping is preserved")
	if desired == f.original_enabled then
		helpers.assert_eq(#f.state.mappings, #f.original_mappings, "refusal restores the exact native mapping inventory")
		for index, mapping in ipairs(f.original_mappings) do
			helpers.assert_true(f.state.mappings[index] == mapping, "refusal retains each original mapping identity and order")
		end
	end
	helpers.assert_eq(f.ctx.state.keymap, false, "the master remains stopped")
	helpers.assert_eq(f.ctx.paused, true, "the scope does not lift pause")
	helpers.assert_nil(hs.settings.get("ergopti.hotstrings_section_dynamichotstrings_textexpansionpersonalinformation"),
		"an external interceptor never acquires a fake registry section")
end

return {
	CaptionFixture = CaptionFixture,
	add_group_mapping = add_group_mapping,
	assert_dynamic_personal_scope = assert_dynamic_personal_scope,
	dynamic_personal_scope_fixture = dynamic_personal_scope_fixture,
	fresh_registry = fresh_registry,
	with_menu_diagnostics = with_menu_diagnostics,
}
