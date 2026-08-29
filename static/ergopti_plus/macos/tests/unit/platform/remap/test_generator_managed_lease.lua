--- tests/unit/platform/remap/test_generator_managed_lease.lua

--- ==============================================================================
--- MODULE: Karabiner Managed Lease Generator Regression Tests
--- DESCRIPTION:
--- Proves that every ErgoptiPlus manipulator is owned by one exact generation,
--- that pause selects only its PAUSED atomic mode, and that regeneration
--- never replaces or mutates a user's Karabiner configuration. These behavioural
--- tests cover the shared-process failure mode where killing stock Karabiner would
--- also destroy unrelated user rules.
--- ==============================================================================

local helpers = require("tests.helpers")
local LegacyReleaseFixtures = require("tests.fixtures.karabiner_legacy_releases")
local LegacyReleaseSchemas = require("platform.remap.legacy_release_fixtures")

local TOKEN = "0123456789abcdef0123456789abcdef"
local OLD_TOKEN_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local OLD_TOKEN_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
local MODE_NAME = "ergopti_mode_" .. TOKEN
local REVOKED_NAME = "ergopti_revoked_" .. TOKEN

local file_data = {}
local unreadable_paths = {}
local file_writes = {}
local file_reads = {}
local missing_parent_paths = {}
local parent_prepare_failures = {}
local parent_prepare_calls = {}
local write_succeeds = true
local before_read = nil
local before_publication = nil

local function run_before_publication(path, content)
	local hook = before_publication
	before_publication = nil
	if hook then hook(path, content) end
end

package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")
package.loaded["adapters.file_system"] = {
	read = function(path) return file_data[path] end,
	read_with_status = function(path)
		file_reads[#file_reads + 1] = path
		if before_read then before_read(path, #file_reads) end
		if missing_parent_paths[path] == true then
			return nil, "error", "missing path prefix"
		end
		if unreadable_paths[path] == true then
			return nil, "error", "injected read failure"
		end
		if file_data[path] == nil then return nil, "absent" end
		return file_data[path], "ok"
	end,
	prepare_parent_for_create = function(path)
		parent_prepare_calls[#parent_prepare_calls + 1] = path
		local failure = parent_prepare_failures[path]
		if failure ~= nil then return false, failure end
		missing_parent_paths[path] = nil
		return true
	end,
	-- An old read()+exists() fallback would misclassify the injected read error
	-- as absence, so this legacy helper intentionally does not expose it.
	exists = function(path) return file_data[path] ~= nil end,
	write = function(path, content)
		run_before_publication(path, content)
		file_writes[#file_writes + 1] = { path = path, content = content, method = "write" }
		if write_succeeds then file_data[path] = content end
		return write_succeeds, write_succeeds and nil or "stub write failure"
	end,
	write_if_unchanged = function(path, content, expected_source)
		run_before_publication(path, content)
		file_writes[#file_writes + 1] = {
			path = path,
			content = content,
			method = "write_if_unchanged",
			expected_source = expected_source,
		}
		if not write_succeeds then return false, "stub write failure" end
		local current = file_data[path]
		local current_status = current == nil and "absent" or "ok"
		local unchanged = type(expected_source) == "table"
			and expected_source.status == current_status
			and (current_status ~= "ok" or expected_source.content == current)
		if not unchanged then return false, "source changed before publication" end
		file_data[path] = content
		return true
	end,
}
package.loaded["infra.config_paths"] = {
	get_config_dir = function() return "/tmp/ergopti_generator_lease" end,
}
package.loaded["infra.keycodes"] = {
	to_name = function(code) return "key_" .. tostring(code) end,
	F13_KARABINER_RETURN = 105,
	F14_KARABINER_BACKSPACE = 107,
	F15_KARABINER_ESCAPE = 113,
	F20_LAYER_NAV_ENTERED = 90,
}

local Generator = helpers.load_with_stubs("platform.remap.generator")

local function state(overrides)
	local result = {
		tap_hold_config = {},
		mod_combos_config = {},
		tap_hold_timeout_ms = 200,
		simultaneous_threshold_ms = 100,
		combo_symmetric = false,
	}
	for key, value in pairs(overrides or {}) do result[key] = value end
	return result
end

local function build(token)
	return Generator.build_karabiner_json(
		state(),
		{ { id = "none", label = "None", karabiner_to = {} } },
		{},
		{},
		{},
		"/managed/",
		token
	)
end

local function build_with(custom_state, actions, keys, combos)
	return Generator.build_karabiner_json(
		custom_state,
		actions,
		keys,
		combos,
		{},
		"/managed/",
		TOKEN
	)
end

local function condition_count(manipulator, name, value)
	local count = 0
	for _, condition in ipairs(manipulator.conditions or {}) do
		if condition.type == "variable_if"
			and condition.name == name
			and condition.value == value then
			count = count + 1
		end
	end
	return count
end

--- Collects variable producers and consumers from a generated rule graph.
--- @param value any Rule graph node.
--- @param names table|nil Mutable name -> count map.
--- @param seen table|nil Visited table identities.
--- @return table names Collected reference counts.
local function collect_variable_names(value, names, seen)
	names = names or {}
	seen = seen or {}
	if type(value) ~= "table" or seen[value] then return names end
	seen[value] = true
	if type(value.set_variable) == "table" and type(value.set_variable.name) == "string" then
		local name = value.set_variable.name
		names[name] = (names[name] or 0) + 1
	end
	if (value.type == "variable_if" or value.type == "variable_unless")
		and type(value.name) == "string" then
		names[value.name] = (names[value.name] or 0) + 1
	end
	for _, nested in pairs(value) do
		if type(nested) == "table" then collect_variable_names(nested, names, seen) end
	end
	return names
end

local function managed_rule(token, mode, label)
	local mode_name = "ergopti_mode_" .. token
	local revoked_name = "ergopti_revoked_" .. token
	return {
		description = string.format("[ErgoptiPlus managed:%s:%s] %s", token, mode, label),
		manipulators = {
			{
				type = "basic",
				from = { key_code = "a" },
				conditions = {
					{ type = "variable_if", name = mode_name, value = mode == "pause" and 2 or 1 },
					{ type = "variable_if", name = revoked_name, value = 0 },
				},
				to = { { key_code = "b" } },
			},
		},
	}
end

local function personal_rule(description)
	return {
		description = description,
		manipulators = {
			{
				type = "basic",
				from = { key_code = "x" },
				to = { { key_code = "y" } },
			},
		},
	}
end

local function deep_copy(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, nested in pairs(value) do copy[deep_copy(key)] = deep_copy(nested) end
	return copy
end

local function install_legacy_static_fixtures()
	file_data["/managed/capsword.json"] = _G.hs.json.encode({
		description = "CapsWord legacy anchor",
		manipulators = {
			{ type = "basic", from = { key_code = "caps_lock" }, to = { { key_code = "caps_lock" } } },
		},
	})
	file_data["/managed/layer_keys.json"] = _G.hs.json.encode({
		description = "Layer legacy anchor",
		manipulators = {
			{ type = "basic", from = { key_code = "a" }, to = { { key_code = "left_arrow" } } },
		},
	})
	file_data["/managed/combos.json"] = _G.hs.json.encode({
		description = "Combo legacy anchor",
		manipulators = {
			{ type = "basic", from = { key_code = "b" }, to = { { key_code = "right_arrow" } } },
		},
	})
end

local function legacy_layout_scenario(physical_key_code, tap_action_id)
	local actions = {
		{ id = "none", label = "None", karabiner_to = {} },
		{
			id = "logical_escape",
			label = "Logical escape",
			logical_char = "x",
			karabiner_modifiers = {},
			karabiner_to = { { key_code = physical_key_code } },
		},
		-- The real French catalogue contains the output-identical compatibility
		-- aliases `cmd_tab` and `alt_tab_apps_list` under one translated label.
		-- Legacy ownership proof must canonicalise only this exact-safe class.
		{
			id = "logical_escape_alias",
			label = "Logical escape",
			logical_char = "x",
			karabiner_modifiers = {},
			karabiner_to = { { key_code = physical_key_code } },
		},
	}
	local keys = {
		{ id = "left_shift", label = "Left Shift", from = { key_code = "left_shift" } },
	}
	local scenario_state = state({
		tap_hold_config = {
			left_shift = { tap = tap_action_id, hold = "none" },
		},
	})
	return scenario_state, actions, keys
end

local function generated_config(rules)
	return {
		profiles = {
			{
				name = "Ergopti generated",
				selected = true,
				complex_modifications = {
					parameters = { generated_parameter = 999 },
					rules = rules,
				},
			},
		},
	}
end

local function existing_config(rules)
	return {
		global = {
			show_in_menu_bar = true,
			show_profile_name_in_menu_bar = true,
			ask_for_confirmation_before_quitting = true,
			check_for_updates_on_startup = true,
			personal_global = "untouched",
		},
		profiles = {
			{
				name = "Work",
				selected = false,
				devices = { { identifiers = { vendor_id = 10 } } },
				complex_modifications = { rules = { personal_rule("work rule") } },
			},
			{
				name = "Personal selected",
				selected = true,
				parameters = { delay_milliseconds_before_open_device = 321 },
				devices = { { identifiers = { vendor_id = 20 } } },
				simple_modifications = { { from = { key_code = "a" }, to = { { key_code = "z" } } } },
				fn_function_keys = { { from = { key_code = "f1" }, to = { { key_code = "display_brightness_decrement" } } } },
				virtual_hid_keyboard = { keyboard_type_v2 = "jis", country_code = 45 },
				complex_modifications = {
					parameters = {
						["basic.to_if_alone_timeout_milliseconds"] = 777,
						personal_parameter = 42,
					},
					rules = rules,
				},
			},
		},
	}
end





-- ===============================================
-- ===============================================
-- ======= 1/ Atomic Generation Gates ============
-- ===============================================
-- ===============================================

helpers.describe("Karabiner generator managed lease gates", function()
	helpers.it("pins all eight pre-lease generator blobs from dev.1 through dev.107", function()
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

	helpers.it("replays the dev.1-dev.64 unsafe log command and the dev.65 quoting fix exactly", function()
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
			capsword = _G.hs.json.decode(file_data["/managed/capsword.json"]),
			layer_keys = _G.hs.json.decode(file_data["/managed/layer_keys.json"]),
			combos = _G.hs.json.decode(file_data["/managed/combos.json"]),
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

	helpers.it("rejects missing and malformed generation tokens", function()
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

	helpers.it("derives exact generation-scoped variable names", function()
		helpers.assert_eq(Generator.mode_variable_name(TOKEN), MODE_NAME)
		helpers.assert_eq(Generator.revoked_variable_name(TOKEN), REVOKED_NAME)
	end)

	helpers.it("scopes every runtime producer and consumer without mutating the cached catalogue", function()
		local token_b = "fedcba9876543210fedcba9876543210"
		local scoped = function(logical_name, token)
			return "ergopti_" .. logical_name .. "_" .. token
		end
		file_data["/managed/capsword.json"] = _G.hs.json.encode({
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
		file_data["/managed/layer_keys.json"] = _G.hs.json.encode({
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
		file_data["/managed/capsword.json"] = nil
		file_data["/managed/layer_keys.json"] = nil
	end)

	helpers.it("gates every manipulator and preserves its existing conditions", function()
		file_data["/managed/capsword.json"] = _G.hs.json.encode({
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

	helpers.it("fails closed if raw rule data uses a reserved legacy lease namespace", function()
		file_data["/managed/capsword.json"] = _G.hs.json.encode({
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
		file_data["/managed/capsword.json"] = nil
	end)

	helpers.it("builds pause-only script controls with atomic mode=2", function()
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

	helpers.it("scopes configured timings to managed manipulators during a preserving merge", function()
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
		file_data[path] = _G.hs.json.encode(existing)
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

	helpers.it("keeps the global simultaneous window authoritative only for managed rules", function()
		local saved_capsword = file_data["/managed/capsword.json"]
		local saved_layer_keys = file_data["/managed/layer_keys.json"]
		local saved_combos = file_data["/managed/combos.json"]
		install_legacy_static_fixtures()
		file_data["/managed/combos.json"] = _G.hs.json.encode({
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
		file_data["/managed/capsword.json"] = saved_capsword
		file_data["/managed/layer_keys.json"] = saved_layer_keys
		file_data["/managed/combos.json"] = saved_combos
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
		file_data[path] = _G.hs.json.encode(existing_config({ personal }))

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





-- ================================================
-- ================================================
-- ======= 2/ Non-Destructive Managed Rule Merge ==
-- ================================================
-- ================================================

helpers.describe("Karabiner generator non-destructive managed merge", function()
	helpers.it("migrates the immutable v0.0.0-dev.74 chord graph without rebuilding it through today's generator", function()
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
		file_data[path] = _G.hs.json.encode(existing)

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

	helpers.it("migrates the one-release v0.0.0-dev.71 paused sentinel schema", function()
		install_legacy_static_fixtures()
		local generated, build_err, legacy_rules, migration_context = build(TOKEN)
		helpers.assert_not_nil(generated, build_err)
		local path = "/merge/release-v71-paused.json"
		local existing = existing_config(LegacyReleaseFixtures.v71_paused_rules())
		existing.profiles[2].complex_modifications.parameters = nil
		file_data[path] = _G.hs.json.encode(existing)

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

	helpers.it("migrates the immutable v0.0.0-dev.45 six-rule paused graph", function()
		install_legacy_static_fixtures()
		local generated, build_err, legacy_rules, migration_context = build(TOKEN)
		helpers.assert_not_nil(generated, build_err)
		local path = "/merge/release-v45-paused.json"
		local existing = existing_config(LegacyReleaseFixtures.v45_paused_rules())
		existing.profiles[2].complex_modifications.parameters = nil
		file_data[path] = _G.hs.json.encode(existing)

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

	helpers.it("migrates the immutable v0.0.0-dev.1 normal graph", function()
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
		file_data[path] = _G.hs.json.encode(existing)

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

	helpers.it("proves a complete legacy graph independently of personal global preferences", function()
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
		file_data[path] = _G.hs.json.encode(existing)

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

	helpers.it("rejects a non-layout F24 output instead of learning it as layout drift", function()
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
		file_data[path] = original_json

		local result, merge_err = Generator.merge_into_existing_config(
			generated,
			path,
			legacy_rules,
			migration_context
		)
		helpers.assert_nil(result,
			"F24 is not a canonical printable layout position and cannot prove legacy ownership")
		helpers.assert_true(type(merge_err) == "string" and merge_err:find("ambiguous legacy", 1, true) ~= nil)
		helpers.assert_eq(file_data[path], original_json,
			"failed layout proof must preserve the personal F24 customization byte-for-byte")
	end)

	helpers.it("requires a bijection between logical characters and physical layout positions", function()
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
		file_data[path] = original_json

		local result, merge_err = Generator.merge_into_existing_config(
			generated,
			path,
			legacy_rules,
			migration_context
		)
		helpers.assert_nil(result,
			"two distinct logical characters cannot prove ownership of the same physical key")
		helpers.assert_true(type(merge_err) == "string" and merge_err:find("ambiguous legacy", 1, true) ~= nil)
		helpers.assert_eq(file_data[path], original_json,
			"failed bijection proof must preserve the existing config byte-for-byte")
	end)

	helpers.it("does not claim a personal rule from a generic ErgoptiPlus-era title alone", function()
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
		file_data[path] = _G.hs.json.encode(existing)

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

	helpers.it("reports every personal legacy-signature conflict with one remediation", function()
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
		file_data[path] = original_json

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
		helpers.assert_eq(file_data[path], original_json,
			"diagnosis must not mutate the personal Karabiner configuration")
	end)

	helpers.it("migrates a proven A graph across config and layout B so crash leaves it inert (legacy-a-to-b-crash-inert)", function()
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
		file_data[path] = _G.hs.json.encode(existing)

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

	helpers.it("refuses an A graph with a personal rule interleaved instead of claiming it (legacy-a-ambiguous-fails-closed)", function()
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
		file_data[path] = original_json

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
		helpers.assert_eq(file_data[path], original_json,
			"a failed ownership proof must leave karabiner.json byte-for-byte untouched")
	end)

	helpers.it("refuses one exact current-state legacy fingerprint without its complete block (legacy-fragment-exact-fails-closed)", function()
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
		file_data[path] = original_json

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
		helpers.assert_eq(file_data[path], original_json,
			"fragment refusal must leave karabiner.json byte-for-byte untouched")
	end)

	helpers.it("treats exact pre-lease fingerprints as non-owning hints without complete-block context", function()
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
		file_data[path] = _G.hs.json.encode(existing)
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

	helpers.it("preserves personal state and replaces only exact managed tags in place", function()
		local path = "/merge/personal.json"
		local near_matches = {
			personal_rule("[ErgoptiPlus managed:" .. string.rep("a", 31) .. ":normal] 31 hex"),
			personal_rule("[ErgoptiPlus managed:" .. string.rep("a", 33) .. ":normal] 33 hex"),
			personal_rule("[ErgoptiPlus managed:" .. string.rep("A", 32) .. ":normal] uppercase"),
			personal_rule("[ErgoptiPlus managed:" .. OLD_TOKEN_A .. ":other] wrong mode"),
			personal_rule("[ErgoptiPlus managed:" .. OLD_TOKEN_A .. ":normal]missing space"),
		}
		local rules = {
			personal_rule("personal before"),
			managed_rule(OLD_TOKEN_A, "normal", "stale normal"),
			personal_rule("personal middle"),
			managed_rule(OLD_TOKEN_B, "pause", "stale pause"),
		}
		for _, rule in ipairs(near_matches) do rules[#rules + 1] = rule end
		rules[#rules + 1] = personal_rule("personal after")
		local existing = existing_config(rules)
		existing.profiles[1].complex_modifications.rules = {
			personal_rule("work personal before"),
			managed_rule(OLD_TOKEN_A, "normal", "inactive-profile stale"),
			personal_rule("work personal after"),
		}
		file_data[path] = _G.hs.json.encode(existing)
		local incoming = generated_config({
			managed_rule(TOKEN, "normal", "new normal"),
			managed_rule(TOKEN, "pause", "new pause"),
		})

		local result, err = Generator.merge_into_existing_config(incoming, path)
		helpers.assert_not_nil(result, err)
		helpers.assert_true(helpers.deep_equal(result.global, existing.global), "global settings must remain byte-for-byte equivalent")
		helpers.assert_eq(result.profiles[1].name, "Work")
		helpers.assert_true(helpers.deep_equal(result.profiles[1].devices, existing.profiles[1].devices),
			"inactive-profile devices must remain untouched")
		local inactive_rules = result.profiles[1].complex_modifications.rules
		helpers.assert_eq(#inactive_rules, 2, "stale managed rules must be removed from inactive profiles")
		helpers.assert_eq(inactive_rules[1].description, "work personal before")
		helpers.assert_eq(inactive_rules[2].description, "work personal after")
		local selected = result.profiles[2]
		helpers.assert_eq(selected.name, "Personal selected")
		helpers.assert_true(helpers.deep_equal(selected.parameters, existing.profiles[2].parameters), "profile parameters must survive")
		helpers.assert_true(helpers.deep_equal(selected.devices, existing.profiles[2].devices), "devices must survive")
		helpers.assert_true(helpers.deep_equal(selected.simple_modifications, existing.profiles[2].simple_modifications), "simple modifications must survive")
		helpers.assert_true(helpers.deep_equal(selected.fn_function_keys, existing.profiles[2].fn_function_keys), "fn mappings must survive")
		helpers.assert_true(helpers.deep_equal(selected.virtual_hid_keyboard, existing.profiles[2].virtual_hid_keyboard), "virtual HID settings must survive")
		helpers.assert_true(helpers.deep_equal(
			selected.complex_modifications.parameters,
			existing.profiles[2].complex_modifications.parameters
		), "complex-modification parameters must survive")

		local merged_rules = selected.complex_modifications.rules
		helpers.assert_eq(merged_rules[1].description, "personal before")
		helpers.assert_true(merged_rules[2].description:find("new normal", 1, true) ~= nil)
		helpers.assert_true(merged_rules[3].description:find("new pause", 1, true) ~= nil)
		helpers.assert_eq(merged_rules[4].description, "personal middle")
		for index, near in ipairs(near_matches) do
			helpers.assert_eq(merged_rules[index + 4].description, near.description, "near-match tag must be preserved")
		end
		helpers.assert_eq(merged_rules[#merged_rules].description, "personal after")
	end)

	helpers.it("is idempotent and cleans all stale managed generations", function()
		local path = "/merge/idempotent.json"
		file_data[path] = _G.hs.json.encode(existing_config({
			managed_rule(OLD_TOKEN_A, "normal", "old A"),
			personal_rule("personal"),
			managed_rule(OLD_TOKEN_B, "normal", "old B"),
		}))
		local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
		local first, first_err = Generator.merge_into_existing_config(incoming, path)
		helpers.assert_not_nil(first, first_err)
		file_data[path] = _G.hs.json.encode(first)
		local second, second_err = Generator.merge_into_existing_config(incoming, path)
		helpers.assert_not_nil(second, second_err)
		helpers.assert_true(helpers.deep_equal(second, first), "repeating a merge must produce the same configuration")
		local current_count = 0
		local personal_count = 0
		for _, rule in ipairs(second.profiles[2].complex_modifications.rules) do
			if rule.description:find(TOKEN, 1, true) then current_count = current_count + 1 end
			if rule.description == "personal" then personal_count = personal_count + 1 end
			helpers.assert_true(rule.description:find(OLD_TOKEN_A, 1, true) == nil, "old generation A must be removed")
			helpers.assert_true(rule.description:find(OLD_TOKEN_B, 1, true) == nil, "old generation B must be removed")
		end
		helpers.assert_eq(current_count, 1, "current managed rules must not duplicate")
		helpers.assert_eq(personal_count, 1, "idempotence must never erase or duplicate a personal rule")
	end)

	helpers.it("does not invent or alter global settings for a fresh config", function()
		local result, err = Generator.merge_into_existing_config(
			generated_config({ managed_rule(TOKEN, "normal", "fresh") }),
			"/merge/absent.json"
		)
		helpers.assert_not_nil(result, err)
		helpers.assert_nil(result.global, "ErgoptiPlus must not impose stock Karabiner UI or update preferences")
	end)
end)





-- =========================================
-- =========================================
-- ======= 3/ Ambiguity Fails Closed =======
-- =========================================
-- =========================================

helpers.describe("Karabiner generator merge ambiguity", function()
	local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })

	helpers.it("refuses malformed existing JSON instead of overwriting it", function()
		local path = "/merge/malformed.json"
		file_data[path] = "{ definitely not JSON"
		local result, err = Generator.merge_into_existing_config(incoming, path)
		helpers.assert_nil(result, "malformed personal configuration must never be overwritten")
		helpers.assert_true(type(err) == "string" and err:find("JSON", 1, true) ~= nil)
	end)

	helpers.it("refuses an existing file that cannot be read", function()
		local path = "/merge/unreadable.json"
		unreadable_paths[path] = true
		local result, err = Generator.merge_into_existing_config(incoming, path)
		helpers.assert_nil(result, "an unreadable personal configuration must never be overwritten")
		helpers.assert_true(type(err) == "string" and err:find("read", 1, true) ~= nil)
	end)

	helpers.it("refuses zero, multiple, or structurally invalid selected profiles", function()
		local cases = {
			{ profiles = {} },
			{ profiles = { { name = "A", selected = false }, { name = "B", selected = false } } },
			{ profiles = { { name = "A", selected = true }, { name = "B", selected = true } } },
			{ profiles = { "not a profile" } },
			{
				profiles = {
					{
						name = "A",
						selected = true,
						complex_modifications = {
							rules = { named_rule = personal_rule("must not be discarded") },
						},
					},
				},
			},
		}
		for index, config in ipairs(cases) do
			local path = "/merge/ambiguous-" .. tostring(index) .. ".json"
			file_data[path] = _G.hs.json.encode(config)
			local result, err = Generator.merge_into_existing_config(incoming, path)
			helpers.assert_nil(result, "ambiguous profile selection must fail closed for case " .. tostring(index))
			helpers.assert_true(type(err) == "string" and err ~= "")
		end
	end)

	helpers.it("refuses a generated rules object that ipairs would silently skip", function()
		local malformed_incoming = generated_config({})
		malformed_incoming.profiles[1].complex_modifications.rules = {
			hidden_rule = managed_rule(TOKEN, "normal", "hidden"),
		}
		local result, err = Generator.merge_into_existing_config(
			malformed_incoming,
			"/merge/generated-rules-object.json"
		)
		helpers.assert_nil(result, "named generated rules must not turn into an accidental cleanup")
		helpers.assert_true(type(err) == "string" and err:find("dense array", 1, true) ~= nil)
	end)

	helpers.it("refuses an incoming managed rule carrying a second generation lease", function()
		local conflicted = managed_rule(TOKEN, "normal", "conflicted")
		conflicted.manipulators[1].conditions[#conflicted.manipulators[1].conditions + 1] = {
			type = "variable_if",
			name = "ergopti_lease_" .. OLD_TOKEN_A,
			value = 1,
		}
		local result, err = Generator.merge_into_existing_config(
			generated_config({ conflicted }),
			"/merge/foreign-lease.json"
		)
		helpers.assert_nil(result, "a foreign lease condition would make a managed rule permanently inert")
		helpers.assert_true(type(err) == "string" and err:find("foreign managed condition", 1, true) ~= nil)
	end)

	helpers.it("refuses malformed or managed legacy fingerprints", function()
		local malformed = { named = personal_rule("hidden fingerprint") }
		local result, err = Generator.merge_into_existing_config(
			incoming,
			"/merge/malformed-legacy.json",
			malformed
		)
		helpers.assert_nil(result, "a named fingerprint object must not trigger hidden removals")
		helpers.assert_true(type(err) == "string" and err:find("dense array", 1, true) ~= nil)
		result, err = Generator.merge_into_existing_config(
			incoming,
			"/merge/false-legacy.json",
			false
		)
		helpers.assert_nil(result, "false must not be confused with an omitted fingerprint list")
		helpers.assert_true(type(err) == "string" and err:find("dense array", 1, true) ~= nil)

		local managed_fingerprint = managed_rule(OLD_TOKEN_A, "normal", "not legacy")
		result, err = Generator.merge_into_existing_config(
			incoming,
			"/merge/managed-legacy.json",
			{ managed_fingerprint }
		)
		helpers.assert_nil(result, "managed rules cannot masquerade as historical fingerprints")
		helpers.assert_true(type(err) == "string" and err:find("untagged", 1, true) ~= nil)

		local scoped_writer_fingerprint = personal_rule("untagged scoped writer")
		scoped_writer_fingerprint.manipulators[1].to = {
			{
				set_variable = {
					name = "ergopti_capsword_" .. OLD_TOKEN_A,
					value = 1,
				},
			},
		}
		result, err = Generator.merge_into_existing_config(
			incoming,
			"/merge/scoped-writer-legacy.json",
			{ scoped_writer_fingerprint }
		)
		helpers.assert_nil(result,
			"a token-scoped runtime writer cannot masquerade as a pre-lease fingerprint")
		helpers.assert_true(type(err) == "string" and err:find("managed variable", 1, true) ~= nil)
	end)
end)

helpers.describe("Karabiner generator publication uses the proven filesystem writer", function()
	local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })

	local function selected_rules(encoded)
		local decoded = _G.hs.json.decode(encoded)
		for _, profile in ipairs(decoded.profiles or {}) do
			if profile.selected == true then
				return profile.complex_modifications and profile.complex_modifications.rules or {}
			end
		end
		return {}
	end

	helpers.it("re-reads, preserves personal rules, and publishes exactly once", function()
		local path = "/merge/publish.json"
		file_data[path] = _G.hs.json.encode({
			profiles = {
				{
					name = "Personal",
					selected = true,
					complex_modifications = { rules = { personal_rule("keep me") } },
				},
			},
		})
		file_writes = {}
		file_reads = {}
		parent_prepare_calls = {}
		write_succeeds = true
		before_publication = nil

		local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)
		helpers.assert_true(ok, tostring(detail))
		helpers.assert_eq(attempts, 1)
		helpers.assert_eq(#parent_prepare_calls, 1)
		helpers.assert_eq(parent_prepare_calls[1], path)
		helpers.assert_eq(#file_reads, 1, "publication must merge from one exact post-preparation read")
		helpers.assert_eq(#file_writes, 1)
		helpers.assert_eq(file_writes[1].path, path)
		helpers.assert_eq(file_writes[1].method, "write_if_unchanged")
		local rules = selected_rules(file_writes[1].content)
		helpers.assert_eq(#rules, 2)
		helpers.assert_eq(rules[1].description, "keep me")
		helpers.assert_true(rules[2].description:find("[ErgoptiPlus managed:", 1, true) == 1)
	end)

	helpers.it("skips a semantically unchanged publication after exact revalidation", function()
		local path = "/merge/publish-unchanged.json"
		file_data[path] = _G.hs.json.encode({
			profiles = {
				{
					name = "Personal",
					selected = true,
					complex_modifications = { rules = { personal_rule("keep me") } },
				},
			},
		})
		file_writes = {}
		file_reads = {}
		parent_prepare_calls = {}
		write_succeeds = true
		before_publication = nil

		local first_ok, first_detail = Generator.merge_and_deploy_config(incoming, path)
		helpers.assert_true(first_ok, tostring(first_detail))
		helpers.assert_eq(#file_writes, 1,
			"the fixture must first publish the managed block")
		local published_bytes = file_data[path]
		file_writes = {}
		file_reads = {}

		local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)

		helpers.assert_true(ok, tostring(detail))
		helpers.assert_eq(detail, "unchanged")
		helpers.assert_eq(attempts, 0,
			"an unchanged merge must make no publication attempt")
		helpers.assert_eq(#file_reads, 2,
			"the unchanged decision must revalidate the exact source snapshot")
		helpers.assert_eq(#file_writes, 0,
			"a semantic no-op must not rewrite karabiner.json")
		helpers.assert_eq(file_data[path], published_bytes,
			"the deployed bytes must remain untouched")
	end)

	helpers.it("refuses an unchanged verdict after the exact source moves", function()
		local path = "/merge/publish-unchanged-race.json"
		file_data[path] = _G.hs.json.encode({
			profiles = {
				{
					name = "Personal",
					selected = true,
					complex_modifications = { rules = { personal_rule("keep me") } },
				},
			},
		})
		file_writes = {}
		file_reads = {}
		parent_prepare_calls = {}
		write_succeeds = true
		before_read = nil
		before_publication = nil

		local first_ok, first_detail = Generator.merge_and_deploy_config(incoming, path)
		helpers.assert_true(first_ok, tostring(first_detail))
		local foreign_bytes = _G.hs.json.encode({
			profiles = {
				{
					name = "Personal",
					selected = true,
					complex_modifications = { rules = { personal_rule("foreign winner") } },
				},
			},
		})
		file_writes = {}
		file_reads = {}
		before_read = function(read_path, read_number)
			helpers.assert_eq(read_path, path)
			if read_number == 2 then file_data[path] = foreign_bytes end
		end

		local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)
		before_read = nil

		helpers.assert_eq(ok, false,
			"a moved source must never be reported as unchanged")
		helpers.assert_true(type(detail) == "string"
			and detail:find("source changed", 1, true) ~= nil,
			"the exact-source conflict must be surfaced")
		helpers.assert_eq(attempts, 0,
			"a no-op revalidation conflict must not enter publication")
		helpers.assert_eq(#file_reads, 2,
			"the source change must be observed by the second exact read")
		helpers.assert_eq(#file_writes, 0,
			"a no-op conflict must never call the writer")
		helpers.assert_eq(file_data[path], foreign_bytes,
			"the foreign winner's exact bytes must survive")
	end)

	helpers.it("prepares a missing parent before the exact absent read and publishes once", function()
		local path = "/merge/fresh-parent/karabiner.json"
		file_data[path] = nil
		missing_parent_paths[path] = true
		parent_prepare_failures[path] = nil
		file_writes = {}
		file_reads = {}
		parent_prepare_calls = {}
		write_succeeds = true
		before_publication = nil

		local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)

		helpers.assert_true(ok, tostring(detail))
		helpers.assert_eq(attempts, 1)
		helpers.assert_eq(#parent_prepare_calls, 1,
			"the parent must be prepared exactly once before source classification")
		helpers.assert_eq(parent_prepare_calls[1], path)
		helpers.assert_eq(#file_reads, 1, "the prepared path must be classified exactly once for the merge")
		helpers.assert_eq(file_reads[1], path)
		helpers.assert_eq(#file_writes, 1, "fresh publication must use one conditional write")
		helpers.assert_eq(file_writes[1].method, "write_if_unchanged")
		helpers.assert_eq(file_writes[1].expected_source.status, "absent")
	end)

	helpers.it("fails closed when safe parent preparation reports permission or symlink failure", function()
		local cases = {
			{ suffix = "permission", detail = "mkdir refused: Permission denied" },
			{ suffix = "symlink", detail = "symlink target changed before preparation" },
		}
		for _, case in ipairs(cases) do
			local path = "/merge/unsafe-" .. case.suffix .. "/karabiner.json"
			file_data[path] = nil
			missing_parent_paths[path] = true
			parent_prepare_failures[path] = case.detail
			file_writes = {}
			file_reads = {}
			parent_prepare_calls = {}
			write_succeeds = true
			before_publication = nil

			local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)

			helpers.assert_eq(ok, false)
			helpers.assert_eq(attempts, 1)
			helpers.assert_true(type(detail) == "string" and detail:find(case.detail, 1, true) ~= nil,
				"the concrete parent-preparation failure must be surfaced")
			helpers.assert_eq(#parent_prepare_calls, 1)
			helpers.assert_eq(#file_reads, 0,
				"an unsafe parent must abort before absence can be inferred")
			helpers.assert_eq(#file_writes, 0,
				"an unsafe parent must never reach publication")
		parent_prepare_failures[path] = nil
		missing_parent_paths[path] = nil
		end
	end)

	helpers.it("refuses a foreign edit after merge instead of overwriting its exact bytes", function()
		local path = "/merge/publish-concurrent.json"
		local source_a = _G.hs.json.encode({
			profiles = {
				{
					name = "Personal",
					selected = true,
					complex_modifications = { rules = { personal_rule("source A") } },
				},
			},
		})
		local foreign_b = _G.hs.json.encode({
			profiles = {
				{
					name = "Personal",
					selected = true,
					complex_modifications = { rules = { personal_rule("foreign B") } },
				},
			},
		})
		file_data[path] = source_a
		file_writes = {}
		file_reads = {}
		parent_prepare_calls = {}
		write_succeeds = true
		before_publication = function(write_path)
			helpers.assert_eq(write_path, path)
			file_data[path] = foreign_b
		end

		local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)

		helpers.assert_eq(ok, false, "a stale merge must never report publication success")
		helpers.assert_true(type(detail) == "string" and detail:find("source changed", 1, true) ~= nil)
		helpers.assert_eq(attempts, 1, "a source conflict must never enter mkdir/retry")
		helpers.assert_eq(#parent_prepare_calls, 1,
			"a source conflict must never re-prepare the parent as a retry strategy")
		helpers.assert_eq(#file_writes, 1, "the stale candidate must be offered exactly once")
		helpers.assert_eq(file_writes[1].method, "write_if_unchanged")
		helpers.assert_eq(file_writes[1].expected_source.status, "ok")
		helpers.assert_eq(file_writes[1].expected_source.content, source_a)
		helpers.assert_eq(file_data[path], foreign_b, "the foreign writer's exact bytes must survive")
	end)

	helpers.it("fails closed without publishing when the live config is malformed", function()
		local path = "/merge/publish-malformed.json"
		file_data[path] = "{ invalid"
		file_writes = {}
		file_reads = {}
		parent_prepare_calls = {}
		write_succeeds = true
		before_publication = nil

		local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)
		helpers.assert_true(ok == false)
		helpers.assert_true(type(detail) == "string" and detail:find("merge failed", 1, true) ~= nil)
		helpers.assert_eq(attempts, 1)
		helpers.assert_eq(#file_writes, 0)
	end)

	helpers.it("reports a failed atomic writer and never claims publication", function()
		local path = "/merge/publish-write-failure.json"
		file_data[path] = _G.hs.json.encode({
			profiles = {
				{
					name = "Personal",
					selected = true,
					complex_modifications = { rules = { personal_rule("keep me") } },
				},
			},
		})
		file_writes = {}
		file_reads = {}
		parent_prepare_calls = {}
		write_succeeds = false
		before_publication = nil

		local ok, detail, attempts = Generator.merge_and_deploy_config(incoming, path)
		helpers.assert_true(ok == false)
		helpers.assert_true(type(detail) == "string" and detail:find("write failed", 1, true) ~= nil)
		helpers.assert_eq(attempts, 1)
		helpers.assert_true(#file_writes >= 1)
		write_succeeds = true
	end)
end)
