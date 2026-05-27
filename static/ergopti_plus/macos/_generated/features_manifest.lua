--- _generated/features_manifest.lua
--- AUTO-GENERATED from _shared/features/manifest.toml.
--- DO NOT EDIT BY HAND — run `npm run build:manifest` to refresh.

local M = {}

M.version = "2.0.0"

M.section_order = { "script", "hotstrings", "llm", "metrics", "shortcuts", "ahk", "hs" }

M.sections = {
	["script"] = {
		description_key = "menu.script",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["hotstrings"] = {
		description_key = "menu.hotstrings",
		platforms = { "ahk", "hs" },
		subsections = { "autocorrection", "distances_reduction", "sfbs_reduction", "rolls", "magic_key", "dynamic", "personal" }
	},
	["hotstrings.autocorrection"] = {
		description_key = "menu.hotstrings.autocorrection",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["hotstrings.distances_reduction"] = {
		description_key = "menu.hotstrings.distances_reduction",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["hotstrings.sfbs_reduction"] = {
		description_key = "menu.hotstrings.sfbs_reduction",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["hotstrings.rolls"] = {
		description_key = "menu.hotstrings.rolls",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["hotstrings.magic_key"] = {
		description_key = "menu.hotstrings.magic_key",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["hotstrings.dynamic"] = {
		description_key = "menu.hotstrings.dynamic",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["hotstrings.personal"] = {
		description_key = "menu.hotstrings.personal",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["llm"] = {
		description_key = "menu.llm",
		platforms = { "ahk", "hs" },
		subsections = { "display", "generation", "models", "profiles", "trigger", "navigation" }
	},
	["llm.display"] = {
		description_key = "menu.llm.display",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["llm.generation"] = {
		description_key = "menu.llm.generation",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["llm.models"] = {
		description_key = "menu.llm.models",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["llm.profiles"] = {
		description_key = "menu.llm.profiles",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["llm.trigger"] = {
		description_key = "menu.llm.trigger",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["llm.navigation"] = {
		description_key = "menu.llm.navigation",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["metrics"] = {
		description_key = "menu.metrics",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["shortcuts"] = {
		description_key = "menu.shortcuts",
		platforms = { "ahk", "hs" },
		subsections = {  }
	},
	["ahk"] = {
		description_key = "menu.ahk",
		platforms = { "ahk" },
		subsections = { "category_enabled", "layout", "shortcuts", "gestures", "metrics" }
	},
	["ahk.category_enabled"] = {
		description_key = "menu.ahk.category_enabled",
		platforms = { "ahk" },
		subsections = {  }
	},
	["ahk.layout"] = {
		description_key = "menu.layout",
		platforms = { "ahk" },
		subsections = {  }
	},
	["ahk.shortcuts"] = {
		description_key = "menu.ahk.shortcuts",
		platforms = { "ahk" },
		subsections = { "alt_gr_caps_lock", "alt_gr_lalt", "keyboard", "lalt_caps_lock", "personal", "script_control" }
	},
	["ahk.shortcuts.alt_gr_caps_lock"] = {
		description_key = "menu.ahk.shortcuts.alt_gr_caps_lock",
		platforms = { "ahk" },
		subsections = {  }
	},
	["ahk.shortcuts.alt_gr_lalt"] = {
		description_key = "menu.ahk.shortcuts.alt_gr_lalt",
		platforms = { "ahk" },
		subsections = {  }
	},
	["ahk.shortcuts.keyboard"] = {
		description_key = "menu.ahk.shortcuts.keyboard",
		platforms = { "ahk" },
		subsections = {  }
	},
	["ahk.shortcuts.lalt_caps_lock"] = {
		description_key = "menu.ahk.shortcuts.lalt_caps_lock",
		platforms = { "ahk" },
		subsections = {  }
	},
	["ahk.shortcuts.personal"] = {
		description_key = "menu.ahk.shortcuts.personal",
		platforms = { "ahk" },
		subsections = {  }
	},
	["ahk.shortcuts.script_control"] = {
		description_key = "menu.ahk.shortcuts.script_control",
		platforms = { "ahk" },
		subsections = {  }
	},
	["ahk.gestures"] = {
		description_key = "menu.gestures",
		platforms = { "ahk" },
		subsections = {  }
	},
	["ahk.metrics"] = {
		description_key = "menu.ahk.metrics",
		platforms = { "ahk" },
		subsections = {  }
	},
	["hs"] = {
		description_key = "menu.hs",
		platforms = { "hs" },
		subsections = { "gestures", "hotstrings" }
	},
	["hs.gestures"] = {
		description_key = "menu.gestures",
		platforms = { "hs" },
		subsections = { "modes", "sensitivities" }
	},
	["hs.gestures.modes"] = {
		description_key = "menu.hs.gestures.modes",
		platforms = { "hs" },
		subsections = {  }
	},
	["hs.gestures.sensitivities"] = {
		description_key = "menu.hs.gestures.sensitivities",
		platforms = { "hs" },
		subsections = {  }
	},
	["hs.hotstrings"] = {
		description_key = "menu.hs.hotstrings",
		platforms = { "hs" },
		subsections = {  }
	},
}

M.features = {
	{
		path = "script.locale",
		id = "locale",
		section = "script",
		default = "fr",
		type = "string",
		description_key = "menu.script.locale",
		platforms = { "ahk", "hs" }
	},
	{
		path = "script.log_level",
		id = "log_level",
		section = "script",
		default = "INFO",
		type = "enum",
		description_key = "menu.script.log_level",
		platforms = { "ahk", "hs" },
		enum_values = { "DEBUG", "TRACE", "DONE", "INFO", "START", "SUCCESS", "WARNING", "ERROR" }
	},
	{
		path = "hotstrings.trigger_char",
		id = "trigger_char",
		section = "hotstrings",
		default = "★",
		type = "string",
		description_key = "menu.hotstrings.trigger_char",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.autocorrection.accents",
		id = "accents",
		section = "hotstrings.autocorrection",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.autocorrection.accents",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.autocorrection.caps",
		id = "caps",
		section = "hotstrings.autocorrection",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.autocorrection.caps",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.autocorrection.errors",
		id = "errors",
		section = "hotstrings.autocorrection",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.autocorrection.errors",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.autocorrection.minus",
		id = "minus",
		section = "hotstrings.autocorrection",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.autocorrection.minus",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.autocorrection.minus_apostrophe",
		id = "minus_apostrophe",
		section = "hotstrings.autocorrection",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.autocorrection.minus_apostrophe",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.autocorrection.multiple_punctuation_marks",
		id = "multiple_punctuation_marks",
		section = "hotstrings.autocorrection",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.autocorrection.multiple_punctuation_marks",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.autocorrection.names",
		id = "names",
		section = "hotstrings.autocorrection",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.autocorrection.names",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.autocorrection.ou",
		id = "ou",
		section = "hotstrings.autocorrection",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.autocorrection.ou",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.autocorrection.suffixes_a_chaining",
		id = "suffixes_a_chaining",
		section = "hotstrings.autocorrection",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.autocorrection.suffixes_a_chaining",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.autocorrection.typographic_apostrophe",
		id = "typographic_apostrophe",
		section = "hotstrings.autocorrection",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.autocorrection.typographic_apostrophe",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.distances_reduction.qu",
		id = "qu",
		section = "hotstrings.distances_reduction",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.distances_reduction.qu",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.distances_reduction.suffixes_a",
		id = "suffixes_a",
		section = "hotstrings.distances_reduction",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.distances_reduction.suffixes_a",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.distances_reduction.comma_j",
		id = "comma_j",
		section = "hotstrings.distances_reduction",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.distances_reduction.comma_j",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.distances_reduction.comma_far_letters",
		id = "comma_far_letters",
		section = "hotstrings.distances_reduction",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.distances_reduction.comma_far_letters",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.distances_reduction.dead_key_e_circumflex",
		id = "dead_key_e_circumflex",
		section = "hotstrings.distances_reduction",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.distances_reduction.dead_key_e_circumflex",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.distances_reduction.e_circumflex_e",
		id = "e_circumflex_e",
		section = "hotstrings.distances_reduction",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.distances_reduction.e_circumflex_e",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.distances_reduction.space_around_symbols",
		id = "space_around_symbols",
		section = "hotstrings.distances_reduction",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.distances_reduction.space_around_symbols",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.sfbs_reduction.comma",
		id = "comma",
		section = "hotstrings.sfbs_reduction",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.sfbs_reduction.comma",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.sfbs_reduction.e_circ",
		id = "e_circ",
		section = "hotstrings.sfbs_reduction",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.sfbs_reduction.e_circ",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.sfbs_reduction.e_grave",
		id = "e_grave",
		section = "hotstrings.sfbs_reduction",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.sfbs_reduction.e_grave",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.sfbs_reduction.bu",
		id = "bu",
		section = "hotstrings.sfbs_reduction",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.sfbs_reduction.bu",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.sfbs_reduction.i_e_acute",
		id = "i_e_acute",
		section = "hotstrings.sfbs_reduction",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.sfbs_reduction.i_e_acute",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.hc",
		id = "hc",
		section = "hotstrings.rolls",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.hc",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.sx",
		id = "sx",
		section = "hotstrings.rolls",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.sx",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.cx",
		id = "cx",
		section = "hotstrings.rolls",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.cx",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.ct",
		id = "ct",
		section = "hotstrings.rolls",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.ct",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.ez",
		id = "ez",
		section = "hotstrings.rolls",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.ez",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.assign",
		id = "assign",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.assign",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.assign_arrow_equal_left",
		id = "assign_arrow_equal_left",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.assign_arrow_equal_left",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.assign_arrow_equal_right",
		id = "assign_arrow_equal_right",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.assign_arrow_equal_right",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.assign_arrow_minus_left",
		id = "assign_arrow_minus_left",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.assign_arrow_minus_left",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.assign_arrow_minus_right",
		id = "assign_arrow_minus_right",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.assign_arrow_minus_right",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.bracket_quote",
		id = "bracket_quote",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.bracket_quote",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.chevron_equal",
		id = "chevron_equal",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.chevron_equal",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.chevron_greater",
		id = "chevron_greater",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.chevron_greater",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.chevron_less",
		id = "chevron_less",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.chevron_less",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.close_chevron_tag",
		id = "close_chevron_tag",
		section = "hotstrings.rolls",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.close_chevron_tag",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.comment_close",
		id = "comment_close",
		section = "hotstrings.rolls",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.comment_close",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.comment_open",
		id = "comment_open",
		section = "hotstrings.rolls",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.comment_open",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.english_negation",
		id = "english_negation",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.english_negation",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.equal_string",
		id = "equal_string",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.equal_string",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.hashtag_close_bracket",
		id = "hashtag_close_bracket",
		section = "hotstrings.rolls",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.hashtag_close_bracket",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.hashtag_open_bracket",
		id = "hashtag_open_bracket",
		section = "hotstrings.rolls",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.hashtag_open_bracket",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.hashtag_parenthesis",
		id = "hashtag_parenthesis",
		section = "hotstrings.rolls",
		default = {
			enabled = true,
			time_activation_seconds = 0.5
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.hashtag_parenthesis",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.hashtag_quote",
		id = "hashtag_quote",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.hashtag_quote",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.left_arrow",
		id = "left_arrow",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.left_arrow",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.not_equal",
		id = "not_equal",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.not_equal",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.rolls.paren_quote",
		id = "paren_quote",
		section = "hotstrings.rolls",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.rolls.paren_quote",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.magic_key.replace",
		id = "replace",
		section = "hotstrings.magic_key",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.magic_key.replace",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.magic_key.repeat_corrections",
		id = "repeat_corrections",
		section = "hotstrings.magic_key",
		default = {
			enabled = true,
			time_activation_seconds = 2
		},
		type = "feature",
		description_key = "menu.hotstrings.magic_key.repeat_corrections",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.magic_key.text_expansion",
		id = "text_expansion",
		section = "hotstrings.magic_key",
		default = {
			enabled = true,
			time_activation_seconds = 2
		},
		type = "feature",
		description_key = "menu.hotstrings.magic_key.text_expansion",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.magic_key.text_expansion_auto",
		id = "text_expansion_auto",
		section = "hotstrings.magic_key",
		default = {
			enabled = true,
			time_activation_seconds = 2
		},
		type = "feature",
		description_key = "menu.hotstrings.magic_key.text_expansion_auto",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.magic_key.text_expansion_emojis",
		id = "text_expansion_emojis",
		section = "hotstrings.magic_key",
		default = {
			enabled = true,
			time_activation_seconds = 2
		},
		type = "feature",
		description_key = "menu.hotstrings.magic_key.text_expansion_emojis",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.magic_key.text_expansion_symbols",
		id = "text_expansion_symbols",
		section = "hotstrings.magic_key",
		default = {
			enabled = true,
			time_activation_seconds = 2
		},
		type = "feature",
		description_key = "menu.hotstrings.magic_key.text_expansion_symbols",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.magic_key.text_expansion_symbols_typst",
		id = "text_expansion_symbols_typst",
		section = "hotstrings.magic_key",
		default = {
			enabled = true,
			time_activation_seconds = 2
		},
		type = "feature",
		description_key = "menu.hotstrings.magic_key.text_expansion_symbols_typst",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.dynamic.date",
		id = "date",
		section = "hotstrings.dynamic",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.dynamic.date",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.dynamic.date_fr",
		id = "date_fr",
		section = "hotstrings.dynamic",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.dynamic.date_fr",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.dynamic.date_long_fr",
		id = "date_long_fr",
		section = "hotstrings.dynamic",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.dynamic.date_long_fr",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.dynamic.iban_prefixes",
		id = "iban_prefixes",
		section = "hotstrings.dynamic",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.dynamic.iban_prefixes",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.dynamic.phone_prefixes",
		id = "phone_prefixes",
		section = "hotstrings.dynamic",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.dynamic.phone_prefixes",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.dynamic.ssn_prefixes",
		id = "ssn_prefixes",
		section = "hotstrings.dynamic",
		default = {
			enabled = true
		},
		type = "feature",
		description_key = "menu.hotstrings.dynamic.ssn_prefixes",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.dynamic.text_expansion_personal_information",
		id = "text_expansion_personal_information",
		section = "hotstrings.dynamic",
		default = {
			enabled = true,
			pattern_max_length = 1
		},
		type = "feature",
		description_key = "menu.hotstrings.dynamic.text_expansion_personal_information",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.personal.autocorrection",
		id = "autocorrection",
		section = "hotstrings.personal",
		default = {
			enabled = true,
			time_activation_seconds = 0.75
		},
		type = "feature",
		description_key = "menu.hotstrings.personal.autocorrection",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.personal.code",
		id = "code",
		section = "hotstrings.personal",
		default = {
			enabled = true,
			time_activation_seconds = 0.75
		},
		type = "feature",
		description_key = "menu.hotstrings.personal.code",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.personal.email_shortcuts",
		id = "email_shortcuts",
		section = "hotstrings.personal",
		default = {
			enabled = true,
			time_activation_seconds = 0.75
		},
		type = "feature",
		description_key = "menu.hotstrings.personal.email_shortcuts",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.personal.professional_vocabulary",
		id = "professional_vocabulary",
		section = "hotstrings.personal",
		default = {
			enabled = true,
			time_activation_seconds = 0.75
		},
		type = "feature",
		description_key = "menu.hotstrings.personal.professional_vocabulary",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hotstrings.personal.test",
		id = "test",
		section = "hotstrings.personal",
		default = {
			enabled = true,
			time_activation_seconds = 0.75
		},
		type = "feature",
		description_key = "menu.hotstrings.personal.test",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.enabled",
		id = "enabled",
		section = "llm",
		default = false,
		type = "boolean",
		description_key = "menu.llm.enabled",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.display.pred_indent",
		id = "pred_indent",
		section = "llm.display",
		default = 0,
		type = "number",
		description_key = "menu.llm.display.pred_indent",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.display.show_info_bar",
		id = "show_info_bar",
		section = "llm.display",
		default = true,
		type = "boolean",
		description_key = "menu.llm.display.show_info_bar",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.display.streaming",
		id = "streaming",
		section = "llm.display",
		default = true,
		type = "boolean",
		description_key = "menu.llm.display.streaming",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.display.streaming_multi",
		id = "streaming_multi",
		section = "llm.display",
		default = true,
		type = "boolean",
		description_key = "menu.llm.display.streaming_multi",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.generation.context_length",
		id = "context_length",
		section = "llm.generation",
		default = 500,
		type = "number",
		description_key = "menu.llm.generation.context_length",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.generation.min_words",
		id = "min_words",
		section = "llm.generation",
		default = 3,
		type = "number",
		description_key = "menu.llm.generation.min_words",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.generation.max_words",
		id = "max_words",
		section = "llm.generation",
		default = 15,
		type = "number",
		description_key = "menu.llm.generation.max_words",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.generation.temperature",
		id = "temperature",
		section = "llm.generation",
		default = 0.1,
		type = "number",
		description_key = "menu.llm.generation.temperature",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.generation.auto_raise_temp",
		id = "auto_raise_temp",
		section = "llm.generation",
		default = true,
		type = "boolean",
		description_key = "menu.llm.generation.auto_raise_temp",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.generation.reset_on_nav",
		id = "reset_on_nav",
		section = "llm.generation",
		default = true,
		type = "boolean",
		description_key = "menu.llm.generation.reset_on_nav",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.generation.sequential_mode",
		id = "sequential_mode",
		section = "llm.generation",
		default = false,
		type = "boolean",
		description_key = "menu.llm.generation.sequential_mode",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.models.selected",
		id = "selected",
		section = "llm.models",
		default = "mlx",
		type = "string",
		description_key = "menu.llm.models.selected",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.models.ollama",
		id = "ollama",
		section = "llm.models",
		default = "gemma-4-E2B-it",
		type = "string",
		description_key = "menu.llm.models.ollama",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.models.mlx",
		id = "mlx",
		section = "llm.models",
		default = "Qwen3.5-2B",
		type = "string",
		description_key = "menu.llm.models.mlx",
		platforms = { "hs" }
	},
	{
		path = "llm.profiles.active",
		id = "active",
		section = "llm.profiles",
		default = "basic",
		type = "string",
		description_key = "menu.llm.profiles.active",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.profiles.num_predictions",
		id = "num_predictions",
		section = "llm.profiles",
		default = 3,
		type = "number",
		description_key = "menu.llm.profiles.num_predictions",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.profiles.auto_profile_for_model",
		id = "auto_profile_for_model",
		section = "llm.profiles",
		default = true,
		type = "boolean",
		description_key = "menu.llm.profiles.auto_profile_for_model",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.trigger.debounce_ms",
		id = "debounce_ms",
		section = "llm.trigger",
		default = 200,
		type = "number",
		description_key = "menu.llm.trigger.debounce_ms",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.trigger.instant_on_word_end",
		id = "instant_on_word_end",
		section = "llm.trigger",
		default = true,
		type = "boolean",
		description_key = "menu.llm.trigger.instant_on_word_end",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.trigger.after_hotstring",
		id = "after_hotstring",
		section = "llm.trigger",
		default = true,
		type = "boolean",
		description_key = "menu.llm.trigger.after_hotstring",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.trigger.secure_filter_enabled",
		id = "secure_filter_enabled",
		section = "llm.trigger",
		default = true,
		type = "boolean",
		description_key = "menu.llm.trigger.secure_filter_enabled",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.trigger.url_bar_filter_enabled",
		id = "url_bar_filter_enabled",
		section = "llm.trigger",
		default = true,
		type = "boolean",
		description_key = "menu.llm.trigger.url_bar_filter_enabled",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.trigger.shortcut",
		id = "shortcut",
		section = "llm.trigger",
		default = false,
		type = "boolean",
		description_key = "menu.llm.trigger.shortcut",
		platforms = { "hs" }
	},
	{
		path = "llm.navigation.val_modifiers",
		id = "val_modifiers",
		section = "llm.navigation",
		default = { "alt" },
		type = "array",
		description_key = "menu.llm.navigation.val_modifiers",
		platforms = { "ahk", "hs" }
	},
	{
		path = "llm.navigation.arrow_nav_enabled",
		id = "arrow_nav_enabled",
		section = "llm.navigation",
		default = false,
		type = "boolean",
		description_key = "menu.llm.navigation.arrow_nav_enabled",
		platforms = { "hs" }
	},
	{
		path = "metrics.enabled",
		id = "enabled",
		section = "metrics",
		default = true,
		type = "boolean",
		description_key = "menu.metrics.enabled",
		platforms = { "ahk", "hs" }
	},
	{
		path = "metrics.private_filter_enabled",
		id = "private_filter_enabled",
		section = "metrics",
		default = true,
		type = "boolean",
		description_key = "menu.metrics.private_filter_enabled",
		platforms = { "ahk", "hs" }
	},
	{
		path = "metrics.secure_filter_enabled",
		id = "secure_filter_enabled",
		section = "metrics",
		default = true,
		type = "boolean",
		description_key = "menu.metrics.secure_filter_enabled",
		platforms = { "ahk", "hs" }
	},
	{
		path = "metrics.system_auth_filter_enabled",
		id = "system_auth_filter_enabled",
		section = "metrics",
		default = true,
		type = "boolean",
		description_key = "menu.metrics.system_auth_filter_enabled",
		platforms = { "ahk", "hs" }
	},
	{
		path = "metrics.encrypt",
		id = "encrypt",
		section = "metrics",
		default = false,
		type = "boolean",
		description_key = "menu.metrics.encrypt",
		platforms = { "hs" }
	},
	{
		path = "shortcuts.enabled",
		id = "enabled",
		section = "shortcuts",
		default = true,
		type = "boolean",
		description_key = "menu.shortcuts.enabled",
		platforms = { "hs" }
	},
	{
		path = "shortcuts.chatgpt_url",
		id = "chatgpt_url",
		section = "shortcuts",
		default = "https://chat.openai.com",
		type = "string",
		description_key = "menu.shortcuts.chatgpt_url",
		platforms = { "ahk", "hs" }
	},
	{
		path = "hs.gestures.enabled",
		id = "enabled",
		section = "hs.gestures",
		default = true,
		type = "boolean",
		description_key = "menu.gestures.enabled",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.space_wrap",
		id = "space_wrap",
		section = "hs.gestures",
		default = true,
		type = "boolean",
		description_key = "menu.gestures.space_wrap",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_2_left",
		id = "swipe_2_left",
		section = "hs.gestures",
		default = "arrow_up",
		type = "action",
		description_key = "menu.gestures.swipe_2_left",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_3_left",
		id = "swipe_3_left",
		section = "hs.gestures",
		default = "word_prev",
		type = "action",
		description_key = "menu.gestures.swipe_3_left",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_3_right",
		id = "swipe_3_right",
		section = "hs.gestures",
		default = "word_next",
		type = "action",
		description_key = "menu.gestures.swipe_3_right",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_3_up",
		id = "swipe_3_up",
		section = "hs.gestures",
		default = "tab_prev",
		type = "action",
		description_key = "menu.gestures.swipe_3_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_3_down",
		id = "swipe_3_down",
		section = "hs.gestures",
		default = "tab_next",
		type = "action",
		description_key = "menu.gestures.swipe_3_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_4_up",
		id = "swipe_4_up",
		section = "hs.gestures",
		default = "mission_control",
		type = "action",
		description_key = "menu.gestures.swipe_4_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_4_down",
		id = "swipe_4_down",
		section = "hs.gestures",
		default = "app_expose",
		type = "action",
		description_key = "menu.gestures.swipe_4_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_4_left",
		id = "swipe_4_left",
		section = "hs.gestures",
		default = "space_next",
		type = "action",
		description_key = "menu.gestures.swipe_4_left",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_4_right",
		id = "swipe_4_right",
		section = "hs.gestures",
		default = "space_prev",
		type = "action",
		description_key = "menu.gestures.swipe_4_right",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_5_up",
		id = "swipe_5_up",
		section = "hs.gestures",
		default = "doc_start",
		type = "action",
		description_key = "menu.gestures.swipe_5_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_5_down",
		id = "swipe_5_down",
		section = "hs.gestures",
		default = "doc_end",
		type = "action",
		description_key = "menu.gestures.swipe_5_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_5_left",
		id = "swipe_5_left",
		section = "hs.gestures",
		default = "win_prev",
		type = "action",
		description_key = "menu.gestures.swipe_5_left",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_5_right",
		id = "swipe_5_right",
		section = "hs.gestures",
		default = "win_next",
		type = "action",
		description_key = "menu.gestures.swipe_5_right",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.tap_3",
		id = "tap_3",
		section = "hs.gestures",
		default = "left_click_toggle",
		type = "action",
		description_key = "menu.gestures.tap_3",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.tap_4",
		id = "tap_4",
		section = "hs.gestures",
		default = "app_window_previous",
		type = "action",
		description_key = "menu.gestures.tap_4",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_2_right",
		id = "swipe_2_right",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_2_right",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_2_up",
		id = "swipe_2_up",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_2_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_2_down",
		id = "swipe_2_down",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_2_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_2_left_down",
		id = "swipe_2_left_down",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_2_left_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_2_left_up",
		id = "swipe_2_left_up",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_2_left_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_2_right_down",
		id = "swipe_2_right_down",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_2_right_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_2_right_up",
		id = "swipe_2_right_up",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_2_right_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_2_diag",
		id = "swipe_2_diag",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_2_diag",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_3_left_down",
		id = "swipe_3_left_down",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_3_left_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_3_left_up",
		id = "swipe_3_left_up",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_3_left_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_3_right_down",
		id = "swipe_3_right_down",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_3_right_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_3_right_up",
		id = "swipe_3_right_up",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_3_right_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_3_diag",
		id = "swipe_3_diag",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_3_diag",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_3_horiz",
		id = "swipe_3_horiz",
		section = "hs.gestures",
		default = "words",
		type = "action",
		description_key = "menu.gestures.swipe_3_horiz",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_4_left_down",
		id = "swipe_4_left_down",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_4_left_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_4_left_up",
		id = "swipe_4_left_up",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_4_left_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_4_right_down",
		id = "swipe_4_right_down",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_4_right_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_4_right_up",
		id = "swipe_4_right_up",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_4_right_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_4_diag",
		id = "swipe_4_diag",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_4_diag",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_4_horiz",
		id = "swipe_4_horiz",
		section = "hs.gestures",
		default = "spaces",
		type = "action",
		description_key = "menu.gestures.swipe_4_horiz",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_5_left_down",
		id = "swipe_5_left_down",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_5_left_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_5_left_up",
		id = "swipe_5_left_up",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_5_left_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_5_right_down",
		id = "swipe_5_right_down",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_5_right_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_5_right_up",
		id = "swipe_5_right_up",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_5_right_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_5_diag",
		id = "swipe_5_diag",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.swipe_5_diag",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.swipe_5_horiz",
		id = "swipe_5_horiz",
		section = "hs.gestures",
		default = "windows",
		type = "action",
		description_key = "menu.gestures.swipe_5_horiz",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.tap_2",
		id = "tap_2",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.tap_2",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.tap_5",
		id = "tap_5",
		section = "hs.gestures",
		default = "none",
		type = "action",
		description_key = "menu.gestures.tap_5",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.modes.swipe_2_left",
		id = "swipe_2_left",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_2_left",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_2_right",
		id = "swipe_2_right",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_2_right",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_2_up",
		id = "swipe_2_up",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_2_up",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_2_down",
		id = "swipe_2_down",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_2_down",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_2_left_down",
		id = "swipe_2_left_down",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_2_left_down",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_2_left_up",
		id = "swipe_2_left_up",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_2_left_up",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_2_right_down",
		id = "swipe_2_right_down",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_2_right_down",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_2_right_up",
		id = "swipe_2_right_up",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_2_right_up",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_3_left",
		id = "swipe_3_left",
		section = "hs.gestures.modes",
		default = "incremental",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_3_left",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_3_right",
		id = "swipe_3_right",
		section = "hs.gestures.modes",
		default = "incremental",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_3_right",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_3_up",
		id = "swipe_3_up",
		section = "hs.gestures.modes",
		default = "incremental",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_3_up",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_3_down",
		id = "swipe_3_down",
		section = "hs.gestures.modes",
		default = "incremental",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_3_down",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_3_left_down",
		id = "swipe_3_left_down",
		section = "hs.gestures.modes",
		default = "incremental",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_3_left_down",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_3_left_up",
		id = "swipe_3_left_up",
		section = "hs.gestures.modes",
		default = "incremental",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_3_left_up",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_3_right_down",
		id = "swipe_3_right_down",
		section = "hs.gestures.modes",
		default = "incremental",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_3_right_down",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_3_right_up",
		id = "swipe_3_right_up",
		section = "hs.gestures.modes",
		default = "incremental",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_3_right_up",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_4_left",
		id = "swipe_4_left",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_4_left",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_4_right",
		id = "swipe_4_right",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_4_right",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_4_up",
		id = "swipe_4_up",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_4_up",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_4_down",
		id = "swipe_4_down",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_4_down",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_4_left_down",
		id = "swipe_4_left_down",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_4_left_down",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_4_left_up",
		id = "swipe_4_left_up",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_4_left_up",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_4_right_down",
		id = "swipe_4_right_down",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_4_right_down",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_4_right_up",
		id = "swipe_4_right_up",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_4_right_up",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_5_left",
		id = "swipe_5_left",
		section = "hs.gestures.modes",
		default = "incremental",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_5_left",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_5_right",
		id = "swipe_5_right",
		section = "hs.gestures.modes",
		default = "incremental",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_5_right",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_5_up",
		id = "swipe_5_up",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_5_up",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_5_down",
		id = "swipe_5_down",
		section = "hs.gestures.modes",
		default = "x1",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_5_down",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_5_left_down",
		id = "swipe_5_left_down",
		section = "hs.gestures.modes",
		default = "incremental",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_5_left_down",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_5_left_up",
		id = "swipe_5_left_up",
		section = "hs.gestures.modes",
		default = "incremental",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_5_left_up",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_5_right_down",
		id = "swipe_5_right_down",
		section = "hs.gestures.modes",
		default = "incremental",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_5_right_down",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.modes.swipe_5_right_up",
		id = "swipe_5_right_up",
		section = "hs.gestures.modes",
		default = "incremental",
		type = "enum",
		description_key = "menu.hs.gestures.modes.swipe_5_right_up",
		platforms = { "hs" },
		enum_values = { "x1", "incremental" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_2_left",
		id = "swipe_2_left",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_2_left",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_2_right",
		id = "swipe_2_right",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_2_right",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_2_up",
		id = "swipe_2_up",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_2_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_2_down",
		id = "swipe_2_down",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_2_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_2_left_down",
		id = "swipe_2_left_down",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_2_left_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_2_left_up",
		id = "swipe_2_left_up",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_2_left_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_2_right_down",
		id = "swipe_2_right_down",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_2_right_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_2_right_up",
		id = "swipe_2_right_up",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_2_right_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_3_left",
		id = "swipe_3_left",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_3_left",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_3_right",
		id = "swipe_3_right",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_3_right",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_3_up",
		id = "swipe_3_up",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_3_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_3_down",
		id = "swipe_3_down",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_3_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_3_left_down",
		id = "swipe_3_left_down",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_3_left_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_3_left_up",
		id = "swipe_3_left_up",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_3_left_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_3_right_down",
		id = "swipe_3_right_down",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_3_right_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_3_right_up",
		id = "swipe_3_right_up",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_3_right_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_4_left",
		id = "swipe_4_left",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_4_left",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_4_right",
		id = "swipe_4_right",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_4_right",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_4_up",
		id = "swipe_4_up",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_4_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_4_down",
		id = "swipe_4_down",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_4_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_4_left_down",
		id = "swipe_4_left_down",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_4_left_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_4_left_up",
		id = "swipe_4_left_up",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_4_left_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_4_right_down",
		id = "swipe_4_right_down",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_4_right_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_4_right_up",
		id = "swipe_4_right_up",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_4_right_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_5_left",
		id = "swipe_5_left",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_5_left",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_5_right",
		id = "swipe_5_right",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_5_right",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_5_up",
		id = "swipe_5_up",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_5_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_5_down",
		id = "swipe_5_down",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_5_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_5_left_down",
		id = "swipe_5_left_down",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_5_left_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_5_left_up",
		id = "swipe_5_left_up",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_5_left_up",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_5_right_down",
		id = "swipe_5_right_down",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_5_right_down",
		platforms = { "hs" }
	},
	{
		path = "hs.gestures.sensitivities.swipe_5_right_up",
		id = "swipe_5_right_up",
		section = "hs.gestures.sensitivities",
		default = 3.5,
		type = "number",
		description_key = "menu.hs.gestures.sensitivities.swipe_5_right_up",
		platforms = { "hs" }
	},
	{
		path = "hs.hotstrings.expansion_delay",
		id = "expansion_delay",
		section = "hs.hotstrings",
		default = 0.75,
		type = "number",
		description_key = "menu.hs.hotstrings.expansion_delay",
		platforms = { "hs" }
	},
	{
		path = "hs.hotstrings.preview_ai_enabled",
		id = "preview_ai_enabled",
		section = "hs.hotstrings",
		default = true,
		type = "boolean",
		description_key = "menu.hs.hotstrings.preview_ai_enabled",
		platforms = { "hs" }
	},
	{
		path = "hs.hotstrings.preview_autocorrect_enabled",
		id = "preview_autocorrect_enabled",
		section = "hs.hotstrings",
		default = true,
		type = "boolean",
		description_key = "menu.hs.hotstrings.preview_autocorrect_enabled",
		platforms = { "hs" }
	},
	{
		path = "hs.hotstrings.preview_colored_tooltips",
		id = "preview_colored_tooltips",
		section = "hs.hotstrings",
		default = true,
		type = "boolean",
		description_key = "menu.hs.hotstrings.preview_colored_tooltips",
		platforms = { "hs" }
	},
	{
		path = "hs.hotstrings.preview_star_enabled",
		id = "preview_star_enabled",
		section = "hs.hotstrings",
		default = true,
		type = "boolean",
		description_key = "menu.hs.hotstrings.preview_star_enabled",
		platforms = { "hs" }
	},
}

return M
