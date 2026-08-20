--- platform/remap/legacy_release_fixtures.lua

--- ==============================================================================
--- MODULE: Karabiner Legacy Release Fixtures
--- DESCRIPTION:
--- Replays the immutable pre-lease generator schemas shipped in real macOS
--- releases. Migration calls this module instead of today's generator, so a
--- current implementation change cannot silently redefine historical ownership.
--- Layout-derived outputs are matched only against canonical printable physical
--- positions with a one-to-one logical/physical mapping.
--- ==============================================================================

local M = {}

local LAYOUT_MARKER_PREFIX = "__ergopti_release_layout_key__"

-- These are the only physical positions `modules/keymap/layout.lua` can resolve
-- for printable logical characters. Function, navigation, modifier, and keypad
-- key codes are deliberately excluded from migration's layout allowance.
local CANONICAL_LAYOUT_KEY_CODES = {
	a = true, b = true, c = true, d = true, e = true, f = true, g = true,
	h = true, i = true, j = true, k = true, l = true, m = true, n = true,
	o = true, p = true, q = true, r = true, s = true, t = true, u = true,
	v = true, w = true, x = true, y = true, z = true,
	["0"] = true, ["1"] = true, ["2"] = true, ["3"] = true, ["4"] = true,
	["5"] = true, ["6"] = true, ["7"] = true, ["8"] = true, ["9"] = true,
	backslash = true,
	close_bracket = true,
	comma = true,
	equal_sign = true,
	grave_accent_and_tilde = true,
	hyphen = true,
	non_us_backslash = true,
	open_bracket = true,
	period = true,
	quote = true,
	semicolon = true,
	slash = true,
	spacebar = true,
	tab = true,
}

local ACTUAL_MODIFIER_KEY_CODES = {
	left_option = true, right_option = true,
	left_command = true, right_command = true,
	left_control = true, right_control = true,
	left_shift = true, right_shift = true,
}

local MODIFIER_CLASS_KEY_CODES = {
	"left_command", "right_command",
	"left_control",
	"left_option",
	"left_shift", "right_shift",
	"fn",
	"caps_lock",
}

local STICKY_TO_BASE_ACTION = {
	sticky_shift = "shift",
	sticky_ctrl = "ctrl",
	sticky_cmd = "cmd",
	sticky_option = "alt",
	sticky_cmd_shift = "cmd_shift",
	sticky_cmd_option = "cmd_option",
	sticky_cmd_ctrl = "cmd_ctrl",
	sticky_option_shift = "option_shift",
	sticky_option_ctrl = "option_ctrl",
	sticky_ctrl_shift = "ctrl_shift",
	sticky_cmd_option_shift = "cmd_option_shift",
	sticky_cmd_option_ctrl = "cmd_option_ctrl",
	sticky_cmd_shift_ctrl = "cmd_shift_ctrl",
	sticky_option_shift_ctrl = "option_shift_ctrl",
	sticky_hyper = "hyper",
}

-- `actions.json`, `capsword.json`, `layer_keys.json`, `combos.json`,
-- `mod_combos.json`, and `tap_hold_keys.json` decode to structurally identical
-- tables throughout v0.0.0-dev.1-v0.0.0-dev.107. Their blobs all changed between
-- dev.40 and dev.41, but a recursively key-sorted JSON comparison proves that
-- boundary was whitespace-only. They are blob-identical from dev.41 onward.
local RELEASES = {
	{
		id = "v0.0.0-dev.1-v0.0.0-dev.44",
		tags = { "v0.0.0-dev.1", "v0.0.0-dev.44" },
		commits = {
			"dd6e196f75557c93e8c120e96547bf6938cd724c",
			"af8d50784b6820d688422fa060a1c05fa8309408",
		},
		generator_blob = "b5fc0ee90aa0577ea6ee75cd80708c5bccb95bf4",
		sentinel_tags = false,
		paused_modifiers = false,
		per_key_timeout = false,
		chord_consumes_modifiers = false,
		safe_shell_quoting = false,
	},
	{
		id = "v0.0.0-dev.45-v0.0.0-dev.64",
		tags = { "v0.0.0-dev.45", "v0.0.0-dev.64" },
		commits = {
			"b88a2e8c210ec1847aa7e43a02d9e86324fd5d68",
			"31e3a2f465456874fa437cbd8300dae5d85b3cf2",
		},
		generator_blob = "1845f742906e373867897c54f4fed4829bfbb70e",
		sentinel_tags = false,
		paused_modifiers = { "right_command", "right_option" },
		per_key_timeout = false,
		chord_consumes_modifiers = false,
		safe_shell_quoting = false,
	},
	{
		id = "v0.0.0-dev.65",
		tags = { "v0.0.0-dev.65" },
		commits = { "c9018de408c64476f57f354b97107d57d1446cdc" },
		generator_blob = "950a23058730a1269bcb2764b596978664387618",
		sentinel_tags = false,
		paused_modifiers = { "right_command", "right_option" },
		per_key_timeout = false,
		chord_consumes_modifiers = false,
		safe_shell_quoting = true,
	},
	-- dev.66 replaced a JSON-string output comparison with structural equality.
	-- The stable decoded catalogue yields the same deployed graph, but the unique
	-- released blob remains a separate fixture so history cannot be collapsed.
	{
		id = "v0.0.0-dev.66-v0.0.0-dev.68",
		tags = { "v0.0.0-dev.66", "v0.0.0-dev.68" },
		commits = {
			"0152651f0606c4562a7f658099b4270eb5d4d3a2",
			"5f3edebdf6ac59c594449b61d5e788149b64d33f",
		},
		generator_blob = "ee23c3b098e3121d8c026c36010aa46d514d8e9b",
		sentinel_tags = false,
		paused_modifiers = { "right_command", "right_option" },
		per_key_timeout = false,
		chord_consumes_modifiers = false,
		safe_shell_quoting = true,
	},
	{
		id = "v0.0.0-dev.69-v0.0.0-dev.70",
		tags = { "v0.0.0-dev.69", "v0.0.0-dev.70" },
		commits = {
			"cad2f8fce4916fd0369044ebfaca875034803322",
			"edda648a0da41e27b77810d8919f8c3494a89804",
		},
		generator_blob = "40e249cd41ba8194a0931c84f9aad91808d4caaa",
		sentinel_tags = { "left_control" },
		paused_modifiers = { "right_command", "option" },
		per_key_timeout = true,
		chord_consumes_modifiers = false,
		safe_shell_quoting = true,
	},
	{
		id = "v0.0.0-dev.71",
		tags = { "v0.0.0-dev.71" },
		commits = { "56671dad9959616528ec0ece1ab660f0a5f5674f" },
		generator_blob = "6eecede1a8c6e413a78d18082002d2b69dd68301",
		sentinel_tags = { "left_control" },
		paused_modifiers = { "option" },
		per_key_timeout = true,
		chord_consumes_modifiers = false,
		safe_shell_quoting = true,
	},
	{
		id = "v0.0.0-dev.72-v0.0.0-dev.74",
		tags = { "v0.0.0-dev.72", "v0.0.0-dev.73", "v0.0.0-dev.74" },
		commits = {
			"038bb217c5f21ccec5af136f9d16fdd0eefdfbde",
			"354f4025bd729e0ce459b1f18f177ca583eea062",
			"867d8b1bc5ed0738371571c194c0050fc0efe01b",
		},
		generator_blob = "c3056cd429144abb873170a0216c139f742cfa12",
		sentinel_tags = { "left_control", "left_shift" },
		paused_modifiers = { "option" },
		per_key_timeout = true,
		chord_consumes_modifiers = false,
		safe_shell_quoting = true,
	},
	{
		id = "v0.0.0-dev.75-v0.0.0-dev.107",
		tags = { "v0.0.0-dev.75", "v0.0.0-dev.107" },
		commits = {
			"a066eeae7ba4cb7710ebd1ae6c12acdf46614225",
			"afc73c374fdc5657e1addf9e7002d91e4e0d6a1d",
		},
		generator_blob = "213080366d7950e67665c4b0a2ae794ce6ec5502",
		sentinel_tags = { "left_control", "left_shift" },
		paused_modifiers = { "option" },
		per_key_timeout = true,
		chord_consumes_modifiers = true,
		safe_shell_quoting = true,
	},
}

local RELEASE_BY_ID = {}
for _, release in ipairs(RELEASES) do RELEASE_BY_ID[release.id] = release end

local function deep_copy(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, nested in pairs(value) do copy[deep_copy(key)] = deep_copy(nested) end
	return copy
end

local function deep_equal(first, second)
	if type(first) ~= type(second) then return false end
	if type(first) ~= "table" then return first == second end
	for key, value in pairs(first) do
		if not deep_equal(value, second[key]) then return false end
	end
	for key in pairs(second) do
		if first[key] == nil then return false end
	end
	return true
end

local function held_var_name(key_code)
	return "ke_held_" .. key_code
end

local function set_var_event(name, value)
	return { set_variable = { name = name, value = value } }
end

local function append_events(target, events)
	for _, event in ipairs(events or {}) do target[#target + 1] = deep_copy(event) end
end

local function detect_sticky_base(tap_id, hold_id)
	if STICKY_TO_BASE_ACTION[tap_id] == hold_id then return hold_id end
	if STICKY_TO_BASE_ACTION[hold_id] == tap_id then return tap_id end
	return nil
end

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function physical_log_command(release, payload, physical_log_path)
	if release.safe_shell_quoting then
		return string.format(
			"echo %s >> %s",
			shell_quote(payload),
			shell_quote(physical_log_path)
		)
	end
	return string.format("echo '%s' >> '%s'", payload, physical_log_path)
end

local function build_action_index(actions)
	local index = {}
	for _, action in ipairs(actions) do index[action.id] = action end
	return index
end

local function mark_layout_actions(actions)
	for _, action in ipairs(actions) do
		if type(action.logical_char) == "string" and action.logical_char ~= "" then
			local event = { key_code = LAYOUT_MARKER_PREFIX .. action.logical_char }
			if type(action.karabiner_modifiers) == "table" and #action.karabiner_modifiers > 0 then
				event.modifiers = deep_copy(action.karabiner_modifiers)
			end
			action.karabiner_to = { event }
		end
	end
end

local function build_sticky_companions(key_def, base_to, variable_name)
	local manipulators = {}
	local self_key = key_def.from.key_code
	for _, modifier_key in ipairs(MODIFIER_CLASS_KEY_CODES) do
		if modifier_key ~= self_key then
			local to_events = { set_var_event(variable_name, 1) }
			append_events(to_events, base_to)
			manipulators[#manipulators + 1] = {
				type = "basic",
				from = deep_copy(key_def.from),
				conditions = {
					{ type = "variable_if", name = held_var_name(modifier_key), value = 1 },
				},
				to = to_events,
				to_after_key_up = { set_var_event(variable_name, 0) },
			}
		end
	end
	return manipulators
end

local function build_tap_hold_rule(
	release,
	key_def,
	tap_action,
	hold_action,
	action_index,
	tap_timeout_ms,
	physical_log_path
)
	local tap_to = tap_action.karabiner_to or {}
	local hold_to = hold_action.karabiner_to or {}
	local key_code = key_def.from.key_code
	local variable_name = held_var_name(key_code)
	local manipulator = { type = "basic", from = deep_copy(key_def.from) }
	local to_events = { set_var_event(variable_name, 1) }
	local after_key_up = { set_var_event(variable_name, 0) }

	if #tap_to == 0 and #hold_to == 0 then
		to_events[#to_events + 1] = { key_code = key_code }
		manipulator.to = to_events
		manipulator.to_after_key_up = after_key_up
		return {
			description = string.format("%s: passthrough (variable tracked)", key_def.label),
			manipulators = { manipulator },
		}
	end

	to_events[#to_events + 1] = {
		shell_command = physical_log_command(release, key_code, physical_log_path),
	}
	after_key_up[#after_key_up + 1] = {
		shell_command = physical_log_command(release, "U:" .. key_code, physical_log_path),
	}

	local passthrough = { { key_code = key_code } }
	local effective_tap = #tap_to > 0 and tap_to or passthrough
	local effective_hold = #hold_to > 0 and hold_to or passthrough
	append_events(to_events, effective_hold)
	manipulator.to = to_events
	if not deep_equal(effective_tap, effective_hold) then
		manipulator.to_if_alone = deep_copy(effective_tap)
	end
	if release.per_key_timeout and tap_timeout_ms and tap_timeout_ms > 0 then
		manipulator.parameters = {
			["basic.to_if_alone_timeout_milliseconds"] = tap_timeout_ms,
		}
	end
	append_events(after_key_up, hold_action.karabiner_to_after_key_up)
	manipulator.to_after_key_up = after_key_up

	local manipulators = { manipulator }
	local base_id = detect_sticky_base(tap_action.id, hold_action.id)
	local base_action = base_id and action_index[base_id] or nil
	if base_action and type(base_action.karabiner_to) == "table" and #base_action.karabiner_to > 0 then
		local combined = build_sticky_companions(
			key_def,
			base_action.karabiner_to,
			variable_name
		)
		combined[#combined + 1] = manipulator
		manipulators = combined
	end

	return {
		description = string.format(
			"%s: %s (tap) / %s (hold)",
			key_def.label,
			tap_action.label,
			hold_action.label
		),
		manipulators = manipulators,
	}
end

local function build_tap_hold_combo_rule(
	combo_def,
	tap_action,
	hold_action,
	first_key,
	second_key,
	first_mandatory
)
	local tap_to = tap_action.karabiner_to or {}
	local hold_to = hold_action.karabiner_to or {}
	if #tap_to == 0 and #hold_to == 0 then return nil end

	local from_modifiers = { optional = { "any" } }
	if first_mandatory and #first_mandatory > 0 then
		from_modifiers.mandatory = deep_copy(first_mandatory)
	end
	local conditions = {
		{ type = "variable_if", name = held_var_name(first_key), value = 1 },
	}
	append_events(conditions, tap_action.karabiner_rule_conditions)
	local manipulator = {
		type = "basic",
		from = { key_code = second_key, modifiers = from_modifiers },
		conditions = conditions,
	}

	if #hold_to > 0 and #tap_to > 0 and not deep_equal(tap_to, hold_to) then
		manipulator.to = deep_copy(hold_to)
		manipulator.to_if_alone = deep_copy(tap_to)
		if hold_action.karabiner_to_after_key_up then
			manipulator.to_after_key_up = deep_copy(hold_action.karabiner_to_after_key_up)
		end
	elseif #hold_to > 0 then
		manipulator.to = deep_copy(hold_to)
		if hold_action.karabiner_to_after_key_up then
			manipulator.to_after_key_up = deep_copy(hold_action.karabiner_to_after_key_up)
		end
	else
		manipulator.to = deep_copy(tap_to)
	end

	return {
		description = string.format(
			"%s (%s→%s): %s (tap) / %s (hold) [var-based]",
			combo_def.label,
			first_key,
			second_key,
			tap_action.label,
			hold_action.label
		),
		manipulators = { manipulator },
	}
end

local function legacy_chord_from(combo_def, combo_symmetric)
	if not combo_symmetric then return deep_copy(combo_def.from) end
	local from = { simultaneous = deep_copy(combo_def.from.simultaneous) }
	if type(combo_def.from.simultaneous_options) == "table" then
		local options = {}
		for key, value in pairs(combo_def.from.simultaneous_options) do
			if key ~= "key_down_order" then options[key] = deep_copy(value) end
		end
		if next(options) then from.simultaneous_options = options end
	end
	if combo_def.from.modifiers then from.modifiers = deep_copy(combo_def.from.modifiers) end
	return from
end

local function modifier_consuming_chord_from(combo_def, combo_symmetric)
	local from = deep_copy(combo_def.from)
	if combo_symmetric and type(from.simultaneous_options) == "table" then
		local options = {}
		for key, value in pairs(from.simultaneous_options) do
			if key ~= "key_down_order" then options[key] = value end
		end
		from.simultaneous_options = next(options) and options or nil
	end

	local mandatory = {}
	for _, simultaneous_key in ipairs(from.simultaneous or {}) do
		if ACTUAL_MODIFIER_KEY_CODES[simultaneous_key.key_code] then
			mandatory[#mandatory + 1] = simultaneous_key.key_code
		end
	end
	local modifiers = { optional = { "any" } }
	if #mandatory > 0 then modifiers.mandatory = mandatory end
	if type(from.modifiers) == "table" then
		for key, value in pairs(from.modifiers) do modifiers[key] = deep_copy(value) end
		modifiers.optional = { "any" }
		if not from.modifiers.mandatory and #mandatory > 0 then
			modifiers.mandatory = mandatory
		end
	end
	from.modifiers = modifiers
	return from
end

local function build_chord_rule(release, combo_def, combo_action, combo_symmetric)
	local combo_to = combo_action.karabiner_to or {}
	if #combo_to == 0 then return nil end
	local from
	if release.chord_consumes_modifiers then
		from = modifier_consuming_chord_from(combo_def, combo_symmetric)
	else
		from = legacy_chord_from(combo_def, combo_symmetric)
	end
	local manipulator = { type = "basic", from = from, to = deep_copy(combo_to) }
	if combo_action.karabiner_to_after_key_up then
		manipulator.to_after_key_up = deep_copy(combo_action.karabiner_to_after_key_up)
	end
	return {
		description = string.format("%s: %s [chord]", combo_def.label, combo_action.label),
		manipulators = { manipulator },
	}
end

local function build_script_control_rules(release, context)
	local rules = {}
	for _, slot in ipairs(context.script_control_slots) do
		local output = { key_code = slot.sentinel }
		if release.sentinel_tags then output.modifiers = deep_copy(release.sentinel_tags) end
		rules[#rules + 1] = {
			description = string.format(
				"Script control: physical rcmd + %s → %s",
				slot.from_key,
				slot.sentinel
			),
			manipulators = {
				{
					type = "basic",
					from = {
						key_code = slot.from_key,
						modifiers = { optional = { "any" } },
					},
					conditions = {
						{ type = "variable_if", name = "ke_held_right_command", value = 1 },
					},
					to = { output },
				},
			},
		}
	end
	return rules
end

local function build_paused_rules(release, context)
	local rules = {}
	if release.paused_modifiers == false then return rules end
	for _, slot in ipairs(context.script_control_slots) do
		for _, modifier in ipairs(release.paused_modifiers) do
			local output = { key_code = slot.sentinel }
			if release.sentinel_tags then output.modifiers = deep_copy(release.sentinel_tags) end
			rules[#rules + 1] = {
				description = string.format(
					"Paused script control: %s + %s → %s",
					modifier,
					slot.from_key,
					slot.sentinel
				),
				manipulators = {
					{
						type = "basic",
						from = {
							key_code = slot.from_key,
							modifiers = { mandatory = { modifier }, optional = { "any" } },
						},
						to = { output },
					},
				},
			}
		end
	end
	return rules
end

local function build_normal_rules(release, state, combo_symmetric, context)
	local actions = deep_copy(context.available_actions)
	mark_layout_actions(actions)
	local tap_hold_keys = deep_copy(context.tap_hold_keys)
	local mod_combos = deep_copy(context.mod_combos)
	local action_index = build_action_index(actions)
	local none_action = action_index.none or { id = "none", label = "none", karabiner_to = {} }
	local rules = { deep_copy(context.capsword) }
	local key_held_modifiers = {}

	for _, key_def in ipairs(tap_hold_keys) do
		local config = state.tap_hold_config[key_def.id] or {}
		local hold_action = action_index[config.hold or "none"] or none_action
		local held_modifiers = {}
		for _, event in ipairs(hold_action.karabiner_to or {}) do
			if ACTUAL_MODIFIER_KEY_CODES[event.key_code] then
				held_modifiers[#held_modifiers + 1] = event.key_code
			end
		end
		if #held_modifiers > 0 then
			key_held_modifiers[key_def.from.key_code] = held_modifiers
		end
	end

	for _, combo_def in ipairs(mod_combos) do
		if not combo_def.menu_hidden then
			local config = state.mod_combos_config[combo_def.id] or {}
			local tap_id = config.tap or "none"
			local hold_id = config.hold or "none"
			local combo_id = config.combo or "none"
			if combo_symmetric and context.non_canonical[combo_def.id] == true then
				combo_id = "none"
			end
			local tap_action = action_index[tap_id] or none_action
			local hold_action = action_index[hold_id] or none_action
			local combo_action = action_index[combo_id] or none_action
			local simultaneous = combo_def.from and combo_def.from.simultaneous
			local first_key = simultaneous and simultaneous[1] and simultaneous[1].key_code
			local second_key = simultaneous and simultaneous[2] and simultaneous[2].key_code
			if first_key and second_key then
				local chord = build_chord_rule(release, combo_def, combo_action, combo_symmetric)
				if chord then rules[#rules + 1] = chord end
				local tap_hold = build_tap_hold_combo_rule(
					combo_def,
					tap_action,
					hold_action,
					first_key,
					second_key,
					key_held_modifiers[first_key]
				)
				if tap_hold then rules[#rules + 1] = tap_hold end
			end
		end
	end

	append_events(rules, build_script_control_rules(release, context))
	rules[#rules + 1] = deep_copy(context.layer_keys)
	rules[#rules + 1] = deep_copy(context.combos)
	for _, key_def in ipairs(tap_hold_keys) do
		local config = state.tap_hold_config[key_def.id] or {}
		local tap_action = action_index[config.tap or "none"] or none_action
		local hold_action = action_index[config.hold or "none"] or none_action
		local timeout_ms = tonumber(config.timeout_ms)
		if timeout_ms and timeout_ms <= 0 then timeout_ms = nil end
		rules[#rules + 1] = build_tap_hold_rule(
			release,
			key_def,
			tap_action,
			hold_action,
			action_index,
			timeout_ms,
			context.physical_log_path
		)
	end
	return rules
end

local function compare_graph(actual, expected, logical_to_physical, physical_to_logical)
	if type(expected) == "string" and expected:sub(1, #LAYOUT_MARKER_PREFIX) == LAYOUT_MARKER_PREFIX then
		if type(actual) ~= "string" or not CANONICAL_LAYOUT_KEY_CODES[actual] then return false end
		local logical_char = expected:sub(#LAYOUT_MARKER_PREFIX + 1)
		local learned_physical = logical_to_physical[logical_char]
		local learned_logical = physical_to_logical[actual]
		if learned_physical and learned_physical ~= actual then return false end
		if learned_logical and learned_logical ~= logical_char then return false end
		logical_to_physical[logical_char] = actual
		physical_to_logical[actual] = logical_char
		return true
	end
	if type(actual) ~= type(expected) then return false end
	if type(expected) ~= "table" then return actual == expected end
	for key, value in pairs(expected) do
		if not compare_graph(actual[key], value, logical_to_physical, physical_to_logical) then
			return false
		end
	end
	for key in pairs(actual) do
		if expected[key] == nil then return false end
	end
	return true
end

function M.release_metadata()
	local metadata = {}
	for _, release in ipairs(RELEASES) do
		metadata[#metadata + 1] = {
			id = release.id,
			tags = deep_copy(release.tags),
			commits = deep_copy(release.commits),
			generator_blob = release.generator_blob,
		}
	end
	return metadata
end

function M.build_normal_candidate(release_id, state, combo_symmetric, context)
	local release = RELEASE_BY_ID[release_id]
	if not release then return nil, "unknown legacy release fixture: " .. tostring(release_id) end
	return build_normal_rules(release, state, combo_symmetric, context)
end

function M.script_control_rule_sets(context)
	local sets = {}
	for _, release in ipairs(RELEASES) do
		local rules = build_script_control_rules(release, context)
		local matching_set = nil
		for _, candidate in ipairs(sets) do
			if deep_equal(candidate.rules, rules) then
				matching_set = candidate
				break
			end
		end
		if matching_set then
			matching_set.release_ids[#matching_set.release_ids + 1] = release.id
		else
			sets[#sets + 1] = { release_ids = { release.id }, rules = rules }
		end
	end
	return sets
end

function M.paused_rule_sets(context)
	local sets = {}
	for _, release in ipairs(RELEASES) do
		local rules = build_paused_rules(release, context)
		if #rules > 0 then
			local matching_set = nil
			for _, candidate in ipairs(sets) do
				if deep_equal(candidate.rules, rules) then
					matching_set = candidate
					break
				end
			end
			if matching_set then
				matching_set.release_ids[#matching_set.release_ids + 1] = release.id
			else
				sets[#sets + 1] = { release_ids = { release.id }, rules = rules }
			end
		end
	end
	return sets
end

function M.graph_equal(actual, expected)
	return compare_graph(actual, expected, {}, {})
end

function M.is_exact_release_control_rule(rule, context)
	for _, set in ipairs(M.script_control_rule_sets(context)) do
		for _, release_rule in ipairs(set.rules) do
			if deep_equal(rule, release_rule) then return true end
		end
	end
	for _, set in ipairs(M.paused_rule_sets(context)) do
		for _, release_rule in ipairs(set.rules) do
			if deep_equal(rule, release_rule) then return true end
		end
	end
	return false
end

return M
