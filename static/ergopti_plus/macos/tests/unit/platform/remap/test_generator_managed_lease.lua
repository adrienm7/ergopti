--- tests/unit/platform/remap/test_generator_managed_lease.lua

--- ==============================================================================
--- MODULE: Managed Lease Generator Generation Gates
--- DESCRIPTION:
--- Verifies exact ownership and non-destructive generation with isolated fixtures.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.generator_managed_lease_fixture")
local TOKEN = support.TOKEN
local OLD_TOKEN_A = support.OLD_TOKEN_A
local MODE_NAME = support.MODE_NAME
local REVOKED_NAME = support.REVOKED_NAME
local LegacyReleaseSchemas = support.LegacyReleaseSchemas
local state = support.state
local condition_count = support.condition_count
local collect_variable_names = support.collect_variable_names
local personal_rule = support.personal_rule
local existing_config = support.existing_config
local with_fixture = support.with_fixture

helpers.describe("Karabiner generator managed lease gates", function()
	helpers.it("pins all eight pre-lease generator blobs from dev.1 through dev.107", function()
		with_fixture(function(fixture)
			local expected = {
				b5fc0ee90aa0577ea6ee75cd80708c5bccb95bf4 = true,
				["1845f742906e373867897c54f4fed4829bfbb70e"] = true,
				["950a23058730a1269bcb2764b596978664387618"] = true,
				ee23c3b098e3121d8c026c36010aa46d514d8e9b = true,
				["40e249cd41ba8194a0931c84f9aad91808d4caaa"] = true,
				["6eecede1a8c6e413a78d18082002d2b69dd68301"] = true,
				c3056cd429144abb873170a0216c139f742cfa12 = true,
				["213080366d7950e67665c4b0a2ae794ce6ec5502"] = true,
			}
			local metadata = LegacyReleaseSchemas.release_metadata()
			helpers.assert_eq(#metadata, 8, "every distinct released pre-lease generator blob needs a fixture")
			for _, release in ipairs(metadata) do
				helpers.assert_true(expected[release.generator_blob] == true,
					"unexpected or unproven release fixture blob: " .. tostring(release.generator_blob))
				expected[release.generator_blob] = nil
			end
			for missing_blob in pairs(expected) do
				helpers.assert_true(false, "missing released generator fixture blob: " .. missing_blob)
			end
		end)
	end)

	helpers.it("replays the dev.1-dev.64 unsafe log command and the dev.65 quoting fix exactly", function()
		with_fixture(function(fixture)
			local install_legacy_static_fixtures = fixture.install_legacy_static_fixtures
			install_legacy_static_fixtures()
			local context = {
				available_actions = {
					{ id = "none", label = "None", karabiner_to = {} },
					{
						id = "logical_x",
						label = "Logical X",
						logical_char = "x",
						karabiner_modifiers = {},
						karabiner_to = { { key_code = "q" } },
					},
				},
				tap_hold_keys = {
					{ id = "left_shift", label = "Left Shift", from = { key_code = "left_shift" } },
				},
				mod_combos = {},
				non_canonical = {},
				capsword = _G.hs.json.decode(fixture.file_data["/managed/capsword.json"]),
				layer_keys = _G.hs.json.decode(fixture.file_data["/managed/layer_keys.json"]),
				combos = _G.hs.json.decode(fixture.file_data["/managed/combos.json"]),
				script_control_slots = {
					{ from_key = "delete_or_backspace", sentinel = "key_107" },
					{ from_key = "return_or_enter", sentinel = "key_105" },
					{ from_key = "escape", sentinel = "key_113" },
				},
				physical_log_path = "/tmp/o'brien/karabiner_kc.log",
			}
			local fixture_state = state({
				tap_hold_config = {
					left_shift = { tap = "logical_x", hold = "none" },
				},
			})
			local dev1 = LegacyReleaseSchemas.build_normal_candidate(
				"v0.0.0-dev.1-v0.0.0-dev.44",
				fixture_state,
				false,
				context
			)
			local dev64 = LegacyReleaseSchemas.build_normal_candidate(
				"v0.0.0-dev.45-v0.0.0-dev.64",
				fixture_state,
				false,
				context
			)
			local dev65 = LegacyReleaseSchemas.build_normal_candidate(
				"v0.0.0-dev.65",
				fixture_state,
				false,
				context
			)
			local dev1_command = dev1[#dev1].manipulators[1].to[2].shell_command
			local dev64_command = dev64[#dev64].manipulators[1].to[2].shell_command
			local dev65_command = dev65[#dev65].manipulators[1].to[2].shell_command
			helpers.assert_eq(dev1_command, "echo 'left_shift' >> '/tmp/o'brien/karabiner_kc.log'")
			helpers.assert_eq(dev64_command, dev1_command,
				"adding paused rules in dev.45 did not change the normal graph's historical shell command")
			helpers.assert_eq(
				dev65_command,
				"echo 'left_shift' >> '/tmp/o'\\''brien/karabiner_kc.log'",
				"dev.65 must replay its released apostrophe-safe shell quoting"
			)
		end)
	end)

	helpers.it("rejects missing and malformed generation tokens", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local build = fixture.build
			local missing_result, missing_err = build(nil)
			helpers.assert_nil(missing_result, "an omitted lease token must fail closed")
			helpers.assert_true(type(missing_err) == "string" and missing_err ~= "")
			for _, token in ipairs({ false, "", "abc", string.rep("g", 32), string.rep("a", 31), string.rep("a", 33), string.rep("A", 32) }) do
				local result, err = build(token)
				helpers.assert_nil(result, "invalid token must fail closed: " .. tostring(token))
				helpers.assert_true(type(err) == "string" and err ~= "", "invalid token must explain the failure")
			end
			local paused_result, paused_err = Generator.build_paused_script_control_rules(nil)
			helpers.assert_nil(paused_result, "pause-only rules must also reject an omitted token")
			helpers.assert_true(type(paused_err) == "string" and paused_err ~= "")
		end)
	end)

	helpers.it("derives exact generation-scoped variable names", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			helpers.assert_eq(Generator.mode_variable_name(TOKEN), MODE_NAME)
			helpers.assert_eq(Generator.revoked_variable_name(TOKEN), REVOKED_NAME)
		end)
	end)

	helpers.it("scopes every runtime producer and consumer without mutating the cached catalogue", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local build = fixture.build
			local token_b = "fedcba9876543210fedcba9876543210"
			local scoped = function(logical_name, token)
				return "ergopti_" .. logical_name .. "_" .. token
			end
			fixture.file_data["/managed/capsword.json"] = _G.hs.json.encode({
				description = "CapsWord runtime probe",
				manipulators = {
					{
						type = "basic",
						from = { key_code = "caps_lock" },
						conditions = {
							{ type = "variable_if", name = "capsword", value = 0 },
							{
								type = "variable_if",
								name = "system.use_fkeys_as_standard_function_keys",
								value = 1,
							},
						},
						to = { { set_variable = { name = "capsword", value = 1 } } },
					},
				},
			})
			fixture.file_data["/managed/layer_keys.json"] = _G.hs.json.encode({
				description = "Layer runtime probe",
				manipulators = {
					{
						type = "basic",
						from = { key_code = "h" },
						conditions = {
							{ type = "variable_if", name = "layer_active", value = 1 },
						},
						to = { { key_code = "left_arrow" } },
					},
				},
			})

			local actions = {
				{ id = "none", label = "None", karabiner_to = {} },
				{
					id = "layer",
					label = "Layer",
					karabiner_to = { { set_variable = { name = "layer_active", value = 1 } } },
					karabiner_to_after_key_up = {
						{ set_variable = { name = "layer_active", value = 0 } },
					},
				},
			}
			local keys = {
				{ id = "right_command", label = "Right Command", from = { key_code = "right_command" } },
			}
			local runtime_state = state({
				tap_hold_config = { right_command = { tap = "none", hold = "layer" } },
			})
			local function build_runtime(token)
				return Generator.build_karabiner_json(
					runtime_state,
					actions,
					keys,
					{},
					{},
					"/managed/",
					token
				)
			end

			local generated_a, err_a, legacy_a, legacy_context_a = build_runtime(TOKEN)
			helpers.assert_not_nil(generated_a, err_a)
			local generated_b, err_b = build_runtime(token_b)
			helpers.assert_not_nil(generated_b, err_b)
			helpers.assert_eq(actions[2].karabiner_to[1].set_variable.name, "layer_active",
				"one build must not tokenize the cached catalogue used by the next regeneration")
			helpers.assert_eq(#actions[2].karabiner_to, 1,
				"F20 sentinel injection must also stay confined to the detached build graph")
			helpers.assert_eq(
				legacy_context_a.available_actions[2].karabiner_to[2].set_variable.name,
				"layer_active",
				"legacy reconstruction must retain the unscoped historical action graph"
			)

			local names_a = collect_variable_names(generated_a)
			local names_b = collect_variable_names(generated_b)
			local expected_logical = {
				"layer_active",
				"capsword",
				"ke_held_right_command",
			}
			for _, logical_name in ipairs(expected_logical) do
				local name_a = scoped(logical_name, TOKEN)
				local name_b = scoped(logical_name, token_b)
				helpers.assert_true((names_a[name_a] or 0) > 0,
					"generation A must consume or produce " .. name_a)
				helpers.assert_true((names_b[name_b] or 0) > 0,
					"generation B must consume or produce " .. name_b)
				helpers.assert_nil(names_a[name_b], "generation A must not reference B runtime state")
				helpers.assert_nil(names_b[name_a], "generation B must not reference A runtime state")
				helpers.assert_nil(names_a[logical_name], "bare personal names must stay unclaimed")
				helpers.assert_nil(names_b[logical_name], "bare personal names must stay unclaimed")
			end
			helpers.assert_true((names_a["system.use_fkeys_as_standard_function_keys"] or 0) > 0,
				"the stock system preference must remain intentionally shared and unrenamed")

			local legacy_names = collect_variable_names(legacy_a)
			helpers.assert_true((legacy_names.layer_active or 0) > 0)
			helpers.assert_true((legacy_names.capsword or 0) > 0)
			helpers.assert_true((legacy_names.ke_held_right_command or 0) > 0,
				"legacy ownership proof must retain the exact historical bare graph")
			fixture.file_data["/managed/capsword.json"] = nil
			fixture.file_data["/managed/layer_keys.json"] = nil
		end)
	end)

	helpers.it("gates every manipulator and preserves its existing conditions", function()
		with_fixture(function(fixture)
			local build = fixture.build
			fixture.file_data["/managed/capsword.json"] = _G.hs.json.encode({
				description = "Static multi-manipulator rule",
				manipulators = {
					{
						type = "basic",
						from = { key_code = "a" },
						conditions = { { type = "frontmost_application_if", bundle_identifiers = { "example" } } },
						to = { { key_code = "b" } },
					},
					{
						type = "basic",
						from = { key_code = "c" },
						to = { { key_code = "d" } },
					},
				},
			})

			local result, err = build(TOKEN)
			helpers.assert_not_nil(result, err)
			local rules = result.profiles[1].complex_modifications.rules
			local normal_count = 0
			local pause_count = 0
			local preserved_application_condition = false
			for _, rule in ipairs(rules) do
				local tagged_token, mode = rule.description:match(
					"^%[ErgoptiPlus managed:([0-9a-f]+):([a-z]+)%] "
				)
				helpers.assert_eq(tagged_token, TOKEN, "every emitted rule must carry the exact lease token")
				helpers.assert_true(mode == "normal" or mode == "pause", "every emitted rule must declare its pause mode")
				if mode == "normal" then normal_count = normal_count + 1 else pause_count = pause_count + 1 end
				for _, manipulator in ipairs(rule.manipulators) do
					local expected_mode = mode == "pause" and 2 or 1
					helpers.assert_eq(condition_count(manipulator, MODE_NAME, expected_mode), 1,
						"every manipulator must require its exact atomic mode")
					helpers.assert_eq(condition_count(manipulator, REVOKED_NAME, 0), 1,
						"every manipulator must reject a tombstoned generation")
					for _, condition in ipairs(manipulator.conditions or {}) do
						if condition.type == "frontmost_application_if" then preserved_application_condition = true end
					end
				end
			end
			helpers.assert_true(normal_count > 0, "full config must contain normal rules")
			helpers.assert_eq(pause_count, 3, "full config must contain all three pause-only script controls")
			helpers.assert_true(preserved_application_condition, "central gating must preserve existing conditions")
		end)
	end)

	helpers.it("fails closed if raw rule data uses a reserved legacy lease namespace", function()
		with_fixture(function(fixture)
			local build = fixture.build
			fixture.file_data["/managed/capsword.json"] = _G.hs.json.encode({
				description = "Conflicting raw rule",
				manipulators = {
					{
						type = "basic",
						from = { key_code = "a" },
						conditions = {
							{ type = "variable_if", name = "ergopti_lease_" .. OLD_TOKEN_A, value = 1 },
						},
						to = { { key_code = "b" } },
					},
				},
			})
			local result, err = build(TOKEN)
			helpers.assert_nil(result, "a foreign lease condition could silently disable the generated rule")
			helpers.assert_true(type(err) == "string" and err:find("reserved generation variable", 1, true) ~= nil)
			fixture.file_data["/managed/capsword.json"] = nil
		end)
	end)

	helpers.it("builds pause-only script controls with atomic mode=2", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local rules, err = Generator.build_paused_script_control_rules(TOKEN)
			helpers.assert_not_nil(rules, err)
			helpers.assert_eq(#rules, 3)
			for _, rule in ipairs(rules) do
				helpers.assert_true(rule.description:match(
					"^%[ErgoptiPlus managed:" .. TOKEN .. ":pause%] "
				) ~= nil, "pause-only rule must carry an exact managed tag")
				for _, manipulator in ipairs(rule.manipulators) do
					helpers.assert_eq(condition_count(manipulator, MODE_NAME, 2), 1)
					helpers.assert_eq(condition_count(manipulator, MODE_NAME, 1), 0)
					helpers.assert_eq(condition_count(manipulator, REVOKED_NAME, 0), 1)
				end
			end
		end)
	end)

	helpers.it("scopes configured timings to managed manipulators during a preserving merge", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local build_with = fixture.build_with
			local tap_action = {
				id = "tap_action",
				label = "Tap action",
				karabiner_to = { { key_code = "f18" } },
			}
			local combo_action = {
				id = "combo_action",
				label = "Combo action",
				karabiner_to = { { key_code = "f19" } },
			}
			local custom_state = state({
				tap_hold_timeout_ms = 345,
				simultaneous_threshold_ms = 67,
				tap_hold_config = {
					right_command = { tap = "tap_action", hold = "none" },
				},
				mod_combos_config = {
					pair = { tap = "none", hold = "none", combo = "combo_action" },
				},
			})
			local generated, build_err, legacy_rules = build_with(
				custom_state,
				{
					{ id = "none", label = "None", karabiner_to = {} },
					tap_action,
					combo_action,
				},
				{
					{
						id = "right_command",
						label = "Right Command timing probe",
						from = { key_code = "right_command" },
					},
				},
				{
					{
						id = "pair",
						label = "Pair timing probe",
						from = {
							simultaneous = { { key_code = "a" }, { key_code = "b" } },
							simultaneous_options = { key_down_order = "strict" },
						},
					},
				}
			)
			helpers.assert_not_nil(generated, build_err)
			local legacy_tap_timeout = nil
			local legacy_simultaneous_threshold = nil
			for _, rule in ipairs(legacy_rules) do
				helpers.assert_true(rule.description:find("[ErgoptiPlus managed:", 1, true) == nil,
					"migration fingerprints must be captured before ownership tags")
				for _, manipulator in ipairs(rule.manipulators) do
					for _, condition in ipairs(manipulator.conditions or {}) do
						helpers.assert_true(condition.name ~= MODE_NAME
							and condition.name ~= REVOKED_NAME,
							"migration fingerprints must be captured before generation gates")
					end
					if type(manipulator.to_if_alone) == "table" then
						legacy_tap_timeout = manipulator.parameters
							and manipulator.parameters["basic.to_if_alone_timeout_milliseconds"]
							or legacy_tap_timeout
					end
					if type(manipulator.from) == "table"
						and type(manipulator.from.simultaneous) == "table" then
						legacy_simultaneous_threshold = manipulator.parameters
							and manipulator.parameters["basic.simultaneous_threshold_milliseconds"]
							or legacy_simultaneous_threshold
					end
				end
			end
			helpers.assert_nil(legacy_tap_timeout,
				"default tap timing must not contaminate the historical fingerprint")
			helpers.assert_nil(legacy_simultaneous_threshold,
				"simultaneous timing must not contaminate the historical fingerprint")

			local path = "/merge/timing.json"
			local existing = existing_config({ personal_rule("personal timing rule") })
			fixture.file_data[path] = _G.hs.json.encode(existing)
			local merged, merge_err = Generator.merge_into_existing_config(generated, path)
			helpers.assert_not_nil(merged, merge_err)
			local selected_complex = merged.profiles[2].complex_modifications
			helpers.assert_true(helpers.deep_equal(
				selected_complex.parameters,
				existing.profiles[2].complex_modifications.parameters
			), "personal profile-level timing parameters must remain unchanged")

			local tap_timeout = nil
			local simultaneous_threshold = nil
			for _, rule in ipairs(selected_complex.rules) do
				for _, manipulator in ipairs(rule.manipulators or {}) do
					if type(manipulator.to_if_alone) == "table" then
						tap_timeout = manipulator.parameters
							and manipulator.parameters["basic.to_if_alone_timeout_milliseconds"]
							or tap_timeout
					end
					if type(manipulator.from) == "table"
						and type(manipulator.from.simultaneous) == "table" then
						simultaneous_threshold = manipulator.parameters
							and manipulator.parameters["basic.simultaneous_threshold_milliseconds"]
							or simultaneous_threshold
					end
				end
			end
			helpers.assert_eq(tap_timeout, 345,
				"managed tap/hold rules must carry the configured timeout locally")
			helpers.assert_eq(simultaneous_threshold, 67,
				"managed simultaneous rules must carry the configured threshold locally")
		end)
	end)

	helpers.it("keeps the global simultaneous window authoritative only for managed rules", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local build_with = fixture.build_with
			local install_legacy_static_fixtures = fixture.install_legacy_static_fixtures
			local saved_capsword = fixture.file_data["/managed/capsword.json"]
			local saved_layer_keys = fixture.file_data["/managed/layer_keys.json"]
			local saved_combos = fixture.file_data["/managed/combos.json"]
			install_legacy_static_fixtures()
			fixture.file_data["/managed/combos.json"] = _G.hs.json.encode({
				description = "Managed simultaneous precedence probe",
				manipulators = {
					{
						type = "basic",
						from = {
							simultaneous = { { key_code = "a" }, { key_code = "b" } },
						},
						parameters = {
							["basic.simultaneous_threshold_milliseconds"] = 500,
						},
						to = { { key_code = "f19" } },
					},
				},
			})

			local generated, build_err, legacy_rules = build_with(
				state({ simultaneous_threshold_ms = 67 }),
				{ { id = "none", label = "None", karabiner_to = {} } },
				{},
				{}
			)
			fixture.file_data["/managed/capsword.json"] = saved_capsword
			fixture.file_data["/managed/layer_keys.json"] = saved_layer_keys
			fixture.file_data["/managed/combos.json"] = saved_combos
			helpers.assert_not_nil(generated, build_err)

			local source_threshold = nil
			for _, rule in ipairs(legacy_rules) do
				if rule.description == "Managed simultaneous precedence probe" then
					source_threshold = rule.manipulators[1].parameters
						["basic.simultaneous_threshold_milliseconds"]
				end
			end
			helpers.assert_eq(source_threshold, 500,
				"the fixture must prove that the managed source carried a local value")

			local managed_threshold = nil
			for _, rule in ipairs(generated.profiles[1].complex_modifications.rules) do
				if rule.description:find("Managed simultaneous precedence probe", 1, true) then
					managed_threshold = rule.manipulators[1].parameters
						["basic.simultaneous_threshold_milliseconds"]
				end
			end
			helpers.assert_eq(managed_threshold, 67,
				"the user-visible global window must govern every managed simultaneous rule")

			local personal = personal_rule("personal simultaneous timing")
			personal.manipulators[1].from = {
				simultaneous = { { key_code = "x" }, { key_code = "y" } },
			}
			personal.manipulators[1].parameters = {
				["basic.simultaneous_threshold_milliseconds"] = 500,
			}
			local path = "/merge/personal-simultaneous-timing.json"
			fixture.file_data[path] = _G.hs.json.encode(existing_config({ personal }))

			local merged, merge_err = Generator.merge_into_existing_config(generated, path)
			helpers.assert_not_nil(merged, merge_err)
			local personal_threshold = nil
			for _, rule in ipairs(merged.profiles[2].complex_modifications.rules) do
				if rule.description == "personal simultaneous timing" then
					personal_threshold = rule.manipulators[1].parameters
						["basic.simultaneous_threshold_milliseconds"]
				end
			end
			helpers.assert_eq(personal_threshold, 500,
				"regeneration must never rewrite a personal simultaneous rule")
		end)
	end)
end)
