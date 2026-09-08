--- tests/unit/platform/remap/generator_managed_lease/test_historical_ownership.lua

--- ==============================================================================
--- MODULE: Managed Lease Generator Historical Ownership
--- DESCRIPTION:
--- Verifies exact ownership and non-destructive generation with isolated fixtures.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.generator_managed_lease_fixture")
local TOKEN = support.TOKEN
local OLD_TOKEN_A = support.OLD_TOKEN_A
local MODE_NAME = support.MODE_NAME
local REVOKED_NAME = support.REVOKED_NAME
local LegacyReleaseFixtures = support.LegacyReleaseFixtures
local state = support.state
local condition_count = support.condition_count
local personal_rule = support.personal_rule
local deep_copy = support.deep_copy
local legacy_layout_scenario = support.legacy_layout_scenario
local existing_config = support.existing_config
local with_fixture = support.with_fixture

helpers.describe("Karabiner generator historical ownership", function()
	helpers.it("migrates the immutable v0.0.0-dev.74 chord graph without rebuilding it through today's generator", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local build_with = fixture.build_with
			local install_legacy_static_fixtures = fixture.install_legacy_static_fixtures
			install_legacy_static_fixtures()
			local actions = {
				{ id = "none", label = "None", karabiner_to = {} },
				{ id = "output", label = "Output", karabiner_to = { { key_code = "x" } } },
			}
			local combos = {
				{
					id = "modifier_pair",
					label = "Modifier pair",
					from = {
						simultaneous = { { key_code = "right_command" }, { key_code = "left_command" } },
						simultaneous_options = { key_down_order = "strict" },
					},
				},
			}
			local generated, build_err, current_legacy, migration_context = build_with(
				state({
					mod_combos_config = {
						modifier_pair = { tap = "none", hold = "none", combo = "none" },
					},
				}),
				actions,
				{},
				combos
			)
			helpers.assert_not_nil(generated, build_err)
			local path = "/merge/release-v74.json"
			local before = personal_rule("personal before released graph")
			local after = personal_rule("personal after released graph")
			local rules = { before }
			for _, rule in ipairs(LegacyReleaseFixtures.v74_chord_rules()) do rules[#rules + 1] = rule end
			rules[#rules + 1] = after
			local existing = existing_config(rules)
			existing.global.show_in_menu_bar = false
			existing.global.show_profile_name_in_menu_bar = false
			existing.global.ask_for_confirmation_before_quitting = false
			existing.global.check_for_updates_on_startup = false
			existing.profiles[2].complex_modifications.parameters = {
				["basic.to_if_alone_timeout_milliseconds"] = 200,
				["basic.simultaneous_threshold_milliseconds"] = 100,
			}
			fixture.file_data[path] = _G.hs.json.encode(existing)

			local live_builder = Generator.build_karabiner_json
			Generator.build_karabiner_json = function()
				error("legacy ownership must not call today's generator")
			end
			local merge_ok, result, merge_err = pcall(
				Generator.merge_into_existing_config,
				generated,
				path,
				current_legacy,
				migration_context
			)
			Generator.build_karabiner_json = live_builder
			helpers.assert_true(merge_ok,
				"historical ownership proof must stay independent from today's generator implementation")
			helpers.assert_not_nil(result, merge_err)
			local merged_rules = result.profiles[2].complex_modifications.rules
			helpers.assert_true(helpers.deep_equal(merged_rules[1], before))
			helpers.assert_true(helpers.deep_equal(merged_rules[#merged_rules], after))
			for index = 2, #merged_rules - 1 do
				helpers.assert_true(
					merged_rules[index].description:find("[ErgoptiPlus managed:" .. TOKEN, 1, true) == 1,
					"every released pre-lease rule must be replaced by the current managed generation"
				)
			end
		end)
	end)

	helpers.it("migrates the one-release v0.0.0-dev.71 paused sentinel schema", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local build = fixture.build
			local install_legacy_static_fixtures = fixture.install_legacy_static_fixtures
			install_legacy_static_fixtures()
			local generated, build_err, legacy_rules, migration_context = build(TOKEN)
			helpers.assert_not_nil(generated, build_err)
			local path = "/merge/release-v71-paused.json"
			local existing = existing_config(LegacyReleaseFixtures.v71_paused_rules())
			existing.profiles[2].complex_modifications.parameters = nil
			fixture.file_data[path] = _G.hs.json.encode(existing)

			local result, merge_err = Generator.merge_into_existing_config(
				generated,
				path,
				legacy_rules,
				migration_context
			)
			helpers.assert_not_nil(result, merge_err)
			helpers.assert_true(helpers.deep_equal(result.global, existing.global),
				"v71 migration must preserve personal global preferences")
			for _, rule in ipairs(result.profiles[2].complex_modifications.rules) do
				helpers.assert_true(
					rule.description:find("[ErgoptiPlus managed:" .. TOKEN, 1, true) == 1,
					"all three v71 paused rules must be replaced by the current managed generation"
				)
			end
		end)
	end)

	helpers.it("migrates the immutable v0.0.0-dev.45 six-rule paused graph", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local build = fixture.build
			local install_legacy_static_fixtures = fixture.install_legacy_static_fixtures
			install_legacy_static_fixtures()
			local generated, build_err, legacy_rules, migration_context = build(TOKEN)
			helpers.assert_not_nil(generated, build_err)
			local path = "/merge/release-v45-paused.json"
			local existing = existing_config(LegacyReleaseFixtures.v45_paused_rules())
			existing.profiles[2].complex_modifications.parameters = nil
			fixture.file_data[path] = _G.hs.json.encode(existing)

			local result, merge_err = Generator.merge_into_existing_config(
				generated,
				path,
				legacy_rules,
				migration_context
			)
			helpers.assert_not_nil(result, merge_err)
			helpers.assert_true(helpers.deep_equal(result.global, existing.global))
			for _, rule in ipairs(result.profiles[2].complex_modifications.rules) do
				helpers.assert_true(
					rule.description:find("[ErgoptiPlus managed:" .. TOKEN, 1, true) == 1,
					"all six dev.45 paused rules must be replaced by the current managed generation"
				)
			end
		end)
	end)

	helpers.it("migrates the immutable v0.0.0-dev.1 normal graph", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local install_legacy_static_fixtures = fixture.install_legacy_static_fixtures
			install_legacy_static_fixtures()
			local old_state, actions, keys = legacy_layout_scenario("q", "logical_escape")
			local generated, build_err, legacy_rules, migration_context = Generator.build_karabiner_json(
				old_state,
				actions,
				keys,
				{},
				{},
				"/managed/",
				TOKEN
			)
			helpers.assert_not_nil(generated, build_err)
			local path = "/merge/release-v1-normal.json"
			local existing = existing_config(LegacyReleaseFixtures.v1_normal_rules())
			existing.profiles[2].complex_modifications.parameters = {
				["basic.to_if_alone_timeout_milliseconds"] = old_state.tap_hold_timeout_ms,
				["basic.simultaneous_threshold_milliseconds"] = old_state.simultaneous_threshold_ms,
			}
			fixture.file_data[path] = _G.hs.json.encode(existing)

			local result, merge_err = Generator.merge_into_existing_config(
				generated,
				path,
				legacy_rules,
				migration_context
			)
			helpers.assert_not_nil(result, merge_err)
			for _, rule in ipairs(result.profiles[2].complex_modifications.rules) do
				helpers.assert_true(
					rule.description:find("[ErgoptiPlus managed:" .. TOKEN, 1, true) == 1,
					"the complete dev.1 normal graph must be replaced by the current managed generation"
				)
			end
		end)
	end)

	helpers.it("proves a complete legacy graph independently of personal global preferences", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local install_legacy_static_fixtures = fixture.install_legacy_static_fixtures
			install_legacy_static_fixtures()
			local old_state, old_actions, keys = legacy_layout_scenario("q", "logical_escape")
			local generated, build_err, legacy_rules, migration_context = Generator.build_karabiner_json(
				old_state,
				old_actions,
				keys,
				{},
				{},
				"/managed/",
				TOKEN
			)
			helpers.assert_not_nil(generated, build_err)
			local old_normal_rules = {}
			for index = 1, #legacy_rules - 3 do old_normal_rules[#old_normal_rules + 1] = deep_copy(legacy_rules[index]) end
			local path = "/merge/personal-globals.json"
			local existing = existing_config(old_normal_rules)
			existing.global.show_in_menu_bar = true
			existing.global.show_profile_name_in_menu_bar = true
			existing.global.ask_for_confirmation_before_quitting = true
			existing.global.check_for_updates_on_startup = true
			existing.profiles[2].complex_modifications.parameters = {
				["basic.to_if_alone_timeout_milliseconds"] = old_state.tap_hold_timeout_ms,
				["basic.simultaneous_threshold_milliseconds"] = old_state.simultaneous_threshold_ms,
			}
			fixture.file_data[path] = _G.hs.json.encode(existing)

			local result, merge_err = Generator.merge_into_existing_config(
				generated,
				path,
				legacy_rules,
				migration_context
			)
			helpers.assert_not_nil(result, merge_err)
			helpers.assert_true(helpers.deep_equal(result.global, existing.global),
				"global Karabiner UI/update preferences are personal data and must stay outside ownership proof")
		end)
	end)

	helpers.it("rejects a non-layout F24 output instead of learning it as layout drift", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local install_legacy_static_fixtures = fixture.install_legacy_static_fixtures
			install_legacy_static_fixtures()
			local old_state, old_actions, keys = legacy_layout_scenario("q", "logical_escape")
			local generated, build_err, legacy_rules, migration_context = Generator.build_karabiner_json(
				old_state,
				old_actions,
				keys,
				{},
				{},
				"/managed/",
				TOKEN
			)
			helpers.assert_not_nil(generated, build_err)
			local old_normal_rules = {}
			for index = 1, #legacy_rules - 3 do old_normal_rules[#old_normal_rules + 1] = deep_copy(legacy_rules[index]) end
			local changed = false
			for _, rule in ipairs(old_normal_rules) do
				for _, manipulator in ipairs(rule.manipulators or {}) do
					for _, event in ipairs(manipulator.to_if_alone or {}) do
						if event.key_code == "q" then event.key_code = "f24"; changed = true end
					end
				end
			end
			helpers.assert_true(changed, "fixture must replace one layout-derived output")
			local path = "/merge/non-layout-f24.json"
			local existing = existing_config(old_normal_rules)
			existing.global.show_in_menu_bar = false
			existing.global.show_profile_name_in_menu_bar = false
			existing.global.ask_for_confirmation_before_quitting = false
			existing.global.check_for_updates_on_startup = false
			existing.profiles[2].complex_modifications.parameters = {
				["basic.to_if_alone_timeout_milliseconds"] = old_state.tap_hold_timeout_ms,
				["basic.simultaneous_threshold_milliseconds"] = old_state.simultaneous_threshold_ms,
			}
			local original_json = _G.hs.json.encode(existing)
			fixture.file_data[path] = original_json

			local result, merge_err = Generator.merge_into_existing_config(
				generated,
				path,
				legacy_rules,
				migration_context
			)
			helpers.assert_nil(result,
				"F24 is not a canonical printable layout position and cannot prove legacy ownership")
			helpers.assert_true(type(merge_err) == "string" and merge_err:find("ambiguous legacy", 1, true) ~= nil)
			helpers.assert_eq(fixture.file_data[path], original_json,
				"failed layout proof must preserve the personal F24 customization byte-for-byte")
		end)
	end)

	helpers.it("requires a bijection between logical characters and physical layout positions", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local install_legacy_static_fixtures = fixture.install_legacy_static_fixtures
			install_legacy_static_fixtures()
			local actions = {
				{ id = "none", label = "None", karabiner_to = {} },
				{
					id = "logical_x",
					label = "Logical X",
					logical_char = "x",
					karabiner_modifiers = {},
					karabiner_to = { { key_code = "q" } },
				},
				{
					id = "logical_y",
					label = "Logical Y",
					logical_char = "y",
					karabiner_modifiers = {},
					karabiner_to = { { key_code = "w" } },
				},
			}
			local keys = {
				{ id = "left_shift", label = "Left Shift", from = { key_code = "left_shift" } },
				{ id = "right_shift", label = "Right Shift", from = { key_code = "right_shift" } },
			}
			local old_state = state({
				tap_hold_config = {
					left_shift = { tap = "logical_x", hold = "none" },
					right_shift = { tap = "logical_y", hold = "none" },
				},
			})
			local generated, build_err, legacy_rules, migration_context = Generator.build_karabiner_json(
				old_state,
				actions,
				keys,
				{},
				{},
				"/managed/",
				TOKEN
			)
			helpers.assert_not_nil(generated, build_err)
			local old_normal_rules = {}
			for index = 1, #legacy_rules - 3 do old_normal_rules[#old_normal_rules + 1] = deep_copy(legacy_rules[index]) end
			local changed = false
			for _, rule in ipairs(old_normal_rules) do
				if rule.description:find("Right Shift:", 1, true) == 1 then
					for _, manipulator in ipairs(rule.manipulators or {}) do
						for _, event in ipairs(manipulator.to_if_alone or {}) do
							if event.key_code == "w" then event.key_code = "q"; changed = true end
						end
					end
				end
			end
			helpers.assert_true(changed, "fixture must collapse two logical outputs onto one physical key")
			local path = "/merge/non-bijective-layout.json"
			local existing = existing_config(old_normal_rules)
			existing.global.show_in_menu_bar = false
			existing.global.show_profile_name_in_menu_bar = false
			existing.global.ask_for_confirmation_before_quitting = false
			existing.global.check_for_updates_on_startup = false
			existing.profiles[2].complex_modifications.parameters = {
				["basic.to_if_alone_timeout_milliseconds"] = old_state.tap_hold_timeout_ms,
				["basic.simultaneous_threshold_milliseconds"] = old_state.simultaneous_threshold_ms,
			}
			local original_json = _G.hs.json.encode(existing)
			fixture.file_data[path] = original_json

			local result, merge_err = Generator.merge_into_existing_config(
				generated,
				path,
				legacy_rules,
				migration_context
			)
			helpers.assert_nil(result,
				"two distinct logical characters cannot prove ownership of the same physical key")
			helpers.assert_true(type(merge_err) == "string" and merge_err:find("ambiguous legacy", 1, true) ~= nil)
			helpers.assert_eq(fixture.file_data[path], original_json,
				"failed bijection proof must preserve the existing config byte-for-byte")
		end)
	end)

	helpers.it("does not claim a personal rule from a generic ErgoptiPlus-era title alone", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local install_legacy_static_fixtures = fixture.install_legacy_static_fixtures
			install_legacy_static_fixtures()
			local current_state, actions, keys = legacy_layout_scenario("q", "none")
			local combos = {
				{
					id = "modifier_pair",
					label = "Modifier pair",
					from = {
						simultaneous = { { key_code = "a" }, { key_code = "b" } },
						simultaneous_options = { key_down_order = "strict" },
					},
				},
			}
			local generated, build_err, legacy_rules, migration_context = Generator.build_karabiner_json(
				current_state,
				actions,
				keys,
				combos,
				{},
				"/managed/",
				TOKEN
			)
			helpers.assert_not_nil(generated, build_err)
			local generic_rules = {}
			for _, title in ipairs({
				"CapsWord — personal rule",
				"Navigation layer — personal rule",
				"Special key combos — personal rule",
				"Script control: physical rcmd + personal rule",
				"Paused script control: option + personal rule",
				"Left Shift: personal rule",
				"Modifier pair: personal rule",
				"Modifier pair (a→b): personal rule",
			}) do
				generic_rules[#generic_rules + 1] = personal_rule(title)
			end
			local path = "/merge/generic-title.json"
			local existing = existing_config(generic_rules)
			fixture.file_data[path] = _G.hs.json.encode(existing)

			local result, merge_err = Generator.merge_into_existing_config(
				generated,
				path,
				legacy_rules,
				migration_context
			)
			helpers.assert_not_nil(result, merge_err)
			local merged_rules = result.profiles[2].complex_modifications.rules
			for _, generic in ipairs(generic_rules) do
				local preserved = 0
				for _, rule in ipairs(merged_rules) do
					if helpers.deep_equal(rule, generic) then preserved = preserved + 1 end
				end
				helpers.assert_eq(preserved, 1,
					"a generic description without a private runtime signature remains personal: "
						.. generic.description)
			end
		end)
	end)

	helpers.it("reports every personal legacy-signature conflict with one remediation", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local build = fixture.build
			local install_legacy_static_fixtures = fixture.install_legacy_static_fixtures
			install_legacy_static_fixtures()
			local generated, build_err, legacy_rules, migration_context = build(TOKEN)
			helpers.assert_not_nil(generated, build_err)

			local variable_rule = personal_rule("personal variable owner")
			variable_rule.manipulators[1].to = {
				{ set_variable = { name = "ke_held_personal_macro", value = 1 } },
			}
			local shell_rule = personal_rule("personal log rotation")
			shell_rule.manipulators[1].to = {
				{ shell_command = "echo personal >> /tmp/karabiner_kc.log.backup" },
			}

			local path = "/merge/personal-signature-conflicts.json"
			local existing = existing_config({ shell_rule })
			existing.profiles[1].complex_modifications.rules = { variable_rule }
			local original_json = _G.hs.json.encode(existing)
			fixture.file_data[path] = original_json

			local result, merge_err = Generator.merge_into_existing_config(
				generated,
				path,
				legacy_rules,
				migration_context
			)
			helpers.assert_nil(result,
				"personal signature collisions must remain fail-closed")
			helpers.assert_type(merge_err, "string")
			helpers.assert_true(merge_err:find("2 ambiguous legacy ErgoptiPlus rules", 1, true) ~= nil,
				"one diagnostic must aggregate every conflicting personal rule")
			helpers.assert_true(merge_err:find("profile 1 rule 1", 1, true) ~= nil)
			helpers.assert_true(merge_err:find("profile 2 rule 1", 1, true) ~= nil)
			helpers.assert_true(merge_err:find("ke_held_", 1, true) ~= nil,
				"the diagnostic must identify the variable-signature family")
			helpers.assert_true(merge_err:find("karabiner_kc.log", 1, true) ~= nil,
				"the diagnostic must identify the log-path signature family")
			helpers.assert_true(merge_err:find("rename the personal signature", 1, true) ~= nil)
			helpers.assert_true(merge_err:find("remove stale ErgoptiPlus rules", 1, true) ~= nil)
			helpers.assert_eq(fixture.file_data[path], original_json,
				"diagnosis must not mutate the personal Karabiner configuration")
		end)
	end)

	helpers.it("migrates a proven A graph across config and layout B so crash leaves it inert (legacy-a-to-b-crash-inert)", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local install_legacy_static_fixtures = fixture.install_legacy_static_fixtures
			install_legacy_static_fixtures()
			local old_state, old_actions, keys = legacy_layout_scenario("q", "logical_escape")
			local old_generated, old_build_err, old_legacy = Generator.build_karabiner_json(
				old_state,
				old_actions,
				keys,
				{},
				{},
				"/managed/",
				OLD_TOKEN_A
			)
			helpers.assert_not_nil(old_generated, old_build_err)
			local old_normal_rules = {}
			for index = 1, #old_legacy - 3 do
				old_normal_rules[#old_normal_rules + 1] = deep_copy(old_legacy[index])
			end

			local new_state, new_actions = legacy_layout_scenario("w", "none")
			local generated, build_err, current_legacy, migration_context = Generator.build_karabiner_json(
				new_state,
				new_actions,
				keys,
				{},
				{},
				"/managed/",
				TOKEN
			)
			helpers.assert_not_nil(generated, build_err)
			helpers.assert_not_nil(migration_context,
				"generation must return the state-independent legacy ownership proof context")

			local path = "/merge/legacy-a-to-b.json"
			local before = personal_rule("personal before old graph")
			local after = personal_rule("personal after old graph")
			local rules = { before }
			for _, rule in ipairs(old_normal_rules) do rules[#rules + 1] = rule end
			rules[#rules + 1] = after
			local existing = existing_config(rules)
			existing.global.show_in_menu_bar = false
			existing.global.show_profile_name_in_menu_bar = false
			existing.global.ask_for_confirmation_before_quitting = false
			existing.global.check_for_updates_on_startup = false
			existing.profiles[2].complex_modifications.parameters = {
				["basic.to_if_alone_timeout_milliseconds"] = old_state.tap_hold_timeout_ms,
				["basic.simultaneous_threshold_milliseconds"] = old_state.simultaneous_threshold_ms,
			}
			fixture.file_data[path] = _G.hs.json.encode(existing)

			local result, merge_err = Generator.merge_into_existing_config(
				generated,
				path,
				current_legacy,
				migration_context
			)
			helpers.assert_not_nil(result, merge_err)
			local merged_rules = result.profiles[2].complex_modifications.rules
			helpers.assert_true(helpers.deep_equal(merged_rules[1], before),
				"a personal rule before the proven block must remain byte-for-byte equivalent")
			helpers.assert_true(helpers.deep_equal(merged_rules[#merged_rules], after),
				"a personal rule after the proven block must remain byte-for-byte equivalent")

			local old_ungated_count = 0
			local managed_count = 0
			for _, rule in ipairs(merged_rules) do
				if rule.description ~= before.description and rule.description ~= after.description then
					local token = rule.description:match("^%[ErgoptiPlus managed:([0-9a-f]+):[a-z]+%] ")
					if token == TOKEN then managed_count = managed_count + 1 else old_ungated_count = old_ungated_count + 1 end
					for _, manipulator in ipairs(rule.manipulators or {}) do
						helpers.assert_eq(condition_count(manipulator, MODE_NAME, 1)
							+ condition_count(manipulator, MODE_NAME, 2), 1,
							"every non-personal rule left after A→B migration must have one atomic mode")
						helpers.assert_eq(condition_count(manipulator, REVOKED_NAME, 0), 1,
							"migrated rules must also reject a tombstoned generation")
					end
				end
			end
			helpers.assert_true(managed_count > 0, "the B generation must be installed")
			helpers.assert_eq(old_ungated_count, 0,
				"no A-generation rule may survive without a crash-revocable lease")
		end)
	end)

	helpers.it("refuses an A graph with a personal rule interleaved instead of claiming it (legacy-a-ambiguous-fails-closed)", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local install_legacy_static_fixtures = fixture.install_legacy_static_fixtures
			install_legacy_static_fixtures()
			local old_state, old_actions, keys = legacy_layout_scenario("q", "logical_escape")
			local _, old_build_err, old_legacy = Generator.build_karabiner_json(
				old_state,
				old_actions,
				keys,
				{},
				{},
				"/managed/",
				OLD_TOKEN_A
			)
			helpers.assert_nil(old_build_err)
			local old_normal_rules = {}
			for index = 1, #old_legacy - 3 do old_normal_rules[#old_normal_rules + 1] = deep_copy(old_legacy[index]) end
			table.insert(old_normal_rules, 2, personal_rule("personal interleaved in old graph"))

			local new_state, new_actions = legacy_layout_scenario("w", "none")
			local generated, build_err, current_legacy, migration_context = Generator.build_karabiner_json(
				new_state,
				new_actions,
				keys,
				{},
				{},
				"/managed/",
				TOKEN
			)
			helpers.assert_not_nil(generated, build_err)
			local path = "/merge/legacy-a-ambiguous.json"
			local existing = existing_config(old_normal_rules)
			existing.global.show_in_menu_bar = false
			existing.global.show_profile_name_in_menu_bar = false
			existing.global.ask_for_confirmation_before_quitting = false
			existing.global.check_for_updates_on_startup = false
			existing.profiles[2].complex_modifications.parameters = {
				["basic.to_if_alone_timeout_milliseconds"] = old_state.tap_hold_timeout_ms,
				["basic.simultaneous_threshold_milliseconds"] = old_state.simultaneous_threshold_ms,
			}
			local original_json = _G.hs.json.encode(existing)
			fixture.file_data[path] = original_json

			local result, merge_err = Generator.merge_into_existing_config(
				generated,
				path,
				current_legacy,
				migration_context
			)
			helpers.assert_nil(result,
				"an interrupted ownership proof must abort before any personal rule can be removed")
			helpers.assert_true(type(merge_err) == "string" and merge_err:find("ambiguous legacy", 1, true) ~= nil,
				"the refusal must diagnose the legacy ownership ambiguity explicitly")
			helpers.assert_eq(fixture.file_data[path], original_json,
				"a failed ownership proof must leave karabiner.json byte-for-byte untouched")
		end)
	end)

	helpers.it("refuses one exact current-state legacy fingerprint without its complete block (legacy-fragment-exact-fails-closed)", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local install_legacy_static_fixtures = fixture.install_legacy_static_fixtures
			install_legacy_static_fixtures()
			local current_state, actions, keys = legacy_layout_scenario("q", "none")
			local generated, build_err, legacy_rules, migration_context = Generator.build_karabiner_json(
				current_state,
				actions,
				keys,
				{},
				{},
				"/managed/",
				TOKEN
			)
			helpers.assert_not_nil(generated, build_err)
			local isolated_fingerprint = nil
			for _, fingerprint in ipairs(legacy_rules) do
				if fingerprint.description:find("Script control: physical rcmd + ", 1, true) == 1 then
					isolated_fingerprint = deep_copy(fingerprint)
					break
				end
			end
			helpers.assert_not_nil(isolated_fingerprint,
				"the fixture must expose one exact current-state historical fingerprint")

			local path = "/merge/legacy-fragment-exact.json"
			local existing = existing_config({ isolated_fingerprint })
			existing.global.show_in_menu_bar = false
			existing.global.show_profile_name_in_menu_bar = false
			existing.global.ask_for_confirmation_before_quitting = false
			existing.global.check_for_updates_on_startup = false
			existing.profiles[2].complex_modifications.parameters = {
				["basic.to_if_alone_timeout_milliseconds"] = current_state.tap_hold_timeout_ms,
				["basic.simultaneous_threshold_milliseconds"] = current_state.simultaneous_threshold_ms,
			}
			local original_json = _G.hs.json.encode(existing)
			fixture.file_data[path] = original_json

			local result, merge_err = Generator.merge_into_existing_config(
				generated,
				path,
				legacy_rules,
				migration_context
			)
			helpers.assert_nil(result,
				"an exact historical fragment is not ownership proof for the complete generated block")
			helpers.assert_true(type(merge_err) == "string"
				and merge_err:find("ambiguous legacy", 1, true) ~= nil,
				"the exact fragment must produce an explicit ownership-ambiguity diagnostic")
			helpers.assert_eq(fixture.file_data[path], original_json,
				"fragment refusal must leave karabiner.json byte-for-byte untouched")
		end)
	end)

	helpers.it("treats exact pre-lease fingerprints as non-owning hints without complete-block context", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local build = fixture.build
			local generated, build_err, legacy_rules = build(TOKEN)
			helpers.assert_not_nil(generated, build_err)
			helpers.assert_true(type(legacy_rules) == "table" and #legacy_rules > 0,
				"build must return historical rules separately for first-upgrade cleanup")
			local exact_legacy = {
				description = "Script control: physical rcmd + delete_or_backspace → key_107",
				manipulators = {
					{
						type = "basic",
						from = {
							key_code = "delete_or_backspace",
							modifiers = { optional = { "any" } },
						},
						conditions = {
							{ type = "variable_if", name = "ke_held_right_command", value = 1 },
						},
						to = {
							{ key_code = "key_107", modifiers = { "left_control", "left_shift" } },
						},
					},
				},
			}
			local normal_fingerprint_count = 0
			for _, fingerprint in ipairs(legacy_rules) do
				if helpers.deep_equal(fingerprint, exact_legacy) then
					normal_fingerprint_count = normal_fingerprint_count + 1
				end
			end
			helpers.assert_eq(normal_fingerprint_count, 1,
				"migration must pin the exact normal rule deployed by old builds")
			local modified_twin = deep_copy(exact_legacy)
			modified_twin.manipulators[1].to[1].key_code = "personal_override"
			helpers.assert_eq(modified_twin.description, exact_legacy.description,
				"the near match must differ structurally, not by description")
			local exact_paused_legacy = {
				description = "Paused script control: option + delete_or_backspace → key_107",
				manipulators = {
					{
						type = "basic",
						from = {
							key_code = "delete_or_backspace",
							modifiers = { mandatory = { "option" }, optional = { "any" } },
						},
						to = {
							{ key_code = "key_107", modifiers = { "left_control", "left_shift" } },
						},
					},
				},
			}
			local paused_fingerprint_count = 0
			for _, fingerprint in ipairs(legacy_rules) do
				if helpers.deep_equal(fingerprint, exact_paused_legacy) then
					paused_fingerprint_count = paused_fingerprint_count + 1
				end
			end
			helpers.assert_eq(paused_fingerprint_count, 1,
				"migration must pin the exact minimal rule deployed by old paused builds")

			local path = "/merge/legacy-fingerprint.json"
			local existing = existing_config({
				personal_rule("personal before legacy"),
				exact_legacy,
				modified_twin,
				exact_paused_legacy,
				personal_rule("personal after legacy"),
			})
			existing.profiles[1].complex_modifications.rules = {
				personal_rule("inactive before legacy"),
				deep_copy(exact_legacy),
				personal_rule("inactive after legacy"),
			}
			fixture.file_data[path] = _G.hs.json.encode(existing)
			local result, merge_err = Generator.merge_into_existing_config(
				generated,
				path,
				legacy_rules
			)
			helpers.assert_not_nil(result, merge_err)
			local inactive_rules = result.profiles[1].complex_modifications.rules
			helpers.assert_eq(#inactive_rules, 3,
				"an isolated exact fingerprint must remain personal without complete-block proof")
			helpers.assert_eq(inactive_rules[1].description, "inactive before legacy")
			helpers.assert_true(helpers.deep_equal(inactive_rules[2], exact_legacy),
				"the exact historical-looking fragment must remain structurally unchanged")
			helpers.assert_eq(inactive_rules[3].description, "inactive after legacy")

			local exact_count = 0
			local exact_paused_count = 0
			local modified_count = 0
			for _, rule in ipairs(result.profiles[2].complex_modifications.rules) do
				if helpers.deep_equal(rule, exact_legacy) then exact_count = exact_count + 1 end
				if helpers.deep_equal(rule, exact_paused_legacy) then
					exact_paused_count = exact_paused_count + 1
				end
				if helpers.deep_equal(rule, modified_twin) then modified_count = modified_count + 1 end
			end
			helpers.assert_eq(exact_count, 1,
				"one exact normal fragment is insufficient evidence for deletion")
			helpers.assert_eq(exact_paused_count, 1,
				"one exact pause fragment is insufficient evidence for deletion")
			helpers.assert_eq(modified_count, 1,
				"a same-description rule with one modified field must remain personal")
		end)
	end)
end)
