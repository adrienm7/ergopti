--- _generated/features_manifest.lua
--- AUTO-GENERATED from _shared/modules/features/manifest.toml.
--- DO NOT EDIT BY HAND — run `npm run build:manifest` to refresh.
---
--- NOTE (F-LOW-15): description_key is emitted here for structural
--- parity with the AHK twin (features_manifest.ahk) and because
--- test-manifest-parity.cjs cross-checks it between the two generated
--- files — but no Lua module on macOS reads entry.description_key today
--- (confirmed via a repo-wide grep; infra/manifest_reader.lua's own
--- docstring documents it as exposing only what macOS modules actually
--- consume). The AHK driver genuinely resolves every description_key via
--- its menu builder. Removing the field from this side alone would break
--- the shared parity-test regex parsers, which require it to even match a
--- section/feature block — left as-is rather than touching that shared path.

local M = {}

M.version = "2.0.0"

M.section_order = { "script", "hotstrings", "llm", "metrics", "shortcuts", "gestures", "layout", "category_enabled", "ui" }
M.scopes = { tap_holds = { action_parameters = { domains = { "tap_hold" }, restore = "remove" }, prefixes = { "tap_holds", "category_enabled.tap_holds" }, preset = "tap_hold", restore_exclude = {  }, clear_exclude = { "tap_holds.enabled", "category_enabled.tap_holds" } }, shortcuts = { includes = { "key_combinations" }, action_parameters = { domains = { "keyboard", "script", "tap_key" }, restore = "remove" }, prefixes = { "shortcuts", "mod_combos", "category_enabled.shortcuts", "category_enabled.key_combinations" }, restore_exclude = {  }, dynamic_defaults = { { prefix = "shortcuts.personal", depth = 1, default = false, recommended = false, type = "boolean" }, { prefix = "shortcuts.keyboard", depth = 1, default = "none", recommended = "none", type = "string" } } }, key_combinations = { action_parameters = { domains = { "combination" }, restore = "remove" }, prefixes = { "shortcuts.key_combination_taps", "shortcuts.key_combination_holds", "mod_combos", "category_enabled.key_combinations" }, restore_exclude = {  }, clear_exclude = { "mod_combos.enabled", "category_enabled.key_combinations" }, dynamic_defaults = { { prefix = "shortcuts.key_combination_taps", depth = 1, default = "none", recommended = "none", type = "string" }, { prefix = "shortcuts.key_combination_holds", depth = 1, default = "none", recommended = "none", type = "string" } } }, gestures = { action_parameters = { domains = { "gesture" }, restore = "remove" }, prefixes = { "gestures" }, restore_exclude = {  }, clear_exclude = { "gestures.enabled" } }, keyboard_layout = { prefixes = { "layout", "category_enabled.layout", "script.alt_gr_is_kana_remap" }, restore_exclude = {  } }, hotstrings = { prefixes = { "hotstrings", "category_enabled.hotstrings", "category_enabled.autocorrection", "category_enabled.distances_reduction", "category_enabled.sfbs_reduction", "category_enabled.rolls", "category_enabled.magic_key" }, restore_exclude = { "hotstrings.preview_ai_enabled" }, dynamic_defaults = { { prefix = "category_enabled", depth = 1, default = false, recommended = true, type = "boolean" }, { prefix = "hotstrings.groups", depth = 1, default = false, recommended = true, type = "boolean" }, { prefix = "hotstrings.modules", depth = 2, default = false, recommended = true, type = "boolean" }, { prefix = "hotstrings.personal", depth = 2, suffix = "enabled", default = false, recommended = false, type = "boolean" }, { prefix = "hotstrings.personal", depth = 2, suffix = "time_activation_seconds", default = 0, recommended = 0, type = "integer" } } }, llm = { prefixes = { "llm" }, restore_exclude = { "llm.enabled" }, dynamic_defaults = { { prefix = "llm.profiles.shortcuts", depth = 2, suffix = "mods", default = {  }, recommended = {  }, type = "array" }, { prefix = "llm.profiles.shortcuts", depth = 2, suffix = "key", default = "", recommended = "", type = "string" } } }, metrics = { prefixes = { "metrics" }, restore_exclude = { "metrics.enabled", "metrics.metrics_enabled" } }, global = { includes = { "tap_holds", "shortcuts", "gestures", "keyboard_layout", "hotstrings", "llm", "metrics" }, prefixes = { "script" }, restore_exclude = {  } } }

M.sections = {
	["script"] = { description_key = "menu.script", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings"] = { description_key = "menu.hotstrings", platforms = { "ahk", "hs", "linux" }, subsections = { "autocorrection", "distances_reduction", "sfbs_reduction", "rolls", "magic_key", "french_distancesreduction", "french_autocorrection", "french_magickey", "dynamic", "personal" } },
	["hotstrings.autocorrection"] = { description_key = "menu.hotstrings.autocorrection", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.distances_reduction"] = { description_key = "menu.hotstrings.distances_reduction", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.sfbs_reduction"] = { description_key = "menu.hotstrings.sfbs_reduction", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.rolls"] = { description_key = "menu.hotstrings.rolls", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.magic_key"] = { description_key = "menu.hotstrings.magic_key", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.french_distancesreduction"] = { description_key = "menu.hotstrings.distances_reduction", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.french_autocorrection"] = { description_key = "menu.hotstrings.autocorrection", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.french_magickey"] = { description_key = "menu.hotstrings.magic_key", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.dynamic"] = { description_key = "menu.hotstrings.dynamic", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.personal"] = { description_key = "menu.hotstrings.personal", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.order_overrides"] = { description_key = "menu.hotstrings", platforms = { "hs" }, subsections = {  } },
	["llm"] = { description_key = "menu.llm", platforms = { "ahk", "hs", "linux" }, subsections = { "display", "generation", "models", "profiles", "trigger", "navigation" } },
	["llm.display"] = { description_key = "menu.llm.display", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["llm.generation"] = { description_key = "menu.llm.generation", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["llm.models"] = { description_key = "menu.llm.models", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["llm.profiles"] = { description_key = "menu.llm.profiles", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["llm.trigger"] = { description_key = "menu.llm.trigger", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["llm.navigation"] = { description_key = "menu.llm.navigation", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["metrics"] = { description_key = "menu.metrics", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["shortcuts"] = { description_key = "menu.shortcuts", platforms = { "ahk", "hs", "linux" }, subsections = { "key_combination_taps", "keyboard", "personal", "script_control", "tap_keys", "wrap_symbols" } },
	["shortcuts.key_combination_taps"] = { description_key = "menu.shortcuts.key_combinations", platforms = { "ahk", "linux" }, subsections = {  } },
	["shortcuts.keyboard"] = { description_key = "menu.shortcuts.keyboard", platforms = { "ahk" }, subsections = {  } },
	["shortcuts.personal"] = { description_key = "menu.shortcuts.personal", platforms = { "ahk" }, subsections = {  } },
	["shortcuts.script_control"] = { description_key = "menu.shortcuts.script_control", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["shortcuts.wrap_symbols"] = { description_key = "menu.shortcuts.wrap_symbols", platforms = { "hs" }, subsections = {  } },
	["shortcuts.tap_keys"] = { description_key = "menu.shortcuts.header_tap_keys", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["category_enabled"] = { description_key = "menu.category_enabled", platforms = { "ahk" }, subsections = {  } },
	["layout"] = { description_key = "menu.layout", platforms = { "ahk", "hs" }, subsections = {  } },
	["ui"] = { description_key = "menu.ui", platforms = { "hs" }, subsections = {  } },
	["gestures"] = { description_key = "menu.gestures", platforms = { "ahk", "hs", "linux" }, subsections = { "modes", "sensitivities" } },
	["gestures.modes"] = { description_key = "menu.gestures.modes", platforms = { "hs" }, subsections = {  } },
	["gestures.sensitivities"] = { description_key = "menu.gestures.sensitivities", platforms = { "hs" }, subsections = {  } },
}

M.features = {
	{
		path = "script.locale", id = "locale", section = "script", default = "fr", type = "string", description_key = "menu.script.locale", platforms = { "ahk", "hs", "linux" }, recommended = "fr", input_altering = false,
	},
	{
		path = "script.log_level", id = "log_level", section = "script", default = "INFO", type = "enum", description_key = "menu.script.log_level", platforms = { "ahk", "hs", "linux" }, recommended = "INFO", input_altering = false, enum_values = { "DEBUG", "TRACE", "DONE", "INFO", "START", "SUCCESS", "WARNING", "ERROR" },
	},
	{
		path = "script.show_error_dialog", id = "show_error_dialog", section = "script", default = true, type = "boolean", description_key = "menu.debug.show_error_dialog", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = false,
	},
	{
		path = "hotstrings.enabled", id = "enabled", section = "hotstrings", default = false, type = "boolean", description_key = "menu.hotstrings", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "hotstrings.dynamic.enabled", id = "enabled", section = "hotstrings.dynamic", default = false, type = "boolean", description_key = "menu.hotstrings", platforms = { "hs", "linux" }, recommended = true, input_altering = true,
	},
	{
		path = "hotstrings.trigger_char", id = "trigger_char", section = "hotstrings", default = "★", type = "string", description_key = "menu.hotstrings.trigger_char", platforms = { "ahk", "hs", "linux" }, recommended = "★", input_altering = false,
	},
	{
		path = "hotstrings.magic_key_source", id = "magic_key_source", section = "hotstrings", default = "auto", type = "enum", description_key = "menu.hotstrings.magic_key_source", platforms = { "ahk", "hs", "linux" }, recommended = "auto", input_altering = false, enum_values = { "auto", "Backquote", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8", "Digit9", "Digit0", "Minus", "Equal", "KeyQ", "KeyW", "KeyE", "KeyR", "KeyT", "KeyY", "KeyU", "KeyI", "KeyO", "KeyP", "BracketLeft", "BracketRight", "KeyA", "KeyS", "KeyD", "KeyF", "KeyG", "KeyH", "KeyJ", "KeyK", "KeyL", "Semicolon", "Quote", "Backslash", "IntlBackslash", "KeyZ", "KeyX", "KeyC", "KeyV", "KeyB", "KeyN", "KeyM", "Comma", "Period", "Slash" },
	},
	{
		path = "hotstrings.repeat_key_enabled", id = "repeat_key_enabled", section = "hotstrings", default = false, type = "boolean", description_key = "menu.hotstrings.repeat_key_enabled", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = true,
	},
	{
		path = "hotstrings.expansion_delay", id = "expansion_delay", section = "hotstrings", default = 0.75, type = "number", description_key = "menu.hotstrings.expansion_delay", platforms = { "hs" }, recommended = 0.75, input_altering = false,
	},
	{
		path = "hotstrings.preview_ai_enabled", id = "preview_ai_enabled", section = "hotstrings", default = false, type = "boolean", description_key = "menu.hotstrings.preview_ai_enabled", platforms = { "hs", "linux" }, recommended = true, input_altering = true,
	},
	{
		path = "hotstrings.preview_autocorrect_enabled", id = "preview_autocorrect_enabled", section = "hotstrings", default = false, type = "boolean", description_key = "menu.hotstrings.preview_autocorrect_enabled", platforms = { "hs", "linux" }, recommended = true, input_altering = true,
	},
	{
		path = "hotstrings.preview_colored_tooltips", id = "preview_colored_tooltips", section = "hotstrings", default = false, type = "boolean", description_key = "menu.hotstrings.preview_colored_tooltips", platforms = { "hs", "linux" }, recommended = true, input_altering = true,
	},
	{
		path = "hotstrings.preview_star_enabled", id = "preview_star_enabled", section = "hotstrings", default = false, type = "boolean", description_key = "menu.hotstrings.preview_star_enabled", platforms = { "hs", "linux" }, recommended = true, input_altering = true,
	},
	{
		path = "hotstrings.autocorrection.names", id = "names", section = "hotstrings.autocorrection", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.names", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.autocorrection.abbreviations", id = "abbreviations", section = "hotstrings.autocorrection", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.abbreviations", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.autocorrection.technical_terms", id = "technical_terms", section = "hotstrings.autocorrection", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.technical_terms", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.distances_reduction.qu", id = "qu", section = "hotstrings.distances_reduction", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.distances_reduction.qu", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.distances_reduction.comma_j", id = "comma_j", section = "hotstrings.distances_reduction", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.distances_reduction.comma_j", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.distances_reduction.comma_far_letters", id = "comma_far_letters", section = "hotstrings.distances_reduction", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.distances_reduction.comma_far_letters", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.distances_reduction.dead_key_e_circumflex", id = "dead_key_e_circumflex", section = "hotstrings.distances_reduction", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.distances_reduction.dead_key_e_circumflex", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.distances_reduction.e_circumflex_e", id = "e_circumflex_e", section = "hotstrings.distances_reduction", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.distances_reduction.e_circumflex_e", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.distances_reduction.space_around_symbols", id = "space_around_symbols", section = "hotstrings.distances_reduction", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.distances_reduction.space_around_symbols", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.sfbs_reduction.comma", id = "comma", section = "hotstrings.sfbs_reduction", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.sfbs_reduction.comma", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.sfbs_reduction.e_circ", id = "e_circ", section = "hotstrings.sfbs_reduction", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.sfbs_reduction.e_circ", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.sfbs_reduction.e_grave", id = "e_grave", section = "hotstrings.sfbs_reduction", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.sfbs_reduction.e_grave", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.sfbs_reduction.bu", id = "bu", section = "hotstrings.sfbs_reduction", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.sfbs_reduction.bu", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.sfbs_reduction.i_e_acute", id = "i_e_acute", section = "hotstrings.sfbs_reduction", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.sfbs_reduction.i_e_acute", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.hc", id = "hc", section = "hotstrings.rolls", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.hc", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.sx", id = "sx", section = "hotstrings.rolls", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.sx", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.cx", id = "cx", section = "hotstrings.rolls", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.cx", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.ct", id = "ct", section = "hotstrings.rolls", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.ct", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.ez", id = "ez", section = "hotstrings.rolls", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.ez", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.assign", id = "assign", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.assign", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.assign_arrow_equal_left", id = "assign_arrow_equal_left", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.assign_arrow_equal_left", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.assign_arrow_equal_right", id = "assign_arrow_equal_right", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.assign_arrow_equal_right", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.assign_arrow_minus_left", id = "assign_arrow_minus_left", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.assign_arrow_minus_left", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.assign_arrow_minus_right", id = "assign_arrow_minus_right", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.assign_arrow_minus_right", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.bracket_quote", id = "bracket_quote", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.bracket_quote", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.chevron_equal", id = "chevron_equal", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.chevron_equal", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.chevron_greater", id = "chevron_greater", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.chevron_greater", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.chevron_less", id = "chevron_less", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.chevron_less", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.close_chevron_tag", id = "close_chevron_tag", section = "hotstrings.rolls", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.close_chevron_tag", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.comment_close", id = "comment_close", section = "hotstrings.rolls", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.comment_close", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.comment_open", id = "comment_open", section = "hotstrings.rolls", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.comment_open", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.english_negation", id = "english_negation", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.english_negation", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.equal_string", id = "equal_string", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.equal_string", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.hashtag_close_bracket", id = "hashtag_close_bracket", section = "hotstrings.rolls", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.hashtag_close_bracket", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.hashtag_open_bracket", id = "hashtag_open_bracket", section = "hotstrings.rolls", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.hashtag_open_bracket", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.hashtag_parenthesis", id = "hashtag_parenthesis", section = "hotstrings.rolls", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.hashtag_parenthesis", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.hashtag_quote", id = "hashtag_quote", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.hashtag_quote", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.left_arrow", id = "left_arrow", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.left_arrow", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.not_equal", id = "not_equal", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.not_equal", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.rolls.paren_quote", id = "paren_quote", section = "hotstrings.rolls", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.rolls.paren_quote", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.magic_key.replace", id = "replace", section = "hotstrings.magic_key", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.magic_key.replace", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = true }, input_altering = true,
	},
	{
		path = "hotstrings.magic_key.repeat_corrections", id = "repeat_corrections", section = "hotstrings.magic_key", default = { enabled = false, time_activation_seconds = 2 }, type = "feature", description_key = "menu.hotstrings.magic_key.repeat_corrections", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 2 }, input_altering = true,
	},
	{
		path = "hotstrings.magic_key.text_expansion_symbols", id = "text_expansion_symbols", section = "hotstrings.magic_key", default = { enabled = false, time_activation_seconds = 2 }, type = "feature", description_key = "menu.hotstrings.magic_key.text_expansion_symbols", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 2 }, input_altering = true,
	},
	{
		path = "hotstrings.magic_key.text_expansion_symbols_typst", id = "text_expansion_symbols_typst", section = "hotstrings.magic_key", default = { enabled = false, time_activation_seconds = 2 }, type = "feature", description_key = "menu.hotstrings.magic_key.text_expansion_symbols_typst", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 2 }, input_altering = true,
	},
	{
		path = "hotstrings.french_distancesreduction.suffixes_a", id = "suffixes_a", section = "hotstrings.french_distancesreduction", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.distances_reduction.suffixes_a", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.french_autocorrection.accents", id = "accents", section = "hotstrings.french_autocorrection", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.accents", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.french_autocorrection.names", id = "names", section = "hotstrings.french_autocorrection", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.names", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.french_autocorrection.typographic_apostrophe", id = "typographic_apostrophe", section = "hotstrings.french_autocorrection", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.typographic_apostrophe", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.french_autocorrection.errors", id = "errors", section = "hotstrings.french_autocorrection", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.errors", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.french_autocorrection.ou", id = "ou", section = "hotstrings.french_autocorrection", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.ou", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.french_autocorrection.multiple_punctuation_marks", id = "multiple_punctuation_marks", section = "hotstrings.french_autocorrection", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.multiple_punctuation_marks", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.french_autocorrection.suffixes_a_chaining", id = "suffixes_a_chaining", section = "hotstrings.french_autocorrection", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.suffixes_a_chaining", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.french_autocorrection.minus", id = "minus", section = "hotstrings.french_autocorrection", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.minus", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.french_autocorrection.minus_apostrophe", id = "minus_apostrophe", section = "hotstrings.french_autocorrection", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.minus_apostrophe", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.french_magickey.text_expansion", id = "text_expansion", section = "hotstrings.french_magickey", default = { enabled = false, time_activation_seconds = 2 }, type = "feature", description_key = "menu.hotstrings.magic_key.text_expansion", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 2 }, input_altering = true,
	},
	{
		path = "hotstrings.french_magickey.text_expansion_auto", id = "text_expansion_auto", section = "hotstrings.french_magickey", default = { enabled = false, time_activation_seconds = 2 }, type = "feature", description_key = "menu.hotstrings.magic_key.text_expansion_auto", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 2 }, input_altering = true,
	},
	{
		path = "hotstrings.french_magickey.text_expansion_emojis", id = "text_expansion_emojis", section = "hotstrings.french_magickey", default = { enabled = false, time_activation_seconds = 2 }, type = "feature", description_key = "menu.hotstrings.magic_key.text_expansion_emojis", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 2 }, input_altering = true,
	},
	{
		path = "hotstrings.dynamic.date", id = "date", section = "hotstrings.dynamic", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.dynamic.date", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.dynamic.date_fr", id = "date_fr", section = "hotstrings.dynamic", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.dynamic.date_fr", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.dynamic.date_long_fr", id = "date_long_fr", section = "hotstrings.dynamic", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.dynamic.date_long_fr", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.dynamic.iban_prefixes", id = "iban_prefixes", section = "hotstrings.dynamic", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.dynamic.iban_prefixes", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.dynamic.phone_prefixes", id = "phone_prefixes", section = "hotstrings.dynamic", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.dynamic.phone_prefixes", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.dynamic.ssn_prefixes", id = "ssn_prefixes", section = "hotstrings.dynamic", default = { enabled = false }, type = "feature", description_key = "menu.hotstrings.dynamic.ssn_prefixes", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false }, input_altering = true,
	},
	{
		path = "hotstrings.dynamic.user_code", id = "user_code", section = "hotstrings.dynamic", default = { enabled = false, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.user_code.title", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, time_activation_seconds = 0.5 }, input_altering = true,
	},
	{
		path = "hotstrings.dynamic.text_expansion_personal_information", id = "text_expansion_personal_information", section = "hotstrings.dynamic", default = { enabled = false, pattern_max_length = 1 }, type = "feature", description_key = "menu.hotstrings.dynamic.text_expansion_personal_information", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = false, pattern_max_length = 1 }, input_altering = true,
	},
	{
		path = "hotstrings.personal.autocorrection", id = "autocorrection", section = "hotstrings.personal", default = { enabled = false, time_activation_seconds = 0.75 }, type = "feature", description_key = "menu.hotstrings.personal.autocorrection", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = true, time_activation_seconds = 0.75 }, input_altering = true,
	},
	{
		path = "hotstrings.personal.code", id = "code", section = "hotstrings.personal", default = { enabled = false, time_activation_seconds = 0.75 }, type = "feature", description_key = "menu.hotstrings.personal.code", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = true, time_activation_seconds = 0.75 }, input_altering = true,
	},
	{
		path = "hotstrings.personal.email_shortcuts", id = "email_shortcuts", section = "hotstrings.personal", default = { enabled = false, time_activation_seconds = 0.75 }, type = "feature", description_key = "menu.hotstrings.personal.email_shortcuts", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = true, time_activation_seconds = 0.75 }, input_altering = true,
	},
	{
		path = "hotstrings.personal.professional_vocabulary", id = "professional_vocabulary", section = "hotstrings.personal", default = { enabled = false, time_activation_seconds = 0.75 }, type = "feature", description_key = "menu.hotstrings.personal.professional_vocabulary", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = true, time_activation_seconds = 0.75 }, input_altering = true,
	},
	{
		path = "hotstrings.personal.test", id = "test", section = "hotstrings.personal", default = { enabled = false, time_activation_seconds = 0.75 }, type = "feature", description_key = "menu.hotstrings.personal.test", platforms = { "ahk", "hs", "linux" }, recommended = { enabled = true, time_activation_seconds = 0.75 }, input_altering = true,
	},
	{
		path = "llm.enabled", id = "enabled", section = "llm", default = false, type = "boolean", description_key = "menu.llm.enabled", platforms = { "ahk", "hs", "linux" }, recommended = false, input_altering = true,
	},
	{
		path = "llm.agent_system1", id = "agent_system1", section = "llm", default = "", type = "string", description_key = "menu.agent.system1_desc", platforms = { "ahk", "hs", "linux" }, recommended = "", input_altering = false,
	},
	{
		path = "llm.agent_system2", id = "agent_system2", section = "llm", default = "", type = "string", description_key = "menu.agent.system2_desc", platforms = { "ahk", "hs", "linux" }, recommended = "", input_altering = false,
	},
	{
		path = "llm.agent_mode", id = "agent_mode", section = "llm", default = "off", type = "enum", description_key = "menu.agent.mode_title", platforms = { "ahk", "hs", "linux" }, recommended = "off", input_altering = false, enum_values = { "off", "action", "auto" },
	},
	{
		path = "llm.agent_disabled_apps", id = "agent_disabled_apps", section = "llm", default = {  }, type = "array", description_key = "menu.agent.disabled_apps", platforms = { "ahk", "hs", "linux" }, recommended = {  }, input_altering = false,
	},
	{
		path = "llm.display.pred_indent", id = "pred_indent", section = "llm.display", default = 0, type = "number", description_key = "menu.llm.display.pred_indent", platforms = { "ahk", "hs", "linux" }, recommended = 0, input_altering = false, choice_values = { -7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7 },
	},
	{
		path = "llm.display.show_info_bar", id = "show_info_bar", section = "llm.display", default = true, type = "boolean", description_key = "menu.llm.display.show_info_bar", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = false,
	},
	{
		path = "llm.display.streaming", id = "streaming", section = "llm.display", default = true, type = "boolean", description_key = "menu.llm.display.streaming", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = false,
	},
	{
		path = "llm.display.streaming_multi", id = "streaming_multi", section = "llm.display", default = true, type = "boolean", description_key = "menu.llm.display.streaming_multi", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = false,
	},
	{
		path = "llm.generation.context_length", id = "context_length", section = "llm.generation", default = 500, type = "number", description_key = "menu.llm.generation.context_length", platforms = { "ahk", "hs", "linux" }, recommended = 500, input_altering = false,
	},
	{
		path = "llm.generation.min_words", id = "min_words", section = "llm.generation", default = 3, type = "number", description_key = "menu.llm.generation.min_words", platforms = { "ahk", "hs", "linux" }, recommended = 3, input_altering = false,
	},
	{
		path = "llm.generation.max_words", id = "max_words", section = "llm.generation", default = 15, type = "number", description_key = "menu.llm.generation.max_words", platforms = { "ahk", "hs", "linux" }, recommended = 15, input_altering = false,
	},
	{
		path = "llm.generation.temperature", id = "temperature", section = "llm.generation", default = 0.1, type = "number", description_key = "menu.llm.generation.temperature", platforms = { "ahk", "hs", "linux" }, recommended = 0.1, input_altering = false,
	},
	{
		path = "llm.generation.auto_raise_temp", id = "auto_raise_temp", section = "llm.generation", default = true, type = "boolean", description_key = "menu.llm.generation.auto_raise_temp", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = false,
	},
	{
		path = "llm.generation.reset_on_nav", id = "reset_on_nav", section = "llm.generation", default = true, type = "boolean", description_key = "menu.llm.generation.reset_on_nav", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = false,
	},
	{
		path = "llm.generation.sequential_mode", id = "sequential_mode", section = "llm.generation", default = false, type = "boolean", description_key = "menu.llm.generation.sequential_mode", platforms = { "ahk", "hs", "linux" }, recommended = false, input_altering = false,
	},
	{
		path = "llm.models.user_models", id = "user_models", section = "llm.models", default = {  }, type = "array", description_key = "menu.llm.title", platforms = { "hs" }, recommended = {  }, input_altering = false,
	},
	{
		path = "llm.models.selected", id = "selected", section = "llm.models", default = "mlx", type = "string", description_key = "menu.llm.models.selected", platforms = { "ahk", "hs", "linux" }, recommended = "mlx", input_altering = false,
	},
	{
		path = "llm.models.ollama", id = "ollama", section = "llm.models", default = "gemma-4-E2B-it", type = "string", description_key = "menu.llm.models.ollama", platforms = { "ahk", "hs", "linux" }, recommended = "gemma-4-E2B-it", input_altering = false,
	},
	{
		path = "llm.models.mlx", id = "mlx", section = "llm.models", default = "Qwen3.5-2B", type = "string", description_key = "menu.llm.models.mlx", platforms = { "hs" }, recommended = "Qwen3.5-2B", input_altering = false,
	},
	{
		path = "llm.profiles.user_profiles", id = "user_profiles", section = "llm.profiles", default = {  }, type = "array", description_key = "menu.profiles.header_custom_profiles", platforms = { "hs" }, recommended = {  }, input_altering = false,
	},
	{
		path = "llm.profiles.active", id = "active", section = "llm.profiles", default = "basic", type = "string", description_key = "menu.llm.profiles.active", platforms = { "ahk", "hs", "linux" }, recommended = "basic", input_altering = false,
	},
	{
		path = "llm.profiles.num_predictions", id = "num_predictions", section = "llm.profiles", default = 3, type = "number", description_key = "menu.llm.profiles.num_predictions", platforms = { "ahk", "hs", "linux" }, recommended = 3, input_altering = false,
	},
	{
		path = "llm.trigger.disabled_apps", id = "disabled_apps", section = "llm.trigger", default = {  }, type = "array", description_key = "menu.llm.title", platforms = { "hs" }, recommended = {  }, input_altering = false,
	},
	{
		path = "llm.trigger.debounce_ms", id = "debounce_ms", section = "llm.trigger", default = 200, type = "number", description_key = "menu.llm.trigger.debounce_ms", platforms = { "ahk", "hs", "linux" }, recommended = 200, input_altering = false,
	},
	{
		path = "llm.trigger.instant_on_word_end", id = "instant_on_word_end", section = "llm.trigger", default = true, type = "boolean", description_key = "menu.llm.trigger.instant_on_word_end", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = false,
	},
	{
		path = "llm.trigger.after_hotstring", id = "after_hotstring", section = "llm.trigger", default = true, type = "boolean", description_key = "menu.llm.trigger.after_hotstring", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = false,
	},
	{
		path = "llm.trigger.secure_filter_enabled", id = "secure_filter_enabled", section = "llm.trigger", default = true, type = "boolean", description_key = "menu.llm.trigger.secure_filter_enabled", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = false,
	},
	{
		path = "llm.trigger.url_bar_filter_enabled", id = "url_bar_filter_enabled", section = "llm.trigger", default = false, type = "boolean", description_key = "menu.llm.trigger.url_bar_filter_enabled", platforms = { "ahk", "hs", "linux" }, recommended = false, input_altering = false,
	},
	{
		path = "llm.navigation.nav_modifiers", id = "nav_modifiers", section = "llm.navigation", default = {  }, type = "array", description_key = "menu.llm.nav_modifiers_prompt", platforms = { "hs", "linux" }, recommended = {  }, input_altering = false,
	},
	{
		path = "llm.navigation.val_modifiers", id = "val_modifiers", section = "llm.navigation", default = {  }, type = "array", description_key = "menu.llm.navigation.val_modifiers", platforms = { "ahk", "hs", "linux" }, recommended = {  }, input_altering = false,
	},
	{
		path = "llm.navigation.arrow_nav_enabled", id = "arrow_nav_enabled", section = "llm.navigation", default = false, type = "boolean", description_key = "menu.llm.navigation.arrow_nav_enabled", platforms = { "hs" }, recommended = false, input_altering = false,
	},
	{
		path = "metrics.enabled", id = "enabled", section = "metrics", default = false, type = "boolean", description_key = "menu.metrics.enabled", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = true,
	},
	{
		path = "metrics.private_filter_enabled", id = "private_filter_enabled", section = "metrics", default = true, type = "boolean", description_key = "menu.metrics.private_filter_enabled", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = false,
	},
	{
		path = "metrics.secure_filter_enabled", id = "secure_filter_enabled", section = "metrics", default = true, type = "boolean", description_key = "menu.metrics.secure_filter_enabled", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = false,
	},
	{
		path = "metrics.system_auth_filter_enabled", id = "system_auth_filter_enabled", section = "metrics", default = true, type = "boolean", description_key = "menu.metrics.system_auth_filter_enabled", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = false,
	},
	{
		path = "metrics.encrypt", id = "encrypt", section = "metrics", default = false, type = "boolean", description_key = "menu.metrics.encrypt_toggle", platforms = { "ahk", "hs", "linux" }, recommended = false, input_altering = false,
	},
	{
		path = "shortcuts.enabled", id = "enabled", section = "shortcuts", default = false, type = "boolean", description_key = "menu.shortcuts.enabled", platforms = { "hs", "linux" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.chatgpt_url", id = "chatgpt_url", section = "shortcuts", default = "https://chat.openai.com", type = "string", description_key = "menu.shortcuts.chatgpt_url", platforms = { "ahk", "hs", "linux" }, recommended = "https://chat.openai.com", input_altering = false,
	},
	{
		path = "shortcuts.script_control.chords_enabled", id = "chords_enabled", section = "shortcuts.script_control", default = true, type = "boolean", description_key = "menu.shortcuts.script_shortcuts_enable", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = false,
	},
	{
		path = "shortcuts.script_control.script_altgr_backspace", id = "script_altgr_backspace", section = "shortcuts.script_control", default = "script_reload", type = "action", description_key = "menu.shortcuts.script_control.script_altgr_backspace", platforms = { "ahk", "hs", "linux" }, recommended = "script_reload", input_altering = true, cleared = "none",
	},
	{
		path = "shortcuts.script_control.script_altgr_delete", id = "script_altgr_delete", section = "shortcuts.script_control", default = "open_personal_shortcuts", type = "action", description_key = "menu.shortcuts.script_control.script_altgr_delete", platforms = { "ahk", "hs", "linux" }, recommended = "open_personal_shortcuts", input_altering = true, cleared = "none",
	},
	{
		path = "shortcuts.script_control.script_altgr_enter", id = "script_altgr_enter", section = "shortcuts.script_control", default = "script_pause_toggle", type = "action", description_key = "menu.shortcuts.script_control.script_altgr_enter", platforms = { "ahk", "hs", "linux" }, recommended = "script_pause_toggle", input_altering = true, cleared = "none",
	},
	{
		path = "shortcuts.script_control.script_altgr_escape", id = "script_altgr_escape", section = "shortcuts.script_control", default = "script_quit", type = "action", description_key = "menu.shortcuts.script_control.script_altgr_escape", platforms = { "ahk", "hs", "linux" }, recommended = "script_quit", input_altering = true, cleared = "none",
	},
	{
		path = "shortcuts.keyboard.magic_editor", id = "magic_editor", section = "shortcuts.keyboard", default = "open_hotstrings_editor", type = "action", description_key = "menu.shortcuts.keyboard.magic_editor", platforms = { "ahk", "hs", "linux" }, recommended = "open_hotstrings_editor", input_altering = true, cleared = "none",
	},
	{
		path = "shortcuts.keyboard.hs_ctrl_space", id = "hs_ctrl_space", section = "shortcuts.keyboard", default = "none", type = "action", description_key = "menu.shortcuts.keyboard.hs_ctrl_space", platforms = { "hs" }, recommended = "llm_generate_prediction", input_altering = true,
	},
	{
		path = "shortcuts.tap_keys.number_row_left", id = "number_row_left", section = "shortcuts.tap_keys", default = "none", type = "action", description_key = "menu.shortcuts.tap_keys.number_row_left", platforms = { "ahk", "hs", "linux" }, recommended = "screenshot_fullscreen_save", input_altering = true,
	},
	{
		path = "shortcuts.tap_keys.number_row_right_1", id = "number_row_right_1", section = "shortcuts.tap_keys", default = "none", type = "action", description_key = "menu.shortcuts.tap_keys.number_row_right_1", platforms = { "ahk", "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "shortcuts.tap_keys.number_row_right_2", id = "number_row_right_2", section = "shortcuts.tap_keys", default = "none", type = "action", description_key = "menu.shortcuts.tap_keys.number_row_right_2", platforms = { "ahk", "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.enabled", id = "enabled", section = "gestures", default = false, type = "boolean", description_key = "menu.gestures.enabled", platforms = { "ahk", "hs", "linux" }, recommended = true, input_altering = true,
	},
	{
		path = "gestures.swipe_3_down", id = "swipe_3_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_down", platforms = { "ahk", "hs", "linux" }, recommended = "tab_next", input_altering = true,
	},
	{
		path = "gestures.swipe_3_left", id = "swipe_3_left", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_left", platforms = { "ahk", "hs", "linux" }, recommended = "sel_word_prev", input_altering = true,
	},
	{
		path = "gestures.swipe_3_right", id = "swipe_3_right", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_right", platforms = { "ahk", "hs", "linux" }, recommended = "sel_word_next", input_altering = true,
	},
	{
		path = "gestures.swipe_3_up", id = "swipe_3_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_up", platforms = { "ahk", "hs", "linux" }, recommended = "tab_prev", input_altering = true,
	},
	{
		path = "gestures.swipe_4_down", id = "swipe_4_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_down", platforms = { "ahk", "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_4_left", id = "swipe_4_left", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_left", platforms = { "ahk", "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_4_right", id = "swipe_4_right", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_right", platforms = { "ahk", "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_4_up", id = "swipe_4_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_up", platforms = { "ahk", "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.tap_3", id = "tap_3", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.tap_3", platforms = { "ahk", "hs", "linux" }, recommended = "left_click_toggle", input_altering = true,
	},
	{
		path = "gestures.tap_4", id = "tap_4", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.tap_4", platforms = { "ahk", "hs", "linux" }, recommended = "win_app_next", input_altering = true,
	},
	{
		path = "gestures.swipe_2_left", id = "swipe_2_left", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_left", platforms = { "hs", "linux" }, recommended = "arrow_up", input_altering = true,
	},
	{
		path = "gestures.swipe_5_up", id = "swipe_5_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_up", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_5_down", id = "swipe_5_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_down", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_5_left", id = "swipe_5_left", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_left", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_5_right", id = "swipe_5_right", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_right", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_2_right", id = "swipe_2_right", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_right", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_2_up", id = "swipe_2_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_up", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_2_down", id = "swipe_2_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_down", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_2_left_down", id = "swipe_2_left_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_left_down", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_2_left_up", id = "swipe_2_left_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_left_up", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_2_right_down", id = "swipe_2_right_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_right_down", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_2_right_up", id = "swipe_2_right_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_right_up", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_2_diag", id = "swipe_2_diag", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_diag", platforms = { "hs" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_3_left_down", id = "swipe_3_left_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_left_down", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_3_left_up", id = "swipe_3_left_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_left_up", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_3_right_down", id = "swipe_3_right_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_right_down", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_3_right_up", id = "swipe_3_right_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_right_up", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_3_diag", id = "swipe_3_diag", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_diag", platforms = { "hs" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_3_horiz", id = "swipe_3_horiz", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_horiz", platforms = { "hs", "linux" }, recommended = "words", input_altering = true,
	},
	{
		path = "gestures.swipe_4_left_down", id = "swipe_4_left_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_left_down", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_4_left_up", id = "swipe_4_left_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_left_up", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_4_right_down", id = "swipe_4_right_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_right_down", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_4_right_up", id = "swipe_4_right_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_right_up", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_4_diag", id = "swipe_4_diag", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_diag", platforms = { "hs" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_4_horiz", id = "swipe_4_horiz", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_horiz", platforms = { "hs", "linux" }, recommended = "spaces", input_altering = true,
	},
	{
		path = "gestures.swipe_5_left_down", id = "swipe_5_left_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_left_down", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_5_left_up", id = "swipe_5_left_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_left_up", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_5_right_down", id = "swipe_5_right_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_right_down", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_5_right_up", id = "swipe_5_right_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_right_up", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_5_diag", id = "swipe_5_diag", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_diag", platforms = { "hs" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.swipe_5_horiz", id = "swipe_5_horiz", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_horiz", platforms = { "hs", "linux" }, recommended = "windows", input_altering = true,
	},
	{
		path = "gestures.tap_2", id = "tap_2", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.tap_2", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.tap_5", id = "tap_5", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.tap_5", platforms = { "hs", "linux" }, recommended = "none", input_altering = true,
	},
	{
		path = "gestures.modes.swipe_2_left", id = "swipe_2_left", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_2_left", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_2_right", id = "swipe_2_right", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_2_right", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_2_up", id = "swipe_2_up", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_2_up", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_2_down", id = "swipe_2_down", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_2_down", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_2_left_down", id = "swipe_2_left_down", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_2_left_down", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_2_left_up", id = "swipe_2_left_up", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_2_left_up", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_2_right_down", id = "swipe_2_right_down", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_2_right_down", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_2_right_up", id = "swipe_2_right_up", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_2_right_up", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_3_left", id = "swipe_3_left", section = "gestures.modes", default = "incremental", type = "enum", description_key = "menu.gestures.modes.swipe_3_left", platforms = { "hs" }, recommended = "incremental", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_3_right", id = "swipe_3_right", section = "gestures.modes", default = "incremental", type = "enum", description_key = "menu.gestures.modes.swipe_3_right", platforms = { "hs" }, recommended = "incremental", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_3_up", id = "swipe_3_up", section = "gestures.modes", default = "incremental", type = "enum", description_key = "menu.gestures.modes.swipe_3_up", platforms = { "hs" }, recommended = "incremental", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_3_down", id = "swipe_3_down", section = "gestures.modes", default = "incremental", type = "enum", description_key = "menu.gestures.modes.swipe_3_down", platforms = { "hs" }, recommended = "incremental", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_3_left_down", id = "swipe_3_left_down", section = "gestures.modes", default = "incremental", type = "enum", description_key = "menu.gestures.modes.swipe_3_left_down", platforms = { "hs" }, recommended = "incremental", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_3_left_up", id = "swipe_3_left_up", section = "gestures.modes", default = "incremental", type = "enum", description_key = "menu.gestures.modes.swipe_3_left_up", platforms = { "hs" }, recommended = "incremental", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_3_right_down", id = "swipe_3_right_down", section = "gestures.modes", default = "incremental", type = "enum", description_key = "menu.gestures.modes.swipe_3_right_down", platforms = { "hs" }, recommended = "incremental", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_3_right_up", id = "swipe_3_right_up", section = "gestures.modes", default = "incremental", type = "enum", description_key = "menu.gestures.modes.swipe_3_right_up", platforms = { "hs" }, recommended = "incremental", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_4_left", id = "swipe_4_left", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_4_left", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_4_right", id = "swipe_4_right", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_4_right", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_4_up", id = "swipe_4_up", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_4_up", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_4_down", id = "swipe_4_down", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_4_down", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_4_left_down", id = "swipe_4_left_down", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_4_left_down", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_4_left_up", id = "swipe_4_left_up", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_4_left_up", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_4_right_down", id = "swipe_4_right_down", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_4_right_down", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_4_right_up", id = "swipe_4_right_up", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_4_right_up", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_5_left", id = "swipe_5_left", section = "gestures.modes", default = "incremental", type = "enum", description_key = "menu.gestures.modes.swipe_5_left", platforms = { "hs" }, recommended = "incremental", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_5_right", id = "swipe_5_right", section = "gestures.modes", default = "incremental", type = "enum", description_key = "menu.gestures.modes.swipe_5_right", platforms = { "hs" }, recommended = "incremental", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_5_up", id = "swipe_5_up", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_5_up", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_5_down", id = "swipe_5_down", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes.swipe_5_down", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_5_left_down", id = "swipe_5_left_down", section = "gestures.modes", default = "incremental", type = "enum", description_key = "menu.gestures.modes.swipe_5_left_down", platforms = { "hs" }, recommended = "incremental", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_5_left_up", id = "swipe_5_left_up", section = "gestures.modes", default = "incremental", type = "enum", description_key = "menu.gestures.modes.swipe_5_left_up", platforms = { "hs" }, recommended = "incremental", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_5_right_down", id = "swipe_5_right_down", section = "gestures.modes", default = "incremental", type = "enum", description_key = "menu.gestures.modes.swipe_5_right_down", platforms = { "hs" }, recommended = "incremental", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_5_right_up", id = "swipe_5_right_up", section = "gestures.modes", default = "incremental", type = "enum", description_key = "menu.gestures.modes.swipe_5_right_up", platforms = { "hs" }, recommended = "incremental", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.sensitivities.swipe_2_left", id = "swipe_2_left", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_2_left", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_2_right", id = "swipe_2_right", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_2_right", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_2_up", id = "swipe_2_up", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_2_up", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_2_down", id = "swipe_2_down", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_2_down", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_2_left_down", id = "swipe_2_left_down", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_2_left_down", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_2_left_up", id = "swipe_2_left_up", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_2_left_up", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_2_right_down", id = "swipe_2_right_down", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_2_right_down", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_2_right_up", id = "swipe_2_right_up", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_2_right_up", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_3_left", id = "swipe_3_left", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_3_left", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_3_right", id = "swipe_3_right", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_3_right", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_3_up", id = "swipe_3_up", section = "gestures.sensitivities", default = 5, type = "number", description_key = "menu.gestures.sensitivities.swipe_3_up", platforms = { "hs" }, recommended = 5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_3_down", id = "swipe_3_down", section = "gestures.sensitivities", default = 5, type = "number", description_key = "menu.gestures.sensitivities.swipe_3_down", platforms = { "hs" }, recommended = 5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_3_left_down", id = "swipe_3_left_down", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_3_left_down", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_3_left_up", id = "swipe_3_left_up", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_3_left_up", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_3_right_down", id = "swipe_3_right_down", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_3_right_down", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_3_right_up", id = "swipe_3_right_up", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_3_right_up", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_4_left", id = "swipe_4_left", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_4_left", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_4_right", id = "swipe_4_right", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_4_right", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_4_up", id = "swipe_4_up", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_4_up", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_4_down", id = "swipe_4_down", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_4_down", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_4_left_down", id = "swipe_4_left_down", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_4_left_down", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_4_left_up", id = "swipe_4_left_up", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_4_left_up", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_4_right_down", id = "swipe_4_right_down", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_4_right_down", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_4_right_up", id = "swipe_4_right_up", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_4_right_up", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_5_left", id = "swipe_5_left", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_5_left", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_5_right", id = "swipe_5_right", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_5_right", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_5_up", id = "swipe_5_up", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_5_up", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_5_down", id = "swipe_5_down", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_5_down", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_5_left_down", id = "swipe_5_left_down", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_5_left_down", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_5_left_up", id = "swipe_5_left_up", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_5_left_up", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_5_right_down", id = "swipe_5_right_down", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_5_right_down", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_5_right_up", id = "swipe_5_right_up", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities.swipe_5_right_up", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.modes.swipe_3_horiz", id = "swipe_3_horiz", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_4_horiz", id = "swipe_4_horiz", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.modes.swipe_5_horiz", id = "swipe_5_horiz", section = "gestures.modes", default = "x1", type = "enum", description_key = "menu.gestures.modes", platforms = { "hs" }, recommended = "x1", input_altering = false, enum_values = { "x1", "incremental" },
	},
	{
		path = "gestures.sensitivities.swipe_3_horiz", id = "swipe_3_horiz", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_4_horiz", id = "swipe_4_horiz", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "gestures.sensitivities.swipe_5_horiz", id = "swipe_5_horiz", section = "gestures.sensitivities", default = 3.5, type = "number", description_key = "menu.gestures.sensitivities", platforms = { "hs" }, recommended = 3.5, input_altering = false,
	},
	{
		path = "layout.direct_access_digits", id = "direct_access_digits", section = "layout", default = "native", type = "enum", description_key = "menu.layout.number_row", platforms = { "ahk", "hs", "linux" }, recommended = "native", input_altering = true, enum_values = { "native", "digits", "symbols" },
	},
	{
		path = "ui.menubar_icon", id = "menubar_icon", section = "ui", default = "v1", type = "enum", description_key = "menu.layout.menubar_icon", platforms = { "hs" }, recommended = "v1", input_altering = false, enum_values = { "v1", "v2" },
	},
	{
		path = "tap_holds.enabled", id = "enabled", section = "tap_holds", default = false, type = "boolean", description_key = "menu.tap_holds", platforms = { "hs", "linux" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.wrap_text_if_selected", id = "wrap_text_if_selected", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_wrap_text", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_a", id = "ctrl_a", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_a", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_d", id = "ctrl_d", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_d", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_e", id = "ctrl_e", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_e", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_g", id = "ctrl_g", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_g", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_h", id = "ctrl_h", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_h", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_i", id = "ctrl_i", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_i", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_m", id = "ctrl_m", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_m", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_o", id = "ctrl_o", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_o", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_p", id = "ctrl_p", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_p", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_s", id = "ctrl_s", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_s", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_t", id = "ctrl_t", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_t", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_u", id = "ctrl_u", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_u", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_w", id = "ctrl_w", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_w", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_x", id = "ctrl_x", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_x", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_capslock", id = "ctrl_capslock", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_capslock", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_l", id = "ctrl_l", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_l", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_period", id = "ctrl_period", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_period", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.ctrl_quote", id = "ctrl_quote", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_ctrl_quote", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.cmd_shift_v", id = "cmd_shift_v", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_cmd_shift_v", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "shortcuts.keys.cmd_star", id = "cmd_star", section = "shortcuts.keys", default = false, type = "boolean", description_key = "shortcuts.label_cmd_star", platforms = { "hs" }, recommended = true, input_altering = true,
	},
	{
		path = "metrics.disabled_apps", id = "disabled_apps", section = "metrics", default = {  }, type = "array", description_key = "menu.metrics.metrics_disabled_apps", platforms = { "hs" }, recommended = {  }, input_altering = false,
	},
	{
		path = "metrics.menubar_wpm", id = "menubar_wpm", section = "metrics", default = false, type = "boolean", description_key = "menu.metrics.show_wpm_menubar", platforms = { "hs" }, recommended = false, input_altering = false,
	},
	{
		path = "metrics.menubar_colors", id = "menubar_colors", section = "metrics", default = true, type = "boolean", description_key = "menu.metrics.colors_by_source", platforms = { "hs" }, recommended = true, input_altering = false,
	},
	{
		path = "metrics.float_wpm", id = "float_wpm", section = "metrics", default = true, type = "boolean", description_key = "menu.metrics.wpm_widget_visible", platforms = { "hs" }, recommended = true, input_altering = false,
	},
	{
		path = "metrics.float_graph", id = "float_graph", section = "metrics", default = true, type = "boolean", description_key = "menu.metrics.wpm_widget_graph", platforms = { "hs" }, recommended = true, input_altering = false,
	},
	{
		path = "metrics.float_colors", id = "float_colors", section = "metrics", default = true, type = "boolean", description_key = "menu.metrics.wpm_widget_colors", platforms = { "hs" }, recommended = true, input_altering = false,
	},
	{
		path = "layout.pause_switch_enabled", id = "pause_switch_enabled", section = "layout", default = false, type = "boolean", description_key = "menu.layout", platforms = { "hs" }, recommended = false, input_altering = true,
	},
	{
		path = "layout.on_pause", id = "on_pause", section = "layout", default = false, type = "boolean", description_key = "menu.layout", platforms = { "hs" }, recommended = false, input_altering = true,
	},
	{
		path = "layout.on_resume", id = "on_resume", section = "layout", default = false, type = "boolean", description_key = "menu.layout", platforms = { "hs" }, recommended = false, input_altering = true,
	},
}

M.unavailable = {
	{
		path = "script.alt_gr_is_kana_remap", section = "script", reason_key = "platform_reason.alt_gr_is_kana_remap", platforms = { "ahk" },
	},
	{
		path = "hotstrings.magic_key_source_char", section = "hotstrings", reason_key = "platform_reason.magic_key_detection_is_windows", platforms = { "ahk" },
	},
	{
		path = "llm.onboarding_seen", section = "llm", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "llm.app_profile_overrides", section = "llm", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "llm.user_profiles", section = "llm", reason_key = "", platforms = { "ahk", "linux" },
	},
	{
		path = "llm.profiles.auto_profile_for_model", section = "llm.profiles", reason_key = "", platforms = { "ahk", "linux" },
	},
	{
		path = "llm.trigger.inline_autotype", section = "llm.trigger", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "metrics.metrics_enabled", section = "metrics", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "metrics.metrics_wpm_menubar_colors", section = "metrics", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "metrics.metrics_disabled_apps", section = "metrics", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "metrics.wpm_widget_visible", section = "metrics", reason_key = "", platforms = { "ahk", "linux" },
	},
	{
		path = "metrics.wpm_widget_x", section = "metrics", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "metrics.wpm_widget_y", section = "metrics", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "metrics.wpm_widget_colors", section = "metrics", reason_key = "", platforms = { "ahk", "linux" },
	},
	{
		path = "metrics.wpm_widget_graph", section = "metrics", reason_key = "", platforms = { "ahk", "linux" },
	},
	{
		path = "metrics.wpm_menubar_visible", section = "metrics", reason_key = "", platforms = { "linux" },
	},
	{
		path = "metrics.wpm_menubar_colors", section = "metrics", reason_key = "", platforms = { "linux" },
	},
	{
		path = "shortcuts.get_hex_value", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.gpt", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.search", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.take_note", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.microsoft_bold", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.title_case", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.uppercase", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.paste_without_formatting", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.select_line", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.spotlight_mouse", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.surround_with_parentheses", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.teleport_mouse", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.wrap_text_if_selected", section = "shortcuts", reason_key = "", platforms = { "ahk", "linux" },
	},
	{
		path = "shortcuts.open_downloads", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.move", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.screen", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.win_caps_lock", section = "shortcuts", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.a_grave.enabled", section = "shortcuts.a_grave", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.a_grave.letter", section = "shortcuts.a_grave", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.e_acute.enabled", section = "shortcuts.e_acute", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.e_acute.letter", section = "shortcuts.e_acute", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.e_circ.enabled", section = "shortcuts.e_circ", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.e_circ.letter", section = "shortcuts.e_circ", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.e_grave.enabled", section = "shortcuts.e_grave", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.e_grave.letter", section = "shortcuts.e_grave", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.key_combination_taps.alt_gr_then_left_alt", section = "shortcuts.key_combination_taps", reason_key = "", platforms = { "ahk", "linux" },
	},
	{
		path = "shortcuts.key_combination_taps.alt_gr_then_caps_lock", section = "shortcuts.key_combination_taps", reason_key = "", platforms = { "ahk", "linux" },
	},
	{
		path = "shortcuts.key_combination_taps.left_alt_then_caps_lock", section = "shortcuts.key_combination_taps", reason_key = "", platforms = { "ahk", "linux" },
	},
	{
		path = "shortcuts.personal.laptop_broken_key", section = "shortcuts.personal", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.personal.mouse_drag_window", section = "shortcuts.personal", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.personal.mouse_tab_switching", section = "shortcuts.personal", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.personal.professional_environment", section = "shortcuts.personal", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.personal.programmable_keyboard", section = "shortcuts.personal", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.ctrl_b", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.ctrl_shift_v", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.win_a", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.win_d", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.win_g", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.win_h", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.win_m", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.win_n", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.win_o", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.win_s", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.win_sc029", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.win_t", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.win_u", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.win_w", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.win_x", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.win_space", section = "shortcuts.keyboard", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.keyboard.ctrl_g", section = "shortcuts.keyboard", reason_key = "", platforms = { "linux" },
	},
	{
		path = "shortcuts.keyboard.super_space", section = "shortcuts.keyboard", reason_key = "", platforms = { "linux" },
	},
	{
		path = "layout.ergopti_base", section = "layout", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "layout.ergopti_alt_gr", section = "layout", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "layout.ergopti_plus", section = "layout", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "layout.ctrl_magic_save", section = "layout", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "layout.emulated_layout", section = "layout", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "category_enabled.hotstrings", section = "category_enabled", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "category_enabled.layout", section = "category_enabled", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "category_enabled.shortcuts", section = "category_enabled", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "category_enabled.tap_holds", section = "category_enabled", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "category_enabled.key_combinations", section = "category_enabled", reason_key = "", platforms = { "ahk", "linux" },
	},
	{
		path = "category_enabled.autocorrection", section = "category_enabled", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "category_enabled.distances_reduction", section = "category_enabled", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "category_enabled.sfbs_reduction", section = "category_enabled", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "category_enabled.rolls", section = "category_enabled", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "category_enabled.magic_key", section = "category_enabled", reason_key = "", platforms = { "ahk" },
	},
}

return M
