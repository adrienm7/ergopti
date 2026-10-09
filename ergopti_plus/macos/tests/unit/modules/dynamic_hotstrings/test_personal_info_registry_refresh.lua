--- tests/unit/modules/dynamic_hotstrings/test_personal_info_registry_refresh.lua

--- ==============================================================================
--- MODULE: Personal-Information Registry Refresh Regression
--- DESCRIPTION:
--- Exercises one editor save through the real PersonalInfo, RulesEngine, and
--- Registry modules. Prefix mappings contain literal personal values, so a
--- committed save must replace the complete dynamic group before publishing the
--- new file and live table; appending new mappings would leave the old secret
--- reachable for the rest of the Hammerspoon session.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"dynamic_hotstrings",
	"modules.dynamic_hotstrings.personal_info",
	"modules.dynamic_hotstrings.rules_engine",
	"modules.keymap.registry",
	"modules.keymap.registry_groups",
	"modules.keymap.registry_index",
	"modules.keymap.state",
}

local OLD_PHONE = "0612345678"
local NEW_PHONE = "0199999999"

--- Reads one complete fixture file.
--- @param path string File path.
--- @return string content
local function read_file(path)
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a"))
	assert(file:close())
	return content
end

--- Finds one exact trigger in the real registry corpus.
--- @param state table CoreState instance.
--- @param trigger string Exact trigger.
--- @return table|nil mapping
local function mapping_for(state, trigger)
	for _, mapping in ipairs(state.mappings) do
		if mapping.trigger == trigger then return mapping end
	end
	return nil
end

--- Counts exact-trigger mappings in the real corpus.
--- @param state table CoreState instance.
--- @param trigger string Exact trigger.
--- @return integer count
local function mapping_count(state, trigger)
	local count = 0
	for _, mapping in ipairs(state.mappings) do
		if mapping.trigger == trigger then count = count + 1 end
	end
	return count
end

--- Runs one isolated real-module graph over a temporary personal-info file.
--- @param scenario function Receives the fixture table.
local function with_fixture(scenario)
	local path = os.tmpname()
	local initial = table.concat({
		"[info]",
		'phone_number = "' .. OLD_PHONE .. '"',
		'phone_number_clean = "06 12 34 56 78"',
		"",
		"[letters]",
		'p = "phone_number"',
		"",
	}, "\n")
	local file = assert(io.open(path, "wb"))
	assert(file:write(initial))
	assert(file:close())

	local ok, err = xpcall(function()
		helpers.with_fresh_modules(MODULES, function()
			local State = require("modules.keymap.state")
			local Registry = require("modules.keymap.registry")
			local RulesEngine = require("modules.dynamic_hotstrings.rules_engine")
			local PersonalInfo = require("modules.dynamic_hotstrings.personal_info")
			local FileSystem = require("adapters.file_system")

			local state = State.new({ trigger_char = "\u{2605}", expansion_delay = 0.4 },
				{ autocorrection = 0.3 })
			helpers.assert_true(Registry.init(state))

			local keymap = {
				add = Registry.add,
				disable_group = Registry.disable_group,
				enable_group = Registry.enable_group,
				get_trigger_char = function() return "\u{2605}" end,
				invalidate_hotstring_preview = function() return true end,
				is_group_enabled = Registry.is_group_enabled,
				is_section_enabled = Registry.is_section_enabled,
				register_interceptor = function() end,
				register_lua_group = Registry.register_lua_group,
				register_preview_provider = function() end,
				registry_transaction = Registry.registry_transaction,
				set_group_context = Registry.set_group_context,
				set_post_load_hook = Registry.set_post_load_hook,
				sort_mappings = Registry.sort_mappings,
			}

			helpers.assert_true(PersonalInfo.start("", keymap, path,
				RulesEngine.refresh_personal_data))
			helpers.assert_true(RulesEngine.inject_data(PersonalInfo.get_info(), "\u{2605}"))
			helpers.assert_true(RulesEngine.start(keymap))

			local original_write = FileSystem.write_if_unchanged
			FileSystem.write_if_unchanged = function(target, content, expected_source)
				helpers.assert_eq(target, path)
				helpers.assert_eq(expected_source.content, initial)
				local destination = assert(io.open(target, "wb"))
				assert(destination:write(content))
				assert(destination:close())
				return true
			end

			local scenario_ok, scenario_err = xpcall(function()
				scenario({
					FileSystem = FileSystem,
					PersonalInfo = PersonalInfo,
					RulesEngine = RulesEngine,
					initial = initial,
					keymap = keymap,
					mapping_count = function(trigger) return mapping_count(state, trigger) end,
					mapping_for = function(trigger) return mapping_for(state, trigger) end,
					path = path,
					read_file = function() return read_file(path) end,
					state = state,
				})
			end, debug.traceback)
			FileSystem.write_if_unchanged = original_write
			RulesEngine.stop()
			PersonalInfo.stop()
			if not scenario_ok then error(scenario_err, 0) end
		end)
	end, debug.traceback)
	os.remove(path)
	if not ok then error(err, 0) end
end





-- ==================================================
-- ==================================================
-- ======= 2/ Registry Refresh Transaction =========
-- ==================================================
-- ==================================================

helpers.describe("personal-info save refreshes literal prefix mappings", function()
	helpers.it("purges the old phone prefix and publishes the new one exactly once", function()
		with_fixture(function(fixture)
			local old_mapping = fixture.mapping_for("0612")
			helpers.assert_not_nil(old_mapping,
				"the real registry must contain the old literal mapping before save")
			helpers.assert_eq(old_mapping.repl, OLD_PHONE)

			helpers.assert_true(fixture.PersonalInfo.save_info({
				phone_number = NEW_PHONE,
				phone_number_clean = "01 99 99 99 99",
			}))

			helpers.assert_nil(fixture.mapping_for("0612"),
				"the old secret prefix must be purged from the live registry")
			local new_mapping = fixture.mapping_for("0199")
			helpers.assert_not_nil(new_mapping,
				"the new prefix must be registered without waiting for hs.reload")
			helpers.assert_eq(new_mapping.repl, NEW_PHONE)
			helpers.assert_eq(fixture.mapping_count("0199"), 1,
				"one save must publish exactly one new literal mapping")
			helpers.assert_eq(fixture.PersonalInfo.get_info().phone_number, NEW_PHONE)
			helpers.assert_contains(fixture.read_file(),
				'phone_number = "' .. NEW_PHONE .. '"')
		end)
	end)

	helpers.it("keeps a disabled group disabled and rebuilds it from the saved winner", function()
		with_fixture(function(fixture)
			helpers.assert_true(fixture.keymap.disable_group("dynamichotstrings"))
			helpers.assert_nil(fixture.mapping_for("0612"))

			helpers.assert_true(fixture.PersonalInfo.save_info({
				phone_number = NEW_PHONE,
				phone_number_clean = "01 99 99 99 99",
			}))

			helpers.assert_eq(fixture.keymap.is_group_enabled("dynamichotstrings"), false,
				"a data refresh must not override the user's disabled-group setting")
			helpers.assert_nil(fixture.mapping_for("0612"))
			helpers.assert_nil(fixture.mapping_for("0199"),
				"disabled groups must not leak their refreshed corpus into the registry")
			helpers.assert_true(fixture.keymap.enable_group("dynamichotstrings"))
			helpers.assert_nil(fixture.mapping_for("0612"))
			helpers.assert_eq(fixture.mapping_count("0199"), 1,
				"re-enabling later must build only the committed personal-data winner")
		end)
	end)

	helpers.it("rolls the rebuilt registry back when filesystem publication refuses", function()
		with_fixture(function(fixture)
			local writes = 0
			fixture.FileSystem.write_if_unchanged = function()
				writes = writes + 1
				return false
			end

			helpers.assert_eq(fixture.PersonalInfo.save_info({
				phone_number = NEW_PHONE,
				phone_number_clean = "01 99 99 99 99",
			}), false)

			helpers.assert_eq(writes, 1)
			helpers.assert_not_nil(fixture.mapping_for("0612"),
				"the old registry snapshot must survive rejected disk publication")
			helpers.assert_nil(fixture.mapping_for("0199"),
				"a rejected candidate must leave no new prefix behind")
			helpers.assert_eq(fixture.PersonalInfo.get_info().phone_number, OLD_PHONE)
			helpers.assert_eq(fixture.read_file(), fixture.initial)
		end)
	end)

	helpers.it("never publishes disk or memory when the registry rebuild refuses", function()
		with_fixture(function(fixture)
			local writes = 0
			fixture.FileSystem.write_if_unchanged = function()
				writes = writes + 1
				return true
			end
			local committed_enable = fixture.keymap.enable_group
			fixture.keymap.enable_group = function(name)
				committed_enable(name)
				return false
			end

			helpers.assert_eq(fixture.PersonalInfo.save_info({
				phone_number = NEW_PHONE,
				phone_number_clean = "01 99 99 99 99",
			}), false)

			helpers.assert_eq(writes, 0,
				"filesystem publication must be the final fallible step")
			helpers.assert_not_nil(fixture.mapping_for("0612"))
			helpers.assert_nil(fixture.mapping_for("0199"))
			helpers.assert_eq(fixture.PersonalInfo.get_info().phone_number, OLD_PHONE)
			helpers.assert_eq(fixture.read_file(), fixture.initial)
		end)
	end)

	helpers.it("rebuilds prefixes for an external winner after a stale save loses", function()
		with_fixture(function(fixture)
			local external_phone = "0788888888"
			local external = table.concat({
				"[info]",
				'phone_number = "' .. external_phone .. '"',
				'phone_number_clean = "07 88 88 88 88"',
				"",
				"[letters]",
				'p = "phone_number"',
				"",
			}, "\n")
			fixture.FileSystem.write_if_unchanged = function(target)
				local winner = assert(io.open(target, "wb"))
				assert(winner:write(external))
				assert(winner:close())
				return false
			end

			helpers.assert_eq(fixture.PersonalInfo.save_info({
				phone_number = NEW_PHONE,
				phone_number_clean = "01 99 99 99 99",
			}), false, "the stale editor candidate must still report rejection")

			helpers.assert_nil(fixture.mapping_for("0612"))
			helpers.assert_nil(fixture.mapping_for("0199"))
			local external_mapping = fixture.mapping_for("0788")
			helpers.assert_not_nil(external_mapping,
				"the validated external winner must own the live prefix corpus")
			helpers.assert_eq(external_mapping.repl, external_phone)
			helpers.assert_eq(fixture.PersonalInfo.get_info().phone_number, external_phone)
			helpers.assert_eq(fixture.read_file(), external)
		end)
	end)
end)

return true
