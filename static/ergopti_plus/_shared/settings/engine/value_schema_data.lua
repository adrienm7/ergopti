--- _shared/settings/engine/value_schema_data.lua
--- AUTO-GENERATED from _shared/settings/data/value_schema/value_schema.json.
--- DO NOT EDIT BY HAND — run `npm run codegen:value-schema` to refresh.
---
--- The declaration of every user-entered setting value, as the table
--- settings.engine.value_check reads on macOS and Linux.

return {
	["version"] = 1,
	["keys"] = {
		["GESTURES_SENSITIVITIES_ANY"] = "gestures.sensitivities.*",
		["HOTSTRINGS_CASCADE_MAX_ARROWS"] = "hotstrings.cascade_max_arrows",
		["HOTSTRINGS_CONFIG_ANY_ANY_DELAY"] = "hotstrings_config.*.*.delay",
		["HOTSTRINGS_CONFIG_ANY_ANY_PRIORITY"] = "hotstrings_config.*.*.priority",
		["HOTSTRINGS_CONFIG_ANY_DELAY"] = "hotstrings_config.*.delay",
		["HOTSTRINGS_CONFIG_ANY_PRIORITY"] = "hotstrings_config.*.priority",
		["HOTSTRINGS_DYNAMIC_USER_CODE_TIME_ACTIVATION_SECONDS"] = "hotstrings.dynamic.user_code.time_activation_seconds",
		["HOTSTRINGS_EXPANSION_DELAY"] = "hotstrings.expansion_delay",
		["HOTSTRINGS_IDLE_RESET_SECONDS"] = "hotstrings.idle_reset_seconds",
		["LLM_GENERATION_CONTEXT_LENGTH"] = "llm.generation.context_length",
		["LLM_GENERATION_MAX_WORDS"] = "llm.generation.max_words",
		["LLM_GENERATION_MIN_WORDS"] = "llm.generation.min_words",
		["LLM_GENERATION_TEMPERATURE"] = "llm.generation.temperature",
		["LLM_PROFILES_NUM_PREDICTIONS"] = "llm.profiles.num_predictions",
		["LLM_TRIGGER_DEBOUNCE_MS"] = "llm.trigger.debounce_ms",
		["LLM_TRIGGER_MIN_REQUEST_INTERVAL_MS"] = "llm.trigger.min_request_interval_ms",
		["MOD_COMBOS_SIMULTANEOUS_THRESHOLD_MS"] = "mod_combos.simultaneous_threshold_ms",
		["PERSONAL_INFO_INFO_ANY"] = "personal_info.info.*",
		["PERSONAL_INFO_LETTERS_ANY"] = "personal_info.letters.*",
		["SHORTCUTS_CAPS_WORD_IDLE_TIMEOUT_SECONDS"] = "shortcuts.caps_word.idle_timeout_seconds",
		["SHORTCUTS_CHATGPT_URL"] = "shortcuts.chatgpt_url",
		["SHORTCUTS_SEARCH_SEARCH_ENGINE"] = "shortcuts.search.search_engine",
		["SHORTCUTS_SEARCH_SEARCH_ENGINE_URL_QUERY"] = "shortcuts.search.search_engine_url_query",
		["TAP_HOLDS_LONE_MODIFIER_TAP_MAX_MS"] = "tap_holds.lone_modifier_tap_max_ms",
		["TAP_HOLD_KEYS_ANY_TIME_ACTIVATION_SECONDS"] = "tap_hold.keys.*.time_activation_seconds",
		["TAP_HOLD_TIME_ACTIVATION_SECONDS"] = "tap_hold.time_activation_seconds",
	},
	["settings"] = {
		["gestures.sensitivities.*"] = {
			["file"] = "config.toml",
			["max"] = 60,
			["min"] = 1,
			["type"] = "decimal",
			["unit"] = "mm",
		},
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
		["llm.generation.context_length"] = {
			["default_from"] = {
				["manifest"] = "llm.generation.context_length",
			},
			["file"] = "config.toml",
			["max"] = 4000,
			["max_from"] = {
				["file"] = "ai/engine/policy/context_buffer.lua",
				["pattern"] = "M\\.MAX_CONTEXT_LENGTH = ([0-9]+)",
			},
			["min"] = 80,
			["type"] = "integer",
			["unit"] = "characters",
		},
		["llm.generation.max_words"] = {
			["default_from"] = {
				["manifest"] = "llm.generation.max_words",
			},
			["file"] = "config.toml",
			["max"] = 10000,
			["min"] = 0,
			["special"] = { {
				["label_key"] = "value_check.special.unlimited",
				["value"] = 0,
			} },
			["type"] = "integer",
			["unit"] = "words",
		},
		["llm.generation.min_words"] = {
			["default_from"] = {
				["manifest"] = "llm.generation.min_words",
			},
			["file"] = "config.toml",
			["max"] = 20,
			["min"] = 1,
			["type"] = "integer",
			["unit"] = "words",
		},
		["llm.generation.temperature"] = {
			["default_from"] = {
				["manifest"] = "llm.generation.temperature",
			},
			["file"] = "config.toml",
			["max"] = 1.3,
			["max_from"] = {
				["file"] = "ai/data/inference.json",
				["pattern"] = "\"max_temperature\": ([0-9.]+)",
			},
			["min"] = 0,
			["type"] = "decimal",
		},
		["llm.profiles.num_predictions"] = {
			["default_from"] = {
				["manifest"] = "llm.profiles.num_predictions",
			},
			["file"] = "config.toml",
			["max"] = 10,
			["min"] = 1,
			["type"] = "integer",
		},
		["llm.trigger.debounce_ms"] = {
			["default_from"] = {
				["manifest"] = "llm.trigger.debounce_ms",
			},
			["file"] = "config.toml",
			["max"] = 10000,
			["min"] = 50,
			["special"] = { {
				["label_key"] = "value_check.special.never",
				["value"] = -1,
			} },
			["type"] = "integer",
			["unit"] = "ms",
		},
		["llm.trigger.min_request_interval_ms"] = {
			["default_from"] = {
				["manifest"] = "llm.trigger.min_request_interval_ms",
			},
			["file"] = "config.toml",
			["max"] = 10000,
			["min"] = 0,
			["type"] = "integer",
			["unit"] = "ms",
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
		["personal_info.info.*"] = {
			["allow_empty"] = true,
			["file"] = "personal_info.toml",
			["type"] = "string",
		},
		["personal_info.letters.*"] = {
			["file"] = "personal_info.toml",
			["type"] = "string",
		},
		["shortcuts.caps_word.idle_timeout_seconds"] = {
			["default_from"] = {
				["manifest"] = "shortcuts.caps_word.idle_timeout_seconds",
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
		["shortcuts.chatgpt_url"] = {
			["default_from"] = {
				["manifest"] = "shortcuts.chatgpt_url",
			},
			["file"] = "config.toml",
			["max_length"] = 2048,
			["type"] = "url",
		},
		["shortcuts.search.search_engine"] = {
			["default_from"] = {
				["manifest"] = "shortcuts.search.search_engine",
			},
			["file"] = "config.toml",
			["max_length"] = 2048,
			["type"] = "url",
		},
		["shortcuts.search.search_engine_url_query"] = {
			["default_from"] = {
				["manifest"] = "shortcuts.search.search_engine_url_query",
			},
			["file"] = "config.toml",
			["max_length"] = 2048,
			["type"] = "url",
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
