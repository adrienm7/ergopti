--- tests/unit/infra/preferences/test_preferences_enum_case.lua

--- ==============================================================================
--- MODULE: Enum Settings Written in Another Case
--- DESCRIPTION:
--- Windows' loader admits a case variant of every enum and keeps the manifest
--- spelling (TomlConfigValueMatchesManifest). The macOS preference loader
--- compared exactly: `agent_mode = "Auto"` or a gesture mode `"X1"` was
--- reported outdated, read as its default and offered for deletion
--- (config-enum-case).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("preferences: enum case variants", function()
	helpers.it("(config-enum-case) a case variant reads in its manifest spelling, never as outdated", function()
		helpers.with_fresh_modules({ "core.logger.engine.shim", "settings.engine.migration.outdated", "infra.preferences" }, function()
			local warnings = {}
			local shim = helpers.make_logger_stub()
			shim.warn = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end
			package.loaded["core.logger.engine.shim"] = shim
			helpers.load_with_stubs("settings.engine.migration.outdated")
			local Preferences = helpers.load_with_stubs("infra.preferences")
			local TomlCodec = require("core.text.engine.toml_codec")
			local source = table.concat({
				"[llm]",
				'agent_mode = "Auto"',
				"[llm.trigger]",
				'while_hotstring_tooltip = "BOTH"',
				"[hotstrings]",
				'magic_key_source = "semicolon"',
				"[layout]",
				'virtual_keyboard = "ISO"',
				"[ui]",
				'menubar_icon = "V2"',
				"[gestures.modes]",
				'swipe_3_left = "X1"',
				"",
			}, "\n")
			local flat = Preferences.flatten_document(TomlCodec.decode(source))
			helpers.assert_eq(warnings, {}, "a case variant is not outdated configuration")
			helpers.assert_eq(flat.llm_agent_mode, "auto")
			helpers.assert_eq(flat.llm_while_hotstring_tooltip, "both")
			helpers.assert_eq(flat.magic_key_source, "Semicolon")
			helpers.assert_eq(flat.layout_virtual_keyboard, "iso")
			helpers.assert_eq(flat.menubar_icon, "v2")
			helpers.assert_eq(flat.gesture_modes and flat.gesture_modes.swipe_3_left, "x1")
			local scan = require("settings.engine.migration.unused_keys").find_in_source(source, Preferences.mark_config_reads)
			helpers.assert_eq(#scan.keys, 0, "the cleanup offers none of them")
		end)
	end)
end)
