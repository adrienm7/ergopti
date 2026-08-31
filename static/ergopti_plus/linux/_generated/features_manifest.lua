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

M.section_order = { "script", "hotstrings", "llm", "metrics", "shortcuts", "gestures", "layout", "category_enabled" }

M.sections = {
	["script"] = { description_key = "menu.script", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings"] = { description_key = "menu.hotstrings", platforms = { "ahk", "hs", "linux" }, subsections = { "autocorrection", "distances_reduction", "sfbs_reduction", "rolls", "magic_key", "dynamic", "personal" } },
	["hotstrings.autocorrection"] = { description_key = "menu.hotstrings.autocorrection", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.distances_reduction"] = { description_key = "menu.hotstrings.distances_reduction", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.sfbs_reduction"] = { description_key = "menu.hotstrings.sfbs_reduction", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.rolls"] = { description_key = "menu.hotstrings.rolls", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.magic_key"] = { description_key = "menu.hotstrings.magic_key", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.dynamic"] = { description_key = "menu.hotstrings.dynamic", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.personal"] = { description_key = "menu.hotstrings.personal", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["llm"] = { description_key = "menu.llm", platforms = { "ahk", "hs", "linux" }, subsections = { "display", "generation", "models", "profiles", "trigger", "navigation" } },
	["llm.display"] = { description_key = "menu.llm.display", platforms = { "ahk", "hs" }, subsections = {  } },
	["llm.generation"] = { description_key = "menu.llm.generation", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["llm.models"] = { description_key = "menu.llm.models", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["llm.profiles"] = { description_key = "menu.llm.profiles", platforms = { "ahk", "hs" }, subsections = {  } },
	["llm.trigger"] = { description_key = "menu.llm.trigger", platforms = { "ahk", "hs" }, subsections = {  } },
	["llm.navigation"] = { description_key = "menu.llm.navigation", platforms = { "ahk", "hs" }, subsections = {  } },
	["metrics"] = { description_key = "menu.metrics", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["shortcuts"] = { description_key = "menu.shortcuts", platforms = { "ahk", "hs" }, subsections = { "alt_gr_caps_lock", "alt_gr_lalt", "keyboard", "lalt_caps_lock", "personal", "script_control" } },
	["shortcuts.alt_gr_caps_lock"] = { description_key = "menu.shortcuts.alt_gr_caps_lock", platforms = { "ahk" }, subsections = {  } },
	["shortcuts.alt_gr_lalt"] = { description_key = "menu.shortcuts.alt_gr_lalt", platforms = { "ahk" }, subsections = {  } },
	["shortcuts.keyboard"] = { description_key = "menu.shortcuts.keyboard", platforms = { "ahk" }, subsections = {  } },
	["shortcuts.lalt_caps_lock"] = { description_key = "menu.shortcuts.lalt_caps_lock", platforms = { "ahk" }, subsections = {  } },
	["shortcuts.personal"] = { description_key = "menu.shortcuts.personal", platforms = { "ahk" }, subsections = {  } },
	["shortcuts.script_control"] = { description_key = "menu.shortcuts.script_control", platforms = { "ahk" }, subsections = {  } },
	["category_enabled"] = { description_key = "menu.category_enabled", platforms = { "ahk" }, subsections = {  } },
	["layout"] = { description_key = "menu.layout", platforms = { "ahk" }, subsections = {  } },
	["gestures"] = { description_key = "menu.gestures", platforms = { "ahk", "hs", "linux" }, subsections = { "modes", "sensitivities" } },
	["gestures.modes"] = { description_key = "menu.gestures.modes", platforms = { "hs" }, subsections = {  } },
	["gestures.sensitivities"] = { description_key = "menu.gestures.sensitivities", platforms = { "hs" }, subsections = {  } },
}

M.features = {
	{
		path = "script.locale", id = "locale", section = "script", default = "fr", type = "string", description_key = "menu.script.locale", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "script.log_level", id = "log_level", section = "script", default = "INFO", type = "enum", description_key = "menu.script.log_level", platforms = { "ahk", "hs", "linux" }, enum_values = { "DEBUG", "TRACE", "DONE", "INFO", "START", "SUCCESS", "WARNING", "ERROR" },
	},
	{
		path = "hotstrings.trigger_char", id = "trigger_char", section = "hotstrings", default = "★", type = "string", description_key = "menu.hotstrings.trigger_char", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.repeat_key_enabled", id = "repeat_key_enabled", section = "hotstrings", default = true, type = "boolean", description_key = "menu.hotstrings.repeat_key_enabled", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.preview_ai_enabled", id = "preview_ai_enabled", section = "hotstrings", default = true, type = "boolean", description_key = "menu.hotstrings.preview_ai_enabled", platforms = { "hs", "linux" },
	},
	{
		path = "hotstrings.preview_autocorrect_enabled", id = "preview_autocorrect_enabled", section = "hotstrings", default = true, type = "boolean", description_key = "menu.hotstrings.preview_autocorrect_enabled", platforms = { "hs", "linux" },
	},
	{
		path = "hotstrings.preview_colored_tooltips", id = "preview_colored_tooltips", section = "hotstrings", default = true, type = "boolean", description_key = "menu.hotstrings.preview_colored_tooltips", platforms = { "hs", "linux" },
	},
	{
		path = "hotstrings.preview_star_enabled", id = "preview_star_enabled", section = "hotstrings", default = true, type = "boolean", description_key = "menu.hotstrings.preview_star_enabled", platforms = { "hs", "linux" },
	},
	{
		path = "hotstrings.autocorrection.accents", id = "accents", section = "hotstrings.autocorrection", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.accents", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.autocorrection.caps", id = "caps", section = "hotstrings.autocorrection", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.caps", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.autocorrection.errors", id = "errors", section = "hotstrings.autocorrection", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.errors", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.autocorrection.minus", id = "minus", section = "hotstrings.autocorrection", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.minus", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.autocorrection.minus_apostrophe", id = "minus_apostrophe", section = "hotstrings.autocorrection", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.minus_apostrophe", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.autocorrection.multiple_punctuation_marks", id = "multiple_punctuation_marks", section = "hotstrings.autocorrection", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.multiple_punctuation_marks", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.autocorrection.names", id = "names", section = "hotstrings.autocorrection", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.names", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.autocorrection.ou", id = "ou", section = "hotstrings.autocorrection", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.ou", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.autocorrection.suffixes_a_chaining", id = "suffixes_a_chaining", section = "hotstrings.autocorrection", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.suffixes_a_chaining", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.autocorrection.typographic_apostrophe", id = "typographic_apostrophe", section = "hotstrings.autocorrection", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.autocorrection.typographic_apostrophe", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.distances_reduction.qu", id = "qu", section = "hotstrings.distances_reduction", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.distances_reduction.qu", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.distances_reduction.suffixes_a", id = "suffixes_a", section = "hotstrings.distances_reduction", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.distances_reduction.suffixes_a", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.distances_reduction.comma_j", id = "comma_j", section = "hotstrings.distances_reduction", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.distances_reduction.comma_j", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.distances_reduction.comma_far_letters", id = "comma_far_letters", section = "hotstrings.distances_reduction", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.distances_reduction.comma_far_letters", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.distances_reduction.dead_key_e_circumflex", id = "dead_key_e_circumflex", section = "hotstrings.distances_reduction", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.distances_reduction.dead_key_e_circumflex", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.distances_reduction.e_circumflex_e", id = "e_circumflex_e", section = "hotstrings.distances_reduction", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.distances_reduction.e_circumflex_e", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.distances_reduction.space_around_symbols", id = "space_around_symbols", section = "hotstrings.distances_reduction", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.distances_reduction.space_around_symbols", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.sfbs_reduction.comma", id = "comma", section = "hotstrings.sfbs_reduction", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.sfbs_reduction.comma", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.sfbs_reduction.e_circ", id = "e_circ", section = "hotstrings.sfbs_reduction", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.sfbs_reduction.e_circ", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.sfbs_reduction.e_grave", id = "e_grave", section = "hotstrings.sfbs_reduction", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.sfbs_reduction.e_grave", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.sfbs_reduction.bu", id = "bu", section = "hotstrings.sfbs_reduction", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.sfbs_reduction.bu", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.sfbs_reduction.i_e_acute", id = "i_e_acute", section = "hotstrings.sfbs_reduction", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.sfbs_reduction.i_e_acute", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.hc", id = "hc", section = "hotstrings.rolls", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.hc", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.sx", id = "sx", section = "hotstrings.rolls", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.sx", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.cx", id = "cx", section = "hotstrings.rolls", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.cx", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.ct", id = "ct", section = "hotstrings.rolls", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.ct", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.ez", id = "ez", section = "hotstrings.rolls", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.ez", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.assign", id = "assign", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.assign", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.assign_arrow_equal_left", id = "assign_arrow_equal_left", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.assign_arrow_equal_left", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.assign_arrow_equal_right", id = "assign_arrow_equal_right", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.assign_arrow_equal_right", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.assign_arrow_minus_left", id = "assign_arrow_minus_left", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.assign_arrow_minus_left", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.assign_arrow_minus_right", id = "assign_arrow_minus_right", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.assign_arrow_minus_right", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.bracket_quote", id = "bracket_quote", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.bracket_quote", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.chevron_equal", id = "chevron_equal", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.chevron_equal", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.chevron_greater", id = "chevron_greater", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.chevron_greater", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.chevron_less", id = "chevron_less", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.chevron_less", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.close_chevron_tag", id = "close_chevron_tag", section = "hotstrings.rolls", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.close_chevron_tag", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.comment_close", id = "comment_close", section = "hotstrings.rolls", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.comment_close", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.comment_open", id = "comment_open", section = "hotstrings.rolls", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.comment_open", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.english_negation", id = "english_negation", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.english_negation", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.equal_string", id = "equal_string", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.equal_string", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.hashtag_close_bracket", id = "hashtag_close_bracket", section = "hotstrings.rolls", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.hashtag_close_bracket", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.hashtag_open_bracket", id = "hashtag_open_bracket", section = "hotstrings.rolls", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.hashtag_open_bracket", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.hashtag_parenthesis", id = "hashtag_parenthesis", section = "hotstrings.rolls", default = { enabled = true, time_activation_seconds = 0.5 }, type = "feature", description_key = "menu.hotstrings.rolls.hashtag_parenthesis", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.hashtag_quote", id = "hashtag_quote", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.hashtag_quote", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.left_arrow", id = "left_arrow", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.left_arrow", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.not_equal", id = "not_equal", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.not_equal", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.rolls.paren_quote", id = "paren_quote", section = "hotstrings.rolls", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.rolls.paren_quote", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.magic_key.replace", id = "replace", section = "hotstrings.magic_key", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.magic_key.replace", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.magic_key.repeat_corrections", id = "repeat_corrections", section = "hotstrings.magic_key", default = { enabled = true, time_activation_seconds = 2 }, type = "feature", description_key = "menu.hotstrings.magic_key.repeat_corrections", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.magic_key.text_expansion", id = "text_expansion", section = "hotstrings.magic_key", default = { enabled = true, time_activation_seconds = 2 }, type = "feature", description_key = "menu.hotstrings.magic_key.text_expansion", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.magic_key.text_expansion_auto", id = "text_expansion_auto", section = "hotstrings.magic_key", default = { enabled = true, time_activation_seconds = 2 }, type = "feature", description_key = "menu.hotstrings.magic_key.text_expansion_auto", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.magic_key.text_expansion_emojis", id = "text_expansion_emojis", section = "hotstrings.magic_key", default = { enabled = true, time_activation_seconds = 2 }, type = "feature", description_key = "menu.hotstrings.magic_key.text_expansion_emojis", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.magic_key.text_expansion_symbols", id = "text_expansion_symbols", section = "hotstrings.magic_key", default = { enabled = true, time_activation_seconds = 2 }, type = "feature", description_key = "menu.hotstrings.magic_key.text_expansion_symbols", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.magic_key.text_expansion_symbols_typst", id = "text_expansion_symbols_typst", section = "hotstrings.magic_key", default = { enabled = true, time_activation_seconds = 2 }, type = "feature", description_key = "menu.hotstrings.magic_key.text_expansion_symbols_typst", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.dynamic.date", id = "date", section = "hotstrings.dynamic", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.dynamic.date", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.dynamic.date_fr", id = "date_fr", section = "hotstrings.dynamic", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.dynamic.date_fr", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.dynamic.date_long_fr", id = "date_long_fr", section = "hotstrings.dynamic", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.dynamic.date_long_fr", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.dynamic.iban_prefixes", id = "iban_prefixes", section = "hotstrings.dynamic", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.dynamic.iban_prefixes", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.dynamic.phone_prefixes", id = "phone_prefixes", section = "hotstrings.dynamic", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.dynamic.phone_prefixes", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.dynamic.ssn_prefixes", id = "ssn_prefixes", section = "hotstrings.dynamic", default = { enabled = true }, type = "feature", description_key = "menu.hotstrings.dynamic.ssn_prefixes", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.dynamic.text_expansion_personal_information", id = "text_expansion_personal_information", section = "hotstrings.dynamic", default = { enabled = true, pattern_max_length = 1 }, type = "feature", description_key = "menu.hotstrings.dynamic.text_expansion_personal_information", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.personal.autocorrection", id = "autocorrection", section = "hotstrings.personal", default = { enabled = true, time_activation_seconds = 0.75 }, type = "feature", description_key = "menu.hotstrings.personal.autocorrection", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.personal.code", id = "code", section = "hotstrings.personal", default = { enabled = true, time_activation_seconds = 0.75 }, type = "feature", description_key = "menu.hotstrings.personal.code", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.personal.email_shortcuts", id = "email_shortcuts", section = "hotstrings.personal", default = { enabled = true, time_activation_seconds = 0.75 }, type = "feature", description_key = "menu.hotstrings.personal.email_shortcuts", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.personal.professional_vocabulary", id = "professional_vocabulary", section = "hotstrings.personal", default = { enabled = true, time_activation_seconds = 0.75 }, type = "feature", description_key = "menu.hotstrings.personal.professional_vocabulary", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "hotstrings.personal.test", id = "test", section = "hotstrings.personal", default = { enabled = true, time_activation_seconds = 0.75 }, type = "feature", description_key = "menu.hotstrings.personal.test", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "llm.enabled", id = "enabled", section = "llm", default = false, type = "boolean", description_key = "menu.llm.enabled", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "llm.generation.context_length", id = "context_length", section = "llm.generation", default = 500, type = "number", description_key = "menu.llm.generation.context_length", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "llm.generation.min_words", id = "min_words", section = "llm.generation", default = 3, type = "number", description_key = "menu.llm.generation.min_words", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "llm.generation.max_words", id = "max_words", section = "llm.generation", default = 15, type = "number", description_key = "menu.llm.generation.max_words", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "llm.generation.temperature", id = "temperature", section = "llm.generation", default = 0.1, type = "number", description_key = "menu.llm.generation.temperature", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "llm.generation.auto_raise_temp", id = "auto_raise_temp", section = "llm.generation", default = true, type = "boolean", description_key = "menu.llm.generation.auto_raise_temp", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "llm.generation.reset_on_nav", id = "reset_on_nav", section = "llm.generation", default = true, type = "boolean", description_key = "menu.llm.generation.reset_on_nav", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "llm.generation.sequential_mode", id = "sequential_mode", section = "llm.generation", default = false, type = "boolean", description_key = "menu.llm.generation.sequential_mode", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "llm.models.selected", id = "selected", section = "llm.models", default = "ollama", type = "string", description_key = "menu.llm.models.selected", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "llm.models.ollama", id = "ollama", section = "llm.models", default = "Qwen3.5-0.8B", type = "string", description_key = "menu.llm.models.ollama", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "metrics.enabled", id = "enabled", section = "metrics", default = true, type = "boolean", description_key = "menu.metrics.enabled", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "metrics.private_filter_enabled", id = "private_filter_enabled", section = "metrics", default = true, type = "boolean", description_key = "menu.metrics.private_filter_enabled", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "metrics.secure_filter_enabled", id = "secure_filter_enabled", section = "metrics", default = true, type = "boolean", description_key = "menu.metrics.secure_filter_enabled", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "metrics.system_auth_filter_enabled", id = "system_auth_filter_enabled", section = "metrics", default = true, type = "boolean", description_key = "menu.metrics.system_auth_filter_enabled", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "metrics.encrypt", id = "encrypt", section = "metrics", default = false, type = "boolean", description_key = "menu.metrics.encrypt_toggle", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "metrics.wpm_widget_visible", id = "wpm_widget_visible", section = "metrics", default = false, type = "boolean", description_key = "menu.metrics.wpm_widget_visible", platforms = { "ahk", "linux" },
	},
	{
		path = "metrics.wpm_widget_colors", id = "wpm_widget_colors", section = "metrics", default = true, type = "boolean", description_key = "menu.metrics.wpm_widget_colors", platforms = { "ahk", "linux" },
	},
	{
		path = "gestures.enabled", id = "enabled", section = "gestures", default = true, type = "boolean", description_key = "menu.gestures.enabled", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "gestures.swipe_3_down", id = "swipe_3_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_down", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "gestures.swipe_3_left", id = "swipe_3_left", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_left", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "gestures.swipe_3_right", id = "swipe_3_right", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_right", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "gestures.swipe_3_up", id = "swipe_3_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_up", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "gestures.swipe_4_down", id = "swipe_4_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_down", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "gestures.swipe_4_left", id = "swipe_4_left", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_left", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "gestures.swipe_4_right", id = "swipe_4_right", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_right", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "gestures.swipe_4_up", id = "swipe_4_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_up", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "gestures.tap_3", id = "tap_3", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.tap_3", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "gestures.tap_4", id = "tap_4", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.tap_4", platforms = { "ahk", "hs", "linux" },
	},
	{
		path = "gestures.swipe_5_up", id = "swipe_5_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_up", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_5_down", id = "swipe_5_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_down", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_5_left", id = "swipe_5_left", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_left", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_5_right", id = "swipe_5_right", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_right", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_2_right", id = "swipe_2_right", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_right", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_2_up", id = "swipe_2_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_up", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_2_down", id = "swipe_2_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_down", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_2_left_down", id = "swipe_2_left_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_left_down", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_2_left_up", id = "swipe_2_left_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_left_up", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_2_right_down", id = "swipe_2_right_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_right_down", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_2_right_up", id = "swipe_2_right_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_2_right_up", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_3_left_down", id = "swipe_3_left_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_left_down", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_3_left_up", id = "swipe_3_left_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_left_up", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_3_right_down", id = "swipe_3_right_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_right_down", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_3_right_up", id = "swipe_3_right_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_3_right_up", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_4_left_down", id = "swipe_4_left_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_left_down", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_4_left_up", id = "swipe_4_left_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_left_up", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_4_right_down", id = "swipe_4_right_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_right_down", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_4_right_up", id = "swipe_4_right_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_4_right_up", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_5_left_down", id = "swipe_5_left_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_left_down", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_5_left_up", id = "swipe_5_left_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_left_up", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_5_right_down", id = "swipe_5_right_down", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_right_down", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.swipe_5_right_up", id = "swipe_5_right_up", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.swipe_5_right_up", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.tap_2", id = "tap_2", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.tap_2", platforms = { "hs", "linux" },
	},
	{
		path = "gestures.tap_5", id = "tap_5", section = "gestures", default = "none", type = "action", description_key = "menu.gestures.tap_5", platforms = { "hs", "linux" },
	},
}

M.unavailable = {
	{
		path = "script.alt_gr_is_kana_remap", section = "script", reason_key = "platform_reason.alt_gr_is_kana_remap", platforms = { "ahk" },
	},
	{
		path = "hotstrings.magic_key_source_scan", section = "hotstrings", reason_key = "platform_reason.magic_key_source_is_windows", platforms = { "ahk" },
	},
	{
		path = "hotstrings.magic_key_source_char", section = "hotstrings", reason_key = "platform_reason.magic_key_source_is_windows", platforms = { "ahk" },
	},
	{
		path = "hotstrings.expansion_delay", section = "hotstrings", reason_key = "", platforms = { "hs" },
	},
	{
		path = "llm.onboarding_seen", section = "llm", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "llm.app_profile_overrides", section = "llm", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "llm.user_profiles", section = "llm", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "llm.display.pred_indent", section = "llm.display", reason_key = "", platforms = { "ahk", "hs" },
	},
	{
		path = "llm.display.show_info_bar", section = "llm.display", reason_key = "", platforms = { "ahk", "hs" },
	},
	{
		path = "llm.display.streaming", section = "llm.display", reason_key = "", platforms = { "ahk", "hs" },
	},
	{
		path = "llm.display.streaming_multi", section = "llm.display", reason_key = "", platforms = { "ahk", "hs" },
	},
	{
		path = "llm.models.mlx", section = "llm.models", reason_key = "platform_reason.llm_mlx_is_apple_silicon", platforms = { "hs" },
	},
	{
		path = "llm.profiles.active", section = "llm.profiles", reason_key = "", platforms = { "ahk", "hs" },
	},
	{
		path = "llm.profiles.num_predictions", section = "llm.profiles", reason_key = "", platforms = { "ahk", "hs" },
	},
	{
		path = "llm.profiles.auto_profile_for_model", section = "llm.profiles", reason_key = "", platforms = { "ahk", "hs" },
	},
	{
		path = "llm.trigger.debounce_ms", section = "llm.trigger", reason_key = "", platforms = { "ahk", "hs" },
	},
	{
		path = "llm.trigger.instant_on_word_end", section = "llm.trigger", reason_key = "", platforms = { "ahk", "hs" },
	},
	{
		path = "llm.trigger.after_hotstring", section = "llm.trigger", reason_key = "", platforms = { "ahk", "hs" },
	},
	{
		path = "llm.trigger.inline_autotype", section = "llm.trigger", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "llm.trigger.secure_filter_enabled", section = "llm.trigger", reason_key = "", platforms = { "ahk", "hs" },
	},
	{
		path = "llm.trigger.url_bar_filter_enabled", section = "llm.trigger", reason_key = "", platforms = { "ahk", "hs" },
	},
	{
		path = "llm.trigger.shortcut", section = "llm.trigger", reason_key = "", platforms = { "hs" },
	},
	{
		path = "llm.navigation.val_modifiers", section = "llm.navigation", reason_key = "", platforms = { "ahk", "hs" },
	},
	{
		path = "llm.navigation.arrow_nav_enabled", section = "llm.navigation", reason_key = "", platforms = { "hs" },
	},
	{
		path = "metrics.metrics_enabled", section = "metrics", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "metrics.metrics_shortcut_typing", section = "metrics", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "metrics.metrics_shortcut_apps", section = "metrics", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "metrics.metrics_wpm_menubar_colors", section = "metrics", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "metrics.metrics_disabled_apps", section = "metrics", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "metrics.wpm_widget_x", section = "metrics", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "metrics.wpm_widget_y", section = "metrics", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "metrics.wpm_widget_graph", section = "metrics", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.enabled", section = "shortcuts", reason_key = "", platforms = { "hs" },
	},
	{
		path = "shortcuts.chatgpt_url", section = "shortcuts", reason_key = "", platforms = { "ahk", "hs" },
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
		path = "shortcuts.wrap_text_if_selected", section = "shortcuts", reason_key = "", platforms = { "ahk" },
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
		path = "shortcuts.screen_instant", section = "shortcuts", reason_key = "", platforms = { "ahk" },
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
		path = "shortcuts.alt_gr_caps_lock.backspace", section = "shortcuts.alt_gr_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_caps_lock.caps_lock", section = "shortcuts.alt_gr_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_caps_lock.caps_word", section = "shortcuts.alt_gr_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_caps_lock.ctrl_backspace", section = "shortcuts.alt_gr_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_caps_lock.ctrl_delete", section = "shortcuts.alt_gr_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_caps_lock.delete", section = "shortcuts.alt_gr_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_caps_lock.enter", section = "shortcuts.alt_gr_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_caps_lock.escape", section = "shortcuts.alt_gr_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_caps_lock.one_shot_shift", section = "shortcuts.alt_gr_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_caps_lock.tab", section = "shortcuts.alt_gr_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_lalt.backspace", section = "shortcuts.alt_gr_lalt", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_lalt.caps_lock", section = "shortcuts.alt_gr_lalt", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_lalt.caps_word", section = "shortcuts.alt_gr_lalt", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_lalt.ctrl_backspace", section = "shortcuts.alt_gr_lalt", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_lalt.ctrl_delete", section = "shortcuts.alt_gr_lalt", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_lalt.delete", section = "shortcuts.alt_gr_lalt", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_lalt.enter", section = "shortcuts.alt_gr_lalt", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_lalt.escape", section = "shortcuts.alt_gr_lalt", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_lalt.one_shot_shift", section = "shortcuts.alt_gr_lalt", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.alt_gr_lalt.tab", section = "shortcuts.alt_gr_lalt", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.lalt_caps_lock.backspace", section = "shortcuts.lalt_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.lalt_caps_lock.caps_lock", section = "shortcuts.lalt_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.lalt_caps_lock.caps_word", section = "shortcuts.lalt_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.lalt_caps_lock.ctrl_backspace", section = "shortcuts.lalt_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.lalt_caps_lock.ctrl_delete", section = "shortcuts.lalt_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.lalt_caps_lock.delete", section = "shortcuts.lalt_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.lalt_caps_lock.enter", section = "shortcuts.lalt_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.lalt_caps_lock.escape", section = "shortcuts.lalt_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.lalt_caps_lock.one_shot_shift", section = "shortcuts.lalt_caps_lock", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.lalt_caps_lock.tab", section = "shortcuts.lalt_caps_lock", reason_key = "", platforms = { "ahk" },
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
		path = "shortcuts.script_control.script_altgr_backspace", section = "shortcuts.script_control", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.script_control.script_altgr_delete", section = "shortcuts.script_control", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.script_control.script_altgr_enter", section = "shortcuts.script_control", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "shortcuts.script_control.script_altgr_escape", section = "shortcuts.script_control", reason_key = "", platforms = { "ahk" },
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
		path = "gestures.space_wrap", section = "gestures", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.swipe_2_left", section = "gestures", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.swipe_2_diag", section = "gestures", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.swipe_3_diag", section = "gestures", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.swipe_3_horiz", section = "gestures", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.swipe_4_diag", section = "gestures", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.swipe_4_horiz", section = "gestures", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.swipe_5_diag", section = "gestures", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.swipe_5_horiz", section = "gestures", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_2_left", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_2_right", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_2_up", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_2_down", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_2_left_down", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_2_left_up", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_2_right_down", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_2_right_up", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_3_left", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_3_right", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_3_up", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_3_down", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_3_left_down", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_3_left_up", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_3_right_down", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_3_right_up", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_4_left", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_4_right", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_4_up", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_4_down", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_4_left_down", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_4_left_up", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_4_right_down", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_4_right_up", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_5_left", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_5_right", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_5_up", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_5_down", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_5_left_down", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_5_left_up", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_5_right_down", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.modes.swipe_5_right_up", section = "gestures.modes", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_2_left", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_2_right", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_2_up", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_2_down", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_2_left_down", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_2_left_up", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_2_right_down", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_2_right_up", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_3_left", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_3_right", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_3_up", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_3_down", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_3_left_down", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_3_left_up", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_3_right_down", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_3_right_up", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_4_left", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_4_right", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_4_up", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_4_down", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_4_left_down", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_4_left_up", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_4_right_down", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_4_right_up", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_5_left", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_5_right", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_5_up", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_5_down", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_5_left_down", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_5_left_up", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_5_right_down", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "gestures.sensitivities.swipe_5_right_up", section = "gestures.sensitivities", reason_key = "", platforms = { "hs" },
	},
	{
		path = "layout.ergopti_base", section = "layout", reason_key = "", platforms = { "ahk" },
	},
	{
		path = "layout.direct_access_digits", section = "layout", reason_key = "", platforms = { "ahk" },
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
}

return M
