--- _shared/settings/engine/value_schema_data.lua
--- AUTO-GENERATED from _shared/settings/data/value_schema/value_schema.json.
--- DO NOT EDIT BY HAND — run `npm run codegen:value-schema` to refresh.
---
--- The declaration of every user-entered setting value, as the table
--- settings.engine.value_check reads on macOS and Linux.

return {
	["version"] = 1,
	["keys"] = {
		["HOTSTRINGS_CASCADE_MAX_ARROWS"] = "hotstrings.cascade_max_arrows",
		["HOTSTRINGS_CONFIG_ANY_ANY_DELAY"] = "hotstrings_config.*.*.delay",
		["HOTSTRINGS_CONFIG_ANY_ANY_PRIORITY"] = "hotstrings_config.*.*.priority",
		["HOTSTRINGS_CONFIG_ANY_DELAY"] = "hotstrings_config.*.delay",
		["HOTSTRINGS_CONFIG_ANY_PRIORITY"] = "hotstrings_config.*.priority",
		["HOTSTRINGS_DYNAMIC_USER_CODE_TIME_ACTIVATION_SECONDS"] = "hotstrings.dynamic.user_code.time_activation_seconds",
		["HOTSTRINGS_EXPANSION_DELAY"] = "hotstrings.expansion_delay",
		["HOTSTRINGS_IDLE_RESET_SECONDS"] = "hotstrings.idle_reset_seconds",
		["MOD_COMBOS_SIMULTANEOUS_THRESHOLD_MS"] = "mod_combos.simultaneous_threshold_ms",
		["TAP_HOLDS_LONE_MODIFIER_TAP_MAX_MS"] = "tap_holds.lone_modifier_tap_max_ms",
		["TAP_HOLD_KEYS_ANY_TIME_ACTIVATION_SECONDS"] = "tap_hold.keys.*.time_activation_seconds",
		["TAP_HOLD_TIME_ACTIVATION_SECONDS"] = "tap_hold.time_activation_seconds",
	},
	["settings"] = {
		["hotstrings.cascade_max_arrows"] = {
			["default_from"] = {
				["manifest"] = "hotstrings.cascade_max_arrows",
			},
			["file"] = "config.toml",
			["max"] = 10,
			["min"] = 1,
			["type"] = "integer",
		},
		["hotstrings.dynamic.user_code.time_activation_seconds"] = {
			["entry_scale"] = 1000,
			["entry_type"] = "integer",
			["entry_unit"] = "ms",
			["file"] = "config.toml",
			["max"] = 3600,
			["min"] = 0,
			["type"] = "decimal",
			["unit"] = "s",
		},
		["hotstrings.expansion_delay"] = {
			["default_from"] = {
				["manifest"] = "hotstrings.expansion_delay",
			},
			["entry_scale"] = 1000,
			["entry_type"] = "integer",
			["entry_unit"] = "ms",
			["file"] = "config.toml",
			["max"] = 3600,
			["min"] = 0,
			["special"] = { {
				["label_key"] = "value_check.special.no_time_limit",
				["value"] = 0,
			} },
			["type"] = "decimal",
			["unit"] = "s",
		},
		["hotstrings.idle_reset_seconds"] = {
			["default_from"] = {
				["manifest"] = "hotstrings.idle_reset_seconds",
			},
			["file"] = "config.toml",
			["max"] = 3600,
			["min"] = 0,
			["special"] = { {
				["label_key"] = "value_check.special.never",
				["value"] = 0,
			} },
			["type"] = "decimal",
			["unit"] = "s",
		},
		["hotstrings_config.*.*.delay"] = {
			["entry_scale"] = 1000,
			["entry_type"] = "integer",
			["entry_unit"] = "ms",
			["file"] = "hotstrings_config.toml",
			["max"] = 3600,
			["min"] = 0,
			["type"] = "decimal",
			["unit"] = "s",
		},
		["hotstrings_config.*.*.priority"] = {
			["file"] = "hotstrings_config.toml",
			["max"] = 100,
			["min"] = 0,
			["type"] = "integer",
		},
		["hotstrings_config.*.delay"] = {
			["entry_scale"] = 1000,
			["entry_type"] = "integer",
			["entry_unit"] = "ms",
			["file"] = "hotstrings_config.toml",
			["max"] = 3600,
			["min"] = 0,
			["type"] = "decimal",
			["unit"] = "s",
		},
		["hotstrings_config.*.priority"] = {
			["file"] = "hotstrings_config.toml",
			["max"] = 100,
			["min"] = 0,
			["type"] = "integer",
		},
		["mod_combos.simultaneous_threshold_ms"] = {
			["default_from"] = {
				["manifest"] = "mod_combos.simultaneous_threshold_ms",
			},
			["file"] = "config.toml",
			["max"] = 1000,
			["min"] = 1,
			["type"] = "integer",
			["unit"] = "ms",
		},
		["tap_hold.keys.*.time_activation_seconds"] = {
			["entry_scale"] = 1000,
			["entry_type"] = "integer",
			["entry_unit"] = "ms",
			["file"] = "tap_hold.toml",
			["max"] = 10,
			["max_from"] = {
				["scale"] = 0.001,
				["timing"] = "tap_hold.max_activation_ms",
			},
			["min"] = 0.001,
			["type"] = "decimal",
			["unit"] = "s",
		},
		["tap_hold.time_activation_seconds"] = {
			["default_from"] = {
				["scale"] = 0.001,
				["timing"] = "tap_hold.default_activation_ms",
			},
			["entry_scale"] = 1000,
			["entry_type"] = "integer",
			["entry_unit"] = "ms",
			["file"] = "tap_hold.toml",
			["max"] = 10,
			["max_from"] = {
				["scale"] = 0.001,
				["timing"] = "tap_hold.max_activation_ms",
			},
			["min"] = 0.001,
			["type"] = "decimal",
			["unit"] = "s",
		},
		["tap_holds.lone_modifier_tap_max_ms"] = {
			["default_from"] = {
				["manifest"] = "tap_holds.lone_modifier_tap_max_ms",
			},
			["file"] = "config.toml",
			["max"] = 10000,
			["min"] = 0,
			["special"] = { {
				["label_key"] = "value_check.special.off",
				["value"] = 0,
			} },
			["type"] = "integer",
			["unit"] = "ms",
		},
	},
}
