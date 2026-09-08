--- tests/support/generator_managed_lease_fixture.lua

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

--- Runs one generator scenario with independent native and file state.
--- @param callback function Receives the real generator and mutable filesystem fixture.
local function with_fixture(callback)
	return helpers.with_stub_scope({
		"platform.remap.generator", "infra.logger", "adapters.file_system",
		"infra.config_paths", "infra.keycodes",
	}, function()
		local fixture = {}
		fixture.file_data = {}
		fixture.unreadable_paths = {}
		fixture.file_writes = {}
		fixture.file_reads = {}
		fixture.missing_parent_paths = {}
		fixture.parent_prepare_failures = {}
		fixture.parent_prepare_calls = {}
		fixture.write_succeeds = true
		fixture.before_read = nil
		fixture.before_publication = nil

		local function run_before_publication(path, content)
			local hook = fixture.before_publication
			fixture.before_publication = nil
			if hook then hook(path, content) end
		end

		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.file_system"] = {
			read = function(path) return fixture.file_data[path] end,
			read_with_status = function(path)
				fixture.file_reads[#fixture.file_reads + 1] = path
				if fixture.before_read then fixture.before_read(path, #fixture.file_reads) end
				if fixture.missing_parent_paths[path] == true then
					return nil, "error", "missing path prefix"
				end
				if fixture.unreadable_paths[path] == true then
					return nil, "error", "injected read failure"
				end
				if fixture.file_data[path] == nil then return nil, "absent" end
				return fixture.file_data[path], "ok"
			end,
			prepare_parent_for_create = function(path)
				fixture.parent_prepare_calls[#fixture.parent_prepare_calls + 1] = path
				local failure = fixture.parent_prepare_failures[path]
				if failure ~= nil then return false, failure end
				fixture.missing_parent_paths[path] = nil
				return true
			end,
			-- An old read()+exists() fallback would misclassify the injected read error
			-- as absence, so this legacy helper intentionally does not expose it.
			exists = function(path) return fixture.file_data[path] ~= nil end,
			write = function(path, content)
				run_before_publication(path, content)
				fixture.file_writes[#fixture.file_writes + 1] = { path = path, content = content, method = "write" }
				if fixture.write_succeeds then fixture.file_data[path] = content end
				return fixture.write_succeeds, fixture.write_succeeds and nil or "stub write failure"
			end,
			write_if_unchanged = function(path, content, expected_source)
				run_before_publication(path, content)
				fixture.file_writes[#fixture.file_writes + 1] = {
					path = path,
					content = content,
					method = "write_if_unchanged",
					expected_source = expected_source,
				}
				if not fixture.write_succeeds then return false, "stub write failure" end
				local current = fixture.file_data[path]
				local current_status = current == nil and "absent" or "ok"
				local unchanged = type(expected_source) == "table"
					and expected_source.status == current_status
					and (current_status ~= "ok" or expected_source.content == current)
				if not unchanged then return false, "source changed before publication" end
				fixture.file_data[path] = content
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

		local function install_legacy_static_fixtures()
			fixture.file_data["/managed/capsword.json"] = _G.hs.json.encode({
				description = "CapsWord legacy anchor",
				manipulators = {
					{ type = "basic", from = { key_code = "caps_lock" }, to = { { key_code = "caps_lock" } } },
				},
			})
			fixture.file_data["/managed/layer_keys.json"] = _G.hs.json.encode({
				description = "Layer legacy anchor",
				manipulators = {
					{ type = "basic", from = { key_code = "a" }, to = { { key_code = "left_arrow" } } },
				},
			})
			fixture.file_data["/managed/combos.json"] = _G.hs.json.encode({
				description = "Combo legacy anchor",
				manipulators = {
					{ type = "basic", from = { key_code = "b" }, to = { { key_code = "right_arrow" } } },
				},
			})
		end

		fixture.Generator = Generator
		fixture.build = build
		fixture.build_with = build_with
		fixture.install_legacy_static_fixtures = install_legacy_static_fixtures
		return callback(fixture)
	end)
end

return {
	TOKEN = TOKEN,
	OLD_TOKEN_A = OLD_TOKEN_A,
	OLD_TOKEN_B = OLD_TOKEN_B,
	MODE_NAME = MODE_NAME,
	REVOKED_NAME = REVOKED_NAME,
	LegacyReleaseFixtures = LegacyReleaseFixtures,
	LegacyReleaseSchemas = LegacyReleaseSchemas,
	state = state,
	condition_count = condition_count,
	collect_variable_names = collect_variable_names,
	managed_rule = managed_rule,
	personal_rule = personal_rule,
	deep_copy = deep_copy,
	legacy_layout_scenario = legacy_layout_scenario,
	generated_config = generated_config,
	existing_config = existing_config,
	with_fixture = with_fixture,
}
