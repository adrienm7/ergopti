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
	["script"] = { description_key = "menu.script", platforms = { "ahk", "hs" }, subsections = {  } },
	["hotstrings"] = { description_key = "menu.hotstrings", platforms = { "ahk", "hs", "linux" }, subsections = { "autocorrection", "distances_reduction", "sfbs_reduction", "rolls", "magic_key", "dynamic", "personal" } },
	["hotstrings.autocorrection"] = { description_key = "menu.hotstrings.autocorrection", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.distances_reduction"] = { description_key = "menu.hotstrings.distances_reduction", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.sfbs_reduction"] = { description_key = "menu.hotstrings.sfbs_reduction", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.rolls"] = { description_key = "menu.hotstrings.rolls", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.magic_key"] = { description_key = "menu.hotstrings.magic_key", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.dynamic"] = { description_key = "menu.hotstrings.dynamic", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["hotstrings.personal"] = { description_key = "menu.hotstrings.personal", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["llm"] = { description_key = "menu.llm", platforms = { "ahk", "hs" }, subsections = { "display", "generation", "models", "profiles", "trigger", "navigation" } },
	["llm.display"] = { description_key = "menu.llm.display", platforms = { "ahk", "hs" }, subsections = {  } },
	["llm.generation"] = { description_key = "menu.llm.generation", platforms = { "ahk", "hs" }, subsections = {  } },
	["llm.models"] = { description_key = "menu.llm.models", platforms = { "ahk", "hs" }, subsections = {  } },
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
	["gestures"] = { description_key = "menu.gestures", platforms = { "ahk", "hs" }, subsections = { "modes", "sensitivities" } },
	["gestures.modes"] = { description_key = "menu.gestures.modes", platforms = { "hs" }, subsections = {  } },
	["gestures.sensitivities"] = { description_key = "menu.gestures.sensitivities", platforms = { "hs" }, subsections = {  } },
}

M.features = {
	{
		path = "hotstrings.trigger_char", id = "trigger_char", section = "hotstrings", default = "★", type = "string", description_key = "menu.hotstrings.trigger_char", platforms = { "ahk", "hs", "linux" },
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
}

return M
