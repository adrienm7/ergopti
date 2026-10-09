--- tests/fixtures/karabiner_legacy_releases.lua

--- ==============================================================================
--- MODULE: Immutable Karabiner Legacy Release Fixtures
--- DESCRIPTION:
--- Literal pre-lease rule graphs copied from released generator revisions. The
--- fixtures deliberately do not call the live generator: changing today's
--- generator must not rewrite history and turn a migration regression green.
--- ==============================================================================

local M = {}

local function deep_copy(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, nested in pairs(value) do copy[deep_copy(key)] = deep_copy(nested) end
	return copy
end

-- Source: tag v0.0.0-dev.74, commit
-- 867d8b1bc5ed0738371571c194c0050fc0efe01b. This release predates the
-- a066eeae7ba4cb7710ebd1ae6c12acdf46614225 chord-modifier fix: its
-- simultaneous `from` table has no synthetic `modifiers` member.
local V74_CHORD_RULES = {
	{
		description = "CapsWord legacy anchor",
		manipulators = {
			{ type = "basic", from = { key_code = "caps_lock" }, to = { { key_code = "caps_lock" } } },
		},
	},
	{
		description = "Modifier pair: Output [chord]",
		manipulators = {
			{
				type = "basic",
				from = {
					simultaneous = { { key_code = "right_command" }, { key_code = "left_command" } },
					simultaneous_options = { key_down_order = "strict" },
				},
				to = { { key_code = "x" } },
			},
		},
	},
	{
		description = "Script control: physical rcmd + delete_or_backspace → key_107",
		manipulators = {
			{
				type = "basic",
				from = { key_code = "delete_or_backspace", modifiers = { optional = { "any" } } },
				conditions = { { type = "variable_if", name = "ke_held_right_command", value = 1 } },
				to = { { key_code = "key_107", modifiers = { "left_control", "left_shift" } } },
			},
		},
	},
	{
		description = "Script control: physical rcmd + return_or_enter → key_105",
		manipulators = {
			{
				type = "basic",
				from = { key_code = "return_or_enter", modifiers = { optional = { "any" } } },
				conditions = { { type = "variable_if", name = "ke_held_right_command", value = 1 } },
				to = { { key_code = "key_105", modifiers = { "left_control", "left_shift" } } },
			},
		},
	},
	{
		description = "Script control: physical rcmd + escape → key_113",
		manipulators = {
			{
				type = "basic",
				from = { key_code = "escape", modifiers = { optional = { "any" } } },
				conditions = { { type = "variable_if", name = "ke_held_right_command", value = 1 } },
				to = { { key_code = "key_113", modifiers = { "left_control", "left_shift" } } },
			},
		},
	},
	{
		description = "Layer legacy anchor",
		manipulators = {
			{ type = "basic", from = { key_code = "a" }, to = { { key_code = "left_arrow" } } },
		},
	},
	{
		description = "Combo legacy anchor",
		manipulators = {
			{ type = "basic", from = { key_code = "b" }, to = { { key_code = "right_arrow" } } },
		},
	},
}

-- Source: tag v0.0.0-dev.71, commit
-- 56671dad9959616528ec0ece1ab660f0a5f5674f, generator blob
-- 6eecede1a8c6e413a78d18082002d2b69dd68301. This one-release schema used
-- option-only paused rules while sentinels still carried only left_control.
local V71_PAUSED_RULES = {
	{
		description = "Paused script control: option + delete_or_backspace → key_107",
		manipulators = {
			{
				type = "basic",
				from = {
					key_code = "delete_or_backspace",
					modifiers = { mandatory = { "option" }, optional = { "any" } },
				},
				to = { { key_code = "key_107", modifiers = { "left_control" } } },
			},
		},
	},
	{
		description = "Paused script control: option + return_or_enter → key_105",
		manipulators = {
			{
				type = "basic",
				from = {
					key_code = "return_or_enter",
					modifiers = { mandatory = { "option" }, optional = { "any" } },
				},
				to = { { key_code = "key_105", modifiers = { "left_control" } } },
			},
		},
	},
	{
		description = "Paused script control: option + escape → key_113",
		manipulators = {
			{
				type = "basic",
				from = {
					key_code = "escape",
					modifiers = { mandatory = { "option" }, optional = { "any" } },
				},
				to = { { key_code = "key_113", modifiers = { "left_control" } } },
			},
		},
	},
}

-- Source: tag v0.0.0-dev.45, commit
-- b88a2e8c210ec1847aa7e43a02d9e86324fd5d68, generator blob
-- 1845f742906e373867897c54f4fed4829bfbb70e. The first pause-capable release
-- emitted both right_command and right_option variants without sentinel tags.
local V45_PAUSED_RULES = {}
for _, slot in ipairs({
	{ from_key = "delete_or_backspace", sentinel = "key_107" },
	{ from_key = "return_or_enter", sentinel = "key_105" },
	{ from_key = "escape", sentinel = "key_113" },
}) do
	for _, modifier in ipairs({ "right_command", "right_option" }) do
		V45_PAUSED_RULES[#V45_PAUSED_RULES + 1] = {
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
					to = { { key_code = slot.sentinel } },
				},
			},
		}
	end
end

-- Source: tag v0.0.0-dev.1, commit
-- dd6e196f75557c93e8c120e96547bf6938cd724c, generator blob
-- b5fc0ee90aa0577ea6ee75cd80708c5bccb95bf4. This full normal block pins
-- pre-pause sentinels and the original unescaped physical-key log command.
local V1_NORMAL_RULES = {
	{
		description = "CapsWord legacy anchor",
		manipulators = {
			{ type = "basic", from = { key_code = "caps_lock" }, to = { { key_code = "caps_lock" } } },
		},
	},
	{
		description = "Script control: physical rcmd + delete_or_backspace → key_107",
		manipulators = {
			{
				type = "basic",
				from = { key_code = "delete_or_backspace", modifiers = { optional = { "any" } } },
				conditions = { { type = "variable_if", name = "ke_held_right_command", value = 1 } },
				to = { { key_code = "key_107" } },
			},
		},
	},
	{
		description = "Script control: physical rcmd + return_or_enter → key_105",
		manipulators = {
			{
				type = "basic",
				from = { key_code = "return_or_enter", modifiers = { optional = { "any" } } },
				conditions = { { type = "variable_if", name = "ke_held_right_command", value = 1 } },
				to = { { key_code = "key_105" } },
			},
		},
	},
	{
		description = "Script control: physical rcmd + escape → key_113",
		manipulators = {
			{
				type = "basic",
				from = { key_code = "escape", modifiers = { optional = { "any" } } },
				conditions = { { type = "variable_if", name = "ke_held_right_command", value = 1 } },
				to = { { key_code = "key_113" } },
			},
		},
	},
	{
		description = "Layer legacy anchor",
		manipulators = {
			{ type = "basic", from = { key_code = "a" }, to = { { key_code = "left_arrow" } } },
		},
	},
	{
		description = "Combo legacy anchor",
		manipulators = {
			{ type = "basic", from = { key_code = "b" }, to = { { key_code = "right_arrow" } } },
		},
	},
	{
		description = "Left Shift: Logical escape (tap) / None (hold)",
		manipulators = {
			{
				type = "basic",
				from = { key_code = "left_shift" },
				to = {
					{ set_variable = { name = "ke_held_left_shift", value = 1 } },
					{
						shell_command = "echo 'left_shift' >> '/tmp/ergopti_generator_lease/metrics/karabiner_kc.log'",
					},
					{ key_code = "left_shift" },
				},
				to_if_alone = { { key_code = "q" } },
				to_after_key_up = {
					{ set_variable = { name = "ke_held_left_shift", value = 0 } },
					{
						shell_command = "echo 'U:left_shift' >> '/tmp/ergopti_generator_lease/metrics/karabiner_kc.log'",
					},
				},
			},
		},
	},
}

function M.v74_chord_rules()
	return deep_copy(V74_CHORD_RULES)
end

function M.v71_paused_rules()
	return deep_copy(V71_PAUSED_RULES)
end

function M.v45_paused_rules()
	return deep_copy(V45_PAUSED_RULES)
end

function M.v1_normal_rules()
	return deep_copy(V1_NORMAL_RULES)
end

return M
