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

M.section_order = { "script", "hotstrings", "llm", "metrics", "shortcuts", "ahk", "hs" }

M.sections = {
	["script"] = { description_key = "menu.script", platforms = { "ahk", "hs" }, subsections = {  } },
	["hotstrings"] = { description_key = "menu.hotstrings", platforms = { "ahk", "hs" }, subsections = { "autocorrection", "distances_reduction", "sfbs_reduction", "rolls", "magic_key", "dynamic", "personal" } },
	["hotstrings.autocorrection"] = { description_key = "menu.hotstrings.autocorrection", platforms = { "ahk", "hs" }, subsections = {  } },
	["hotstrings.distances_reduction"] = { description_key = "menu.hotstrings.distances_reduction", platforms = { "ahk", "hs" }, subsections = {  } },
	["hotstrings.sfbs_reduction"] = { description_key = "menu.hotstrings.sfbs_reduction", platforms = { "ahk", "hs" }, subsections = {  } },
	["hotstrings.rolls"] = { description_key = "menu.hotstrings.rolls", platforms = { "ahk", "hs" }, subsections = {  } },
	["hotstrings.magic_key"] = { description_key = "menu.hotstrings.magic_key", platforms = { "ahk", "hs" }, subsections = {  } },
	["hotstrings.dynamic"] = { description_key = "menu.hotstrings.dynamic", platforms = { "ahk", "hs" }, subsections = {  } },
	["hotstrings.personal"] = { description_key = "menu.hotstrings.personal", platforms = { "ahk", "hs" }, subsections = {  } },
	["llm"] = { description_key = "menu.llm", platforms = { "ahk", "hs" }, subsections = { "display", "generation", "models", "profiles", "trigger", "navigation" } },
	["llm.display"] = { description_key = "menu.llm.display", platforms = { "ahk", "hs" }, subsections = {  } },
	["llm.generation"] = { description_key = "menu.llm.generation", platforms = { "ahk", "hs" }, subsections = {  } },
	["llm.models"] = { description_key = "menu.llm.models", platforms = { "ahk", "hs" }, subsections = {  } },
	["llm.profiles"] = { description_key = "menu.llm.profiles", platforms = { "ahk", "hs" }, subsections = {  } },
	["llm.trigger"] = { description_key = "menu.llm.trigger", platforms = { "ahk", "hs" }, subsections = {  } },
	["llm.navigation"] = { description_key = "menu.llm.navigation", platforms = { "ahk", "hs" }, subsections = {  } },
	["metrics"] = { description_key = "menu.metrics", platforms = { "ahk", "hs", "linux" }, subsections = {  } },
	["shortcuts"] = { description_key = "menu.shortcuts", platforms = { "ahk", "hs" }, subsections = {  } },
	["ahk"] = { description_key = "menu.ahk", platforms = { "ahk" }, subsections = { "category_enabled", "layout", "shortcuts", "gestures", "metrics" } },
	["ahk.category_enabled"] = { description_key = "menu.ahk.category_enabled", platforms = { "ahk" }, subsections = {  } },
	["ahk.layout"] = { description_key = "menu.layout", platforms = { "ahk" }, subsections = {  } },
	["ahk.shortcuts"] = { description_key = "menu.ahk.shortcuts", platforms = { "ahk" }, subsections = { "alt_gr_caps_lock", "alt_gr_lalt", "keyboard", "lalt_caps_lock", "personal", "script_control" } },
	["ahk.shortcuts.alt_gr_caps_lock"] = { description_key = "menu.ahk.shortcuts.alt_gr_caps_lock", platforms = { "ahk" }, subsections = {  } },
	["ahk.shortcuts.alt_gr_lalt"] = { description_key = "menu.ahk.shortcuts.alt_gr_lalt", platforms = { "ahk" }, subsections = {  } },
	["ahk.shortcuts.keyboard"] = { description_key = "menu.ahk.shortcuts.keyboard", platforms = { "ahk" }, subsections = {  } },
	["ahk.shortcuts.lalt_caps_lock"] = { description_key = "menu.ahk.shortcuts.lalt_caps_lock", platforms = { "ahk" }, subsections = {  } },
	["ahk.shortcuts.personal"] = { description_key = "menu.ahk.shortcuts.personal", platforms = { "ahk" }, subsections = {  } },
	["ahk.shortcuts.script_control"] = { description_key = "menu.ahk.shortcuts.script_control", platforms = { "ahk" }, subsections = {  } },
	["ahk.gestures"] = { description_key = "menu.gestures", platforms = { "ahk" }, subsections = {  } },
	["ahk.metrics"] = { description_key = "menu.ahk.metrics", platforms = { "ahk" }, subsections = {  } },
	["hs"] = { description_key = "menu.hs", platforms = { "hs" }, subsections = { "gestures", "hotstrings" } },
	["hs.gestures"] = { description_key = "menu.gestures", platforms = { "hs" }, subsections = { "modes", "sensitivities" } },
	["hs.gestures.modes"] = { description_key = "menu.hs.gestures.modes", platforms = { "hs" }, subsections = {  } },
	["hs.gestures.sensitivities"] = { description_key = "menu.hs.gestures.sensitivities", platforms = { "hs" }, subsections = {  } },
	["hs.hotstrings"] = { description_key = "menu.hs.hotstrings", platforms = { "hs" }, subsections = {  } },
}

M.features = {
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
