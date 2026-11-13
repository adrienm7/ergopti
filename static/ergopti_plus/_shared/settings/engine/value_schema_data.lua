--- _shared/settings/engine/value_schema_data.lua
--- AUTO-GENERATED from _shared/settings/data/value_schema/value_schema.json.
--- DO NOT EDIT BY HAND — run `npm run codegen:value-schema` to refresh.
---
--- The declaration of every user-entered setting value, as the table
--- settings.engine.value_check reads on macOS and Linux.

return {
	["version"] = 1,
	["keys"] = {
		["MOD_COMBOS_SIMULTANEOUS_THRESHOLD_MS"] = "mod_combos.simultaneous_threshold_ms",
		["TAP_HOLDS_LONE_MODIFIER_TAP_MAX_MS"] = "tap_holds.lone_modifier_tap_max_ms",
		["TAP_HOLD_KEYS_ANY_TIME_ACTIVATION_SECONDS"] = "tap_hold.keys.*.time_activation_seconds",
		["TAP_HOLD_TIME_ACTIVATION_SECONDS"] = "tap_hold.time_activation_seconds",
	},
	["settings"] = {
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
